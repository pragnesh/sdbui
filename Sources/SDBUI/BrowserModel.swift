import ADBCKit
import Foundation
import SwiftCrossUI

#if canImport(Observation)
    import Observation
#endif

/// All state for the query browser window.
///
/// ADBC calls block, so they run on detached tasks; results are applied back
/// on the main actor.
@Observable
@MainActor
final class BrowserModel {
    // MARK: Connection setup

    var profiles: [ConnectionProfile] = []
    var drivers: [DriverManifest] = []
    var selectedProfileID: String?
    var directDriver: DriverManifest?
    var directURI = ""

    // MARK: Connection state

    var connection: ADBCConnection?
    var connectionTitle = ""
    var isConnecting = false

    // MARK: Schema browser

    var tables: [TableInfo] = []
    /// What's typed in the table filter field; see ``TableBrowser``.
    @ObservationIgnored var tableFilterDraft = ""
    @ObservationIgnored private var tableFilterTask: Task<Void, Never>?
    var showSystemSchemas = false
    @ObservationIgnored private(set) var selectedTableID: String? { didSet { queryStateChanged() } }
    @ObservationIgnored private(set) var selectedTableColumns: [ResultColumn] = [] {
        didSet { queryStateChanged() }
    }

    // MARK: Editor and results
    //
    // This state changes on every query, so it isn't `@Observable`: SwiftCrossUI's
    // observation merges child views' reads into their ancestors, so changing
    // an observed property re-renders and re-lays-out the whole window. The
    // views that show it subscribe with ``onQueryStateChange(_:_:)`` instead
    // and re-render on their own.

    /// The editor's text. Not observed: the GTK text view owns the live text,
    /// and observing every keystroke made SwiftCrossUI re-layout the whole
    /// window per key. Code that replaces the text calls ``setSQL(_:)``.
    @ObservationIgnored var sql = ""
    /// Bumped by ``setSQL(_:)`` so the editor picks up programmatic changes.
    @ObservationIgnored private(set) var sqlRevision = 0 { didSet { queryStateChanged() } }
    @ObservationIgnored private(set) var isRunning = false { didSet { queryStateChanged() } }
    @ObservationIgnored private(set) var result: QueryResult? { didSet { queryStateChanged() } }
    @ObservationIgnored private(set) var page = 0 { didSet { queryStateChanged() } }
    /// The current page rendered as monospaced text (see ``ResultText``).
    @ObservationIgnored private(set) var gridHeader = "" { didSet { queryStateChanged() } }
    @ObservationIgnored private(set) var gridBody = "" { didSet { queryStateChanged() } }
    @ObservationIgnored private var columnWidths: [Int] = []
    var maxRows: Int? = 10_000
    let pageSize = 100
    let maxRowsOptions = [100, 1_000, 10_000, 100_000]

    @ObservationIgnored private(set) var statusMessage = "Not connected" {
        didSet { queryStateChanged() }
    }
    @ObservationIgnored private(set) var errorMessage: String? { didSet { queryStateChanged() } }

    @ObservationIgnored private var queryStateSubscribers: [String: @MainActor () -> Void] = [:]
    @ObservationIgnored private var queryStateNotificationPending = false

    /// Call `update` (once per batch of changes) whenever query state changes.
    /// Re-registering under the same `key` replaces the previous callback.
    func onQueryStateChange(_ key: String, _ update: @escaping @MainActor () -> Void) {
        queryStateSubscribers[key] = update
    }

    private func queryStateChanged() {
        guard !queryStateNotificationPending else { return }
        queryStateNotificationPending = true
        Task { @MainActor in
            queryStateNotificationPending = false
            for update in queryStateSubscribers.values {
                update()
            }
        }
    }

    func selectTable(_ id: String?) {
        guard id != selectedTableID else { return }
        selectedTableID = id
        openSelectedTable()
    }

    static let systemSchemas: Set<String> = [
        "information_schema", "pg_catalog", "pg_toast", "mysql", "performance_schema", "sys",
    ]

    // MARK: Discovery

