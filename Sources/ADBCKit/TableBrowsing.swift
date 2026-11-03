import Foundation

extension SQLDialect {
    public indirect enum FilterExpression: Sendable, Hashable {
        case condition(Filter)
        case all([FilterExpression])
        case any([FilterExpression])
    }
    public func whereClause(for expression: FilterExpression) -> String {
        switch expression {
        case .condition(let filter): return whereClause(for: filter)
        case .all(let children): return children.isEmpty ? "1=1" : "(" + children.map { whereClause(for: $0) }.joined(separator: " AND ") + ")"
        case .any(let children): return children.isEmpty ? "1=0" : "(" + children.map { whereClause(for: $0) }.joined(separator: " OR ") + ")"
        }
    }
    public func countSQL(_ table: TableInfo, expression: FilterExpression?) -> String {
        "SELECT COUNT(*) FROM " + qualifiedName(of: table) + (expression.map { " WHERE " + whereClause(for: $0) } ?? "")
    }
    public func primaryKeySQL(_ table: TableInfo) -> String? {
        switch self {
        case .postgres:
            return "SELECT a.attname FROM pg_index i JOIN pg_class c ON c.oid=i.indrelid JOIN pg_namespace n ON n.oid=c.relnamespace CROSS JOIN LATERAL unnest(i.indkey) WITH ORDINALITY k(num,ord) JOIN pg_attribute a ON a.attrelid=c.oid AND a.attnum=k.num WHERE i.indisprimary AND n.nspname=\(literal(table.namespace)) AND c.relname=\(literal(table.name)) ORDER BY k.ord"
        case .mysql:
            return "SELECT COLUMN_NAME FROM information_schema.KEY_COLUMN_USAGE WHERE TABLE_SCHEMA=\(literal(table.namespace)) AND TABLE_NAME=\(literal(table.name)) AND CONSTRAINT_NAME='PRIMARY' ORDER BY ORDINAL_POSITION"
        case .generic: return nil
        }
    }
    public func editColumnsSQL(_ table: TableInfo) -> String? {
        switch self {
        case .postgres:
            return "SELECT column_name, data_type, is_nullable, column_default, CASE WHEN is_generated <> 'NEVER' OR is_identity='YES' THEN 'YES' ELSE 'NO' END FROM information_schema.columns WHERE table_schema=\(literal(table.namespace)) AND table_name=\(literal(table.name)) ORDER BY ordinal_position"
        case .mysql:
            return "SELECT COLUMN_NAME, DATA_TYPE, IS_NULLABLE, COLUMN_DEFAULT, CASE WHEN EXTRA LIKE '%GENERATED%' OR EXTRA LIKE '%auto_increment%' THEN 'YES' ELSE 'NO' END FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=\(literal(table.namespace)) AND TABLE_NAME=\(literal(table.name)) ORDER BY ORDINAL_POSITION"
        case .generic: return nil
        }
    }
    public func editableTableSQL(_ table: TableInfo) -> String? {
        switch self {
        case .postgres:
            return "SELECT CASE WHEN c.relkind IN ('r','p') THEN 'YES' ELSE 'NO' END FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname=\(literal(table.namespace)) AND c.relname=\(literal(table.name))"
        case .mysql:
            return "SELECT CASE WHEN t.TABLE_TYPE='BASE TABLE' AND e.TRANSACTIONS='YES' THEN 'YES' ELSE 'NO' END FROM information_schema.TABLES t LEFT JOIN information_schema.ENGINES e ON e.ENGINE=t.ENGINE WHERE t.TABLE_SCHEMA=\(literal(table.namespace)) AND t.TABLE_NAME=\(literal(table.name))"
        case .generic: return nil
        }
    }
    public func relationsSQL(_ table: TableInfo) -> String? {
        switch self {
        case .postgres:
            return "SELECT con.conname AS \"Constraint\", sn.nspname||'.'||src.relname AS \"From table\", sa.attname AS \"Column\", tn.nspname||'.'||dst.relname AS \"To table\", ta.attname AS \"Referenced column\", pg_get_constraintdef(con.oid) AS \"Definition\" FROM pg_constraint con JOIN pg_class src ON src.oid=con.conrelid JOIN pg_namespace sn ON sn.oid=src.relnamespace JOIN pg_class dst ON dst.oid=con.confrelid JOIN pg_namespace tn ON tn.oid=dst.relnamespace CROSS JOIN LATERAL unnest(con.conkey,con.confkey) WITH ORDINALITY keys(srcnum,dstnum,ord) JOIN pg_attribute sa ON sa.attrelid=src.oid AND sa.attnum=keys.srcnum JOIN pg_attribute ta ON ta.attrelid=dst.oid AND ta.attnum=keys.dstnum WHERE con.contype='f' AND ((sn.nspname=\(literal(table.namespace)) AND src.relname=\(literal(table.name))) OR (tn.nspname=\(literal(table.namespace)) AND dst.relname=\(literal(table.name)))) ORDER BY sn.nspname,src.relname,con.conname,keys.ord"
        case .mysql:
            return "SELECT k.CONSTRAINT_NAME AS `Constraint`, CONCAT(k.TABLE_SCHEMA,'.',k.TABLE_NAME) AS `From table`, k.COLUMN_NAME AS `Column`, CONCAT(k.REFERENCED_TABLE_SCHEMA,'.',k.REFERENCED_TABLE_NAME) AS `To table`, k.REFERENCED_COLUMN_NAME AS `Referenced column`, r.UPDATE_RULE AS `On update`, r.DELETE_RULE AS `On delete` FROM information_schema.KEY_COLUMN_USAGE k LEFT JOIN information_schema.REFERENTIAL_CONSTRAINTS r ON r.CONSTRAINT_SCHEMA=k.CONSTRAINT_SCHEMA AND r.CONSTRAINT_NAME=k.CONSTRAINT_NAME AND r.TABLE_NAME=k.TABLE_NAME WHERE k.REFERENCED_TABLE_NAME IS NOT NULL AND ((k.TABLE_SCHEMA=\(literal(table.namespace)) AND k.TABLE_NAME=\(literal(table.name))) OR (k.REFERENCED_TABLE_SCHEMA=\(literal(table.namespace)) AND k.REFERENCED_TABLE_NAME=\(literal(table.name)))) ORDER BY k.TABLE_SCHEMA,k.TABLE_NAME,k.CONSTRAINT_NAME,k.ORDINAL_POSITION"
        case .generic: return nil
        }
    }
    public func triggersSQL(_ table: TableInfo) -> String? {
        switch self {
        case .postgres:
            return "SELECT t.tgname AS \"Trigger\", CASE t.tgenabled WHEN 'D' THEN 'Disabled' ELSE 'Enabled' END AS \"Status\", pg_get_triggerdef(t.oid,true) AS \"Definition\" FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid JOIN pg_namespace n ON n.oid=c.relnamespace WHERE NOT t.tgisinternal AND n.nspname=\(literal(table.namespace)) AND c.relname=\(literal(table.name)) ORDER BY t.tgname"
        case .mysql:
            return "SELECT TRIGGER_NAME AS `Trigger`, ACTION_TIMING AS `Timing`, EVENT_MANIPULATION AS `Event`, ACTION_STATEMENT AS `Definition` FROM information_schema.TRIGGERS WHERE EVENT_OBJECT_SCHEMA=\(literal(table.namespace)) AND EVENT_OBJECT_TABLE=\(literal(table.name)) ORDER BY TRIGGER_NAME"
        case .generic: return nil
        }
    }
    public func viewDefinitionSQL(_ table: TableInfo) -> String? {
        switch self {
        case .postgres:
            return "SELECT pg_get_viewdef(c.oid,true) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE c.relkind IN ('v','m') AND n.nspname=\(literal(table.namespace)) AND c.relname=\(literal(table.name))"
        case .mysql:
            return "SELECT VIEW_DEFINITION FROM information_schema.VIEWS WHERE TABLE_SCHEMA=\(literal(table.namespace)) AND TABLE_NAME=\(literal(table.name))"
        case .generic: return nil
        }
    }
    /// Value literals for writes must not depend on session backslash modes.
    public func editLiteral(_ value: String) throws -> String {
        guard !value.contains("\0") else { throw ADBCError("Text values cannot contain an embedded NUL.") }
        switch self {
        case .postgres: return "E'" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "''") + "'"
        case .mysql:
            return "_utf8mb4 X'" + value.utf8.map { String(format: "%02x", $0) }.joined() + "'"
        case .generic: throw ADBCError("Row editing is supported for PostgreSQL and MySQL only.")
        }
    }
}

