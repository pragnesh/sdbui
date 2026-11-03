import Foundation
import XCTest
@testable import ADBCKit
@testable import SDBUI

final class CellFilterTests: XCTestCase {
    private func target(_ value: String?) -> CellFilterTarget {
        CellFilterTarget(column: "odd\"column", value: value, tableID: "table", sessionRevision: 1, paneRevision: 1)
    }
    func testNullEmptyAndLiteralNullSemantics() throws {
        XCTAssertEqual(target(nil).filter(for: 0)?.op, .isNull)
        XCTAssertEqual(target(nil).filter(for: 1)?.op, .isNotNull)
        XCTAssertEqual(target("").filter(for: 0)?.op, .equals)
        XCTAssertEqual(target("").filter(for: 0)?.value, "")
        XCTAssertEqual(target("NULL").filter(for: 0)?.value, "NULL")
        XCTAssertEqual(target("anything").filter(for: 2)?.op, .isNull)
        XCTAssertEqual(target("anything").filter(for: 2)?.value, "")
        XCTAssertNil(target("x").filter(for: 999))
        XCTAssertNil(target("a\0b").filter(for: 0))
        XCTAssertNotNil(target("a\0b").filter(for: 2))
        let filter = try XCTUnwrap(target("O'Reilly\\value").filter(for: 0))
        XCTAssertEqual(SQLDialect.postgres.whereClause(for: filter), "\"odd\"\"column\" = 'O''Reilly\\value'")
        XCTAssertEqual(SQLDialect.mysql.whereClause(for: filter), "`odd\"column` = 'O''Reilly\\\\value'")
    }
}

@MainActor
final class CellFilterIntegrationTests: XCTestCase {
    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !predicate() {
            guard Date() < deadline else { throw ADBCError("Timed out filtering cell") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
    func testExactFullValuesNullsPagingAndStaleSnapshots() async throws {
        guard let uri = ProcessInfo.processInfo.environment["SDBUI_TEST_POSTGRES_URI"] else { throw XCTSkip("Set SDBUI_TEST_POSTGRES_URI") }
        let model = BrowserModel(queryLibrary: QueryLibraryStore(url: nil))
        defer { model.disconnect() }
        model.connectionDraft.useURI = true; model.connectionDraft.uri = uri
        model.connectFavorite()
        try await waitUntil { model.connection != nil && !model.isConnecting }
        let connection = try XCTUnwrap(model.connection)
        _ = try connection.execute("CREATE TABLE public.cell_filter_test (id int, value text)", maxRows: 0)
        defer { _ = try? connection.execute("DROP TABLE public.cell_filter_test", maxRows: 0) }
        let full = String(repeating: "x", count: 12_000) + "'\\tail"
        _ = try connection.execute("INSERT INTO public.cell_filter_test VALUES (1, \(model.dialect.literal(full))), (2, ''), (3, NULL), (4, 'NULL'), (5, 'other')", maxRows: 0)
        model.refreshTables()
        try await waitUntil { model.tables.contains { $0.name == "cell_filter_test" } }
        model.selectTable(model.tables.first { $0.name == "cell_filter_test" }!.id)
        let sql = "SELECT 'keep editor'"
        model.setSQL(sql)
        model.browseSelectedTable()
        try await waitUntil { !model.isRunning }
        XCTAssertNil(model.cellFilterTarget(in: model.structurePane, row: 0, column: 0))
        XCTAssertNil(model.cellFilterTarget(in: model.queryPane, row: -1, column: 0))
        XCTAssertNil(model.cellFilterTarget(in: model.queryPane, row: 0, column: 100))
        let target = try XCTUnwrap(model.cellFilterTarget(in: model.queryPane, row: 0, column: 1))
        XCTAssertEqual(target.value, full)
        model.applyCellFilter(target, command: 0)
        try await waitUntil { !model.isRunning }
        XCTAssertEqual(model.queryPane.result?.rowCount, 1)
        XCTAssertEqual(model.filterValue, full)
        XCTAssertEqual(model.filterColumn, "value")
        XCTAssertEqual(model.filterOperator, .equals)
        XCTAssertEqual(model.contentOffset, 0)
        XCTAssertEqual(model.sql, sql)
        let before = model.contentFilter
        model.applyCellFilter(target, command: 1) // The result revision changed.
        XCTAssertEqual(model.contentFilter, before)
        XCTAssertFalse(model.isRunning)
        model.clearContentFilter()
        try await waitUntil { !model.isRunning }
        let null = try XCTUnwrap(model.cellFilterTarget(in: model.queryPane, row: 2, column: 1))
        XCTAssertNil(null.value)
        model.applyCellFilter(null, command: 1)
        try await waitUntil { !model.isRunning }
        XCTAssertEqual(model.filterOperator, .isNotNull)
        XCTAssertEqual(model.queryPane.result?.rowCount, 4)
        let nonNull = try XCTUnwrap(model.cellFilterTarget(in: model.queryPane, row: 0, column: 1))
        model.applyCellFilter(nonNull, command: 2)
        try await waitUntil { !model.isRunning }
        XCTAssertEqual(model.filterOperator, .isNull)
        XCTAssertEqual(model.queryPane.result?.rowCount, 1)
        XCTAssertEqual(model.sql, sql)
        model.clearContentFilter()
        try await waitUntil { !model.isRunning }
        let empty = try XCTUnwrap(model.cellFilterTarget(in: model.queryPane, row: 1, column: 1))
        model.applyCellFilter(empty, command: 0)
        try await waitUntil { !model.isRunning }
        XCTAssertEqual(model.queryPane.result?.rowCount, 1)
        XCTAssertEqual(model.queryPane.result?.cell(0, 0, maxLength: nil), "2")
        model.clearContentFilter()
        try await waitUntil { !model.isRunning }
        _ = try connection.execute("INSERT INTO public.cell_filter_test SELECT n, 'page' FROM generate_series(6, 1005) n", maxRows: 0)
        model.browseSelectedTable()
        try await waitUntil { !model.isRunning }
        model.showContentPage(next: true)
        try await waitUntil { !model.isRunning }
        XCTAssertEqual(model.contentOffset, 1000)
        let paged = try XCTUnwrap(model.cellFilterTarget(in: model.queryPane, row: 0, column: 0))
        model.applyCellFilter(paged, command: 0)
        try await waitUntil { !model.isRunning }
        XCTAssertEqual(model.contentOffset, 0)
        XCTAssertEqual(model.queryPane.result?.rowCount, 1)
        XCTAssertEqual(model.queryPane.result?.cell(0, 0, maxLength: nil), paged.value)
        let old = try XCTUnwrap(model.cellFilterTarget(in: model.queryPane, row: 0, column: 1))
        model.selectTable(nil)
        model.applyCellFilter(old, command: 1)
        XCTAssertFalse(model.isRunning)
        model.setSQL("SELECT 1")
        model.runQuery()
        try await waitUntil { !model.isRunning }
        XCTAssertNil(model.cellFilterTarget(in: model.queryPane, row: 0, column: 0))
    }
}
