import Foundation
import XCTest
@testable import ADBCKit
@testable import SDBUI

@MainActor
final class KeyboardShortcutsTests: XCTestCase {
    private func workspace() -> ConnectionWorkspace {
        ConnectionWorkspace { BrowserModel(queryLibrary: QueryLibraryStore(url: nil)) }
    }
    func testTabCommandsWrapAndSelectLastWithoutChangingEditors() {
        let workspace = workspace()
        let first = workspace.selectedID
        workspace.selectedTab.model.setSQL("SELECT 'first'")
        XCTAssertTrue(workspace.performShortcut(1))
        let second = workspace.selectedID
        workspace.selectedTab.model.setSQL("SELECT 'second'")
        XCTAssertTrue(workspace.performShortcut(3))
        XCTAssertEqual(workspace.selectedID, first)
        workspace.performShortcut(4)
        XCTAssertEqual(workspace.selectedID, second)
        workspace.performShortcut(101)
        XCTAssertEqual(workspace.selectedID, first)
        XCTAssertEqual(workspace.selectedTab.model.sql, "SELECT 'first'")
        workspace.performShortcut(108) // Missing numbered tabs are ignored.
        XCTAssertEqual(workspace.selectedID, first)
        workspace.performShortcut(109)
        XCTAssertEqual(workspace.selectedID, second)
        XCTAssertEqual(workspace.selectedTab.model.sql, "SELECT 'second'")
        workspace.performShortcut(2)
        workspace.confirmClose()
        XCTAssertEqual(workspace.selectedID, first)
        workspace.performShortcut(2)
        workspace.confirmClose()
        XCTAssertEqual(workspace.tabs.count, 1)
        XCTAssertNotEqual(workspace.selectedID, first)
        XCTAssertFalse(workspace.performShortcut(999))
    }
    func testFontSizeIsBoundedAndIndependentAndUnavailableCommandsAreSafe() {
        let workspace = workspace()
        let first = workspace.selectedTab
        XCTAssertFalse(workspace.performShortcut(5))
        XCTAssertFalse(workspace.performShortcut(6))
        XCTAssertFalse(workspace.performShortcut(7))
        workspace.performShortcut(10)
        XCTAssertFalse(first.model.isBrowsing)
        for _ in 0..<50 { workspace.performShortcut(11) }
        XCTAssertEqual(first.model.queryFontSize, 28)
        workspace.performShortcut(1)
        XCTAssertEqual(workspace.selectedTab.model.queryFontSize, 13)
        for _ in 0..<50 { workspace.performShortcut(12) }
        XCTAssertEqual(workspace.selectedTab.model.queryFontSize, 9)
        workspace.select(first.id)
        XCTAssertEqual(first.model.queryFontSize, 28)
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !predicate() {
            guard Date() < deadline else { throw ADBCError("Timed out waiting for shortcut") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func testPagingRefreshEditorAndEscapeOnActiveSession() async throws {
        guard let uri = ProcessInfo.processInfo.environment["SDBUI_TEST_POSTGRES_URI"] else { throw XCTSkip("Set SDBUI_TEST_POSTGRES_URI") }
        let workspace = workspace()
        let model = workspace.selectedTab.model
        defer { for tab in workspace.tabs { tab.model.disconnect() } }
        model.connectionDraft.useURI = true
        model.connectionDraft.uri = uri
        model.connectFavorite()
        try await waitUntil { model.connection != nil && !model.isConnecting }
        let connection = try XCTUnwrap(model.connection)
        _ = try connection.execute("CREATE TABLE public.keyboard_page AS SELECT generate_series(1, 2005) AS n", maxRows: 0)
        defer { _ = try? connection.execute("DROP TABLE public.keyboard_page", maxRows: 0) }
        model.refreshTables()
        try await waitUntil { model.tables.contains { $0.name == "keyboard_page" } }
        let table = try XCTUnwrap(model.tables.first { $0.name == "keyboard_page" })
        model.selectTable(table.id)
        model.browseSelectedTable()
        try await waitUntil { !model.isRunning }
        workspace.performShortcut(10)
        try await waitUntil { !model.isRunning }
        XCTAssertEqual(model.contentOffset, 1000)
        workspace.performShortcut(9)
        try await waitUntil { !model.isRunning }
        XCTAssertEqual(model.contentOffset, 0)
        model.selectTab(.structure)
        workspace.performShortcut(6)
        XCTAssertEqual(model.selectedTab, .query)
        model.setSQL("SELECT 'keep editor'")
        workspace.performShortcut(8)
        try await waitUntil { !model.isRunning }
        XCTAssertEqual(model.sql, "SELECT 'keep editor'")
        model.setSQL("DELETE FROM keyboard_page")
        model.runQuery()
        XCTAssertNotNil(model.pendingQuery)
        workspace.performShortcut(7)
        XCTAssertNil(model.pendingQuery)
        XCTAssertEqual(try connection.execute("SELECT count(*) FROM keyboard_page", maxRows: 1).cell(0, 0, maxLength: nil), "2005")
        model.setSQL("SELECT pg_sleep(10)")
        model.runQuery()
        try await Task.sleep(nanoseconds: 100_000_000)
        workspace.performShortcut(7)
        try await waitUntil { !model.isRunning }
        XCTAssertTrue(model.queryStatus?.text.contains("cancelled") == true, String(describing: model.queryStatus))
        let lastManualStatus = model.queryStatus
        _ = try connection.execute("CREATE VIEW public.keyboard_slow AS SELECT 1 AS n FROM pg_sleep(10)", maxRows: 0)
        defer { _ = try? connection.execute("DROP VIEW public.keyboard_slow", maxRows: 0) }
        let slow = TableInfo(catalog: nil, schema: "public", name: "keyboard_slow", type: "VIEW")
        model.tables.append(slow)
        model.selectTable(slow.id)
        model.browseSelectedTable()
        try await Task.sleep(nanoseconds: 100_000_000)
        workspace.performShortcut(7)
        try await waitUntil { !model.isRunning }
        XCTAssertEqual(model.statusMessage, "Loading keyboard_slow cancelled")
        XCTAssertEqual(model.queryStatus, lastManualStatus)

    }
}
