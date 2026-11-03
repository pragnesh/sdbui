import Foundation
import XCTest
@testable import ADBCKit

final class TransferTests: XCTestCase {
    func connection() throws -> ADBCConnection {
        guard let uri = ProcessInfo.processInfo.environment["SDBUI_TEST_POSTGRES_URI"] else { throw XCTSkip("Requires isolated PostgreSQL integration fixture") }
        return try ADBCConnection.open(.direct(driver: "postgresql", uri: uri))
    }
    func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sdbui-transfer-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func testWholeTableFormatsAndSQLRestore() throws {
        let connection = try connection(), runtime = try TransferRuntime.discover(), directory = try temporaryDirectory()
        let name = "transfer_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let table = TableInfo(catalog: nil, schema: "public", name: name, type: "TABLE")
        let q = connection.qualifiedName(of: table)
        _ = try connection.execute("CREATE TABLE \(q) (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, n numeric(30,6), t text, b bytea, computed bigint GENERATED ALWAYS AS (id * 2) STORED)", maxRows: 0)
        defer { _ = try? connection.execute("DROP TABLE \(q)", maxRows: 0) }
        _ = try connection.execute("INSERT INTO \(q) (n,t,b) SELECT 12345678901234.123456, CASE WHEN i=1 THEN E'a,\\\"b\\\"\\n雪' WHEN i=2 THEN E'\\\\N' ELSE NULL END, decode(repeat('00ff',256),'hex') FROM generate_series(1,2501) i", maxRows: 0)
        for format in TableExportFormat.allCases {
            let output = directory.appendingPathComponent("all." + format.rawValue)
            XCTAssertEqual(try connection.exportTable(table, to: output, format: format, runtime: runtime, progress: TransferProgress()), 2501)
            XCTAssertGreaterThan(try Data(contentsOf: output).count, 100)
            if format == .json {
                let rows = try JSONSerialization.jsonObject(with: Data(contentsOf: output)) as! [[String: Any]]
                XCTAssertEqual(rows.count, 2501)
                XCTAssertEqual((rows[0]["b"] as? String)?.count, 1026)
            }
            if format == .sql {
                let text = try String(contentsOf: output, encoding: .utf8)
                XCTAssertTrue(text.contains("OVERRIDING SYSTEM VALUE"))
                XCTAssertFalse(text.contains("\"computed\""))
                _ = try connection.execute("DELETE FROM \(q)", maxRows: 0)
                for statement in SQLDialect.postgres.statements(in: text) {
                    _ = try connection.execute(statement.text, maxRows: 0, usePostgresCopy: false)
                }
                XCTAssertEqual(try connection.execute("SELECT count(*) FROM \(q) WHERE computed = id * 2 AND octet_length(b)=512 AND n=12345678901234.123456", maxRows: 1).cell(0, 0), "2501")
            }
        }
        let filtered = directory.appendingPathComponent("filtered.json")
        XCTAssertEqual(try connection.exportTable(table, to: filtered, format: .json, expression: .condition(.init(column: "id", op: .less, value: "4")), orderBy: ("id", false), readOnly: true, runtime: runtime, progress: TransferProgress()), 3)
        let result = try JSONSerialization.jsonObject(with: Data(contentsOf: filtered)) as! [[String: Any]]
        XCTAssertEqual(result[0]["id"] as? Int, 3)
        let preserved = directory.appendingPathComponent("cancel.csv")
        try "keep".write(to: preserved, atomically: true, encoding: .utf8)
        let cancelled = TransferProgress(); cancelled.cancel()
        XCTAssertThrowsError(try connection.exportTable(table, to: preserved, format: .csv, runtime: runtime, progress: cancelled))
        XCTAssertEqual(try String(contentsOf: preserved, encoding: .utf8), "keep")
        XCTAssertEqual(try connection.execute("SELECT 1", maxRows: 1).cell(0, 0), "1")
    }
    func testCSVMappingDefaultsNullsAndTransactionalFailures() throws {
        let connection = try connection(), runtime = try TransferRuntime.discover(), directory = try temporaryDirectory()
        let name = "import_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let table = TableInfo(catalog: nil, schema: "public", name: name, type: "TABLE")
        let q = connection.qualifiedName(of: table)
        _ = try connection.execute("CREATE TABLE \(q) (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, n integer CHECK(n>=0), t text, b bytea, d text DEFAULT 'default', computed bigint GENERATED ALWAYS AS (id * 2) STORED)", maxRows: 0)
        defer { _ = try? connection.execute("DROP TABLE \(q)", maxRows: 0) }
        let csv = directory.appendingPathComponent("input.csv")
        let options = CSVImportOptions()
        try "number,t,b,unused\r\n1,\\N,\\x00ff,ignore\r\n2,\"\\N\",\\x,ignore\r\n3,\"\",\\N,ignore\r\n4,\"a,\"\"b\"\"\n雪\",\\x01,ignore\r\n".write(to: csv, atomically: true, encoding: .utf8)
        func preview() throws -> CSVImportPreview { try connection.previewCSV(csv, into: table, options: options, runtime: runtime, progress: TransferProgress()) }
        let first = try preview()
        XCTAssertEqual(first.samples[0][1], nil)
        XCTAssertEqual(first.samples[1][1], "\\N")
        XCTAssertTrue(first.columns.first { $0.name == "id" }!.identity)
        XCTAssertTrue(first.columns.first { $0.name == "computed" }!.computed)
        let mapping: [String?] = ["n", "t", "b", nil]
        XCTAssertEqual(try connection.importCSV(csv, into: table, options: options, preview: first, mapping: mapping, runtime: runtime, progress: TransferProgress()), 4)
        let rows = try connection.execute("SELECT n,t,encode(b,'hex'),d FROM \(q) ORDER BY id", maxRows: 10)
        XCTAssertNil(rows.cell(0, 1)); XCTAssertEqual(rows.cell(1, 1), "\\N"); XCTAssertEqual(rows.cell(2, 1), "")
        XCTAssertEqual(rows.cell(0, 2), "00ff"); XCTAssertEqual(rows.cell(0, 3), "default")
        func count() throws -> String? { try connection.execute("SELECT count(*) FROM \(q)", maxRows: 1).cell(0, 0) }
        // Failure after one or more batches must undo the earlier batches too.
        let many = "number,t,b,unused\n" + (0..<2001).map { "\($0),ok,\\x00,skip\n" }.joined() + "-1,bad,\\x00,skip\n"
        try many.write(to: csv, atomically: true, encoding: .utf8)
        let bulk = try preview()
        XCTAssertThrowsError(try connection.importCSV(csv, into: table, options: options, preview: bulk, mapping: mapping, runtime: runtime, progress: TransferProgress()))
        XCTAssertEqual(try count(), "4")
        let cancelled = TransferProgress(); cancelled.cancel()
        XCTAssertThrowsError(try connection.importCSV(csv, into: table, options: options, preview: bulk, mapping: mapping, runtime: runtime, progress: cancelled))
        XCTAssertEqual(try count(), "4")
        // Preview invalidation: file, target schema and mapping.
        try "number,t,b,unused\n8,ok,\\x00,skip\n".write(to: csv, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try connection.importCSV(csv, into: table, options: options, preview: bulk, mapping: mapping, runtime: runtime, progress: TransferProgress()))
        let fresh = try preview()
        XCTAssertThrowsError(try connection.importCSV(csv, into: table, options: options, preview: fresh, mapping: ["n", "n", "b", nil], runtime: runtime, progress: TransferProgress()))
        _ = try connection.execute("ALTER TABLE \(q) ADD COLUMN extra text", maxRows: 0)
        XCTAssertThrowsError(try connection.importCSV(csv, into: table, options: options, preview: fresh, mapping: mapping, runtime: runtime, progress: TransferProgress()))
        XCTAssertEqual(try count(), "4")
        let changed = try preview()
        _ = try connection.execute("BEGIN", maxRows: 0)
        _ = try connection.execute("INSERT INTO \(q) (n) VALUES (9)", maxRows: 0)
        XCTAssertThrowsError(try connection.importCSV(csv, into: table, options: options, preview: changed, mapping: mapping, runtime: runtime, progress: TransferProgress()))
        XCTAssertEqual(try count(), "5")
        _ = try connection.execute("ROLLBACK", maxRows: 0)
        XCTAssertEqual(try count(), "4")
        XCTAssertEqual(try connection.importCSV(csv, into: table, options: options, preview: changed, mapping: mapping, runtime: runtime, progress: TransferProgress()), 1)
    }
}
