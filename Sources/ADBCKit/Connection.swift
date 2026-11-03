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
                options = uri.isEmpty ? [] : [.init(key: "uri", value: uri)]
                options += extra
        }

        let (library, entrypoint) = try Discovery.resolveDriver(driver)
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
        return try executeLocked(sql, maxRows: maxRows, usePostgresCopy: usePostgresCopy)
    }

    /// Executes one approved read query in a database-enforced read-only transaction.
    /// The lock covers BEGIN, the query and ROLLBACK so other loads cannot interleave.
    public func executeReadOnly(_ sql: String, maxRows: Int, usePostgresCopy: Bool = true) throws -> QueryResult {
        lock.lock()
        defer { lock.unlock() }
        let dialect = SQLDialect(vendorName: vendorName)
        guard dialect != .generic else { throw ADBCError("Read-only execution is supported for PostgreSQL and MySQL only.") }
        guard SQLSafetyAssessment(sql, dialect: dialect).allowsReadOnly else {
            throw ADBCError("Read-only favorite: only read queries are allowed.")
        }
        _ = try executeLocked(dialect == .postgres ? "BEGIN READ ONLY" : "START TRANSACTION READ ONLY", maxRows: 0)
        do {
            let result = try executeLocked(sql, maxRows: maxRows, usePostgresCopy: usePostgresCopy)
            _ = try executeLocked("ROLLBACK", maxRows: 0)
            return result
        } catch {
            _ = try? executeLocked("ROLLBACK", maxRows: 0)
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
