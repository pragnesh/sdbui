import ADBCKit
import Foundation
import SwiftCrossUI
import XCTest
@testable import SDBUI

final class QueryStatusTests: XCTestCase {
    func testRowsDurationTruncationAndAffectedRows() {
        let rows = QueryResult(columns: [.init(name: "n", type: "int64")], rows: [["1"], ["2"]], truncated: true)
        let status = QueryStatus.completed(rows, elapsed: .milliseconds(84), statements: 1, maxRows: 2)
        XCTAssertEqual(status.text, "2 rows · 84 ms · truncated at Max rows (2) ⚠")
        XCTAssertTrue(status.truncated)
        let write = QueryResult(columns: [], rows: [], rowsAffected: 1)
        XCTAssertEqual(QueryStatus.completed(write, elapsed: .seconds(1.25), statements: 2, maxRows: 100).text,
                       "2 statements · last result: 1 row affected · 1.25 s")
        let empty = QueryResult(columns: [.init(name: "n", type: "int64")], rows: [])
        XCTAssertEqual(QueryStatus.completed(empty, elapsed: .zero, statements: 1, maxRows: 100).text, "0 rows · 0 ms")
        XCTAssertNil(status.error)
    }

    func testErrorPositionUsesUnicodeScalarsAndSelectionBase() throws {
        let source = "-- 🙂 comment\nSELECT 1;\n  SELECT 'é', oops;"
        let statements = SQLDialect.postgres.statements(in: source)
        let second = try XCTUnwrap(statements.last)
        let position = try XCTUnwrap(second.text.range(of: "oops")).lowerBound
        let relative = second.text[..<position].unicodeScalars.count
        let location = try XCTUnwrap(QueryErrorLocation.resolve(position: relative + 1, statement: second, source: source, baseOffset: 0))
        let original = try XCTUnwrap(source.range(of: "oops")).lowerBound
        XCTAssertEqual(location.offset, source[..<original].unicodeScalars.count)
        let selected = "  SELECT 'é', oops;"
        let base = source.unicodeScalars.count - selected.unicodeScalars.count
        let statement = try XCTUnwrap(SQLDialect.postgres.statements(in: selected).first)
        XCTAssertEqual(QueryErrorLocation.resolve(position: relative + 1, statement: statement, source: source, baseOffset: base)?.offset,
                       location.offset)
        for invalid in [nil, 0, -1, Int.max] {
            XCTAssertNil(QueryErrorLocation.resolve(position: invalid, statement: second, source: source, baseOffset: 0))
        }
    }
}

@MainActor
final class QueryStatusIntegrationTests: XCTestCase {
    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(8)
        while !predicate() {
            guard Date() < deadline else { throw ADBCError("Timed out waiting for query state") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func connectedModel() async throws -> BrowserModel {
        guard let uri = ProcessInfo.processInfo.environment["SDBUI_TEST_POSTGRES_URI"] else { throw XCTSkip("Set SDBUI_TEST_POSTGRES_URI") }
        let model = BrowserModel(queryLibrary: QueryLibraryStore(url: nil))
        model.connectionDraft.useURI = true
        model.connectionDraft.uri = uri
        model.connectFavorite()
        try await waitUntil { model.connection != nil && !model.isConnecting }
        return model
    }

    func testRealLimitErrorPositionAndRecovery() async throws {
        let model = try await connectedModel()
        defer { model.disconnect() }
        model.maxRows = 100
        model.setSQL("SELECT generate_series(1, 101)")
        model.runQuery()
        model.maxRows = 1_000 // The summary must describe the cap used by this run.
        try await waitUntil { !model.isRunning }
        XCTAssertEqual(model.queryPane.result?.rowCount, 100)
        XCTAssertTrue(model.queryStatus?.truncated == true)
        XCTAssertTrue(model.queryStatus?.text.contains("Max rows (100)") == true)
        let script = "SELECT '🙂';\n SELECT 1 + ;"
        model.setSQL(script)
        model.runQuery()
        try await waitUntil { !model.isRunning }
        XCTAssertNotNil(model.queryStatus?.error)
        XCTAssertEqual(model.queryStatus?.error, model.errorMessage)
        // PostgreSQL's syntax position is a one-based character offset in the submitted statement.
        let endOfExpression = try XCTUnwrap(script.range(of: "+")).upperBound
        XCTAssertEqual(model.queryErrorLocation?.offset, script[..<endOfExpression].unicodeScalars.count)
        let failedStatus = model.queryStatus
        model.refreshTables()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(model.queryStatus, failedStatus)
        model.setSQL("SELECT 1")
        model.runQuery()
        try await waitUntil { !model.isRunning }
        XCTAssertNil(model.queryStatus?.error)
        XCTAssertNil(model.queryErrorLocation)
        XCTAssertFalse(model.queryStatus?.truncated ?? true)
    }

    func testSelectedStatementsMapPositionAndEditedSQLDoesNotJump() async throws {
        let model = try await connectedModel()
        defer { model.disconnect() }
        let prefix = "SELECT '🙂';\n"
        let selected = "SELECT 1 + ;"
        let source = prefix + selected + "\nSELECT 2;"
        model.runCurrentStatement(TextEditorSubmission(text: source,
            selection: prefix.unicodeScalars.count..<(prefix + selected).unicodeScalars.count, cursor: 0))
        try await waitUntil { !model.isRunning }
        XCTAssertEqual(model.queryErrorLocation?.offset, (prefix + "SELECT 1 +").unicodeScalars.count)
        model.setSQL("SELECT pg_sleep(0.2); SELECT 1 + ;")
        model.runQuery()
        model.sql = "SELECT 'edited while running'"
        try await waitUntil { !model.isRunning }
        XCTAssertNil(model.queryErrorLocation)
        XCTAssertNotNil(model.queryStatus?.error)
    }
}