public struct TableEditColumn: Hashable, Sendable {
    public let name: String
    public let type: String
    public let nullable: Bool
    public let generated: Bool
    public var binary: Bool { ["bytea", "blob", "binary", "bit", "varbit"].contains { type.lowercased().contains($0) } }
    public init(name: String, type: String, nullable: Bool, generated: Bool = false) {
        self.name = name; self.type = type; self.nullable = nullable; self.generated = generated
    }
}
public enum TableEditValue: Hashable, Sendable {
    case value(String), null, `default`
}
public struct TableAssignment: Hashable, Sendable {
    public let column: String
    public let value: TableEditValue
    public init(column: String, value: TableEditValue) { self.column = column; self.value = value }
}
public struct TableMutation: Hashable, Sendable {
    public enum Kind: String, Sendable { case insert, update, delete }
    public let table: TableInfo
    public let kind: Kind
    public let assignments: [TableAssignment]
    public let keys: [TableAssignment]
    public let originalColumns: [String]
    public let originalValues: [String?]
    public init(table: TableInfo, kind: Kind, assignments: [TableAssignment], keys: [TableAssignment] = [], originalColumns: [String] = [], originalValues: [String?] = []) {
        self.table = table; self.kind = kind; self.assignments = assignments; self.keys = keys
        self.originalColumns = originalColumns; self.originalValues = originalValues
    }
    public func keyPredicate(_ dialect: SQLDialect) throws -> String {
        guard !keys.isEmpty, Set(keys.map(\.column)).count == keys.count else { throw ADBCError("A primary key is required to identify this row.") }
        return try keys.map { key in
            guard case .value(let text) = key.value else { throw ADBCError("Primary-key values cannot be NULL or DEFAULT.") }
            return dialect.quote(key.column) + " = " + (try dialect.editLiteral(text))
        }.joined(separator: " AND ")
    }
    public func sql(_ dialect: SQLDialect) throws -> String {
        guard Set(assignments.map(\.column)).count == assignments.count else { throw ADBCError("Duplicate column assignments.") }
        func value(_ value: TableEditValue) throws -> String {
            switch value { case .value(let text): return try dialect.editLiteral(text); case .null: return "NULL"; case .default: return "DEFAULT" }
        }
        let table = dialect.qualifiedName(of: table)
        switch kind {
        case .insert:
            let specified = assignments.filter { $0.value != .default }
            if specified.isEmpty { return dialect == .mysql ? "INSERT INTO \(table) () VALUES ()" : "INSERT INTO \(table) DEFAULT VALUES" }
            return "INSERT INTO \(table) (" + specified.map { dialect.quote($0.column) }.joined(separator: ", ") + ") VALUES (" + (try specified.map { try value($0.value) }).joined(separator: ", ") + ")"
        case .update:
            guard !assignments.isEmpty else { throw ADBCError("No values have changed.") }
            return "UPDATE \(table) SET " + (try assignments.map { dialect.quote($0.column) + " = " + (try value($0.value)) }).joined(separator: ", ") + " WHERE " + (try keyPredicate(dialect))
        case .delete: return "DELETE FROM \(table) WHERE " + (try keyPredicate(dialect))
        }
    }
}
