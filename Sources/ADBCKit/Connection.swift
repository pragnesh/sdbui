import CADBC
import Foundation

/// How to open a connection — the same two modes databow offers.
public enum ConnectionSource: Sendable, Hashable {
    case ssh(driver: String, options: [ConnectionProfile.Option], settings: SSHSettings)
    /// A saved profile, by name or path.
    case profile(String)
    /// An explicit driver (name, manifest or library path) plus options.
    /// When `driver` is nil it is inferred from the URI scheme.
    case direct(driver: String?, uri: String, options: [ConnectionProfile.Option] = [])
}

public struct TableInfo: Sendable, Hashable, Identifiable {
    public var catalog: String?
    public var schema: String?
    public var name: String
    public var type: String?

    public var id: String { [catalog ?? "", schema ?? "", name].joined(separator: "\u{1F}") }

    /// The container shown above the table in the browser.
    public var namespace: String {
        if let schema, !schema.isEmpty { return schema }
        return catalog ?? ""
    }
}

/// An open ADBC connection.
///
/// Statements are serialized with a lock (ADBC connections are not
/// thread-safe), but ``cancel()`` can be called from any thread while a query
/// is running.
public final class ADBCConnection: @unchecked Sendable {
    private let session: OpaquePointer
    private let lock = NSLock()
    private var userTransaction = false
    private var transactionSettingsUnknown = false
    private let tunnel: SSHTunnel?

    public let source: ConnectionSource
    public private(set) var vendorName: String?
    public private(set) var vendorVersion: String?

    public static func open(_ source: ConnectionSource,
                            sshExecutableURL: URL = URL(fileURLWithPath: "/usr/bin/ssh")) throws -> ADBCConnection {
        let driver: String
        var options: [ConnectionProfile.Option]
        var tunnel: SSHTunnel?
        switch source {
            case .profile(let reference):
                let profile = try Discovery.profile(named: reference)
                if profile.ssh.enabled {
                    return try open(ConnectionDraft(profile: profile).source(), sshExecutableURL: sshExecutableURL)
                }
                driver = profile.driver
                options = try profile.options.map {
                    .init(key: $0.key, value: try Discovery.substitutingEnvironment(in: $0.value))
                }
            case .ssh(let name, let original, let settings):
                driver = name
                options = original
                let destination = try TunnelDestination(
                    uri: options.last(where: { $0.key == "uri" })?.value ?? "", driver: driver)
                let started = try SSHTunnel.start(settings: settings, destination: destination, executableURL: sshExecutableURL)
                tunnel = started
                options.removeAll { $0.key == "uri" }
                options.insert(.init(key: "uri", value: destination.forwardedURI(localPort: started.localPort)), at: 0)
            case .direct(let explicitDriver, let uri, let extra):
                guard let name = explicitDriver ?? Discovery.driverName(forURI: uri) else {
                    throw ADBCError("Could not infer a driver from '\(uri)'; choose one explicitly")
                }
                driver = name
                let pathDriver = name.lowercased().contains("duckdb")
                options = uri.isEmpty ? [] : [.init(key: pathDriver ? "path" : "uri", value: uri)]
                options += extra
        }

        // DuckDB's ADBC database option is path; favorites use the common URI field.
        if driver.lowercased().contains("duckdb") {
            let hasPath = options.contains { $0.key == "path" }
            options = options.compactMap { option in
                if option.key != "uri" { return option }
                return hasPath ? nil : .init(key: "path", value: option.value)
            }
        }

        let (library, entrypoint) = try Discovery.resolveDriver(driver)
        if Discovery.installedDrivers().contains(where: { $0.libraryPath == library && $0.displayName.lowercased().contains("foundry") && $0.id == "mysql" }) {
            options = try options.map { option in
                option.key == "uri" ? .init(key: option.key, value: try MySQLTransport.foundryURI(option.value)) : option
            }
        }
        let session = try withCStrings(options.map(\.key)) { keys in
            try withCStrings(options.map(\.value)) { values in
                var error: UnsafeMutablePointer<CChar>?
                let session = keys.withUnsafeBufferPointer { keyBuffer in
                    values.withUnsafeBufferPointer { valueBuffer in
                        cadbc_open(
                            library, entrypoint, keyBuffer.baseAddress, valueBuffer.baseAddress,
                            options.count, &error)
                    }
                }
                guard let session else { throw takeError(error, fallback: "Failed to connect") }
                return session
            }
        }

        let connection = ADBCConnection(session: session, source: source, tunnel: tunnel)
        connection.loadVendorInfo()
        return connection
    }

