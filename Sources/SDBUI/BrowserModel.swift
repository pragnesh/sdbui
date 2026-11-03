import ADBCKit
import Foundation
import SwiftCrossUI

#if canImport(Observation)
    import Observation
#endif

/// The tabs of the main window, as in Sequel Ace's toolbar.
enum BrowserTab: String, CaseIterable, Hashable {
    /// The SQL editor and results; clicking a table browses it here.
    case query = "Query"
    case structure = "Structure"
    case info = "Table Info"
}

/// All state for one connection tab.
///
/// ADBC calls block, so they run on detached tasks; results are applied back
/// on the main actor.
///
/// Only rarely-changing state (profiles, the connection, the table list, the
/// selected database) is `@Observable`. SwiftCrossUI's observation merges
/// child views' reads into their ancestors, so changing an observed property
/// re-renders and re-lays-out the whole window. Everything that changes per
/// table, tab or query is `@ObservationIgnored`; views that show it subscribe
/// with ``watch(_:of:_:)`` and redraw on their own, only when what they show
/// changed.
@Observable
@MainActor
final class BrowserModel {
    // MARK: Connection setup

    var profiles: [ConnectionProfile] = []
    var drivers: [DriverManifest] = []
    var selectedProfileID: String?
    var directDriver: DriverManifest?
    var directURI = ""
    var connectionDraft = ConnectionDraft()
    var connectionFeedback = ""

    // MARK: Connection state

    var connection: ADBCConnection?
    var connectionTitle = ""
    private(set) var connectionSafety = FavoriteSafety()
    @ObservationIgnored private(set) var pendingQuery: PendingQuery? { didSet { stateChanged() } }

    struct PendingQuery {
        let statements: [SQLStatement]
        let sourceSQL: String
        let baseOffset: Int
        let revision: Int
        let warnings: [String]
        var sql: String { statements.map(\.text).joined(separator: ";\n") }
    }
    var isConnecting = false
    private(set) var isConnectionLost = false
    /// An unknown SSH host key waiting for the user to verify and trust it.
    private(set) var hostKeyPrompt: SSHHostKeyScan?
    /// What to repeat once the host key is trusted.
    @ObservationIgnored private var hostKeyRetry: HostKeyRetry?

    private enum HostKeyRetry {
        case test
        case connect(ConnectionSource, title: String, safety: FavoriteSafety, favoriteID: String?, reconnecting: Bool)
    }
    @ObservationIgnored private var reconnectSource: ConnectionSource?
    @ObservationIgnored private var sessionRevision = 0
    @ObservationIgnored private var connectionMonitor: Task<Void, Never>?
    @ObservationIgnored private let openConnection: @Sendable (ConnectionSource) throws -> ADBCConnection
    @ObservationIgnored private let healthCheckIntervalNanoseconds: UInt64

    init(
        openConnection: @escaping @Sendable (ConnectionSource) throws -> ADBCConnection = { try ADBCConnection.open($0) },
        healthCheckIntervalNanoseconds: UInt64 = 5_000_000_000,
        queryLibrary: QueryLibraryStore = QueryLibraryStore(),
        preferences: AppPreferences = AppPreferences()
    ) {
        self.openConnection = openConnection
        self.queryLibrary = queryLibrary
        self.libraryFeedback = queryLibrary.loadError ?? ""
        self.healthCheckIntervalNanoseconds = healthCheckIntervalNanoseconds
        self.pageSize = preferences.pageSize; self.queryFontSize = Double(preferences.fontSize); self.maxRows = preferences.rowLimit
    }

    @ObservationIgnored private(set) var queryFontSize = 13.0 { didSet { stateChanged() } }

    func applyPreferences(_ preferences: AppPreferences, refresh: Bool = true) {
        guard preferences.isValid, !isRunning, !isConnecting else { return }
        let resized = pageSize != preferences.pageSize
        pageSize = preferences.pageSize; queryFontSize = Double(preferences.fontSize); maxRows = preferences.rowLimit
        if resized {
            contentOffset = 0; contentHasMore = false
            if refresh, isBrowsing, let table = selectedTable { loadContent(table) }
        }
    }

    func adjustQueryFontSize(by delta: Int) {
        queryFontSize = min(28, max(9, queryFontSize + Double(delta)))
        sessionDidChange?()
    }

    func flushTableFilter() {
        tableFilterTask?.cancel()
        tableFilterTask = nil
    }

    func refreshActiveView() {
        guard canUseConnection, !isRunning else { return }
        refreshTables()
        contentTotal = nil
        rowEstimates = [:]
        loadedTables = [:]
        if selectedTab == .query, isBrowsing, let table = selectedTable { loadContent(table) }
        else { loadCurrentTab() }
    }

    @ObservationIgnored var sessionDidChange: (@MainActor () -> Void)?
    @ObservationIgnored private var editorBaselineSQL: String? = "" { didSet { stateChanged() } }
    @ObservationIgnored private(set) var sidebarWidth = 290
    @ObservationIgnored private(set) var restorableProfileID: String?
    @ObservationIgnored private var pendingSessionRestore: SessionTabState?
    var activeSQLIsDirty: Bool { editorBaselineSQL.map { $0 != sql } ?? true }
    var hasUnsavedSQL: Bool { activeSQLIsDirty || queryDocuments.enumerated().contains { $0.offset != selectedQueryIndex && $0.element.dirty } }

    func updateSidebarWidth(_ width: Int) {
        guard (180...4000).contains(width), width != sidebarWidth else { return }
        sidebarWidth = width
        sessionDidChange?()
    }

    var sessionState: SessionTabState {
        SessionTabState(favoriteID: restorableProfileID, sql: sql, dirty: hasUnsavedSQL,
            database: pendingSessionRestore?.database ?? selectedDatabase,
            table: pendingSessionRestore?.table ?? selectedTable.map { SessionTableState(catalog: $0.catalog, schema: $0.schema, name: $0.name) },
            pane: pendingSessionRestore?.pane ?? selectedTab.rawValue, fontSize: queryFontSize, sidebarWidth: sidebarWidth,
            queries: queryDrafts, selectedQueryID: activeQueryDocument.id)
    }

    func restoreSession(_ state: SessionTabState) {
        pendingSessionRestore = state
        restorableProfileID = state.favoriteID
        if let queries = state.queries, !queries.isEmpty {
            queryDocuments = queries.map { draft in
                let document = QueryDocument(id: draft.id, name: draft.name, pane: makePane())
                document.sql = draft.sql
                document.baseline = draft.dirty ? nil : draft.sql
                return document
            }
            selectedQueryIndex = queryDocuments.firstIndex { $0.id == state.selectedQueryID } ?? 0
            setSQL(activeQueryDocument.sql)
            editorBaselineSQL = activeQueryDocument.baseline
        } else {
            setSQL(state.sql)
            editorBaselineSQL = state.dirty ? nil : state.sql
        }
        queryFontSize = state.fontSize
        sidebarWidth = state.sidebarWidth
        guard let id = state.favoriteID else {
            connectionFeedback = "SQL restored. Choose connection settings to reconnect this tab."
            return
        }
        guard profiles.contains(where: { $0.id == id }) else {
            connectionFeedback = "Saved favorite '\(id)' was not found. SQL was restored; choose a connection to continue."
            return
        }
        selectFavorite(id)
        connectSelectedProfile()
    }

    var canUseConnection: Bool { connection != nil && !isConnectionLost && !isConnecting }


    // MARK: Schema

    var tables: [TableInfo] = []
    /// The database (MySQL) or schema (PostgreSQL) shown in the sidebar. It's
    /// also the session's default, so unqualified table names resolve in it.
    private(set) var selectedDatabase: String? { didSet { sessionDidChange?() } }
    /// The session's default database, as far as we know (`nil` until
    /// queried after connecting).
    @ObservationIgnored private var sessionDatabase: String?
    /// The database to select again once a reconnected session lists tables.
    @ObservationIgnored private var preferredDatabase: String?
    /// What's typed in the table filter field; see ``TableBrowser``.
    @ObservationIgnored var tableFilterDraft = ""
    @ObservationIgnored private var tableFilterTask: Task<Void, Never>?

    @ObservationIgnored private(set) var selectedTableID: String? { didSet { stateChanged() } }
    @ObservationIgnored private(set) var selectedTab: BrowserTab = .query {
        didSet { stateChanged() }
    }
    /// Which table each tab last loaded, so switching back doesn't reload.
    @ObservationIgnored private var loadedTables: [BrowserTab: String] = [:]

    // MARK: Panes

    /// Rows per page when browsing a table (as in Sequel Ace). The grid is
    /// virtualized, so this mostly costs fetch time.
    @ObservationIgnored private(set) var pageSize = 1000 { didSet { stateChanged() } }
    @ObservationIgnored private(set) lazy var structurePane = makePane()
    @ObservationIgnored private(set) lazy var indexPane = makePane()
    @ObservationIgnored private(set) lazy var infoPane: ResultPane = {
        let pane = makePane()
        pane.isSortable = false  // property/value pairs
        return pane
    }()
    @ObservationIgnored private(set) lazy var relationsPane = makePane()
    @ObservationIgnored private(set) lazy var triggersPane = makePane()
    @ObservationIgnored private(set) var viewDefinition = "" { didSet { stateChanged() } }
    @ObservationIgnored private(set) lazy var queryDocuments = [QueryDocument(name: "Query 1", pane: makePane())]
    @ObservationIgnored private(set) var selectedQueryIndex = 0
    @ObservationIgnored private(set) var queryDocumentsRevision = 0 { didSet { stateChanged() } }
    @ObservationIgnored private(set) var pendingQueryCloseID: UUID? { didSet { stateChanged() } }
    @ObservationIgnored var editorCursor = 0
    @ObservationIgnored var editorSelection: Range<Int>?
    var activeQueryDocument: QueryDocument { queryDocuments[selectedQueryIndex] }
    var queryPane: ResultPane { activeQueryDocument.pane }
    var queryDrafts: [QueryDraftState] {
        queryDocuments.enumerated().map { index, document in
            QueryDraftState(id: document.id, name: document.name,
                sql: index == selectedQueryIndex ? sql : document.sql,
                dirty: index == selectedQueryIndex ? activeSQLIsDirty : document.dirty)
        }
    }