    func reloadDiscovery() {
        profiles = Discovery.profiles()
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
            selectedProfileID = profile
            connectSelectedProfile()
        }
    }

    @ObservationIgnored private var runOnConnect = false

    // MARK: Connecting

    func connectSelectedProfile() {
        guard let selectedProfileID else { return }
        connect(.profile(selectedProfileID), title: selectedProfileID)
    }

    func connectDirect() {
        let uri = directURI.trimmingCharacters(in: .whitespacesAndNewlines)
        // Let the URI scheme pick the driver when it names an installed one,
        // like `databow --uri postgresql://…`.
        let inferred = Discovery.driverName(forURI: uri)
        let driver = drivers.contains { $0.id == inferred } ? inferred : directDriver?.id
        connect(.direct(driver: driver, uri: uri), title: driver ?? "connection")
    }

    private func connect(_ source: ConnectionSource, title: String) {
        guard !isConnecting else { return }
        isConnecting = true
        errorMessage = nil
        statusMessage = "Connecting to \(title)…"

        Task {
            let outcome = await Task.detached {
                Result { try ADBCConnection.open(source) }
            }.value
            isConnecting = false

            switch outcome {
                case .success(let connection):
                    self.connection = connection
                    connectionTitle = title
                    show(nil)
                    tables = []
                    selectedTableID = nil
                    let vendor = [connection.vendorName, connection.vendorVersion]
                        .compactMap { $0 }.joined(separator: " ")
                    statusMessage = vendor.isEmpty ? "Connected" : "Connected to \(vendor)"
                    if sql.isEmpty {
                        setSQL("SELECT 1")
                    }
                    refreshTables()
                    if runOnConnect {
                        runOnConnect = false
                        runQuery()
                    }
                case .failure(let error):
                    statusMessage = "Connection failed"
                    errorMessage = "\(error)"
            }
        }
    }

    func disconnect() {
        connection = nil
        tables = []
        selectedTableID = nil
        selectedTableColumns = []
        show(nil)
        statusMessage = "Not connected"
    }

    // MARK: Schema browser

    var vendorDescription: String {
        guard let connection else { return "" }
        return [connection.vendorName, connection.vendorVersion].compactMap { $0 }
            .joined(separator: " ")
    }

    func visibleTables(matching filter: String) -> [TableInfo] {
        let filter = filter.trimmingCharacters(in: .whitespaces).lowercased()
        return tables.filter { table in
            (showSystemSchemas || !Self.systemSchemas.contains(table.namespace.lowercased()))
                && (filter.isEmpty || table.name.lowercased().contains(filter)
                    || table.namespace.lowercased().contains(filter))
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
        let name = table.namespace.isEmpty ? table.name : "\(table.namespace).\(table.name)"
        if let type = table.type, type.uppercased() != "TABLE", type.uppercased() != "BASE TABLE" {
            return "\(name)  (\(type.lowercased()))"
        }
        return name
    }

    func refreshTables() {
        guard let connection else { return }
        Task {
            let outcome = await Task.detached { Result { try connection.tables() } }.value
            switch outcome {
                case .success(let tables):
                    self.tables = tables.sorted {
                        $0.namespace == $1.namespace ? $0.name < $1.name : $0.namespace < $1.namespace
                    }
                case .failure(let error):
                    errorMessage = "Could not list tables: \(error)"
            }
        }
    }

    /// Show a table's columns and preview its first rows.
    func openSelectedTable() {
        guard let connection, let table = selectedTable else {
            selectedTableColumns = []
            return
        }
        setSQL("SELECT * FROM \(connection.qualifiedName(of: table)) LIMIT \(pageSize)")
        runQuery()

        Task {
            let outcome = await Task.detached { Result { try connection.columns(of: table) } }.value
            // Drivers without GetTableSchema just leave the list empty.
            selectedTableColumns = (try? outcome.get()) ?? []
        }
    }

    // MARK: Queries

    var canRun: Bool {
        connection != nil && !isRunning
    }

    func setSQL(_ text: String) {
        sql = text
        sqlRevision += 1
    }

    func runQuery() {
        guard let connection, canRun else { return }
        var statement = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !statement.isEmpty else {
            statusMessage = "Nothing to run"
            return
        }
        while statement.hasSuffix(";") {
            statement = String(statement.dropLast()).trimmingCharacters(in: .whitespaces)
        }
        let limit = maxRows ?? 10_000

        isRunning = true
        errorMessage = nil
        statusMessage = "Running…"

        Task {
            let outcome = await Task.detached {
                Result { try connection.execute(statement, maxRows: limit) }
            }.value
            isRunning = false

            switch outcome {
                case .success(let result):
                    show(result)
                    statusMessage = summary(of: result)
                case .failure(let error):
                    statusMessage = "Query failed"
                    errorMessage = "\(error)"
            }
        }
    }

    func cancelQuery() {
        guard let connection, isRunning else { return }
        Task.detached {
            do {
                try connection.cancel()
            } catch {
                await MainActor.run { self.errorMessage = "\(error)" }
            }
        }
    }

    private func summary(of result: QueryResult) -> String {
        let seconds = Double(result.elapsed.components.attoseconds) / 1e18
            + Double(result.elapsed.components.seconds)
        let time = String(format: "%.3fs", seconds)
        if result.columns.isEmpty {
            if let affected = result.rowsAffected {
                return "\(affected) row\(affected == 1 ? "" : "s") affected in \(time)"
            }
            return "Statement executed in \(time)"
        }
        let rows = result.rows.count
        let more = result.truncated ? " (limit reached; more rows available)" : ""
        return "\(rows) row\(rows == 1 ? "" : "s")\(more) in \(time)"
    }

    // MARK: Paging

    private func show(_ result: QueryResult?) {
        self.result = result
        columnWidths = result.map(ResultText.columnWidths(of:)) ?? []
        gridHeader = result.map { ResultText.header(of: $0, widths: columnWidths) } ?? ""
        showPage(0)
    }

    func showPage(_ page: Int) {
        self.page = max(0, min(page, pageCount - 1))
        gridBody = result.map { ResultText.body(of: $0, rows: pageRange, widths: columnWidths) } ?? ""
    }

    var pageCount: Int {
        guard let result, !result.rows.isEmpty else { return 1 }
        return (result.rows.count + pageSize - 1) / pageSize
    }

    var pageRange: Range<Int> {
        guard let result else { return 0..<0 }
        let start = min(page * pageSize, result.rows.count)
        return start..<min(start + pageSize, result.rows.count)
    }

    // MARK: Export

    func exportCSV(to url: URL) {
        guard let result else { return }
        func escape(_ field: String?) -> String {
            guard let field else { return "" }
            if field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) {
                return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }
            return field
        }
        var csv = result.columns.map { escape($0.name) }.joined(separator: ",") + "\n"
        for row in result.rows {
            csv += row.map(escape).joined(separator: ",") + "\n"
        }
        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
            statusMessage = "Exported \(result.rows.count) rows to \(url.lastPathComponent)"
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
