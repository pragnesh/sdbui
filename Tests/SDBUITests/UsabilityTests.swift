import ADBCKit
import CSQLite
import Foundation
import SwiftCrossUI
import XCTest
@testable import SDBUI

final class HistoryOutcomeTests: XCTestCase {
    func testOutcomesConnectionSearchAndOldSchemaMigration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("history.sqlite3")
        var fixture: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &fixture), SQLITE_OK)
        let id = UUID()
        XCTAssertEqual(sqlite3_exec(fixture, """
            CREATE TABLE history (seq INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL UNIQUE, sql TEXT NOT NULL, connection TEXT NOT NULL, date REAL NOT NULL);
            INSERT INTO history(id,sql,connection,date) VALUES ('\(id.uuidString)','SELECT old','A',0);
            PRAGMA user_version=1;
            """, nil, nil, nil), SQLITE_OK)
        sqlite3_close(fixture)
        let store = QueryLibraryStore(url: url)
        XCTAssertNil(store.loadError)
        XCTAssertEqual(store.history.first?.id, id)
        XCTAssertNil(store.history.first?.succeeded)
        let a = try XCTUnwrap(store.record(sql: "SELECT '50%_off'", connection: "A"))
        try store.completeHistory(a, duration: 0.25, rowCount: 17, succeeded: true)
        let b = try XCTUnwrap(store.record(sql: "SELECT '50%_off'", connection: "B"))
        try store.completeHistory(b, duration: 0.5, rowCount: nil, succeeded: false)
        let reopened = QueryLibraryStore(url: url)
        XCTAssertNil(reopened.loadError)
        let page = try reopened.historyPage(matching: "50%_off", connection: "A")
        XCTAssertEqual(page.entries.count, 1)
        XCTAssertEqual(page.entries.first?.duration, 0.25)
        XCTAssertEqual(page.entries.first?.rowCount, 17)
        XCTAssertEqual(page.entries.first?.succeeded, true)
        XCTAssertTrue(page.entries.first?.outcomeLabel.contains("✓") == true)
        let failure = try XCTUnwrap(reopened.historyPage(connection: "B").entries.first)
        XCTAssertEqual(failure.succeeded, false)
        XCTAssertNil(failure.rowCount)
        XCTAssertEqual(try reopened.historyPage(matching: "B", connection: "A").entries.count, 0)
        XCTAssertEqual(reopened.historyCount, 3)
    }
}

@MainActor
final class GridUsabilityTests: XCTestCase {
    func testHideFreezeSortCopyAndSchemaReset() {
        let pane = ResultPane()
        let result = QueryResult(columns: [.init(name: "id", type: "int"), .init(name: "name", type: "text"), .init(name: "note", type: "text")],
            rows: [["2", "long name", nil], ["1", "first", "NULL"]])
        pane.show(result)
        XCTAssertEqual(pane.headerCommand(2, column: 1), "name")
        XCTAssertEqual(pane.headerCommand(3, column: 2), "NULL\nNULL")
        _ = pane.headerCommand(6, column: 1)
        XCTAssertEqual(pane.frozenColumns, [0, 1])
        XCTAssertEqual(pane.scrollingColumns, [2])
        _ = pane.headerCommand(4, column: 0)
        XCTAssertEqual(pane.visibleColumns, [1, 2])
        XCTAssertEqual(pane.frozenColumns, [1])
        _ = pane.headerCommand(0, column: 0)
        XCTAssertEqual(pane.result?.cell(0, 0), "1")
        _ = pane.headerCommand(1, column: 0)
        XCTAssertEqual(pane.result?.cell(0, 0), "2")
        pane.show(result)
        XCTAssertEqual(pane.visibleColumns, [1, 2]) // Paging keeps layout.
        _ = pane.headerCommand(8, column: 1)
        XCTAssertEqual(pane.visibleColumns, [0, 1, 2])
        _ = pane.headerCommand(7, column: 0)
        XCTAssertEqual(pane.frozenCount, 0)
        _ = pane.headerCommand(4, column: 1)
        _ = pane.headerCommand(4, column: 2)
        _ = pane.headerCommand(4, column: 0)
        XCTAssertEqual(pane.visibleColumns, [0]) // Never hide the last column.
        pane.show(QueryResult(columns: [.init(name: "other", type: "text")], rows: [["value"]]))
        XCTAssertTrue(pane.hiddenColumns.isEmpty)
        XCTAssertEqual(pane.frozenCount, 0)
    }