    private func captureQueryDocument() {
        let document = activeQueryDocument
        document.sql = sql; document.baseline = editorBaselineSQL
        document.status = queryStatus; document.errorLocation = queryErrorLocation
        document.statusText = statusMessage; document.error = errorMessage
        document.browsing = isBrowsing; document.browseSQL = browseSQL
        document.browsePageSize = pageSize
        document.offset = contentOffset; document.hasMore = contentHasMore
        document.total = contentTotal
        document.filter = contentFilter; document.sort = contentSort; document.columns = contentColumns
        document.filterColumn = filterColumn; document.filterOperator = filterOperator; document.filterValue = filterValue
        document.tableID = selectedTableID; document.cursor = editorCursor; document.selection = editorSelection
    }
    func selectQueryDocument(_ id: UUID) {
        guard !isRunning, let index = queryDocuments.firstIndex(where: { $0.id == id }), index != selectedQueryIndex else { return }
        captureQueryDocument()
        rowEditDraft = nil
        selectedQueryIndex = index
        let document = activeQueryDocument
        pendingQuery = nil
        setSQL(document.sql); editorBaselineSQL = document.baseline
        editorCursor = document.cursor; editorSelection = document.selection
        queryStatus = document.status; queryErrorLocation = document.errorLocation
        statusMessage = document.statusText; errorMessage = document.error
        // Restore the browse source before enabling paging or server sorting.
        let browseTable = document.browsing ? tables.first { $0.id == document.tableID } : nil
        if let browseTable {
            selectedTableID = browseTable.id
            if selectedDatabase != browseTable.namespace {
                selectedDatabase = browseTable.namespace
                applySelectedDatabase()
            }
            loadedTables = [:]
            clearTablePanes()
        }
        isBrowsing = browseTable != nil
        browseSQL = document.browseSQL; contentOffset = document.offset; contentHasMore = document.hasMore
        filterEditorVisible = false; contentTotal = document.total
        contentFilter = document.filter; contentSort = document.sort; contentColumns = document.columns
        filterColumn = document.filterColumn; filterOperator = document.filterOperator; filterValue = document.filterValue
        queryDocumentsRevision += 1
        scheduleCompletionMetadata()
        if let browseTable, document.browsePageSize != pageSize { contentOffset = 0; loadContent(browseTable) }
    }
    func addQueryDocument() {
        guard !isRunning, queryDocuments.count < 1000 else { return }
        let names = Set(queryDocuments.map(\.name))
        let number = (1...1001).first { !names.contains("Query \($0)") }!
        let document = QueryDocument(name: "Query \(number)", pane: makePane())
        queryDocuments.append(document)
        selectQueryDocument(document.id)
    }
    func closeQueryDocument(_ id: UUID) {
        guard !isRunning, let index = queryDocuments.firstIndex(where: { $0.id == id }) else { return }
        if index == selectedQueryIndex ? activeSQLIsDirty : queryDocuments[index].dirty {
            pendingQueryCloseID = id
        } else { removeQueryDocument(id) }
    }
    func cancelQueryDocumentClose() { pendingQueryCloseID = nil }
    func confirmQueryDocumentClose() {
        guard !isRunning, let id = pendingQueryCloseID else { return }
        pendingQueryCloseID = nil
        removeQueryDocument(id)
    }
    private func removeQueryDocument(_ id: UUID) {
        guard let index = queryDocuments.firstIndex(where: { $0.id == id }) else { return }
        if queryDocuments.count == 1 { addQueryDocument() }
        if index == selectedQueryIndex {
            selectQueryDocument(queryDocuments[index == 0 ? 1 : index - 1].id)
        }
        let selected = activeQueryDocument.id
        queryDocuments.removeAll { $0.id == id }
        selectedQueryIndex = queryDocuments.firstIndex { $0.id == selected } ?? 0
        queryDocumentsRevision += 1
    }
    @ObservationIgnored private(set) var createStatement = "" { didSet { stateChanged() } }

    // MARK: Table browsing (in the Query tab, server-side paging and filtering)

    /// Whether the Query tab's results come from browsing the selected table
    /// (clicking it, then filtering, paging or sorting), rather than from SQL
    /// the user ran. Shows the filter bar and pager, and makes header clicks
    /// sort on the server.
    @ObservationIgnored private(set) var isBrowsing = false {
        didSet {
            if isBrowsing {
                queryPane.sortHandler = { [weak self] sort in self?.sortContent(by: sort) }
                queryPane.filterHandler = { [weak self] column in self?.openColumnFilter(column) }
            } else {
                queryPane.sortHandler = nil
                queryPane.filterHandler = nil
                filterEditorVisible = false
            }
            stateChanged()
        }
    }

    /// The SELECT behind the browsed rows, shown above them. Browsing never
    /// touches the editor.
    @ObservationIgnored private(set) var browseSQL = "" { didSet { stateChanged() } }
    @ObservationIgnored private(set) var contentOffset = 0 { didSet { stateChanged() } }
    @ObservationIgnored private(set) var contentHasMore = false { didSet { stateChanged() } }
    @ObservationIgnored private(set) var contentFilter: SQLDialect.Filter? {
        didSet { stateChanged() }
    }
    @ObservationIgnored private(set) var contentSort: DataGridSort?
    /// Columns offered by the filter bar (from the unfiltered content).
    @ObservationIgnored private(set) var contentColumns: [String] = [] { didSet { stateChanged() } }
    @ObservationIgnored var filterColumn: String? { didSet { stateChanged() } }
    @ObservationIgnored var filterOperator: SQLDialect.Filter.Operator? = .contains {
        didSet { stateChanged() }
    }
    /// What's typed in the filter value field (the GTK entry owns the text).
    @ObservationIgnored var filterValue = ""

