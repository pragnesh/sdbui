@testable import ADBCKit
import Foundation
import SwiftCrossUI
import XCTest
@testable import SDBUI

@MainActor
final class ProductionSafetyIntegrationTests: XCTestCase {
    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !predicate() {
            guard Date() < deadline else { throw ADBCError("Timed out waiting for query") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func model(readOnly: Bool = false) async throws -> BrowserModel {
        guard let uri = ProcessInfo.processInfo.environment["SDBUI_TEST_POSTGRES_URI"] else { throw XCTSkip("Set SDBUI_TEST_POSTGRES_URI") }
        let model = BrowserModel(queryLibrary: QueryLibraryStore(url: nil))
        model.connectionDraft.useURI = true
        model.connectionDraft.uri = uri
        model.connectionDraft.safety = FavoriteSafety(label: "Test", color: "Red", readOnly: readOnly)
        model.connectFavorite()
        try await waitUntil { model.connection != nil && !model.isConnecting }
        return model
    }

    func testWholeBatchConfirmationCancelAndStaleSQL() async throws {
        let model = try await model()
        defer { model.disconnect() }
        let connection = try XCTUnwrap(model.connection)
        _ = try connection.execute("CREATE TEMP TABLE safety_test (n int)", maxRows: 1)
        _ = try connection.execute("INSERT INTO safety_test VALUES (1)", maxRows: 1)
        model.setSQL("INSERT INTO safety_test VALUES (2); DELETE FROM safety_test")
        model.runQuery()
        XCTAssertNotNil(model.pendingQuery)
        XCTAssertFalse(model.isRunning)
        XCTAssertEqual(try connection.execute("SELECT * FROM safety_test", maxRows: 10).rowCount, 1)
        model.cancelPendingQuery()
        XCTAssertNil(model.pendingQuery)
        model.runQuery()
        model.setSQL("DELETE FROM safety_test WHERE false")
        model.confirmPendingQuery()
        XCTAssertFalse(model.isRunning)
        XCTAssertEqual(try connection.execute("SELECT * FROM safety_test", maxRows: 10).rowCount, 1)
        model.setSQL("DELETE FROM safety_test")
        model.runCurrentStatement(TextEditorSubmission(text: model.sql, selection: nil, cursor: 0))
        XCTAssertNotNil(model.pendingQuery)
        model.selectDatabase("pg_catalog")
        XCTAssertNil(model.pendingQuery)
        model.runQuery()
        model.confirmPendingQuery()
        try await waitUntil { !model.isRunning }
        XCTAssertEqual(try connection.execute("SELECT * FROM safety_test", maxRows: 10).rowCount, 0)
        model.runQuery()
        XCTAssertNotNil(model.pendingQuery) // Approval is never remembered.
        model.disconnect()
        XCTAssertNil(model.pendingQuery)
    }

    func testReadOnlyBlocksBatchAndDatabaseRejectsSideEffects() async throws {
        let model = try await model(readOnly: true)
        defer { model.disconnect() }
        XCTAssertEqual(model.connectionSafety.label, "Test")
        XCTAssertTrue(model.connectionSafety.readOnly)
        model.setSQL("SELECT 1; CREATE TABLE should_never_exist (n int)")
        model.runQuery()
        XCTAssertFalse(model.isRunning)
        XCTAssertTrue(model.queryStatus?.text.contains("Blocked") == true)
        XCTAssertNil(model.pendingQuery)
        let connection = try XCTUnwrap(model.connection)
        // A SELECT function can write; the database transaction must block it.
        let name = "safety_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        _ = try connection.execute("CREATE FUNCTION pg_temp.\(name)() RETURNS int LANGUAGE plpgsql AS $$ BEGIN CREATE TABLE public.\(name)(n int); RETURN 1; END $$", maxRows: 0)
        XCTAssertThrowsError(try connection.executeReadOnly("SELECT pg_temp.\(name)()", maxRows: 1))
        XCTAssertEqual(try connection.executeReadOnly("SELECT 42", maxRows: 1).cell(0, 0, maxLength: nil), "42")
        _ = try connection.execute("CREATE TEMP VIEW safety_view AS SELECT pg_temp.\(name)() AS n", maxRows: 0)
        let namespace = try XCTUnwrap(try connection.execute("SELECT nspname FROM pg_namespace WHERE oid = pg_my_temp_schema()", maxRows: 1).cell(0, 0, maxLength: nil))
        model.tables = [TableInfo(catalog: nil, schema: namespace, name: "safety_view", type: "VIEW")]
        model.selectTable(model.tables[0].id)
        model.browseSelectedTable()
        try await waitUntil { !model.isRunning }
        XCTAssertTrue(model.errorMessage?.contains("read-only transaction") == true)

        model.setSQL("SELECT current_setting('transaction_read_only')")
        model.runQuery()
        try await waitUntil { !model.isRunning }
        XCTAssertEqual(model.queryPane.result?.cell(0, 0, maxLength: nil), "on")
        XCTAssertNil(model.queryStatus?.error)
    }
}
