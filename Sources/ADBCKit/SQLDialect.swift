import Foundation

/// SQL flavour of the connected database: quoting, literals and the
/// catalog queries behind the browser's Structure, Content and Table Info
/// views. MySQL/MariaDB, PostgreSQL, SQLite and DuckDB have native catalog
/// queries; other databases fall back to what ADBC itself reports.
public enum SQLDialect: Sendable, Equatable {
    case mysql
    case postgres
    case sqlite
    case duckdb
    case generic

    /// Pick a dialect from the ADBC vendor name (`GetInfo`).
    public init(vendorName: String?) {
        let vendor = (vendorName ?? "").lowercased()
        if vendor.contains("mysql") || vendor.contains("mariadb") {
            self = .mysql
        } else if vendor.contains("postgres") {
            self = .postgres
        } else if vendor.contains("sqlite") {
            self = .sqlite
        } else if vendor.contains("duckdb") {
            self = .duckdb
        } else {
            self = .generic
        }
    }

    /// What a top-level namespace is called ("Database" for MySQL).
    public var namespaceLabel: String {
        self == .postgres || self == .duckdb ? "Schema" : "Database"
    }

    // MARK: Quoting

    public func quote(_ identifier: String) -> String {
        switch self {
            case .mysql:
                return "`" + identifier.replacingOccurrences(of: "`", with: "``") + "`"
            case .postgres, .sqlite, .duckdb, .generic:
                return "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
    }

    /// A string literal. MySQL treats backslashes as escapes by default, so
    /// they're doubled there too.
    public func literal(_ value: String) -> String {
        var escaped = value.replacingOccurrences(of: "'", with: "''")
        if self == .mysql {
            escaped = escaped.replacingOccurrences(of: "\\", with: "\\\\")
        }
        return "'" + escaped + "'"
    }

    public func qualifiedName(of table: TableInfo) -> String {
        var parts = table.namespace.isEmpty ? [table.name] : [table.namespace, table.name]
        if self == .duckdb, let catalog = table.catalog, !catalog.isEmpty, table.schema != nil { parts.insert(catalog, at: 0) }
        return parts.map(quote).joined(separator: ".")
    }

    // MARK: Default namespace

    /// The session's current database (MySQL) or schema (PostgreSQL).
    public var currentNamespaceSQL: String? {
        switch self {
            case .mysql: return "SELECT DATABASE()"
            case .postgres, .duckdb: return "SELECT current_schema()"
            case .sqlite: return "SELECT 'main'"
            case .generic: return nil
        }
    }

    /// Makes `namespace` the session's default for unqualified table names.
    /// PostgreSQL keeps `public` on the search path for shared functions.
    public func useNamespaceSQL(_ namespace: String) -> String? {
        switch self {
            case .mysql:
                return "USE \(quote(namespace))"
            case .postgres:
                return namespace == "public"
                    ? "SET search_path TO public" : "SET search_path TO \(quote(namespace)), public"
            case .duckdb: return "SET schema = " + literal(namespace)
            case .sqlite: return nil // Attached databases are always qualified explicitly.
            case .generic:
                return nil
        }
    }

    // MARK: Browsing

    /// A filter on one column, as in Sequel Ace's content filter bar.
    public struct Filter: Sendable, Hashable {
        public enum Operator: String, CaseIterable, Sendable, CustomStringConvertible {
            case contains = "contains"
            case equals = "="
            case notEquals = "≠"
            case greater = ">"
            case less = "<"
            case greaterOrEqual = "≥"
            case lessOrEqual = "≤"
            case like = "LIKE"
            case notLike = "NOT LIKE"
            case isNull = "IS NULL"
            case isNotNull = "IS NOT NULL"

            public var description: String { rawValue }

            /// Whether the operator takes a value.
            public var needsValue: Bool { self != .isNull && self != .isNotNull }
        }

        public var column: String
        public var op: Operator
        public var value: String

        public init(column: String, op: Operator, value: String) {
            self.column = column
            self.op = op
            self.value = value
        }
    }

    public func whereClause(for filter: Filter) -> String {
        let column = quote(filter.column)
        let value = literal(filter.value)
        switch filter.op {
            case .contains:
                // Cast so it also works on non-text columns.
                let text = self == .mysql ? column : "CAST(\(column) AS TEXT)"
                let pattern = literal("%" + escapeLike(filter.value) + "%")
                return "\(text) LIKE \(pattern)" + (self == .sqlite || self == .duckdb ? " ESCAPE '\\'" : "")
            case .equals: return "\(column) = \(value)"
            case .notEquals: return "\(column) <> \(value)"
            case .greater: return "\(column) > \(value)"
            case .less: return "\(column) < \(value)"
            case .greaterOrEqual: return "\(column) >= \(value)"
            case .lessOrEqual: return "\(column) <= \(value)"
            case .like: return "\(column) LIKE \(value)"
            case .notLike: return "\(column) NOT LIKE \(value)"
            case .isNull: return "\(column) IS NULL"
            case .isNotNull: return "\(column) IS NOT NULL"
        }
    }

    /// Escape LIKE wildcards so "contains" matches the text literally.
    private func escapeLike(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    /// One page of a table's rows, optionally filtered and ordered by a column.
    public func browseSQL(
        _ table: TableInfo, filter: Filter?, expression: FilterExpression? = nil, orderBy: (column: String, ascending: Bool)? = nil,
        limit: Int, offset: Int
    ) -> String {
        var sql = "SELECT * FROM \(qualifiedName(of: table))"
        if let expression { sql += " WHERE " + whereClause(for: expression) }
        else if let filter { sql += " WHERE " + whereClause(for: filter) }
        if let orderBy {
            sql += " ORDER BY \(quote(orderBy.column)) \(orderBy.ascending ? "ASC" : "DESC")"
        }
        sql += " LIMIT \(limit)"
        if offset > 0 {
            sql += " OFFSET \(offset)"
        }
        return sql
    }

    // MARK: Catalog queries

    /// Columns with their declared types, nullability, keys and defaults.
    public func columnsSQL(_ table: TableInfo) -> String? {
        let schema = literal(table.namespace)
        let name = literal(table.name)
        switch self {
            case .mysql:
                return """
                    SELECT COLUMN_NAME AS Field, COLUMN_TYPE AS Type, IS_NULLABLE AS `Null`, \
                    COLUMN_KEY AS `Key`, COLUMN_DEFAULT AS `Default`, EXTRA AS Extra, \
                    COLUMN_COMMENT AS Comment \
                    FROM information_schema.COLUMNS \
                    WHERE TABLE_SCHEMA = \(schema) AND TABLE_NAME = \(name) \
                    ORDER BY ORDINAL_POSITION
                    """
            case .postgres:
                return """
                    SELECT column_name AS "Field", \
                    CASE WHEN character_maximum_length IS NOT NULL \
                    THEN data_type || '(' || character_maximum_length || ')' \
                    ELSE data_type END AS "Type", \
                    is_nullable AS "Null", column_default AS "Default" \
                    FROM information_schema.columns \
                    WHERE table_schema = \(schema) AND table_name = \(name) \
                    ORDER BY ordinal_position
                    """
            case .sqlite, .duckdb: return embeddedColumnsSQL(table)
            case .generic:
                return nil
        }
    }

    public func indexesSQL(_ table: TableInfo) -> String? {
        let schema = literal(table.namespace)
        let name = literal(table.name)
        switch self {
            case .mysql:
                return """
                    SELECT INDEX_NAME AS `Key`, \
                    GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX) AS `Columns`, \
                    IF(NON_UNIQUE = 0, 'YES', 'NO') AS `Unique`, INDEX_TYPE AS `Type` \
                    FROM information_schema.STATISTICS \
                    WHERE TABLE_SCHEMA = \(schema) AND TABLE_NAME = \(name) \
                    GROUP BY INDEX_NAME, NON_UNIQUE, INDEX_TYPE \
                    ORDER BY INDEX_NAME = 'PRIMARY' DESC, INDEX_NAME
                    """
            case .postgres:
                return """
                    SELECT indexname AS "Key", indexdef AS "Definition" \
                    FROM pg_indexes \
                    WHERE schemaname = \(schema) AND tablename = \(name) \
                    ORDER BY indexname
                    """
            case .sqlite, .duckdb: return embeddedIndexesSQL(table)
            case .generic:
                return nil
        }
    }

    /// One row of table metadata (engine, row estimate, sizes, …).
    public func tableInfoSQL(_ table: TableInfo) -> String? {
        let schema = literal(table.namespace)
        let name = literal(table.name)
        switch self {
            case .mysql:
                return """
                    SELECT TABLE_TYPE AS `Type`, ENGINE AS `Engine`, ROW_FORMAT AS `Row format`, \
                    TABLE_ROWS AS `Rows (estimate)`, AVG_ROW_LENGTH AS `Avg row length`, \
                    DATA_LENGTH AS `Data size`, INDEX_LENGTH AS `Index size`, \
                    AUTO_INCREMENT AS `Auto increment`, CREATE_TIME AS `Created`, \
                    UPDATE_TIME AS `Updated`, TABLE_COLLATION AS `Collation`, \
                    TABLE_COMMENT AS `Comment` \
                    FROM information_schema.TABLES \
                    WHERE TABLE_SCHEMA = \(schema) AND TABLE_NAME = \(name)
                    """
            case .postgres:
                return """
                    SELECT CASE c.relkind WHEN 'r' THEN 'table' WHEN 'v' THEN 'view' \
                    WHEN 'm' THEN 'materialized view' WHEN 'p' THEN 'partitioned table' \
                    ELSE c.relkind::text END AS "Type", \
                    c.reltuples::bigint AS "Rows (estimate)", \
                    pg_size_pretty(pg_total_relation_size(c.oid)) AS "Total size", \
                    pg_size_pretty(pg_relation_size(c.oid)) AS "Data size", \
                    pg_size_pretty(pg_indexes_size(c.oid)) AS "Index size", \
                    pg_get_userbyid(c.relowner) AS "Owner", \
                    obj_description(c.oid, 'pg_class') AS "Comment" \
                    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace \
                    WHERE n.nspname = \(schema) AND c.relname = \(name)
                    """
            case .sqlite, .duckdb: return embeddedInfoSQL(table)
            case .generic:
                return nil
        }
    }

    /// The statement that creates the table (MySQL only).
    public func createTableSQL(_ table: TableInfo) -> String? {
        if self == .sqlite { return sqliteDefinitionSQL(table) }
        if self == .duckdb { return embeddedDefinitionSQL(table) }
        return self == .mysql ? "SHOW CREATE TABLE \(qualifiedName(of: table))" : nil
    }
}

extension SQLDialect {
    func transferColumnsSQL(_ table: TableInfo) -> String? {
        let schema = literal(table.namespace), name = literal(table.name)
        switch self {
        case .postgres:
            return "SELECT column_name, data_type, CASE WHEN is_generated <> 'NEVER' THEN 'YES' ELSE 'NO' END, is_identity FROM information_schema.columns WHERE table_schema = \(schema) AND table_name = \(name) ORDER BY ordinal_position"
        case .mysql:
            return "SELECT COLUMN_NAME, DATA_TYPE, IF(COALESCE(GENERATION_EXPRESSION,'') <> '', 'YES','NO'), IF(EXTRA LIKE '%auto_increment%', 'YES','NO') FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = \(schema) AND TABLE_NAME = \(name) ORDER BY ORDINAL_POSITION"
        case .sqlite, .duckdb, .generic: return nil
        }
    }

    func transferSQL(_ table: TableInfo, format: TableExportFormat, columns: [TransferColumn], expression: FilterExpression?, orderBy: (column: String, ascending: Bool)?) throws -> String {
        var projection = "*"
        if format == .sql {
            guard supportsTableWrites else { throw ADBCError("SQL INSERT export requires PostgreSQL or MySQL metadata.") }
            let fields = columns.filter { !$0.computed }.map { column in
                let field = "sdbui_source." + quote(column.name)
                let cast = self == .postgres ? "CAST(\(field) AS TEXT)" : (Self.binaryTypes.contains(column.type.lowercased()) ? "HEX(\(field))" : "CAST(\(field) AS CHAR CHARACTER SET utf8mb4)")
                return cast + " AS " + quote(column.name)
            }
            projection = fields.isEmpty ? "1 AS sdbui_default" : fields.joined(separator: ", ")
        }
        var sql = "SELECT \(projection) FROM \(qualifiedName(of: table)) AS sdbui_source"
        if let expression { sql += " WHERE " + whereClause(for: expression) }
        if let orderBy { sql += " ORDER BY sdbui_source.\(quote(orderBy.column)) \(orderBy.ascending ? "ASC" : "DESC")" }
        return sql
    }
    static let binaryTypes: Set<String> = ["binary", "varbinary", "tinyblob", "blob", "mediumblob", "longblob", "bit"]
}