    @ObservationIgnored private(set) var completionRevision = 0 { didSet { stateChanged() } }
    @ObservationIgnored private(set) var completionColumns: [String: [String]] = [:]
    @ObservationIgnored private var completionTask: Task<Void, Never>?
    private func scheduleCompletionMetadata() {
        completionTask?.cancel()
        guard canUseConnection, !isRunning else { return }
        let text = sql, revision = sessionRevision
        completionTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, revision == sessionRevision, canUseConnection, !isRunning else { return }
            let references = SQLCompletionEngine.references(text, tables: tables, namespace: selectedDatabase, dialect: dialect)
            let missing = Array(Set(references.values.map(\.id))).filter { completionColumns[$0] == nil }.prefix(8)
            let targets = missing.compactMap { id in tables.first { $0.id == id } }
            for table in targets {
                guard !Task.isCancelled, revision == sessionRevision, !isRunning else { return }
                guard let statement = dialect.columnsSQL(table) else { continue }
                let outcome = await fetch(statement)
                guard revision == sessionRevision else { return }
                if case .success(let result) = outcome {
                    completionColumns[table.id] = (0..<result.rowCount).compactMap { result.cell($0, 0, maxLength: nil) }
                    completionRevision += 1
                }
            }
        }
    }
    func editorCompletions(text: String, cursor: Int) -> SQLCompletion? {
        SQLCompletionEngine.complete(text, cursor: cursor, dialect: dialect, tables: tables,
            namespace: selectedDatabase, columns: completionColumns)
    }

    // MARK: Browse filters, exact counts, pins and row changes

    @ObservationIgnored var filterEditorVisible = false { didSet { stateChanged() } }
    @ObservationIgnored private(set) var contentTotal: Int64? { didSet { stateChanged() } }
    @ObservationIgnored private(set) var isCounting = false { didSet { stateChanged() } }
    var effectiveFilter: SQLDialect.FilterExpression? { contentFilter.map(SQLDialect.FilterExpression.condition) }
    func openColumnFilter(_ column: Int) {
        guard canRun, isBrowsing, let result = queryPane.result, result.columns.indices.contains(column) else { return }
        let name = result.columns[column].name
        filterColumn = name
        filterOperator = contentFilter?.column == name ? contentFilter?.op : .contains
        filterValue = contentFilter?.column == name ? contentFilter!.value : ""
        filterEditorVisible = true
    }
    func countContentRows() {
        guard canRun, isBrowsing, let table = selectedTable else { return }
        let revision = sessionRevision, document = activeQueryDocument.id, expression = effectiveFilter
        isRunning = true; isCounting = true; queryCancellationRequested = false
        statusMessage = "Counting rows…"
        Task {
            let outcome = await fetch(dialect.countSQL(table, expression: expression), maxRows: 1, readOnly: connectionSafety.readOnly)
            guard revision == sessionRevision else { return }
            isRunning = false; isCounting = false
            guard activeQueryDocument.id == document, selectedTableID == table.id, effectiveFilter == expression else { return }
            switch outcome {
            case .success(let result):
                if let text = result.cell(0, 0), let count = Int64(text) { contentTotal = count; statusMessage = "Exact count: \(count.formatted()) rows" }
            case .failure(let error): errorMessage = "Count failed: \(error)"
            }
        }
    }

    @ObservationIgnored private(set) var pinnedTableIDs: Set<String> = [] { didSet { stateChanged() } }
    private var pinScope: String {
        if let id = restorableProfileID { return "favorite:" + id }
        if case .direct(let driver, let uri, _) = connection?.source, let url = URLComponents(string: uri) {
            return [driver ?? connectionTitle, url.host ?? "", url.port.map(String.init) ?? "", url.path].joined(separator: "|")
        }
        return connectionTitle
    }
    func toggleSelectedTablePin() {
        guard let id = selectedTableID else { return }
        do {
            try queryLibrary.setTablePinned(id, connection: pinScope, pinned: !pinnedTableIDs.contains(id))
            pinnedTableIDs = queryLibrary.pinnedTables(connection: pinScope)
        } catch { errorMessage = "Could not save table pin: \(error)" }
    }

    @ObservationIgnored private(set) var editMetadata: [String: TableEditMetadata] = [:]
    @ObservationIgnored private var editMetadataLoading: Set<String> = []
    @ObservationIgnored private(set) var editMetadataRevision = 0 { didSet { stateChanged() } }
    @ObservationIgnored private(set) var editMetadataError = "" { didSet { stateChanged() } }
    @ObservationIgnored var rowEditDraft: RowEditDraft? { didSet { stateChanged() } }
    @ObservationIgnored private(set) var editFeedback = "" { didSet { stateChanged() } }
    var canInsertRows: Bool { canRun && isBrowsing && !connectionSafety.readOnly && selectedTableID.flatMap { editMetadata[$0]?.transactional } == true }
    var canEditRows: Bool { canInsertRows && selectedTableID.flatMap { editMetadata[$0]?.canIdentifyRows } == true }
    private func loadEditMetadata(_ table: TableInfo) {
        guard editMetadata[table.id] == nil, !editMetadataLoading.contains(table.id),
              let columnsSQL = dialect.editColumnsSQL(table), let keySQL = dialect.primaryKeySQL(table),
              let eligibility = dialect.editableTableSQL(table) else { return }
        editMetadataLoading.insert(table.id)
        let revision = sessionRevision
        Task {
            do {
                let columns = try await fetch(columnsSQL).get()
                guard revision == sessionRevision else { return }
                let keys = try await fetch(keySQL).get()
                guard revision == sessionRevision else { return }
                let eligible = try await fetch(eligibility, maxRows: 1).get()
                guard revision == sessionRevision else { return }
                editMetadata[table.id] = TableEditMetadata(columns: (0..<columns.rowCount).compactMap { row in
                    guard let name = columns.cell(row, 0, maxLength: nil), let type = columns.cell(row, 1) else { return nil }
                    return TableEditColumn(name: name, type: type, nullable: columns.cell(row, 2) == "YES", generated: columns.cell(row, 4) == "YES")
                }, keys: (0..<keys.rowCount).compactMap { keys.cell($0, 0, maxLength: nil) }, transactional: eligible.cell(0, 0) == "YES")
                editMetadataError = ""
            } catch {
                guard revision == sessionRevision else { return }
                editMetadataError = "Row metadata unavailable: \(error)"
            }
            guard revision == sessionRevision else { return }
            editMetadataLoading.remove(table.id); editMetadataRevision += 1
        }
    }
    func beginRowEdit(kind: TableMutation.Kind, row: Int? = nil) {
        guard canInsertRows, kind == .insert || canEditRows, let table = selectedTable,
              let metadata = editMetadata[table.id] else { errorMessage = "Row editing is unavailable for this table or read-only connection."; return }
        let result = queryPane.result
        guard kind == .insert || (row.map { $0 >= 0 && $0 < (result?.rowCount ?? 0) } == true) else { return }
        let names = result?.columns.map(\.name) ?? []
        let values = row.flatMap { result?.row($0) } ?? []
        let fields = metadata.columns.map { column in
            let value = names.firstIndex(of: column.name).flatMap { values.indices.contains($0) ? values[$0] : nil }
            return RowEditField(column: column, mode: kind == .insert || column.generated ? .default : (value == nil ? .null : .value), text: value ?? "", unrepresentable: value?.contains("\0") == true)
        }
        rowEditDraft = RowEditDraft(table: table, documentID: activeQueryDocument.id, sessionRevision: sessionRevision,
            paneRevision: queryPane.revision, kind: kind, metadata: metadata, originalColumns: names, originalValues: values, fields: fields)
        editFeedback = ""
    }
    func cancelRowEdit() { rowEditDraft = nil }
    private func rowDraftIsCurrent(_ draft: RowEditDraft) -> Bool {
        canInsertRows && draft.sessionRevision == sessionRevision && draft.documentID == activeQueryDocument.id
            && draft.table.id == selectedTableID && draft.paneRevision == queryPane.revision && editMetadata[draft.table.id] == draft.metadata
    }
    func reviewRowEdit() {
        guard var draft = rowEditDraft else { return }
        guard rowDraftIsCurrent(draft) else { errorMessage = "Results changed. Reopen the row editor from the current result."; return }
        do { draft.reviewedSQL = try draft.mutation().sql(dialect); rowEditDraft = draft }
        catch { errorMessage = "\(error)" }
    }
    func confirmRowEdit() {
        guard let draft = rowEditDraft, rowDraftIsCurrent(draft), let reviewed = draft.reviewedSQL, let connection else { return }
        do {
            let mutation = try draft.mutation()
            guard try mutation.sql(dialect) == reviewed else { errorMessage = "The change was modified. Review it again."; return }
            let revision = sessionRevision
            isRunning = true; queryCancellationRequested = false
            Task {
                let outcome = await Task.detached { Result { try connection.applyTableMutation(mutation) } }.value
                guard revision == sessionRevision else { return }
                isRunning = false
                switch outcome {
                case .success:
                    rowEditDraft = nil; editFeedback = "Row \(mutation.kind.rawValue) committed."
                    contentTotal = nil; rowEstimates.removeValue(forKey: draft.table.id)
                    editMetadata.removeValue(forKey: draft.table.id)
                    if selectedTableID == draft.table.id && activeQueryDocument.id == draft.documentID { loadContent(draft.table) }
                    else { statusMessage = "Change committed to \(draft.table.name)." }
                case .failure(let error):
                    handleConnectionFailure(error, from: connection)
                    errorMessage = "Change failed: \(error)"
                }
            }
        } catch { errorMessage = "\(error)" }
    }

    // MARK: Query library

    @ObservationIgnored let queryLibrary: QueryLibraryStore
    @ObservationIgnored private(set) var librarySection: QueryLibrarySection? { didSet { stateChanged() } }
    @ObservationIgnored private(set) var libraryRevision = 0 { didSet { stateChanged() } }
    @ObservationIgnored private(set) var libraryFeedback = "" { didSet { stateChanged() } }

    func refreshQueryLibrary() { libraryRevision += 1 }

    func toggleLibrary(_ section: QueryLibrarySection) {
        librarySection = librarySection == section ? nil : section
    }

    func loadLibrarySQL(_ text: String) {
        isBrowsing = false
        setSQL(text)
        libraryFeedback = "Loaded into the editor. Choose Run All or Ctrl+Enter to execute."
    }

    private func recordHistory(_ statement: String, connectionTitle: String) -> UUID? {
        do {
            let id = try queryLibrary.record(sql: statement, connection: connectionTitle)
            libraryRevision += 1
            return id
        } catch {
            libraryFeedback = "History could not be saved: \(error)"
            return nil
        }
    }

    private func finishHistory(_ id: UUID?, elapsed: Duration, result: QueryResult?) {
        guard let id else { return }
        let parts = elapsed.components
        do {
            try queryLibrary.completeHistory(id, duration: Double(parts.seconds) + Double(parts.attoseconds) / 1e18,
                rowCount: result.map { $0.columns.isEmpty ? $0.rowsAffected : Int64($0.rowCount) } ?? nil,
                succeeded: result != nil)
            libraryRevision += 1
        } catch { libraryFeedback = "History outcome could not be saved: \(error)" }
    }

    @ObservationIgnored private(set) var pendingDisconnect = false { didSet { stateChanged() } }
    func requestDisconnect() {
        if isRunning { pendingDisconnect = true } else { disconnect() }
    }
    func cancelDisconnect() { pendingDisconnect = false }
    func confirmDisconnect() {
        pendingDisconnect = false
        cancelQuery()
        disconnect()
    }

    func clearQueryHistory() {
        updateLibrary { try queryLibrary.clearHistory() }
    }

    func deleteHistoryEntry(_ id: UUID) {
        updateLibrary { try queryLibrary.deleteHistory(id) }
    }

    func saveQuerySnippet(id: UUID?, name: String) -> UUID? {
        do {
            let saved = try queryLibrary.saveSnippet(id: id, name: name, sql: sql)
            libraryRevision += 1
            editorBaselineSQL = sql
            libraryFeedback = id == nil ? "Snippet saved." : "Snippet updated from the editor."
            return saved
        } catch {
            libraryFeedback = "Snippet could not be saved: \(error)"
            return nil
        }
    }

    func deleteQuerySnippet(_ id: UUID) {
        updateLibrary { try queryLibrary.deleteSnippet(id) }
    }

    private func updateLibrary(_ change: () throws -> Void) {
        do {
            try change()
            libraryRevision += 1
            libraryFeedback = ""
        } catch {
            libraryFeedback = "Query library could not be saved: \(error)"
        }
    }

    // MARK: Query tab

    /// The editor's text. Not observed: the GTK text view owns the live text.
    /// Code that replaces it calls ``setSQL(_:)``. Saved as the connection's
    /// draft shortly after it changes.
    @ObservationIgnored var sql = "" {
        didSet {
            if sql != oldValue {
                scheduleDraftSave(); sessionDidChange?(); scheduleCompletionMetadata()
                if (editorBaselineSQL.map { $0 != oldValue } ?? true) != activeSQLIsDirty { stateChanged() }
            }
        }
    }
    /// The connection whose draft the editor holds (its title).
    @ObservationIgnored private var draftKey: String?
    @ObservationIgnored private var draftSaveTask: Task<Void, Never>?
    /// Bumped by ``setSQL(_:)`` so the editor picks up programmatic changes.
    @ObservationIgnored private(set) var sqlRevision = 0 { didSet { stateChanged() } }
    @ObservationIgnored private(set) var isRunning = false { didSet { stateChanged() } }
    var maxRows: Int? = 10_000
    let maxRowsOptions = AppPreferences.rowLimits

    @ObservationIgnored private(set) var queryStatus: QueryStatus? { didSet { stateChanged() } }
    @ObservationIgnored private(set) var queryErrorLocation: QueryErrorLocation? { didSet { stateChanged() } }

    // MARK: Status

    @ObservationIgnored private(set) var statusMessage = "Not connected" {
        didSet { stateChanged() }
    }
    @ObservationIgnored private(set) var errorMessage: String? { didSet { stateChanged() } }
    /// Number of catalog/content loads in flight.
    @ObservationIgnored private(set) var loadsInFlight = 0 { didSet { stateChanged() } }

    static let systemSchemas: Set<String> = [
        "information_schema", "pg_catalog", "pg_toast", "mysql", "performance_schema", "sys",
    ]

    private func makePane() -> ResultPane {
        let pane = ResultPane()
        pane.onChange = { [weak self] in self?.stateChanged() }
        pane.copyContext = { [weak self] in
            guard let self else { return (.generic, "table_name") }
            let dialect = dialect
            let table = selectedTable.map { dialect.qualifiedName(of: $0) }
            return (dialect, table ?? dialect.quote("table_name"))
        }
        return pane
    }

    // MARK: Change notification

    private struct Subscriber {
        var snapshot: @MainActor () -> AnyHashable
        var last: AnyHashable
        var update: @MainActor () -> Void
    }
    @ObservationIgnored private var subscribers: [String: Subscriber] = [:]
    @ObservationIgnored private var notificationPending = false

    /// Call `update` when the value returned by `snapshot` (what a view
    /// shows) changes; checked once per batch of state changes.
    /// Re-registering under the same `key` replaces the previous subscription.
    func watch(
        _ key: String,
        of snapshot: @escaping @MainActor () -> AnyHashable,
        _ update: @escaping @MainActor () -> Void
    ) {
        let last = subscribers[key]?.last ?? snapshot()
        subscribers[key] = Subscriber(snapshot: snapshot, last: last, update: update)
    }

    /// Mounted views subscribe again when this session becomes visible. Drop
    /// callbacks to removed widgets without stopping background database work.
    func detachViews() {
        subscribers.removeAll()
        tableFilterTask?.cancel()
    }

    private func stateChanged() {
        sessionDidChange?()
        guard !notificationPending else { return }
        notificationPending = true
        Task { @MainActor in
            notificationPending = false
            for (key, subscriber) in subscribers {
                let current = subscriber.snapshot()
                guard current != subscriber.last else { continue }
                subscribers[key]?.last = current
                subscriber.update()
            }
        }
    }

    // MARK: Discovery

    func reloadDiscovery() {
        profiles = Discovery.profiles()
        if let selectedProfileID, !profiles.contains(where: { $0.id == selectedProfileID }) {
            self.selectedProfileID = nil
        }
        drivers = Discovery.installedDrivers()
        if directDriver == nil {
            directDriver = drivers.first
        }
    }

    /// `SDBUI_PROFILE=<name> [SDBUI_SQL=<query>]` connects (and runs the
    /// query) on launch — handy for scripting and profiling.
    func applyLaunchEnvironment() {
        let environment = ProcessInfo.processInfo.environment
        if let query = environment["SDBUI_SQL"] {
            setSQL(query)
            runOnConnect = true
        }
        if let profile = environment["SDBUI_PROFILE"] {
            selectFavorite(profile)
            connectSelectedProfile()
        }
    }

    @ObservationIgnored private var runOnConnect = false

    // MARK: Connecting

    func selectFavorite(_ id: String?) {
        guard id != selectedProfileID else { return }
        selectedProfileID = id
        if let profile = profiles.first(where: { $0.id == id }) {
            connectionDraft = ConnectionDraft(profile: profile)
        }
        connectionFeedback = ""
    }

    /// Open the saved profile activated in the sidebar, not unsaved form edits.
    func activateFavorite(_ id: String) {
        guard !isConnecting, connection == nil, profiles.contains(where: { $0.id == id }) else { return }
        selectFavorite(id)
        connectSelectedProfile()
    }

    func newFavorite() {
        selectedProfileID = nil
        connectionDraft = ConnectionDraft()
        connectionFeedback = ""
    }

    func saveFavorite() {
        guard !isConnecting else { return }
        guard !connectionDraft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            connectionFeedback = "Enter a favorite name above, then choose Save."
            return
        }
        do {
            if profiles.contains(where: { $0.id == connectionDraft.name && $0.url != connectionDraft.originalURL }) {
                throw ADBCError("A favorite with this name already exists. Choose another name.")
            }
            let url = try connectionDraft.save()
            reloadDiscovery()
            selectedProfileID = profiles.first(where: { $0.url == url })?.id
            if let profile = profiles.first(where: { $0.id == selectedProfileID }) {
                connectionDraft = ConnectionDraft(profile: profile)
            }
            connectionFeedback = "Favorite saved."
        } catch {
            connectionFeedback = "Save failed: \(error)"
        }
    }

    func testFavorite() {
        guard !isConnecting else { return }
        do {
            let source = try connectionDraft.source()
            let opener = openConnection
            isConnecting = true
            connectionFeedback = "Testing connection…"
            Task {
                let outcome = await Task.detached {
                    Result { () -> String in
                        let connection = try opener(source)
                        _ = try connection.execute("SELECT 1", maxRows: 1)
                        return connection.vendorName ?? "database"
                    }
                }.value
                isConnecting = false
                switch outcome {
                case .success(let vendor): connectionFeedback = "Connection successful (\(vendor))."
                case .failure(let error):
                    connectionFeedback = "Connection test failed: \(error)"
                    if let unknown = error as? SSHUnknownHostKeyError {
                        askToTrustHostKey(unknown, retry: .test)
                    }
                }
            }
        } catch {
            connectionFeedback = "Connection test failed: \(error)"
        }
    }

    func connectFavorite() {
        do {
            let source = try connectionDraft.source()
            connectionFeedback = ""
            let favorite = profiles.first { ConnectionDraft(profile: $0) == connectionDraft }?.id
            connect(source, title: connectionDraft.name.isEmpty ? connectionDraft.driver : connectionDraft.name, safety: connectionDraft.safety, favoriteID: favorite)
        } catch {
            connectionFeedback = "Connection failed: \(error)"
        }
    }

    func connectSelectedProfile() {
        guard let selectedProfileID else { return }
        guard let profile = profiles.first(where: { $0.id == selectedProfileID }) else { return }
        connect(.profile(profile.url.path), title: profile.id, safety: profile.safety, favoriteID: profile.id)
    }

    func connectDirect() {
        let uri = directURI.trimmingCharacters(in: .whitespacesAndNewlines)
        // Let the URI scheme pick the driver when it names an installed one,
        // like `databow --uri postgresql://…`.
        let inferred = Discovery.driverName(forURI: uri)
        let driver = drivers.contains { $0.id == inferred } ? inferred : directDriver?.id
        connect(.direct(driver: driver, uri: uri), title: driver ?? "connection")
    }

    private func connect(_ source: ConnectionSource, title: String, safety: FavoriteSafety = .init(), favoriteID: String? = nil, reconnecting: Bool = false) {
        guard !isConnecting else { return }
        pendingQuery = nil
        restorableProfileID = favoriteID
        sessionRevision += 1
        loadsInFlight = 0
        let revision = sessionRevision
        connectionMonitor?.cancel()
        let opener = openConnection
        isConnecting = true
        errorMessage = nil
        statusMessage = reconnecting ? "Reconnecting to \(title)…" : "Connecting to \(title)…"

        Task {
            guard revision == sessionRevision else { return }
            let outcome = await Task.detached {
                Result { try opener(source) }
            }.value
            guard revision == sessionRevision else {
                if case .success(let obsolete) = outcome { Self.release(obsolete) }
                return
            }
            isConnecting = false
            switch outcome {
                case .success(let connection):
                    Self.release(self.connection)
                    preferredDatabase = reconnecting ? selectedDatabase : nil
                    sessionDatabase = nil
                    resetBrowsing()
                    isBrowsing = false
                    isRunning = false
                    self.connection = connection
                    isConnectionLost = false
                    reconnectSource = source
                    connectionTitle = title
                    connectionSafety = safety
                    let vendor = [connection.vendorName, connection.vendorVersion]
                        .compactMap { $0 }.joined(separator: " ")
                    statusMessage = reconnecting
                        ? "Reconnected. Run your query when ready."
                        : (vendor.isEmpty ? "Connected" : "Connected to \(vendor)")
                    if !reconnecting && pendingSessionRestore != nil { draftKey = title }
                    if !reconnecting && pendingSessionRestore == nil {
                        // Keep the previous connection's draft, then open this one's.
                        saveDraft()
                        draftKey = title
                        if !runOnConnect, let draft = queryLibrary.draft(for: title) {
                            setSQL(draft)
                            editorBaselineSQL = sql
                        } else if sql.isEmpty {
                            setSQL("SELECT 1")
                            editorBaselineSQL = sql
                        }
                    }
                    refreshTables()
                    startConnectionMonitor()
                    if !reconnecting && runOnConnect {
                        runOnConnect = false
                        selectTab(.query)
                        runQuery()
                    }
                case .failure(let error):
                    statusMessage = reconnecting ? "Reconnect failed — try again when the server is available." : "Connection failed"
                    errorMessage = "\(error)"
                    if let unknown = error as? SSHUnknownHostKeyError {
                        askToTrustHostKey(unknown, retry: .connect(
                            source, title: title, safety: safety, favoriteID: favoriteID, reconnecting: reconnecting))
                    }
            }
        }
    }

    // MARK: SSH host keys

    /// Fetches the unknown host key so the user can compare its fingerprint
    /// with the server's before trusting it.
    private func askToTrustHostKey(_ error: SSHUnknownHostKeyError, retry: HostKeyRetry) {
        let host = error.host, port = error.port
        Task {
            let outcome = await Task.detached { Result { try SSHHostKeys.scan(host: host, port: port) } }.value
            switch outcome {
                case .success(let scan):
                    hostKeyRetry = retry
                    hostKeyPrompt = scan
                case .failure(let scanError):
                    errorMessage = "\(error)\nThe host key could not be fetched for verification: \(scanError)"
            }
        }
    }

    /// Saves the verified key to known_hosts and retries.
    func trustHostKey() {
        guard let scan = hostKeyPrompt else { return }
        do {
            try SSHHostKeys.trust(scan)
        } catch {
            errorMessage = "Could not save the host key: \(error)"
            return
        }
        let retry = hostKeyRetry
        hostKeyPrompt = nil
        hostKeyRetry = nil
        errorMessage = nil
        switch retry {
            case .test: testFavorite()
            case .connect(let source, let title, let safety, let favoriteID, let reconnecting):
                connect(source, title: title, safety: safety, favoriteID: favoriteID, reconnecting: reconnecting)
            case nil: break
        }
    }

    func dismissHostKeyPrompt() {
        hostKeyPrompt = nil
        hostKeyRetry = nil
    }

    func reconnect() {
        guard isConnectionLost, let reconnectSource, !isConnecting else { return }
        connect(reconnectSource, title: connectionTitle, safety: connectionSafety, favoriteID: restorableProfileID, reconnecting: true)
    }

    private func startConnectionMonitor() {
        connectionMonitor?.cancel()
        let interval = healthCheckIntervalNanoseconds
        connectionMonitor = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: interval) } catch { return }
                guard !Task.isCancelled else { return }
                await self?.checkConnectionHealth()
            }
        }
    }

    private func checkConnectionHealth() async {
        guard canUseConnection, !isRunning, loadsInFlight == 0, let connection else { return }
        let revision = sessionRevision
        let outcome = await Task.detached { Result { try connection.checkHealth() } }.value
        guard revision == sessionRevision, canUseConnection else { return }
        if case .failure(let error) = outcome { handleConnectionFailure(error, from: connection) }
    }

    private func handleConnectionFailure(_ error: Error, from failed: ADBCConnection) {
        guard connection === failed, !isConnectionLost, !isConnecting,
              failed.isConnectionLoss(error) else { return }
        isConnectionLost = true
        if isRunning { queryStatus = QueryStatus(text: "Connection lost", error: "\(error)") }
        isRunning = false
        pendingQuery = nil
        connectionMonitor?.cancel()
        Self.release(failed)
        statusMessage = "Connection lost — reconnect to continue."
        errorMessage = "\(error)"
    }

    func disconnect() {
        pendingDisconnect = false
        saveDraft()
        draftKey = nil
        restorableProfileID = nil
        pendingSessionRestore = nil
        pendingQuery = nil
        sessionRevision += 1
        loadsInFlight = 0
        connectionMonitor?.cancel()
        connectionMonitor = nil
        reconnectSource = nil
        isConnectionLost = false
        isConnecting = false
        isRunning = false
        Self.release(connection)
        connection = nil
        connectionSafety = FavoriteSafety()
        sessionDatabase = nil
        preferredDatabase = nil
        resetBrowsing()
        statusMessage = "Not connected"
    }

    /// Stops `connection`'s SSH tunnel off the main thread: waiting for ssh
    /// (and the driver's close, when this drops the last reference) must not
    /// freeze the UI.
    private nonisolated static func release(_ connection: ADBCConnection?) {
        guard let connection else { return }
        Task.detached { connection.stopTunnel() }
    }

    private func resetBrowsing() {
        queryStatus = nil
        queryErrorLocation = nil
        tables = []
        transferPoll?.cancel(); transferPoll = nil; transferProgress?.cancel(); transferProgress = nil; csvPreview = nil; transferVisible = false
        rowEditDraft = nil; editMetadata = [:]; editMetadataLoading = []; editMetadataError = ""
        contentTotal = nil; isCounting = false; pinnedTableIDs = []
        rowEstimates = [:]
        estimateLoads = []
        selectedDatabase = nil
        selectedTableID = nil
        loadedTables = [:]
        clearTablePanes()
        for document in queryDocuments { document.pane.show(nil); document.browsing = false; document.status = nil; document.errorLocation = nil; document.error = nil; document.statusText = "Ready" }
        completionColumns = [:]
        completionTask?.cancel()
        errorMessage = nil
    }

    var vendorDescription: String {
        guard let connection else { return "" }
        return [connection.vendorName, connection.vendorVersion].compactMap { $0 }
            .joined(separator: " ")
    }

    var dialect: SQLDialect {
        connection?.dialect ?? .generic
    }

    // MARK: Databases and tables

    /// Databases (or schemas) that contain tables, system ones last.
    var databases: [String] {
        let names = Set(tables.map(\.namespace))
        return names.sorted { a, b in
            let aSystem = Self.systemSchemas.contains(a.lowercased())
            let bSystem = Self.systemSchemas.contains(b.lowercased())
            return aSystem == bSystem ? a < b : !aSystem
        }
    }

    func selectDatabase(_ database: String?) {
        guard canUseConnection else { return }
        guard database != selectedDatabase else { return }
        selectedDatabase = database
        selectTable(nil)
        applySelectedDatabase()
    }

    /// Makes the selected database the session's default (`USE`).
    private func applySelectedDatabase() {
        guard canUseConnection, let database = selectedDatabase, database != sessionDatabase,
              let sql = dialect.useNamespaceSQL(database) else { return }
        if pendingQuery != nil { cancelPendingQuery() }
        sessionDatabase = database
        let revision = sessionRevision
        Task {
            let outcome = await fetch(sql, maxRows: 1)
            guard revision == sessionRevision, case .failure(let error) = outcome else { return }
            sessionDatabase = nil
            if !isConnectionLost && selectedDatabase == database {
                errorMessage = "Could not make \(database) the default \(dialect.namespaceLabel.lowercased()): \(error)"
            }
        }
    }

    /// All matching names, with exact/prefix/substring matches ahead of fuzzy matches.
    func visibleTables(matching filter: String) -> [TableInfo] {
        let matches = TableSearch.results(tables, namespace: selectedDatabase ?? "", query: filter)
        return matches.filter { pinnedTableIDs.contains($0.id) } + matches.filter { !pinnedTableIDs.contains($0.id) }
    }

    /// Record a filter keystroke and call `apply` once typing pauses.
    func editTableFilter(_ text: String, apply: @escaping @MainActor (String) -> Void) {
        tableFilterDraft = text
        tableFilterTask?.cancel()
        tableFilterTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            apply(text)
        }
    }

    var selectedTable: TableInfo? {
        tables.first { $0.id == selectedTableID }
    }

    func label(for table: TableInfo) -> String {
        if let type = table.type, type.uppercased() != "TABLE", type.uppercased() != "BASE TABLE" {
            return (pinnedTableIDs.contains(table.id) ? "★ " : "") + "\(table.name)  (\(type.lowercased()))"
        }
        return (pinnedTableIDs.contains(table.id) ? "★ " : "") + table.name
    }

    func refreshTables() {
        guard canUseConnection, let connection else { return }
        Task {
            guard self.connection === connection, canUseConnection else { return }
            // After connecting, also ask which database the session starts in.
            let currentSQL = sessionDatabase == nil ? dialect.currentNamespaceSQL : nil
            let outcome = await Task.detached {
                Result { () -> ([TableInfo], String?) in
                    let tables = try connection.tables()
                    let current = try currentSQL.flatMap {
                        try connection.execute($0, maxRows: 1).cell(0, 0, maxLength: nil)
                    }
                    return (tables, current)
                }
            }.value
            guard self.connection === connection, canUseConnection else { return }
            switch outcome {
                case .success(let (tables, current)):
                    self.tables = tables.sorted {
                        $0.namespace == $1.namespace ? $0.name < $1.name : $0.namespace < $1.namespace
                    }
                    if let current { sessionDatabase = current }
                    if let restored = pendingSessionRestore?.database, databases.contains(restored) {
                        selectedDatabase = restored
                    } else if let preferred = preferredDatabase, databases.contains(preferred) {
                        selectedDatabase = preferred
                    } else if selectedDatabase.map({ !databases.contains($0) }) ?? true {
                        selectedDatabase = sessionDatabase.flatMap { databases.contains($0) ? $0 : nil }
                            ?? databases.first
                    }
                    preferredDatabase = nil
                    editMetadata = [:]
                    if isBrowsing, let table = selectedTable { loadEditMetadata(table) }
                    pinnedTableIDs = queryLibrary.pinnedTables(connection: pinScope)
                    completionColumns = [:]
                    scheduleCompletionMetadata()
                    applySelectedDatabase()
                    if let restored = pendingSessionRestore {
                        pendingSessionRestore = nil
                        selectedTab = BrowserTab(rawValue: restored.pane) ?? .query
                        if let saved = restored.table,
                           let table = self.tables.first(where: { $0.catalog == saved.catalog && $0.schema == saved.schema && $0.name == saved.name }) {
                            selectTable(table.id)
                        }
                        sessionDidChange?()
                    }
                case .failure(let error):
                    handleConnectionFailure(error, from: connection)
                    if !isConnectionLost { errorMessage = "Could not list tables: \(error)" }
            }
        }
    }

    func selectTable(_ id: String?) {
        guard canUseConnection else { return }
        guard id != selectedTableID else { return }
        selectedTableID = id
        rowEditDraft = nil; filterEditorVisible = false
        if isBrowsing {
            // The rows belong to the previous table.
            isBrowsing = false
            browseSQL = ""
            contentHasMore = false
            queryPane.show(nil)
        }
        loadedTables = [:]
        contentOffset = 0
        contentFilter = nil
        contentTotal = nil
        contentSort = nil
        contentColumns = []
        filterColumn = nil
        clearTablePanes()
        loadCurrentTab()
    }

    private func clearTablePanes() {
        for pane in [structurePane, indexPane, infoPane, relationsPane, triggersPane] {
            pane.show(nil)
        }
        createStatement = ""
        viewDefinition = ""
    }

    // MARK: Tabs

    func selectTab(_ tab: BrowserTab) {
        selectedTab = tab
        loadCurrentTab()
    }

    /// Reload what the current tab shows.
    func refreshCurrentTab() {
        guard canRun else { return }
        contentTotal = nil
        if let id = selectedTableID { editMetadata.removeValue(forKey: id); editMetadataRevision += 1 }
        if let id = selectedTableID { rowEstimates.removeValue(forKey: id) }
        if selectedTab == .query {
            if isBrowsing, let table = selectedTable {
                loadContent(table)
            } else {
                runQuery()
            }
            return
        }
        loadedTables[selectedTab] = nil
        loadCurrentTab()
    }

    private func loadCurrentTab() {
        // The Query tab shows a table's rows only on request (Show rows).
        guard selectedTab != .query else { return }
        guard canUseConnection, let table = selectedTable, loadedTables[selectedTab] != table.id else { return }
        loadedTables[selectedTab] = table.id
        switch selectedTab {
            case .query: break
            case .structure: loadStructure(table)
            case .info: loadInfo(table)
        }
    }

    /// Run `sql` off the main actor, counting it as a load in flight.
    private func fetch(_ sql: String, maxRows: Int = 10_000, readOnly: Bool = false, direct: Bool = false) async -> Result<QueryResult, any Error> {
        guard canUseConnection, let connection else { return .failure(ADBCError("Not connected")) }
        let revision = sessionRevision
        loadsInFlight += 1
        defer { if revision == sessionRevision { loadsInFlight -= 1 } }
        let outcome = await Task.detached {
            Result { try readOnly ? connection.executeReadOnly(sql, maxRows: maxRows, usePostgresCopy: !direct) : connection.execute(sql, maxRows: maxRows, usePostgresCopy: !direct) }
        }.value
        guard revision == sessionRevision, self.connection === connection else {
            return .failure(ADBCError("Connection changed"))
        }
        if case .failure(let error) = outcome { handleConnectionFailure(error, from: connection) }
        return outcome
    }

    /// Show `outcome` in `pane` if `table` is still selected.
    private func apply(
        _ outcome: Result<QueryResult, any Error>, to pane: ResultPane, for table: TableInfo,
        what: String, revision: Int
    ) {
        guard revision == sessionRevision, canUseConnection, selectedTableID == table.id else { return }
        switch outcome {
            case .success(let result):
                pane.show(result)
            case .failure(let error):
                pane.show(nil)
                errorMessage = "Could not load \(what) of \(table.name): \(error)"
        }
    }

    // MARK: Browsing a table in the Query tab

    /// Shows the first page of the selected table's rows in the Query tab.
    func browseSelectedTable() {
        guard canRun, let table = selectedTable else { return }
        contentOffset = 0
        contentFilter = nil
        contentTotal = nil
        contentSort = nil
        contentColumns = []
        filterColumn = nil
        loadContent(table)
    }

    /// Shows one page of `table` in the Query tab, with its SQL above the rows.
    private func loadContent(_ table: TableInfo) {
        guard canRun else { return }
        let revision = sessionRevision
        let orderBy = contentSort.flatMap { sort in
            contentColumns.indices.contains(sort.column)
                ? (column: contentColumns[sort.column], ascending: sort.ascending) : nil
        }
        let sql = dialect.browseSQL(
            table, filter: contentFilter, orderBy: orderBy, limit: pageSize + 1,
            offset: contentOffset)
        // As shown on the Query tab: the page's real limit (one extra row is
        // fetched only to know whether there's a next page).
        let displayedSQL = dialect.browseSQL(
            table, filter: contentFilter, orderBy: orderBy, limit: pageSize,
            offset: contentOffset)
        loadRowEstimate(table)
        browseSQL = displayedSQL
        isBrowsing = true
        isRunning = true
        errorMessage = nil
        queryCancellationRequested = false
        statusMessage = "Loading \(table.name)…"
        Task {
            guard revision == sessionRevision, canUseConnection else { return }
            let outcome = await fetch(sql, maxRows: pageSize + 1, readOnly: connectionSafety.readOnly)
            guard revision == sessionRevision, canUseConnection else { return }
            isRunning = false
            guard selectedTableID == table.id, isBrowsing else { return }
            switch outcome {
                case .success(var result):
                    // One extra row tells whether there's a next page.
                    contentHasMore = result.rowCount > pageSize
                    result.limit(to: pageSize)
                    queryPane.show(result, sortedBy: orderBy == nil ? nil : contentSort)
                    if contentFilter == nil {
                        contentColumns = result.columns.map(\.name)
                        completionColumns[table.id] = contentColumns
                    }
                    loadEditMetadata(table)
                    statusMessage = "\(contentRowsLabel) in \(Self.format(result.elapsed))"
                case .failure(let error):
                    contentHasMore = false
                    queryPane.show(nil)
                    statusMessage = "Loading \(table.name) " + (queryCancellationRequested ? "cancelled" : "failed")
                    errorMessage = "\(error)"
            }
        }
    }

    @ObservationIgnored private(set) var rowEstimates: [String: Int64] = [:] { didSet { stateChanged() } }
    @ObservationIgnored private var estimateLoads: Set<String> = []
    private func loadRowEstimate(_ table: TableInfo) {
        guard rowEstimates[table.id] == nil, !estimateLoads.contains(table.id),
              let infoSQL = dialect.tableInfoSQL(table) else { return }
        estimateLoads.insert(table.id)
        let revision = sessionRevision
        Task {
            let outcome = await fetch(infoSQL)
            guard revision == sessionRevision else { return }
            estimateLoads.remove(table.id)
            if case .success(let result) = outcome,
               let index = result.columns.firstIndex(where: { $0.name == "Rows (estimate)" }),
               let text = result.cell(0, index), let value = Int64(text), value >= 0 {
                rowEstimates[table.id] = value
            }
        }
    }
    var contentPage: Int { contentOffset / pageSize + 1 }
    func goToContentPage(_ text: String) {
        guard canRun, isBrowsing, let table = selectedTable else { return }
        guard let page = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)), page > 0,
              page - 1 <= (Int.max - pageSize) / pageSize else {
            errorMessage = "Enter a positive page number within the supported range."
            return
        }
        contentOffset = (page - 1) * pageSize
        loadContent(table)
    }

    var contentRowsLabel: String {
        let count = queryPane.result?.rowCount ?? 0
        guard count > 0 else {
            if let total = contentTotal { return total == 0 ? "No matching rows (0 total)" : "No rows on this page (\(total.formatted()) total)" }
            return contentFilter == nil ? "No rows" : "No matching rows"
        }
        let range = "Rows \(contentOffset + 1)–\(contentOffset + count)"
        if let total = contentTotal { return range + " of \(total.formatted()) (exact)" }
        if contentFilter == nil, let id = selectedTableID, let estimate = rowEstimates[id], estimate >= Int64(contentOffset + count) {
            return range + " of ~\(estimate.formatted()) (estimate)"
        }
        return range + (contentHasMore ? "+" : "")
    }

    private func sortContent(by sort: DataGridSort) {
        guard canRun else { return }
        guard let table = selectedTable, sort != contentSort else { return }
        contentSort = sort
        contentOffset = 0
        loadContent(table)
    }

    func showContentPage(next: Bool) {
        guard canRun, isBrowsing, !next || contentHasMore, contentOffset <= Int.max - pageSize else { return }
        guard let table = selectedTable else { return }
        contentOffset = max(0, contentOffset + (next ? pageSize : -pageSize))
        loadContent(table)
    }

    func applyContentFilter() {
        guard canRun else { return }
        guard let table = selectedTable else { return }
        if let column = filterColumn ?? contentColumns.first, let op = filterOperator {
            contentFilter = SQLDialect.Filter(column: column, op: op, value: filterValue)
        } else {
            contentFilter = nil
        }
        contentTotal = nil
        filterEditorVisible = false
        contentOffset = 0
        loadContent(table)
    }

    func cellFilterTarget(in pane: ResultPane, row: Int, column: Int) -> CellFilterTarget? {
        guard pane === queryPane, isBrowsing, canRun, let table = selectedTable,
              let result = pane.result, row >= 0, row < result.rowCount,
              result.columns.indices.contains(column) else { return nil }
        return CellFilterTarget(column: result.columns[column].name, value: result.cell(row, column, maxLength: nil),
            tableID: table.id, sessionRevision: sessionRevision, paneRevision: pane.revision, queryID: activeQueryDocument.id, row: row)
    }

    func applyCellFilter(_ target: CellFilterTarget, command: Int32) {
        guard (0...4).contains(command) else { return }
        guard canRun, isBrowsing, selectedTableID == target.tableID, target.queryID == activeQueryDocument.id,
              sessionRevision == target.sessionRevision, queryPane.revision == target.paneRevision,
              let table = selectedTable else { return }
        if command == 3 || command == 4 {
            if let row = target.row { beginRowEdit(kind: command == 3 ? .update : .delete, row: row) }
            return
        }
        guard let filter = target.filter(for: command) else {
            errorMessage = "This value cannot be represented by the text filter (embedded NUL)."
            return
        }
        filterColumn = filter.column
        filterOperator = filter.op
        filterValue = filter.value
        contentFilter = filter
        contentTotal = nil
        contentOffset = 0
        loadContent(table)
    }

    func clearContentFilter() {
        guard canRun else { return }
        guard let table = selectedTable, contentFilter != nil else { return }
        contentFilter = nil
        filterValue = ""
        filterEditorVisible = false
        contentTotal = nil
        contentOffset = 0
        loadContent(table)
    }

    // MARK: Structure tab

    private func loadStructure(_ table: TableInfo) {
        guard canUseConnection, let connection else { return }
        let revision = sessionRevision
        errorMessage = nil
        Task {
            guard revision == sessionRevision, canUseConnection else { return }
            if let columnsSQL = dialect.columnsSQL(table) {
                apply(await fetch(columnsSQL), to: structurePane, for: table, what: "columns", revision: revision)
            } else {
                // Other databases: what ADBC reports (names and Arrow types).
                let outcome = await Task.detached {
                    Result { try connection.columns(of: table) }
                }.value
                guard revision == sessionRevision, canUseConnection else { return }
                if case .failure(let error) = outcome { handleConnectionFailure(error, from: connection) }
                apply(
                    outcome.map { columns in
                        QueryResult(
                            columns: [.init(name: "Field", type: ""), .init(name: "Type", type: "")],
                            rows: columns.map { [$0.name, $0.type] })
                    },
                    to: structurePane, for: table, what: "columns", revision: revision)
            }
            guard revision == sessionRevision, canUseConnection else { return }
            if let indexesSQL = dialect.indexesSQL(table) {
                apply(await fetch(indexesSQL), to: indexPane, for: table, what: "indexes", revision: revision)
            }
            if revision == sessionRevision, canUseConnection, selectedTableID == table.id {
                statusMessage = "Structure of \(table.name)"
            }
        }
    }

    // MARK: Table Info tab

    private func loadInfo(_ table: TableInfo) {
        guard canUseConnection else { return }
        let revision = sessionRevision
        errorMessage = nil
        Task {
            guard revision == sessionRevision, canUseConnection else { return }
            if let infoSQL = dialect.tableInfoSQL(table) {
                let outcome = await fetch(infoSQL).map(Self.transposed)
                apply(outcome, to: infoPane, for: table, what: "table information", revision: revision)
            } else {
                infoPane.show(QueryResult(
                    columns: [.init(name: "Property", type: ""), .init(name: "Value", type: "")],
                    rows: [["Name", table.name], ["Type", table.type ?? ""]]))
            }
            guard revision == sessionRevision, canUseConnection else { return }
            if let sql = dialect.relationsSQL(table) { apply(await fetch(sql), to: relationsPane, for: table, what: "relations", revision: revision) }
            if let sql = dialect.triggersSQL(table) { apply(await fetch(sql), to: triggersPane, for: table, what: "triggers", revision: revision) }
            if let sql = dialect.viewDefinitionSQL(table), case .success(let result) = await fetch(sql),
               revision == sessionRevision, selectedTableID == table.id { viewDefinition = result.cell(0, 0, maxLength: nil) ?? "" }
            if let createSQL = dialect.createTableSQL(table),
                case .success(let result) = await fetch(createSQL),
                revision == sessionRevision, canUseConnection, selectedTableID == table.id
            {
                createStatement =
                    result.cell(0, result.columns.count - 1, maxLength: nil) ?? ""
            }
            if revision == sessionRevision, canUseConnection, selectedTableID == table.id {
                statusMessage = "Information about \(table.name)"
            }
        }
    }

    /// A one-row result as Property/Value rows.
    private static func transposed(_ result: QueryResult) -> QueryResult {
        let row = result.rowCount > 0 ? result.row(0) : []
        return QueryResult(
            columns: [.init(name: "Property", type: ""), .init(name: "Value", type: "")],
            rows: result.columns.enumerated().map { index, column in
                [column.name, index < row.count ? row[index] : nil]
            })
    }

    // MARK: Query tab

    var canRun: Bool {
        canUseConnection && !isRunning
    }

    func setSQL(_ text: String) {
        sql = text
        sqlRevision += 1
    }

    private func scheduleDraftSave() {
        guard draftKey != nil else { return }
        draftSaveTask?.cancel()
        draftSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            self?.saveDraft()
        }
    }

    /// Stores the editor's text as the current connection's draft.
    func saveDraft() {
        draftSaveTask?.cancel()
        draftSaveTask = nil
        guard let draftKey else { return }
        do {
            try queryLibrary.saveDraft(sql, for: draftKey)
        } catch {
            libraryFeedback = "Draft could not be saved: \(error)"
        }
    }

    /// Runs every statement in the editor (the Run button).
    func runQuery() {
        run(dialect.statements(in: sql), sourceSQL: sql)
    }

    func explainQuery() {
        guard canRun else { return }
        guard dialect.supportsExplain else {
            queryStatus = QueryStatus(text: "EXPLAIN unavailable", error: "EXPLAIN is currently supported for PostgreSQL and MySQL.")
            return
        }
        let submission = TextEditorSubmission(text: sql, selection: editorSelection, cursor: editorCursor)
        let statements = submission.selectedText.map { dialect.statements(in: $0) }
            ?? dialect.statement(in: sql, at: editorCursor).map { [$0] } ?? []
        guard statements.count == 1, let statement = statements.first,
              SQLSafetyAssessment(statement.text, dialect: dialect).allowsReadOnly,
              !statement.text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().hasPrefix("EXPLAIN") else {
            queryStatus = QueryStatus(text: "Choose one query to explain", error: "Place the cursor in a read-only statement or select exactly one. EXPLAIN never adds ANALYZE.")
            return
        }
        run(dialect.statements(in: (dialect == .sqlite ? "EXPLAIN QUERY PLAN " : "EXPLAIN ") + statement.text), sourceSQL: sql, explaining: true)
    }

    /// Ctrl+Enter: runs the selected statements, or else the statement the
    /// cursor is in.
    func runCurrentStatement(_ submission: TextEditorSubmission) {
        sql = submission.text
        if let selected = submission.selectedText {
            run(dialect.statements(in: selected), sourceSQL: submission.text, baseOffset: submission.selection?.lowerBound ?? 0)
        } else {
            run(dialect.statement(in: submission.text, at: submission.cursor).map { [$0] } ?? [], sourceSQL: submission.text)
        }
    }

    /// Runs statements one after another, stopping at the first error, and
    /// shows the last result that has columns.
    private func run(_ statements: [SQLStatement], sourceSQL: String, baseOffset: Int = 0, confirmed: Bool = false, explaining: Bool = false) {
        guard connection != nil, canRun else { return }
        guard !statements.isEmpty else {
            statusMessage = "Nothing to run"
            queryStatus = QueryStatus(text: "Nothing to run")
            queryErrorLocation = nil
            pendingQuery = nil
            return
        }
        queryErrorLocation = nil
        errorMessage = nil
        let assessments = statements.map { SQLSafetyAssessment($0.text, dialect: dialect) }
        if connectionSafety.readOnly && (!dialect.supportsReadOnly || assessments.contains { !$0.allowsReadOnly }) {
            pendingQuery = nil
            let message = !dialect.supportsReadOnly
                ? "Read-only execution is supported for PostgreSQL, MySQL, SQLite and DuckDB."
                : "Read-only favorite: this batch contains a statement that is not allowed. Nothing was executed."
            queryStatus = QueryStatus(text: "Blocked by read-only mode", error: message)
            errorMessage = message
            return
        }
        let warnings = Array(Set(assessments.flatMap(\.warnings))).sorted()
        if !confirmed && !warnings.isEmpty {
            pendingQuery = PendingQuery(statements: statements, sourceSQL: sourceSQL, baseOffset: baseOffset,
                revision: sessionRevision, warnings: warnings)
            queryStatus = QueryStatus(text: "Awaiting confirmation · nothing executed")
            return
        }
        pendingQuery = nil
        queryCancellationRequested = false
        queryStatus = QueryStatus(text: "Running…")
        let runMaxRows = maxRows ?? 10_000
        // Running SQL by hand leaves table browsing (filter bar, pager,
        // server-side sorting); header clicks then sort in memory.
        isBrowsing = false

        isRunning = true
        errorMessage = nil
        let revision = sessionRevision
        let historyConnection = connectionTitle
        let readOnly = connectionSafety.readOnly
        Task {
            guard revision == sessionRevision, canUseConnection else { return }
            let clock = ContinuousClock()
            let started = clock.now
            var shown: QueryResult?
            var elapsed = Duration.zero
            for (index, statement) in statements.enumerated() {
                if queryCancellationRequested {
                    isRunning = false
                    statusMessage = "Query cancelled"
                    if let shown { queryPane.show(shown) }
                    queryStatus = .failed("Execution stopped. Statements already completed were not rolled back.",
                        elapsed: started.duration(to: clock.now), cancelled: true)
                    queryStatus?.text += " · \(index)/\(statements.count) completed · \(statements.count - index) not executed"
                    return
                }
                statusMessage =
                    statements.count > 1
                    ? "Running statement \(index + 1) of \(statements.count)…" : "Running…"
                // Record only statements we attempt, including failures, never table loads or health probes.
                queryStatus = QueryStatus(text: statements.count > 1 ? "Running statement \(index + 1) of \(statements.count)…" : "Running…")
                let historyID = recordHistory(statement.text, connectionTitle: historyConnection)
                let statementStarted = clock.now
                let plan = explaining || SQLCompletionEngine.scan(statement.text).tokens.first?.text.uppercased() == "EXPLAIN"
                let outcome = await fetch(statement.text, maxRows: runMaxRows, readOnly: readOnly, direct: plan && dialect == .postgres)
                // Persist the attempted statement's outcome even if disconnect or
                // connection loss invalidated this run's UI while it was fetching.
                finishHistory(historyID, elapsed: clock.now - statementStarted, result: try? outcome.get())
                guard revision == sessionRevision, canUseConnection else { return }
                switch outcome {
                    case .success(let result):
                        elapsed += result.elapsed
                        if !result.columns.isEmpty || shown?.columns.isEmpty != false {
                            shown = result
                        }
                    case .failure(let error):
                        if let shown { queryPane.show(shown) }
                        isRunning = false
                        let message = statements.count > 1
                            ? "Statement \(index + 1) of \(statements.count) failed: \(error)" : "\(error)"
                        errorMessage = message
                        let adbcError = error as? ADBCError
                        let cancelled = queryCancellationRequested || (adbcError.map { $0.message.contains("[CANCELLED]") || $0.message.contains("[SQLSTATE 57014]") } ?? false)
                        statusMessage = cancelled ? "Query cancelled" : "Query failed"
                        queryStatus = .failed(message, elapsed: started.duration(to: clock.now), cancelled: cancelled)
                        if statements.count > 1 {
                            queryStatus?.text += " · statement \(index + 1)/\(statements.count) · \(index) completed"
                            if index + 1 < statements.count { queryStatus?.text += " · \(statements.count - index - 1) not executed" }
                        }
                        if !explaining, sql == sourceSQL {
                            queryErrorLocation = QueryErrorLocation.resolve(position: adbcError?.statementPosition,
                                statement: statement, source: sourceSQL, baseOffset: baseOffset)
                        }
                        return
                }
            }
            isRunning = false
            if let shown {
                queryPane.show(shown)
                let completed = QueryStatus.completed(shown, elapsed: elapsed, statements: statements.count, maxRows: runMaxRows)
                queryStatus = completed
                if !explaining, sql == sourceSQL { editorBaselineSQL = sql }
                statusMessage = completed.text
            }
        }
    }

    func cancelPendingQuery() {
        pendingQuery = nil
        queryStatus = QueryStatus(text: "Execution cancelled · nothing executed")
    }

    func confirmPendingQuery() {
        guard let request = pendingQuery else { return }
        pendingQuery = nil
        guard request.revision == sessionRevision, request.sourceSQL == sql else {
            queryStatus = QueryStatus(text: "SQL or connection changed. Run again to review the current query.")
            return
        }
        run(request.statements, sourceSQL: request.sourceSQL, baseOffset: request.baseOffset, confirmed: true)
    }

    @ObservationIgnored private var queryCancellationRequested = false

    func cancelQuery() {
        guard let connection, isRunning else { return }
        queryCancellationRequested = true
        transferProgress?.cancel()
        if isBrowsing { statusMessage = "Cancelling…" }
        else { queryStatus = QueryStatus(text: "Cancelling…") }
        Task.detached {
            do {
                try connection.cancel()
            } catch {
                await MainActor.run {
                    guard self.connection === connection, !self.isConnecting else { return }
                    self.handleConnectionFailure(error, from: connection)
                    if !self.isConnectionLost { self.errorMessage = "\(error)" }
                }
            }
        }
    }

    private static func format(_ elapsed: Duration) -> String {
        let seconds = Double(elapsed.components.attoseconds) / 1e18
            + Double(elapsed.components.seconds)
        return String(format: "%.3fs", seconds)
    }

    // MARK: Whole-table transfers

    @ObservationIgnored var transferVisible = false { didSet { stateChanged() } }
    var supportedExportFormats: [TableExportFormat] { dialect.supportsTableWrites ? TableExportFormat.allCases : TableExportFormat.allCases.filter { $0 != .sql } }
    @ObservationIgnored var transferFormat = TableExportFormat.csv { didSet { stateChanged() } }
    @ObservationIgnored var transferFiltered = false { didSet { stateChanged() } }
    @ObservationIgnored var csvOptions = CSVImportOptions() { didSet { csvPreview = nil; stateChanged() } }
    @ObservationIgnored var csvURL: URL? { didSet { csvPreview = nil; stateChanged() } }
    @ObservationIgnored private(set) var csvPreview: CSVImportPreview? { didSet { stateChanged() } }
    @ObservationIgnored var csvMapping: [String?] = [] { didSet { stateChanged() } }
    @ObservationIgnored private var csvPreviewTable: String?
    @ObservationIgnored private var csvPreviewSession: Int = 0
    @ObservationIgnored private var csvPreviewDocument: UUID?
    @ObservationIgnored private var transferProgress: TransferProgress?
    @ObservationIgnored private(set) var transferMessage = "" { didSet { stateChanged() } }
    @ObservationIgnored private var transferPoll: Task<Void, Never>?
    var canImportCSV: Bool { canRun && !connectionSafety.readOnly && selectedTable != nil && dialect.supportsTableWrites }
    var canConfirmCSV: Bool {
        canImportCSV && csvPreview != nil && csvPreviewTable == selectedTableID && csvPreviewSession == sessionRevision && csvPreviewDocument == activeQueryDocument.id &&
        !csvMapping.compactMap({ $0 }).isEmpty && Set(csvMapping.compactMap { $0 }).count == csvMapping.compactMap({ $0 }).count
    }
    func toggleTransfers() {
        guard !isRunning else { return }
        if !supportedExportFormats.contains(transferFormat) { transferFormat = .csv }
        transferVisible.toggle(); rowEditDraft = nil
    }
    private func startTransfer(_ message: String) -> TransferProgress {
        let progress = TransferProgress()
        transferProgress = progress; isRunning = true; errorMessage = nil
        queryCancellationRequested = false; transferMessage = message
        transferPoll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { break }
                self?.transferMessage = "\(message) · \(progress.rows) rows processed"
            }
        }
        return progress
    }
    private func finishTransfer(_ message: String) {
        transferPoll?.cancel(); transferPoll = nil; transferProgress = nil
        isRunning = false; transferMessage = message; statusMessage = message
    }
    func exportTable(to url: URL) {
        guard canRun, let connection, let table = selectedTable else { return }
        let revision = sessionRevision, format = transferFormat
        let expression = transferFiltered && isBrowsing ? effectiveFilter : nil
        let order = isBrowsing ? contentSort.flatMap { sort in contentColumns.indices.contains(sort.column) ? (column: contentColumns[sort.column], ascending: sort.ascending) : nil } : nil
        let readOnly = connectionSafety.readOnly
        let progress = startTransfer("Exporting \(table.name)")
        Task {
            let outcome = await Task.detached { () -> Result<Int64, Error> in
                Result { try connection.exportTable(table, to: url, format: format, expression: expression, orderBy: order, readOnly: readOnly, runtime: TransferRuntime.discover(), progress: progress) }
            }.value
            guard revision == sessionRevision, self.connection === connection else { return }
            switch outcome {
            case .success(let rows): finishTransfer("Exported \(rows) rows to \(url.lastPathComponent)")
            case .failure(let error): finishTransfer("Export failed"); errorMessage = "\(error)"; handleConnectionFailure(error, from: connection)
            }
        }
    }
    func previewCSV() {
        guard canImportCSV, let connection, let table = selectedTable, let url = csvURL else { return }
        csvPreview = nil
        let revision = sessionRevision, document = activeQueryDocument.id, options = csvOptions
        let progress = startTransfer("Previewing CSV")
        Task {
            let outcome = await Task.detached { () -> Result<CSVImportPreview, Error> in
                Result { try connection.previewCSV(url, into: table, options: options, runtime: TransferRuntime.discover(), progress: progress) }
            }.value
            guard revision == sessionRevision, self.connection === connection else { return }
            finishTransfer("CSV preview ready")
            guard selectedTableID == table.id, document == activeQueryDocument.id, csvOptions == options, csvURL == url else { return }
            switch outcome {
            case .success(let preview):
                csvPreview = preview; csvPreviewTable = table.id; csvPreviewSession = revision; csvPreviewDocument = document
                csvMapping = preview.headers.map { header in preview.columns.first { $0.name == header && !$0.computed && !$0.identity }?.name }
            case .failure(let error): transferMessage = "Preview failed"; errorMessage = "\(error)"; handleConnectionFailure(error, from: connection)
            }
        }
    }
    func confirmCSVImport() {
        guard canConfirmCSV, let connection, let table = selectedTable, let preview = csvPreview, let url = csvURL else { return }
        let revision = sessionRevision, options = csvOptions, mapping = csvMapping, document = activeQueryDocument.id
        csvPreview = nil
        let progress = startTransfer("Importing into \(table.name)")
        Task {
            let outcome = await Task.detached { () -> Result<Int64, Error> in
                Result { try connection.importCSV(url, into: table, options: options, preview: preview, mapping: mapping, runtime: TransferRuntime.discover(), progress: progress) }
            }.value
            guard revision == sessionRevision, self.connection === connection else { return }
            switch outcome {
            case .success(let rows):
                finishTransfer("Imported \(rows) rows into \(table.name)")
                contentTotal = nil; rowEstimates.removeValue(forKey: table.id); editMetadata.removeValue(forKey: table.id)
                if selectedTableID == table.id, activeQueryDocument.id == document, isBrowsing { loadContent(table) }
            case .failure(let error): finishTransfer("Import failed; transaction rolled back"); errorMessage = "\(error)"; handleConnectionFailure(error, from: connection)
            }
        }
    }

    // MARK: Export

    func exportCSV(_ pane: ResultPane, to url: URL) {
        guard let result = pane.result else { return }
        let escape = ResultCopy.csvField
        var csv = result.columns.map { escape($0.name) }.joined(separator: ",") + "\n"
        for row in 0..<result.rowCount {
            csv += result.row(row).map(escape).joined(separator: ",") + "\n"
        }
        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
            statusMessage = "Exported \(result.rowCount) rows to \(url.lastPathComponent)"
        } catch {
            errorMessage = "Export failed: \(error.localizedDescription)"
        }
    }
}

extension BrowserModel {
    /// A binding that ignores writes of an unchanged value.
    ///
    /// `@Observable` notifies on every assignment, even of an equal value, and
    /// some controls (e.g. `Picker`) write their binding back while being
    /// updated, which would trigger an extra re-render each time.
    func binding<Value: Equatable>(
        _ keyPath: ReferenceWritableKeyPath<BrowserModel, Value>
    ) -> Binding<Value> {
        Binding(
            get: { self[keyPath: keyPath] },
            set: { newValue in
                if self[keyPath: keyPath] != newValue {
                    self[keyPath: keyPath] = newValue
                }
            }
        )
    }
}