    private init(session: OpaquePointer, source: ConnectionSource, tunnel: SSHTunnel?) {
        self.session = session
        self.source = source
        self.tunnel = tunnel
    }

    deinit {
        cadbc_close(session)
        tunnel?.stop()
    }

    /// Stop forwarding immediately when the user explicitly disconnects.
    public func stopTunnel() { tunnel?.stop() }

    // MARK: Queries

    /// Run `sql`, keeping at most `maxRows` rows.
    public func execute(_ sql: String, maxRows: Int, usePostgresCopy: Bool = true) throws -> QueryResult {
        lock.lock()
        defer { lock.unlock() }
        let dialect = SQLDialect(vendorName: vendorName)
        let controls = dialect.statements(in: sql).map { SafetyLexer.tokens($0.text, dialect: dialect).map(\.word) }
        do {
            let result = try executeLocked(sql, maxRows: maxRows, usePostgresCopy: usePostgresCopy)
            for words in controls {
                if ["BEGIN", "START"].contains(words.first ?? "") { userTransaction = true }
                if ["COMMIT", "END", "ROLLBACK"].contains(words.first ?? ""), !words.contains("TO") {
                    userTransaction = words.contains("CHAIN") && !words.contains("NO")
                }
                if ["CALL", "DO", "EXECUTE", "XA", "LOCK"].contains(words.first ?? "") || (words.first == "SET" && words.contains("AUTOCOMMIT")) || words.contains("UNSAFE") || (words.first == "FLUSH" && words.contains("LOCK")) { transactionSettingsUnknown = true }
            }
            return result
        } catch {
            if controls.contains(where: { ["BEGIN", "START", "SET", "CALL", "DO", "EXECUTE", "XA", "LOCK"].contains($0.first ?? "") || $0.contains("UNSAFE") }) { transactionSettingsUnknown = true }
            throw error
        }
    }

    /// The lock covers row verification and COMMIT; unrelated metadata cannot
    /// interleave. Never take ownership of a manually opened transaction.
    public func applyTableMutation(_ mutation: TableMutation) throws {
        lock.lock(); defer { lock.unlock() }
        let dialect = SQLDialect(vendorName: vendorName)
        guard dialect.supportsTableWrites else { throw ADBCError("This driver does not support row editing.") }
        guard !userTransaction, !transactionSettingsUnknown else {
            throw ADBCError("Finish the manual transaction before editing rows. Reconnect after changing autocommit settings or executing transaction-controlling procedures.")
        }
        guard cadbc_autocommit_enabled(session) == 1 else { throw ADBCError("Row editing requires a driver with confirmed autocommit enabled.") }
        let sql = try mutation.sql(dialect)
        _ = try executeLocked(dialect == .postgres ? "BEGIN" : "START TRANSACTION", maxRows: 0)
        do {
            guard let eligibility = dialect.editableTableSQL(mutation.table),
                  try executeLocked(eligibility, maxRows: 1).cell(0, 0) == "YES" else {
                throw ADBCError("Edits require a base table with transactional storage.")
            }
            if mutation.kind != .insert {
                guard let keySQL = dialect.primaryKeySQL(mutation.table) else { throw ADBCError("Primary-key metadata unavailable.") }
                let keyResult = try executeLocked(keySQL, maxRows: 1000)
                let actualKeys = (0..<keyResult.rowCount).compactMap { keyResult.cell($0, 0, maxLength: nil) }
                guard actualKeys == mutation.keys.map(\.column) else { throw ADBCError("The primary key changed. Refresh before editing.") }
                let predicate = try mutation.keyPredicate(dialect)
                let current = try executeLocked("SELECT * FROM \(dialect.qualifiedName(of: mutation.table)) WHERE \(predicate) LIMIT 2 FOR UPDATE", maxRows: 2)
                let values = current.rowCount == 1 ? current.row(0) : []
                let unchanged = values.count == mutation.originalValues.count && zip(values, mutation.originalValues).allSatisfy { pair in
                    switch pair {
                    case (nil, nil): return true
                    case (let a?, let b?): return a.utf8.elementsEqual(b.utf8)
                    default: return false
                    }
                }
                guard current.rowCount == 1, current.columns.map(\.name) == mutation.originalColumns, unchanged else {
                    throw ADBCError("The row changed or was deleted since it was loaded. Refresh and review it again.")
                }
            }
            let affected = try executeUpdateLocked(sql)
            guard affected == 1 else { throw ADBCError("The change did not affect exactly one row; it was rolled back.") }
            _ = try executeLocked("COMMIT", maxRows: 0)
        } catch {
            do { _ = try executeLocked("ROLLBACK", maxRows: 0) }
            catch { transactionSettingsUnknown = true }
            throw error
        }
    }

