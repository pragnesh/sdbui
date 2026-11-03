import Foundation
import XCTest
@testable import ADBCKit

final class EmbeddedDriverTests: XCTestCase {
    private func connection(_ driver: String) throws -> ADBCConnection {
        guard ProcessInfo.processInfo.environment["SDBUI_TEST_EMBEDDED"] == "1" else { throw XCTSkip("Enable real SQLite/DuckDB driver tests with SDBUI_TEST_EMBEDDED=1") }
        return try ADBCConnection.open(.direct(driver: driver, uri: ":memory:"))
    }
    func testSQLiteCatalogBrowseFilterAndReadOnly() throws { try exercise("sqlite", expected: .sqlite) }
    func testDuckDBCatalogBrowseFilterAndReadOnly() throws { try exercise("duckdb", expected: .duckdb) }
    private func exercise(_ driver: String, expected: SQLDialect) throws {
        let connection = try connection(driver)
        XCTAssertEqual(connection.dialect, expected, connection.vendorName ?? "no vendor")
        func sql(_ text: String) throws -> QueryResult { try connection.execute(text, maxRows: 100) }
        _ = try sql("CREATE TABLE parent (id INTEGER PRIMARY KEY)")
        _ = try sql("CREATE TABLE \"odd' table\" (id INTEGER PRIMARY KEY, name TEXT, parent_id INTEGER REFERENCES parent(id))")
        _ = try sql("CREATE INDEX name_idx ON \"odd' table\"(name)")
        _ = try sql("CREATE VIEW sample_view AS SELECT id,name FROM \"odd' table\"")
        _ = try sql("INSERT INTO parent VALUES (1)")
        _ = try sql("INSERT INTO \"odd' table\" VALUES (1,'50%_off',1),(2,'plain',1),(3,NULL,1)")
        if expected == .sqlite { _ = try sql("CREATE TRIGGER sample_trigger AFTER INSERT ON \"odd' table\" BEGIN SELECT 1; END") }
        let tables = try connection.tables()
        let table = try XCTUnwrap(tables.first { $0.name == "odd' table" })
        let view = try XCTUnwrap(tables.first { $0.name == "sample_view" })
        XCTAssertEqual(try connection.columns(of: table).map(\.name), ["id","name","parent_id"])
        let columns = try sql(try XCTUnwrap(expected.columnsSQL(table)))
        XCTAssertEqual(columns.rowCount, 3)
        XCTAssertEqual(columns.cell(0, 0), "id")
        XCTAssertGreaterThan(try sql(try XCTUnwrap(expected.indexesSQL(table))).rowCount, 0)
        XCTAssertGreaterThan(try sql(try XCTUnwrap(expected.tableInfoSQL(table))).rowCount, 0)
        XCTAssertGreaterThan(try sql(try XCTUnwrap(expected.relationsSQL(table))).rowCount, 0)
        let triggers = try sql(try XCTUnwrap(expected.triggersSQL(table)))
        XCTAssertEqual(triggers.rowCount, expected == .sqlite ? 1 : 0)
        XCTAssertTrue(try sql(try XCTUnwrap(expected.viewDefinitionSQL(view))).cell(0, 0)!.lowercased().contains("select"))
        let filter = SQLDialect.Filter(column: "name", op: .contains, value: "%_")
        let browse = try sql(expected.browseSQL(table, filter: filter, orderBy: ("id",false), limit: 1, offset: 0))
        XCTAssertEqual(browse.rowCount, 1); XCTAssertEqual(browse.cell(0, 0), "1")
        XCTAssertEqual(try sql(expected.countSQL(table, expression: .condition(.init(column: "name", op: .isNull, value: "")))).cell(0, 0), "1")
        let full = expected.browseSQL(table, filter: nil, limit: 10, offset: 0)
        XCTAssertEqual(try connection.executeReadOnly(full, maxRows: 10).rowCount, 3)
        XCTAssertThrowsError(try connection.executeReadOnly("DELETE FROM " + expected.qualifiedName(of: table), maxRows: 0))
        // A read-shaped query may still invoke a write-capable function. Database enforcement matters.
        if expected == .duckdb {
            XCTAssertThrowsError(try connection.executeReadOnly("SELECT * FROM query('DELETE FROM parent')", maxRows: 10))
        }
        if expected == .sqlite {
            XCTAssertEqual(try sql("PRAGMA query_only").cell(0, 0), "0")
            _ = try sql("PRAGMA query_only = ON")
            XCTAssertEqual(try connection.executeReadOnly(full, maxRows: 10).rowCount, 3)
            XCTAssertEqual(try sql("PRAGMA query_only").cell(0, 0), "1")
            _ = try sql("PRAGMA query_only = OFF")
        }
        XCTAssertThrowsError(try connection.executeReadOnly("SELECT * FROM missing_table", maxRows: 10))
        XCTAssertEqual(try sql("SELECT count(*) FROM parent").cell(0, 0), "1")
        _ = try sql("INSERT INTO parent VALUES (2)")
        if expected == .duckdb {
            _ = try sql("ATTACH ':memory:' AS other")
            _ = try sql("CREATE TABLE other.main.\"odd' table\" (id INTEGER, marker TEXT)")
            _ = try sql("INSERT INTO other.main.\"odd' table\" VALUES (7,'attached')")
            let attached = try XCTUnwrap(try connection.tables().first { $0.catalog == "other" && $0.name == "odd' table" })
            XCTAssertEqual(try connection.columns(of: attached).map(\.name), ["id","marker"])
            XCTAssertEqual(try sql(expected.browseSQL(attached, filter: nil, limit: 10, offset: 0)).cell(0, 1), "attached")
            XCTAssertEqual(try sql(try XCTUnwrap(expected.columnsSQL(attached))).rowCount, 2)
        }
        _ = try sql("BEGIN")
        XCTAssertThrowsError(try connection.executeReadOnly(full, maxRows: 10))
        _ = try sql("ROLLBACK")
    }
    func testEmbeddedDialectQuotingAndSQLiteStatements() {
        XCTAssertEqual(SQLDialect(vendorName: "DuckDB"), .duckdb)
        XCTAssertEqual(SQLDialect(vendorName: "SQLite"), .sqlite)
        XCTAssertEqual(SQLDialect.duckdb.qualifiedName(of: .init(catalog: "db", schema: "main", name: "t")), "\"db\".\"main\".\"t\"")
        XCTAssertEqual(SQLDialect.sqlite.statements(in: "SELECT [odd;name]; SELECT 2").count, 2)
        XCTAssertTrue(SQLSafetyAssessment("SELECT [delete;drop] FROM [t]", dialect: .sqlite).warnings.isEmpty)
    }
}
