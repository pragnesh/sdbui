import Foundation

extension SQLDialect {
    public var supportsTableWrites: Bool { self == .postgres || self == .mysql }
    public var supportsReadOnly: Bool { self == .postgres || self == .mysql || self == .sqlite || self == .duckdb }
    public var supportsExplain: Bool { self != .generic }
    /// SQLite's attached database name is reported as a catalog by ADBC.
    private func sqliteSchema(_ table: TableInfo) -> String { table.namespace.isEmpty ? "main" : table.namespace }
    private func duckPredicate(_ table: TableInfo, nameColumn: String = "table_name") -> String {
        "schema_name = \(literal(table.namespace.isEmpty ? "main" : table.namespace)) AND \(nameColumn) = \(literal(table.name))" + (table.catalog.map { " AND database_name = " + literal($0) } ?? "")
    }
    func embeddedColumnsSQL(_ table: TableInfo) -> String {
        if self == .sqlite {
            return "SELECT name AS \"Field\", type AS \"Type\", CASE WHEN \"notnull\"=1 OR pk>0 THEN 'NO' ELSE 'YES' END AS \"Null\", dflt_value AS \"Default\", pk AS \"Primary key order\", hidden AS \"Generated/hidden\" FROM pragma_table_xinfo(\(literal(table.name)), \(literal(sqliteSchema(table)))) ORDER BY cid"
        }
        return "SELECT column_name AS \"Field\", data_type AS \"Type\", CASE WHEN is_nullable THEN 'YES' ELSE 'NO' END AS \"Null\", column_default AS \"Default\" FROM duckdb_columns() WHERE \(duckPredicate(table)) ORDER BY column_index"
    }
    func embeddedIndexesSQL(_ table: TableInfo) -> String {
        if self == .sqlite {
            let schema = literal(sqliteSchema(table))
            return "SELECT il.name AS \"Key\", group_concat(coalesce(ii.name,'<expression>'), ', ') AS \"Columns\", CASE WHEN il.\"unique\"=1 THEN 'YES' ELSE 'NO' END AS \"Unique\", il.origin AS \"Origin\", il.partial AS \"Partial\" FROM pragma_index_list(\(literal(table.name)),\(schema)) il LEFT JOIN pragma_index_info(il.name,\(schema)) ii GROUP BY il.seq,il.name,il.\"unique\",il.origin,il.partial ORDER BY il.seq"
        }
        return "SELECT index_name AS \"Key\", expressions AS \"Columns\", is_unique AS \"Unique\", is_primary AS \"Primary\", sql AS \"Definition\" FROM duckdb_indexes() WHERE \(duckPredicate(table)) ORDER BY index_name"
    }
    func sqliteDefinitionSQL(_ table: TableInfo) -> String {
        "SELECT sql FROM \(quote(sqliteSchema(table))).sqlite_schema WHERE name = \(literal(table.name)) AND type IN ('table','view')"
    }
    func embeddedDefinitionSQL(_ table: TableInfo) -> String {
        if self == .sqlite { return sqliteDefinitionSQL(table) }
        return "SELECT sql FROM duckdb_tables() WHERE \(duckPredicate(table)) UNION ALL SELECT sql FROM duckdb_views() WHERE \(duckPredicate(table, nameColumn: "view_name"))"
    }
    func embeddedInfoSQL(_ table: TableInfo) -> String {
        if self == .sqlite {
            return "SELECT type AS \"Type\", sql AS \"Definition\" FROM \(quote(sqliteSchema(table))).sqlite_schema WHERE name = \(literal(table.name)) AND type IN ('table','view')"
        }
        return "SELECT 'table' AS \"Type\", estimated_size AS \"Rows (estimate)\", column_count AS \"Columns\", index_count AS \"Indexes\", sql AS \"Definition\" FROM duckdb_tables() WHERE \(duckPredicate(table)) UNION ALL SELECT 'view', NULL, column_count, NULL, sql FROM duckdb_views() WHERE \(duckPredicate(table, nameColumn: "view_name"))"
    }
    func embeddedRelationsSQL(_ table: TableInfo) -> String {
        if self == .sqlite {
            return "SELECT id AS \"Constraint\", seq AS \"Position\", \"from\" AS \"Column\", \"table\" AS \"To table\", \"to\" AS \"Referenced column\", on_update AS \"On update\", on_delete AS \"On delete\" FROM pragma_foreign_key_list(\(literal(table.name)),\(literal(sqliteSchema(table)))) ORDER BY id,seq"
        }
        return "SELECT constraint_name AS \"Constraint\", constraint_type AS \"Type\", constraint_column_names AS \"Columns\", constraint_text AS \"Definition\" FROM duckdb_constraints() WHERE \(duckPredicate(table)) AND constraint_type = 'FOREIGN KEY' ORDER BY constraint_index"
    }
    func embeddedTriggersSQL(_ table: TableInfo) -> String {
        if self == .sqlite {
            return "SELECT name AS \"Trigger\", sql AS \"Definition\" FROM \(quote(sqliteSchema(table))).sqlite_schema WHERE type = 'trigger' AND tbl_name = \(literal(table.name)) ORDER BY name"
        }
        // DuckDB has no trigger catalog because triggers are not supported.
        return "SELECT CAST(NULL AS VARCHAR) AS \"Trigger\", CAST(NULL AS VARCHAR) AS \"Definition\" WHERE FALSE"
    }
}