    /// Executes one approved read query in a database-enforced read-only transaction.
    /// The lock covers BEGIN, the query and ROLLBACK so other loads cannot interleave.
    public func executeReadOnly(_ sql: String, maxRows: Int, usePostgresCopy: Bool = true) throws -> QueryResult {
        lock.lock(); defer { lock.unlock() }
        guard SQLSafetyAssessment(sql, dialect: dialect).allowsReadOnly else {
            throw ADBCError("Read-only favorite: only read queries are allowed.")
        }
        return try withReadOnlyTransaction {
            try executeLocked(sql, maxRows: maxRows, usePostgresCopy: usePostgresCopy)
        }
    }

    /// The caller owns the connection lock. Do not take over a user's transaction.
    private func withReadOnlyTransaction<T>(_ body: () throws -> T) throws -> T {
        guard dialect.supportsReadOnly, !userTransaction, !transactionSettingsUnknown,
              cadbc_autocommit_enabled(session) == 1 else {
            throw ADBCError("Read-only execution requires an idle connection with confirmed autocommit. Finish manual transactions or reconnect first.")
        }
        let previousQueryOnly = dialect == .sqlite ? try executeLocked("PRAGMA query_only", maxRows: 1).cell(0, 0) : nil
        if dialect == .sqlite, previousQueryOnly != "0", previousQueryOnly != "1" {
            throw ADBCError("This SQLite driver does not expose query_only mode; read-only execution is unavailable.")
        }
        var begun = false
        do {
            if dialect == .sqlite {
                _ = try executeLocked("PRAGMA query_only = ON", maxRows: 0)
                guard try executeLocked("PRAGMA query_only", maxRows: 1).cell(0, 0) == "1" else {
                    throw ADBCError("Could not enable SQLite query_only mode.")
                }
            }
            let begin = dialect == .mysql ? "START TRANSACTION READ ONLY" : dialect == .sqlite ? "BEGIN" : "BEGIN TRANSACTION READ ONLY"
            _ = try executeLocked(begin, maxRows: 0); begun = true
            let result = try body()
            _ = try executeLocked("ROLLBACK", maxRows: 0); begun = false
            if let previousQueryOnly { _ = try executeLocked("PRAGMA query_only = " + (previousQueryOnly == "1" ? "ON" : "OFF"), maxRows: 0) }
            return result
        } catch {
            if begun { do { _ = try executeLocked("ROLLBACK", maxRows: 0) } catch { transactionSettingsUnknown = true } }
            if let previousQueryOnly {
                do { _ = try executeLocked("PRAGMA query_only = " + (previousQueryOnly == "1" ? "ON" : "OFF"), maxRows: 0) }
                catch { transactionSettingsUnknown = true }
            }
            throw error
        }
    }

    private func transferColumns(_ table: TableInfo) throws -> [TransferColumn] {
        guard let sql = dialect.transferColumnsSQL(table) else { return [] }
        let result = try executeLocked(sql, maxRows: 10000)
        guard !result.truncated else { throw ADBCError("Too many columns for transfer metadata.") }
        return (0..<result.rowCount).map { row in
            TransferColumn(name: result.cell(row, 0, maxLength: nil) ?? "", type: result.cell(row, 1) ?? "",
                           computed: result.cell(row, 2) == "YES", identity: result.cell(row, 3) == "YES")
        }
    }