    func testAutoFitPreservesLongLoadedValuesAndSortHandler() {
        let pane = ResultPane()
        pane.show(QueryResult(columns: [.init(name: "text", type: "text")], rows: [[String(repeating: "x", count: 150)]]))
        _ = pane.headerCommand(5, column: 0)
        XCTAssertGreaterThan(pane.columns[0].width, 420)
        var sort: DataGridSort?
        pane.sortHandler = { sort = $0 }
        _ = pane.headerCommand(1, column: 0)
        XCTAssertEqual(sort, DataGridSort(column: 0, ascending: false))
    }
}

@MainActor
final class UsabilityIntegrationTests: XCTestCase {
    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !predicate() {
            guard Date() < deadline else { throw ADBCError("Timed out waiting for usability test") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
    private func connected() async throws -> BrowserModel {
        guard let uri = ProcessInfo.processInfo.environment["SDBUI_TEST_POSTGRES_URI"] else { throw XCTSkip("Set SDBUI_TEST_POSTGRES_URI") }
        let model = BrowserModel(queryLibrary: QueryLibraryStore(url: nil))
        model.connectionDraft.useURI = true
        model.connectionDraft.uri = uri
        model.connectFavorite()
        try await waitUntil { model.connection != nil && !model.isConnecting }
        return model
    }
    func testPagerEstimateAndFilteredPageJump() async throws {
        let model = try await connected()
        defer { model.disconnect() }
        let connection = try XCTUnwrap(model.connection)
        _ = try connection.execute("CREATE TABLE public.usability_pager AS SELECT i AS id FROM generate_series(1,2505) AS i", maxRows: 0)
        defer { _ = try? connection.execute("DROP TABLE public.usability_pager", maxRows: 0) }
        _ = try connection.execute("ANALYZE public.usability_pager", maxRows: 0)
        model.refreshTables()
        try await waitUntil { model.tables.contains { $0.name == "usability_pager" } }
        model.selectTable(model.tables.first { $0.name == "usability_pager" }!.id)
        model.browseSelectedTable()
        try await waitUntil { !model.isRunning && !model.rowEstimates.isEmpty }
        XCTAssertTrue(model.contentRowsLabel.contains("estimate"))
        model.goToContentPage("3")
        try await waitUntil { !model.isRunning }
        XCTAssertEqual(model.contentPage, 3)
        XCTAssertEqual(model.contentOffset, 2000)
        XCTAssertEqual(model.queryPane.result?.rowCount, 505)
        XCTAssertFalse(model.contentHasMore)
        for invalid in ["0", "-1", "bad", String(Int.max)] { model.goToContentPage(invalid); XCTAssertFalse(model.isRunning) }
        XCTAssertEqual(model.contentOffset, 2000)
        model.goToContentPage("4")
        try await waitUntil { !model.isRunning }
        XCTAssertEqual(model.queryPane.result?.rowCount, 0)
        model.goToContentPage("1")
        try await waitUntil { !model.isRunning }
        model.filterColumn = "id"; model.filterOperator = .equals; model.filterValue = "1"
        model.applyContentFilter()
        try await waitUntil { !model.isRunning }
        XCTAssertFalse(model.contentRowsLabel.contains("estimate"))
    }
    func testStatementLogHistoryAndDisconnectConfirmation() async throws {
        let model = try await connected()
        defer { model.disconnect() }
        model.setSQL("SELECT 1; SELEC invalid; SELECT 3")
        model.runQuery()
        try await waitUntil { !model.isRunning }
        XCTAssertEqual(model.statementLog.count, 3)
        XCTAssertTrue(model.statementLog[0].hasPrefix("✓ Statement 1/3"))
        XCTAssertTrue(model.statementLog[1].hasPrefix("✗ Statement 2/3"))
        XCTAssertTrue(model.statementLog[2].contains("not executed"))
        XCTAssertEqual(model.queryPane.result?.cell(0, 0), "1")
        XCTAssertEqual(model.queryLibrary.history.map(\.succeeded), [false, true])
        XCTAssertTrue(model.queryLibrary.history.allSatisfy { $0.duration != nil })
        model.setSQL("SELECT pg_sleep(5)")
        model.runQuery()
        try await Task.sleep(nanoseconds: 100_000_000)
        model.requestDisconnect()
        XCTAssertTrue(model.pendingDisconnect)
        XCTAssertNotNil(model.connection)
        model.cancelDisconnect()
        XCTAssertFalse(model.pendingDisconnect)
        XCTAssertTrue(model.isRunning)
        model.requestDisconnect()
        model.confirmDisconnect()
        XCTAssertNil(model.connection)
        XCTAssertFalse(model.isRunning)
        XCTAssertFalse(model.pendingDisconnect)
        XCTAssertEqual(model.sql, "SELECT pg_sleep(5)")
        try await waitUntil { model.queryLibrary.history.first?.succeeded != nil }
        XCTAssertEqual(model.queryLibrary.history.first?.succeeded, false)
    }
}
