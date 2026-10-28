import CADBC
import Foundation

/// How to open a connection — the same two modes databow offers.
public enum ConnectionSource: Sendable, Hashable {
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

public struct ResultColumn: Sendable, Hashable {
    public var name: String
    public var type: String

    public init(name: String, type: String) {
        self.name = name
        self.type = type
    }
}

public struct QueryResult: Sendable {
    public var columns: [ResultColumn]
    /// Cell text; `nil` is SQL NULL.
    public var rows: [[String?]]
    /// True when the result had more rows than `maxRows` and was cut short.
    public var truncated: Bool
    public var rowsAffected: Int64?
    public var elapsed: Duration

    public init(
        columns: [ResultColumn], rows: [[String?]], truncated: Bool = false,
        rowsAffected: Int64? = nil, elapsed: Duration = .zero
    ) {
        self.columns = columns
        self.rows = rows
        self.truncated = truncated
        self.rowsAffected = rowsAffected
        self.elapsed = elapsed
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

    public let source: ConnectionSource
    public private(set) var vendorName: String?
    public private(set) var vendorVersion: String?

    /// Maximum number of characters kept per cell.
    public var maxCellLength = 500

    public static func open(_ source: ConnectionSource) throws -> ADBCConnection {
        let driver: String
        var options: [ConnectionProfile.Option]
        switch source {
            case .profile(let reference):
                let profile = try Discovery.profile(named: reference)
                driver = profile.driver
                options = try profile.options.map {
                    .init(key: $0.key, value: try Discovery.substitutingEnvironment(in: $0.value))
                }
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

        let connection = ADBCConnection(session: session, source: source)
        connection.loadVendorInfo()
        return connection
    }

    private init(session: OpaquePointer, source: ConnectionSource) {
        self.session = session
        self.source = source
    }

    deinit {
        cadbc_close(session)
    }

    // MARK: Queries

    /// Run `sql`, keeping at most `maxRows` rows.
    public func execute(_ sql: String, maxRows: Int) throws -> QueryResult {
        lock.lock()
        defer { lock.unlock() }

        let clock = ContinuousClock()
        let start = clock.now
        var stream = ArrowArrayStream()
        var rowsAffected: Int64 = -1
        var error: UnsafeMutablePointer<CChar>?
        guard cadbc_execute(session, sql, &stream, &rowsAffected, &error) == ADBC_STATUS_OK else {
            throw takeError(error, fallback: "Query failed")
        }
        defer { cadbc_stream_release(&stream) }

        var rows: [[String?]] = []
        var truncated = false
        let schema = try readStream(&stream) { batch in
            let remaining = maxRows - rows.count
            if batch.length > remaining {
                truncated = true
            }
            for row in 0..<min(batch.length, remaining) {
                rows.append(batch.children.map { column in
                    let value = column.value(row)
                    return value.isNull ? nil : self.cellText(value)
                })
            }
            return !truncated
        }

        return QueryResult(
            columns: schema.children.map { ResultColumn(name: $0.name, type: $0.typeName) },
            rows: rows,
            truncated: truncated,
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

    private func cellText(_ value: ArrowValue) -> String {
        var text = value.description
        if text.count > maxCellLength {
            text = String(text.prefix(maxCellLength)) + "…"
        }
        return text
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
