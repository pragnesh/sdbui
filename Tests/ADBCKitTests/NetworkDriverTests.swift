import Foundation
import XCTest
@testable import ADBCKit

final class NetworkDriverTests: XCTestCase {
    func testPostgreSQLDriver() throws { try exercise("postgresql", environment: "SDBUI_TEST_POSTGRES_URI") }
    func testMySQLDriver() throws { try exercise("mysql", environment: "SDBUI_TEST_MYSQL_URI") }
    private func exercise(_ driver: String, environment: String) throws {
        guard let uri = ProcessInfo.processInfo.environment[environment] else {
            if ProcessInfo.processInfo.environment["SDBUI_REQUIRE_NETWORK_DRIVERS"] == "1" { return XCTFail("Missing required \(environment)") }
            throw XCTSkip("Set \(environment) for the real server fixture")
        }
        let connection = try ADBCConnection.open(.direct(driver: driver, uri: uri))
        let dialect = connection.dialect
        XCTAssertEqual(dialect, driver == "mysql" ? .mysql : .postgres)
        let name = "quality_" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        func sql(_ text: String, limit: Int = 100) throws -> QueryResult { try connection.execute(text, maxRows: limit) }
        _ = try sql("CREATE TABLE \(dialect.quote(name)) (id INTEGER PRIMARY KEY, name VARCHAR(200), payload \(dialect == .mysql ? "BLOB" : "BYTEA"))")
        defer { _ = try? sql("DROP TABLE \(dialect.quote(name))") }
        let table = try XCTUnwrap(try connection.tables().first { $0.name == name })
        let q = dialect.qualifiedName(of: table)
        _ = try sql("INSERT INTO \(q) (id,name) VALUES (1,'snow 雪'),(2,NULL),(3,'50%_off')")
        XCTAssertEqual(try connection.columns(of: table).map(\.name), ["id","name","payload"])
        XCTAssertEqual(try sql(try XCTUnwrap(dialect.columnsSQL(table))).rowCount, 3)
        XCTAssertGreaterThan(try sql(try XCTUnwrap(dialect.indexesSQL(table))).rowCount, 0)
        XCTAssertEqual(try sql(try XCTUnwrap(dialect.tableInfoSQL(table))).rowCount, 1)
        _ = try sql(try XCTUnwrap(dialect.relationsSQL(table)))
        _ = try sql(try XCTUnwrap(dialect.triggersSQL(table)))
        let browseSQL = dialect.browseSQL(table, filter: nil, orderBy: ("id",true), limit: 100, offset: 0)
        XCTAssertEqual(try connection.executeReadOnly(browseSQL, maxRows: 100).rowCount, 3)
        XCTAssertThrowsError(try connection.executeReadOnly("DELETE FROM \(q)", maxRows: 0))
        _ = try sql("UPDATE \(q) SET payload=" + (dialect == .mysql ? "X'00ff'" : "decode('00ff','hex')") + " WHERE id=1")
        let original = try sql("SELECT * FROM \(q) WHERE id=1")
        try connection.applyTableMutation(.init(table: table, kind: .update, assignments: [.init(column: "name", value: .value("updated"))],
            keys: [.init(column: "id", value: .value("1"))], originalColumns: original.columns.map(\.name), originalValues: original.row(0)))
        XCTAssertEqual(try sql("SELECT name FROM \(q) WHERE id=1").cell(0, 0), "updated")
        let filter = SQLDialect.Filter(column: "name", op: .contains, value: "%_")
        XCTAssertEqual(try sql(dialect.browseSQL(table, filter: filter, limit: 100, offset: 0)).rowCount, 1)
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let runtime = try TransferRuntime.discover(), file = temp.appendingPathComponent("input.csv")
        let options = CSVImportOptions()
        try "id,name\n4,imported\n".write(to: file, atomically: true, encoding: .utf8)
        let preview = try connection.previewCSV(file, into: table, options: options, runtime: runtime, progress: TransferProgress())
        XCTAssertEqual(try connection.importCSV(file, into: table, options: options, preview: preview, mapping: ["id","name"], runtime: runtime, progress: TransferProgress()), 1)
        let failing = "id,name\n" + (10..<2010).map { "\($0),row\n" }.joined() + "1,duplicate\n"
        try failing.write(to: file, atomically: true, encoding: .utf8)
        let failingPreview = try connection.previewCSV(file, into: table, options: options, runtime: runtime, progress: TransferProgress())
        XCTAssertThrowsError(try connection.importCSV(file, into: table, options: options, preview: failingPreview, mapping: ["id","name"], runtime: runtime, progress: TransferProgress()))
        XCTAssertEqual(try sql("SELECT count(*) FROM \(q)").cell(0, 0), "4")
        for format in TableExportFormat.allCases {
            let output = temp.appendingPathComponent("all." + format.rawValue)
            XCTAssertEqual(try connection.exportTable(table, to: output, format: format, runtime: runtime, progress: TransferProgress()), 4)
            XCTAssertGreaterThan(try Data(contentsOf: output).count, 0)
        }
        if dialect == .mysql {
            let generatedName = name + "_defaults"
            _ = try sql("CREATE TABLE " + dialect.quote(generatedName) + " (id INTEGER AUTO_INCREMENT PRIMARY KEY, name VARCHAR(200) DEFAULT 'fallback', qty INTEGER DEFAULT 5, calculated INTEGER GENERATED ALWAYS AS (qty+1) STORED)")
            defer { _ = try? sql("DROP TABLE " + dialect.quote(generatedName)) }
            let generated = try XCTUnwrap(try connection.tables().first { $0.name == generatedName })
            try "ignored,name,computed\n999,kept,999\n".write(to: file, atomically: true, encoding: .utf8)
            let generatedPreview = try connection.previewCSV(file, into: generated, options: options, runtime: runtime, progress: TransferProgress())
            XCTAssertTrue(generatedPreview.columns.first { $0.name == "calculated" }!.computed)
            XCTAssertEqual(try connection.importCSV(file, into: generated, options: options, preview: generatedPreview, mapping: [nil,"name",nil], runtime: runtime, progress: TransferProgress()), 1)
            XCTAssertEqual(try sql("SELECT name,qty,calculated FROM " + dialect.qualifiedName(of: generated)).row(0), ["kept","5","6"])
            XCTAssertEqual(try sql("SELECT count(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME LIKE 'sdbui_import_%'").cell(0,0), "0")
        }
        _ = try sql("BEGIN")
        XCTAssertThrowsError(try connection.executeReadOnly(browseSQL, maxRows: 100))
        _ = try sql("ROLLBACK")
    }
}
