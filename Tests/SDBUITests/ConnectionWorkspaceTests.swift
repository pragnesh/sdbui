import ADBCKit
import Foundation
import XCTest
@testable import SDBUI

@MainActor
final class ConnectionWorkspaceTests: XCTestCase {
    private func workspace() -> ConnectionWorkspace {
        ConnectionWorkspace { BrowserModel(queryLibrary: QueryLibraryStore(url: nil)) }
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(8)
        while !predicate() {
            guard Date() < deadline else { throw ADBCError("Timed out waiting for session") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func testSwitchAndCloseKeepIndependentEditorAndSelectionState() {
        let workspace = workspace()
        let first = workspace.selectedTab
        first.model.setSQL("SELECT 'first'")
        first.model.tableFilterDraft = "customers"
        first.model.selectTab(.structure)
        let secondID = workspace.addTab()
        let second = workspace.selectedTab
        second.model.setSQL("SELECT 'second'")
        second.model.maxRows = 100
        workspace.select(first.id)
        XCTAssertTrue(workspace.selectedTab.model === first.model)
        XCTAssertEqual(first.model.sql, "SELECT 'first'")
        XCTAssertEqual(first.model.tableFilterDraft, "customers")
        XCTAssertEqual(first.model.selectedTab, .structure)
        XCTAssertEqual(first.model.maxRows, 10_000)
        workspace.close(secondID) // Closing a background tab does not select another.
        XCTAssertEqual(workspace.selectedID, first.id)
        workspace.select(secondID) // Stale IDs are ignored.
        XCTAssertEqual(workspace.selectedID, first.id)
        workspace.close(first.id)
        XCTAssertEqual(workspace.tabs.count, 1)
        XCTAssertNotEqual(workspace.selectedID, first.id)
        XCTAssertEqual(workspace.selectedTab.model.sql, "")
    }

    func testInactiveViewsKeepReceivingModelUpdatesUntilClosed() async throws {
        let workspace = workspace()
        let first = workspace.selectedTab
        var notifications = 0
        first.model.watch("cached-editor", of: { first.model.sqlRevision }) { notifications += 1 }
        workspace.addTab()
        first.model.setSQL("SELECT 'background'")
        try await waitUntil { notifications == 1 }
        workspace.select(first.id)
        first.model.setSQL("SELECT 'visible'")
        try await waitUntil { notifications == 2 }
        workspace.close(first.id)
        first.model.setSQL("SELECT 'closed'")
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(notifications, 2)
    }

    func testClosingSelectedTabChoosesAdjacentTab() {
        let workspace = workspace()
        let first = workspace.selectedID
        let second = workspace.addTab()
        let third = workspace.addTab()
        workspace.select(second)
        workspace.close(second)
        XCTAssertEqual(workspace.selectedID, third)
        workspace.close(third)
        XCTAssertEqual(workspace.selectedID, first)
    }

    func testSessionsKeepResultsAndTransactionsWhileSwitchingAndClosing() async throws {
        guard let uri = ProcessInfo.processInfo.environment["SDBUI_TEST_POSTGRES_URI"] else {
            throw XCTSkip("Set SDBUI_TEST_POSTGRES_URI for multiple-session integration tests.")
        }
        let workspace = workspace()
        defer { for tab in workspace.tabs { tab.model.disconnect() } }
        let first = workspace.selectedTab
        first.model.connectionDraft.useURI = true
        first.model.connectionDraft.uri = uri
        first.model.connectionDraft.name = "First"
        first.model.connectFavorite()
        try await waitUntil { first.model.connection != nil && !first.model.isConnecting }
        first.model.setSQL("CREATE TEMP TABLE tab_state (value TEXT); INSERT INTO tab_state VALUES ('first'); SELECT value FROM tab_state")
        first.model.runQuery()
        try await waitUntil { !first.model.isRunning }
        XCTAssertEqual(first.model.queryPane.result?.cell(0, 0, maxLength: nil), "first")
        let secondID = workspace.addTab()
        let second = workspace.selectedTab
        second.model.connectionDraft.useURI = true
        second.model.connectionDraft.uri = uri
        second.model.connectionDraft.name = "Second"
        second.model.connectFavorite()
        try await waitUntil { second.model.connection != nil && !second.model.isConnecting }
        XCTAssertFalse(first.model.connection === second.model.connection)
        second.model.setSQL("SELECT pg_sleep(0.2), 'second'")
        second.model.runQuery()
        workspace.select(first.id) // Query completes in the background.
        try await waitUntil { !second.model.isRunning }
        XCTAssertEqual(second.model.queryPane.result?.cell(0, 1, maxLength: nil), "second")
        XCTAssertEqual(first.model.queryPane.result?.cell(0, 0, maxLength: nil), "first")
        // Closing a running session cancels its query and invalidates its callbacks.
        second.model.setSQL("SELECT pg_sleep(5)")
        second.model.runQuery()
        try await waitUntil { second.model.loadsInFlight > 0 }
        workspace.close(secondID)
        XCTAssertNil(second.model.connection)
        XCTAssertTrue(first.model.canRun)
        first.model.setSQL("SELECT value FROM tab_state")
        first.model.runQuery()
        try await waitUntil { !first.model.isRunning }
        XCTAssertNil(first.model.errorMessage)
        XCTAssertEqual(first.model.queryPane.result?.cell(0, 0, maxLength: nil), "first")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNil(second.model.queryPane.result)
        XCTAssertEqual(second.model.loadsInFlight, 0)
    }
}