    private func transferStream(_ sql: String, body: (inout ArrowArrayStream) throws -> Void) throws {
        try tunnel?.check()
        var stream = ArrowArrayStream(), rows: Int64 = -1, position: Int64 = 0
        var error: UnsafeMutablePointer<CChar>?
        guard cadbc_execute_options(session, sql, 0, &stream, &rows, &position, &error) == ADBC_STATUS_OK else {
            throw takeError(error, fallback: "Transfer query failed")
        }
        defer { cadbc_stream_release(&stream) }
        try body(&stream)
    }

    /// Consumes the original Arrow batches, without the browser's row limit.
    public func exportTable(_ table: TableInfo, to url: URL, format: TableExportFormat,
                            expression: SQLDialect.FilterExpression? = nil,
                            orderBy: (column: String, ascending: Bool)? = nil, readOnly: Bool = false,
                            runtime: TransferRuntime, progress: TransferProgress) throws -> Int64 {
        lock.lock(); defer { lock.unlock() }
        let ownsTransaction = !userTransaction && !transactionSettingsUnknown && cadbc_autocommit_enabled(session) == 1 && dialect.supportsReadOnly
        guard !readOnly || ownsTransaction else { throw ADBCError("Reconnect before exporting from a read-only favorite with a manual transaction.") }
        func performExport() throws -> Int64 {
            // Acquire the schema lock before inspecting generated and identity columns.
            _ = try executeLocked("SELECT * FROM \(dialect.qualifiedName(of: table)) LIMIT 0", maxRows: 0)
            let columns = try transferColumns(table)
            let sql = try dialect.transferSQL(table, format: format, columns: columns, expression: expression, orderBy: orderBy)
            try transferStream(sql) { stream in
                try withUnsafeMutablePointer(to: &stream) { address in
                    let scope = try runtime.scope([
                        "mode": "export", "stream": UInt(bitPattern: address), "path": url.path,
                        "format": format.rawValue, "dialect": dialect == .postgres ? "postgres" : dialect == .mysql ? "mysql" : "generic",
                        "tableSQL": dialect.qualifiedName(of: table), "identity": columns.contains { $0.identity },
                        "sqlText": true, "sqlBinary": columns.filter { SQLDialect.binaryTypes.contains($0.type.lowercased()) }.map(\.name),
                        "skip": format == .sql && columns.allSatisfy({ $0.computed }) ? ["sdbui_default"] : []
                    ], progress: progress)
                    withExtendedLifetime(scope) {}
                }
            }
            return progress.rows
        }
        if ownsTransaction { return try withReadOnlyTransaction { try performExport() } }
        return try performExport()
    }

    public func previewCSV(_ url: URL, into table: TableInfo, options: CSVImportOptions,
                           runtime: TransferRuntime, progress: TransferProgress) throws -> CSVImportPreview {
        lock.lock(); defer { lock.unlock() }
        let columns = try transferColumns(table)
        guard !columns.isEmpty else { throw ADBCError("CSV import requires PostgreSQL or MySQL column metadata.") }
        var preview: CSVImportPreview?
        try transferStream("SELECT * FROM \(dialect.qualifiedName(of: table)) LIMIT 0") { stream in
            try withUnsafeMutablePointer(to: &stream) { address in
                let scope = try runtime.scope(["mode": "preview", "path": url.path, "options": try options.jsonObject(), "schemaStream": UInt(bitPattern: address)], progress: progress)
                preview = try scope.result(CSVImportPreview.self)
            }
        }
        preview!.columns = columns
        return preview!
    }

