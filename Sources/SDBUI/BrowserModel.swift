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
    var isConnecting = false
    private(set) var isConnectionLost = false
    @ObservationIgnored private var reconnectSource: ConnectionSource?
    @ObservationIgnored private var sessionRevision = 0
    @ObservationIgnored private var connectionMonitor: Task<Void, Never>?
    @ObservationIgnored private let openConnection: @Sendable (ConnectionSource) throws -> ADBCConnection
    @ObservationIgnored private let healthCheckIntervalNanoseconds: UInt64

    init(
        openConnection: @escaping @Sendable (ConnectionSource) throws -> ADBCConnection = { try ADBCConnection.open($0) },
        healthCheckIntervalNanoseconds: UInt64 = 5_000_000_000,
        queryLibrary: QueryLibraryStore = QueryLibraryStore()
    ) {
        self.openConnection = openConnection
        self.queryLibrary = queryLibrary
        self.libraryFeedback = queryLibrary.loadError ?? ""
        self.healthCheckIntervalNanoseconds = healthCheckIntervalNanoseconds
    }

    var canUseConnection: Bool { connection != nil && !isConnectionLost && !isConnecting }


    // MARK: Schema

    var tables: [TableInfo] = []
    /// The database (MySQL) or schema (PostgreSQL) shown in the sidebar. It's
    /// also the session's default, so unqualified table names resolve in it.
    private(set) var selectedDatabase: String?
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
    let pageSize = 1000
    @ObservationIgnored private(set) lazy var structurePane = makePane()
    @ObservationIgnored private(set) lazy var indexPane = makePane()
    @ObservationIgnored private(set) lazy var infoPane: ResultPane = {
        let pane = makePane()
        pane.isSortable = false  // property/value pairs
        return pane
    }()
    @ObservationIgnored private(set) lazy var queryPane = makePane()
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
            } else {
                queryPane.sortHandler = nil
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

    private func recordHistory(_ statement: String, connectionTitle: String) {
        do {
            try queryLibrary.record(sql: statement, connection: connectionTitle)
            libraryRevision += 1
        } catch {
            libraryFeedback = "History could not be saved: \(error)"
        }
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
        didSet { if sql != oldValue { scheduleDraftSave() } }
    }
    /// The connection whose draft the editor holds (its title).
    @ObservationIgnored private var draftKey: String?
    @ObservationIgnored private var draftSaveTask: Task<Void, Never>?
    /// Bumped by ``setSQL(_:)`` so the editor picks up programmatic changes.
    @ObservationIgnored private(set) var sqlRevision = 0 { didSet { stateChanged() } }
    @ObservationIgnored private(set) var isRunning = false { didSet { stateChanged() } }
    var maxRows: Int? = 10_000
    let maxRowsOptions = [100, 1_000, 10_000, 100_000]

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
                case .failure(let error): connectionFeedback = "Connection test failed: \(error)"
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
            connect(source, title: connectionDraft.name.isEmpty ? connectionDraft.driver : connectionDraft.name)
        } catch {
            connectionFeedback = "Connection failed: \(error)"
        }
    }

    func connectSelectedProfile() {
        guard let selectedProfileID else { return }
        guard let profile = profiles.first(where: { $0.id == selectedProfileID }) else { return }
        connect(.profile(profile.url.path), title: profile.id)
    }

    func connectDirect() {
        let uri = directURI.trimmingCharacters(in: .whitespacesAndNewlines)
        // Let the URI scheme pick the driver when it names an installed one,
        // like `databow --uri postgresql://…`.
        let inferred = Discovery.driverName(forURI: uri)
        let driver = drivers.contains { $0.id == inferred } ? inferred : directDriver?.id
        connect(.direct(driver: driver, uri: uri), title: driver ?? "connection")
    }

    private func connect(_ source: ConnectionSource, title: String, reconnecting: Bool = false) {
        guard !isConnecting else { return }
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
                    let vendor = [connection.vendorName, connection.vendorVersion]
                        .compactMap { $0 }.joined(separator: " ")
                    statusMessage = reconnecting
                        ? "Reconnected. Run your query when ready."
                        : (vendor.isEmpty ? "Connected" : "Connected to \(vendor)")
                    if !reconnecting {
                        // Keep the previous connection's draft, then open this one's.
                        saveDraft()
                        draftKey = title
                        if !runOnConnect, let draft = queryLibrary.draft(for: title) {
                            setSQL(draft)
                        } else if sql.isEmpty {
                            setSQL("SELECT 1")
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
            }
        }
    }

    func reconnect() {
        guard isConnectionLost, let reconnectSource, !isConnecting else { return }
        connect(reconnectSource, title: connectionTitle, reconnecting: true)
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
        isRunning = false
        connectionMonitor?.cancel()
        Self.release(failed)
        statusMessage = "Connection lost — reconnect to continue."
        errorMessage = "\(error)"
    }

    func disconnect() {
        saveDraft()
        draftKey = nil
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
        tables = []
        selectedDatabase = nil
        selectedTableID = nil
        loadedTables = [:]
        clearTablePanes()
        queryPane.show(nil)
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

    /// Tables of the selected database whose name contains `filter`.
    func visibleTables(matching filter: String) -> [TableInfo] {
        let filter = filter.trimmingCharacters(in: .whitespaces).lowercased()
        return tables.filter { table in
            table.namespace == (selectedDatabase ?? "")
                && (filter.isEmpty || table.name.lowercased().contains(filter))
        }
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
            return "\(table.name)  (\(type.lowercased()))"
        }
        return table.name
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
                    if let preferred = preferredDatabase, databases.contains(preferred) {
                        selectedDatabase = preferred
                    } else if selectedDatabase.map({ !databases.contains($0) }) ?? true {
                        selectedDatabase = sessionDatabase.flatMap { databases.contains($0) ? $0 : nil }
                            ?? databases.first
                    }
                    preferredDatabase = nil
                    applySelectedDatabase()
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
        contentSort = nil
        contentColumns = []
        filterColumn = nil
        clearTablePanes()
        loadCurrentTab()
    }

    private func clearTablePanes() {
        for pane in [structurePane, indexPane, infoPane] {
            pane.show(nil)
        }
        createStatement = ""
    }

    // MARK: Tabs

    func selectTab(_ tab: BrowserTab) {
        selectedTab = tab
        loadCurrentTab()
    }

    /// Reload what the current tab shows.
    func refreshCurrentTab() {
        guard canUseConnection else { return }
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
    private func fetch(_ sql: String, maxRows: Int = 10_000) async -> Result<QueryResult, any Error> {
        guard canUseConnection, let connection else { return .failure(ADBCError("Not connected")) }
        let revision = sessionRevision
        loadsInFlight += 1
        defer { if revision == sessionRevision { loadsInFlight -= 1 } }
        let outcome = await Task.detached {
            Result { try connection.execute(sql, maxRows: maxRows) }
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
        guard canUseConnection, let table = selectedTable else { return }
        contentOffset = 0
        contentFilter = nil
        contentSort = nil
        contentColumns = []
        filterColumn = nil
        loadContent(table)
    }

    /// Shows one page of `table` in the Query tab, with its SQL above the rows.
    private func loadContent(_ table: TableInfo) {
        guard canUseConnection else { return }
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
        browseSQL = displayedSQL
        isBrowsing = true
        isRunning = true
        errorMessage = nil
        statusMessage = "Loading \(table.name)…"
        Task {
            guard revision == sessionRevision, canUseConnection else { return }
            let outcome = await fetch(sql)
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
                    }
                    statusMessage = "\(contentRowsLabel) in \(Self.format(result.elapsed))"
                case .failure(let error):
                    contentHasMore = false
                    queryPane.show(nil)
                    statusMessage = "Loading \(table.name) failed"
                    errorMessage = "\(error)"
            }
        }
    }

    var contentRowsLabel: String {
        let count = queryPane.result?.rowCount ?? 0
        guard count > 0 else { return contentFilter == nil ? "No rows" : "No matching rows" }
        let more = contentHasMore ? "+" : ""
        return "Rows \(contentOffset + 1)–\(contentOffset + count)\(more)"
    }

    private func sortContent(by sort: DataGridSort) {
        guard canUseConnection else { return }
        guard let table = selectedTable, sort != contentSort else { return }
        contentSort = sort
        contentOffset = 0
        loadContent(table)
    }

    func showContentPage(next: Bool) {
        guard canUseConnection else { return }
        guard let table = selectedTable else { return }
        contentOffset = max(0, contentOffset + (next ? pageSize : -pageSize))
        loadContent(table)
    }

    func applyContentFilter() {
        guard canUseConnection else { return }
        guard let table = selectedTable else { return }
        if let column = filterColumn ?? contentColumns.first, let op = filterOperator {
            contentFilter = SQLDialect.Filter(column: column, op: op, value: filterValue)
        } else {
            contentFilter = nil
        }
        contentOffset = 0
        loadContent(table)
    }

    func clearContentFilter() {
        guard canUseConnection else { return }
        guard let table = selectedTable, contentFilter != nil else { return }
        contentFilter = nil
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
        run(dialect.statements(in: sql).map(\.text))
    }

    /// Ctrl+Enter: runs the selected statements, or else the statement the
    /// cursor is in.
    func runCurrentStatement(_ submission: TextEditorSubmission) {
        sql = submission.text
        if let selected = submission.selectedText {
            run(dialect.statements(in: selected).map(\.text))
        } else {
            run(dialect.statement(in: submission.text, at: submission.cursor).map { [$0.text] } ?? [])
        }
    }

    /// Runs statements one after another, stopping at the first error, and
    /// shows the last result that has columns.
    private func run(_ statements: [String]) {
        guard connection != nil, canRun else { return }
        guard !statements.isEmpty else {
            statusMessage = "Nothing to run"
            return
        }
        // Running SQL by hand leaves table browsing (filter bar, pager,
        // server-side sorting); header clicks then sort in memory.
        isBrowsing = false

        isRunning = true
        errorMessage = nil
        let revision = sessionRevision
        let historyConnection = connectionTitle
        Task {
            guard revision == sessionRevision, canUseConnection else { return }
            var shown: QueryResult?
            var elapsed = Duration.zero
            for (index, statement) in statements.enumerated() {
                statusMessage =
                    statements.count > 1
                    ? "Running statement \(index + 1) of \(statements.count)…" : "Running…"
                // Record only statements we attempt, including failures, never table loads or health probes.
                recordHistory(statement, connectionTitle: historyConnection)
                let outcome = await fetch(statement, maxRows: maxRows ?? 10_000)
                guard revision == sessionRevision, canUseConnection else { return }
                switch outcome {
                    case .success(let result):
                        elapsed += result.elapsed
                        if !result.columns.isEmpty || shown?.columns.isEmpty != false {
                            shown = result
                        }
                    case .failure(let error):
                        isRunning = false
                        statusMessage = "Query failed"
                        errorMessage =
                            statements.count > 1
                            ? "Statement \(index + 1) of \(statements.count) failed: \(error)" : "\(error)"
                        return
                }
            }
            isRunning = false
            if let shown {
                queryPane.show(shown)
                statusMessage =
                    statements.count > 1
                    ? "\(statements.count) statements in \(Self.format(elapsed)); last result: "
                        + Self.summary(of: shown)
                    : Self.summary(of: shown)
            }
        }
    }

    func cancelQuery() {
        guard let connection, isRunning else { return }
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

    private static func summary(of result: QueryResult) -> String {
        let time = format(result.elapsed)
        if result.columns.isEmpty {
            if let affected = result.rowsAffected {
                return "\(affected) row\(affected == 1 ? "" : "s") affected in \(time)"
            }
            return "Statement executed in \(time)"
        }
        let rows = result.rowCount
        let more = result.truncated ? " (limit reached; more rows available)" : ""
        return "\(rows) row\(rows == 1 ? "" : "s")\(more) in \(time)"
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