    /// Appends using ADBC bulk ingestion; failure or cancellation rolls back every batch.
    public func importCSV(_ url: URL, into table: TableInfo, options: CSVImportOptions,
                          preview: CSVImportPreview, mapping: [String?],
                          runtime: TransferRuntime, progress: TransferProgress) throws -> Int64 {
        lock.lock(); defer { lock.unlock() }
        guard dialect.supportsTableWrites, !userTransaction, !transactionSettingsUnknown, cadbc_autocommit_enabled(session) == 1 else {
            throw ADBCError("CSV import requires confirmed autocommit. Finish manual transactions or reconnect first.")
        }
        guard mapping.count == preview.headers.count, mapping.compactMap({ $0 }).count > 0,
              Set(mapping.compactMap { $0 }).count == mapping.compactMap({ $0 }).count else { throw ADBCError("Map at least one CSV column, without duplicate targets.") }
        _ = try executeLocked(dialect == .postgres ? "BEGIN" : "START TRANSACTION", maxRows: 0)
        var stagingTable: String?
        defer {
            if let stagingTable {
                do { _ = try executeUpdateLocked("DROP TEMPORARY TABLE IF EXISTS " + dialect.quote(stagingTable)) }
                catch { transactionSettingsUnknown = true }
            }
        }
        do {
            guard let eligibility = dialect.editableTableSQL(table), try executeLocked(eligibility, maxRows: 1).cell(0, 0) == "YES" else {
                throw ADBCError("CSV import requires a base table with transactional storage.")
            }
            _ = try executeLocked("SELECT * FROM \(dialect.qualifiedName(of: table)) LIMIT 0", maxRows: 0)
            let current = try transferColumns(table)
            guard current == preview.columns, mapping.compactMap({ $0 }).allSatisfy({ name in current.contains { $0.name == name && !$0.computed } }) else {
                throw ADBCError("Target columns changed or mapping includes a generated column. Preview again.")
            }
            try transferStream("SELECT * FROM \(dialect.qualifiedName(of: table)) LIMIT 0") { schemaStream in
                var input = ArrowArrayStream()
                var scope: TransferScope?
                defer { cadbc_stream_release(&input); withExtendedLifetime(scope) {} }
                try withUnsafeMutablePointer(to: &schemaStream) { schemaAddress in
                    try withUnsafeMutablePointer(to: &input) { outputAddress in
                        scope = try runtime.scope([
                            "mode": "reader", "path": url.path, "options": try options.jsonObject(),
                            "fingerprint": preview.fingerprint, "schema": preview.schema,
                            "mapping": mapping.map { $0 as Any? ?? NSNull() },
                            "schemaStream": UInt(bitPattern: schemaAddress), "outputStream": UInt(bitPattern: outputAddress)
                        ], progress: progress)
                    }
                }
                // Foundry MySQL bulk append uses positional INSERTs. Stage exactly the
                // mapped fields, then name the destination columns so defaults and
                // generated columns are handled by the server, in the same transaction.
                if dialect == .mysql {
                    let name = "sdbui_import_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
                    stagingTable = name
                    let columns = mapping.compactMap { $0 }.map(dialect.quote).joined(separator: ", ")
                    _ = try executeUpdateLocked("CREATE TEMPORARY TABLE " + dialect.quote(name) + " AS SELECT " + columns + " FROM " + dialect.qualifiedName(of: table) + " LIMIT 0")
                }
                var rows: Int64 = -1
                var error: UnsafeMutablePointer<CChar>?
                guard cadbc_ingest_append(session, stagingTable ?? table.name, nil,
                                          dialect == .postgres ? table.schema : nil, &input, &rows, &error) == ADBC_STATUS_OK else {
                    throw takeError(error, fallback: "ADBC bulk import failed")
                }
                guard rows < 0 || rows == progress.rows else { throw ADBCError("Driver row count did not match the CSV. Import rolled back.") }
            }
            if let name = stagingTable {
                let columns = mapping.compactMap { $0 }.map(dialect.quote).joined(separator: ", ")
                let affected = try executeUpdateLocked("INSERT INTO " + dialect.qualifiedName(of: table) + " (" + columns + ") SELECT " + columns + " FROM " + dialect.quote(name))
                guard affected == progress.rows else { throw ADBCError("Inserted row count did not match the CSV. Import rolled back.") }
                _ = try executeUpdateLocked("DROP TEMPORARY TABLE " + dialect.quote(name))
                stagingTable = nil
            }
            guard !progress.isCancelled else { throw ADBCError("Import cancelled.") }
            _ = try executeLocked("COMMIT", maxRows: 0)
            return progress.rows
        } catch {
            do { _ = try executeLocked("ROLLBACK", maxRows: 0) } catch { transactionSettingsUnknown = true }
            throw error
        }
    }

    /// Probe only an idle connection; never queue behind a running query.
    /// A false return means a query owns the connection, not that it is lost.
    public func checkHealth() throws -> Bool {
        guard lock.try() else { return false }
        defer { lock.unlock() }
        _ = try executeLocked("SELECT 1", maxRows: 1)
        return true
    }

    public func isConnectionLoss(_ error: Error) -> Bool {
        if let tunnel, !tunnel.isRunning { return true }
        return (error as? ADBCError)?.isConnectionLoss ?? false
    }

    /// Drivers such as Foundry MySQL report affected rows through ExecuteUpdate
    /// (the ADBC C entry point with a NULL result stream), not through ExecuteQuery.
    private func executeUpdateLocked(_ sql: String) throws -> Int64 {
        try tunnel?.check()
        var affected: Int64 = -1
        var error: UnsafeMutablePointer<CChar>?
        guard cadbc_execute(session, sql, nil, &affected, nil, &error) == ADBC_STATUS_OK else {
            throw takeError(error, fallback: "Row change failed")
        }
        return affected
    }

    private func executeLocked(_ sql: String, maxRows: Int, usePostgresCopy: Bool = true) throws -> QueryResult {
        try tunnel?.check()
        let clock = ContinuousClock()
        let start = clock.now
        var stream = ArrowArrayStream()
        var rowsAffected: Int64 = -1
        var error: UnsafeMutablePointer<CChar>?
        var errorPosition: Int64 = 0
        guard cadbc_execute_options(session, sql, usePostgresCopy ? 0 : 1, &stream, &rowsAffected, &errorPosition, &error) == ADBC_STATUS_OK else {
            var failure = takeError(error, fallback: "Query failed")
            failure.statementPosition = errorPosition > 0 ? Int(exactly: errorPosition) : nil
            throw failure
        }
        defer { cadbc_stream_release(&stream) }

        // Keep the record batches; cells are formatted on demand (see
        // QueryResult). Batches stay valid after the stream is released.
        var schema = ArrowSchema()
        guard cadbc_stream_get_schema(&stream, &schema, &error) == 0 else {
            throw takeError(error, fallback: "Reading result schema failed")
        }
        defer { cadbc_schema_release(&schema) }
        let field = ArrowField(&schema)

        var arrays: [ArrowArray] = []
        var rowCount = 0
        do {
            while rowCount <= maxRows {
                var array = ArrowArray()
                guard cadbc_stream_get_next(&stream, &array, &error) == 0 else {
                    throw takeError(error, fallback: "Reading results failed")
                }
                guard array.release != nil else { break }
                arrays.append(array)
                rowCount += Int(array.length)
            }
        } catch {
            for index in arrays.indices {
                cadbc_array_release(&arrays[index])
            }
            throw error
        }

        return QueryResult(
            columns: field.children.map { ResultColumn(name: $0.name, type: $0.typeName) },
            storage: ArrowStorage(field: field, arrays: arrays, rowLimit: maxRows),
            truncated: rowCount > maxRows,
            rowsAffected: rowsAffected >= 0 ? rowsAffected : nil,
            elapsed: clock.now - start
        )
    }

    /// Ask the driver to abort the running statement (ADBC 1.1 drivers).
    public func cancel() throws {
        var error: UnsafeMutablePointer<CChar>?
        guard cadbc_cancel(session, &error) == ADBC_STATUS_OK else {
            throw takeError(error, fallback: "Cancel failed")
        }
    }

    /// List tables and views via `AdbcConnectionGetObjects`.
    public func tables() throws -> [TableInfo] {
        lock.lock()
        defer { lock.unlock() }
        try tunnel?.check()

        var stream = ArrowArrayStream()
        var error: UnsafeMutablePointer<CChar>?
        guard cadbc_get_objects(session, ADBC_OBJECT_DEPTH_TABLES, &stream, &error) == ADBC_STATUS_OK else {
            throw takeError(error, fallback: "Listing tables failed")
        }
        defer { cadbc_stream_release(&stream) }

        var tables: [TableInfo] = []
        _ = try readStream(&stream) { batch in
            guard let catalogs = batch.children.first(where: { $0.field.name == "catalog_name" }),
                let schemas = batch.children.first(where: { $0.field.name == "catalog_db_schemas" })
            else { return false }
            for row in 0..<batch.length {
                let catalog = catalogs.value(row).string
                for schema in schemas.value(row).elements {
                    let schemaName = schema[field: "db_schema_name"].string
                    for table in schema[field: "db_schema_tables"].elements {
                        guard let name = table[field: "table_name"].string else { continue }
                        tables.append(TableInfo(
                            catalog: catalog, schema: schemaName, name: name,
                            type: table[field: "table_type"].string))
                    }
                }
            }
            return true
        }
        return tables
    }

    /// Columns of a table via `AdbcConnectionGetTableSchema`.
    public func columns(of table: TableInfo) throws -> [ResultColumn] {
        lock.lock()
        defer { lock.unlock() }
        try tunnel?.check()

        var schema = ArrowSchema()
        var error: UnsafeMutablePointer<CChar>?
        let status = cadbc_get_table_schema(
            session, table.catalog, table.schema, table.name, &schema, &error)
        guard status == ADBC_STATUS_OK else {
            throw takeError(error, fallback: "Reading table schema failed")
        }
        defer { cadbc_schema_release(&schema) }
        return ArrowField(&schema).children.map { ResultColumn(name: $0.name, type: $0.typeName) }
    }

    // MARK: SQL helpers

    /// The connected database's SQL flavour (from the vendor name).
    public var dialect: SQLDialect { SQLDialect(vendorName: vendorName) }

    /// Quote an identifier using the convention of the connected database.
    public func quote(_ identifier: String) -> String {
        dialect.quote(identifier)
    }

    public func qualifiedName(of table: TableInfo) -> String {
        dialect.qualifiedName(of: table)
    }

    // MARK: Internals

    private func loadVendorInfo() {
        // Best effort, like databow's get_vendor_info: failures are ignored.
        let codes: [UInt32] = [UInt32(ADBC_INFO_VENDOR_NAME), UInt32(ADBC_INFO_VENDOR_VERSION)]
        var stream = ArrowArrayStream()
        var error: UnsafeMutablePointer<CChar>?
        let status = codes.withUnsafeBufferPointer {
            cadbc_get_info(session, $0.baseAddress, $0.count, &stream, &error)
        }
        guard status == ADBC_STATUS_OK else {
            cadbc_free_string(error)
            return
        }
        defer { cadbc_stream_release(&stream) }

        _ = try? readStream(&stream) { batch in
            guard batch.children.count >= 2 else { return false }
            for row in 0..<batch.length {
                guard case .uint(let code) = batch.children[0].value(row),
                    let text = batch.children[1].value(row).string
                else { continue }
                if code == UInt64(ADBC_INFO_VENDOR_NAME) { vendorName = text }
                if code == UInt64(ADBC_INFO_VENDOR_VERSION) { vendorVersion = text }
            }
            return true
        }
    }

    /// Read the stream batch by batch. `body` returns false to stop early.
    /// Returns the stream's schema (a struct whose children are the columns).
    private func readStream(
        _ stream: inout ArrowArrayStream,
        _ body: (ArrowArrayView) throws -> Bool
    ) throws -> ArrowField {
        var schema = ArrowSchema()
        var error: UnsafeMutablePointer<CChar>?
        guard cadbc_stream_get_schema(&stream, &schema, &error) == 0 else {
            throw takeError(error, fallback: "Reading result schema failed")
        }
        defer { cadbc_schema_release(&schema) }
        let field = ArrowField(&schema)

        while true {
            var array = ArrowArray()
            guard cadbc_stream_get_next(&stream, &array, &error) == 0 else {
                throw takeError(error, fallback: "Reading results failed")
            }
            guard array.release != nil else { break }
            defer { cadbc_array_release(&array) }
            guard try body(ArrowArrayView(field: field, array: array)) else { break }
        }
        return field
    }
}

private func takeError(_ error: UnsafeMutablePointer<CChar>?, fallback: String) -> ADBCError {
    guard let error else { return ADBCError(fallback) }
    defer { cadbc_free_string(error) }
    return ADBCError(String(cString: error))
}

/// Duplicate `strings` as C strings for the duration of `body`.
private func withCStrings<R>(
    _ strings: [String], _ body: ([UnsafePointer<CChar>?]) throws -> R
) rethrows -> R {
    let pointers = strings.map { strdup($0) }
    defer { pointers.forEach { free($0) } }
    return try body(pointers.map { UnsafePointer($0) })
}
