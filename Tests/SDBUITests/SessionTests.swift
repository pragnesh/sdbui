import Foundation
import XCTest
@testable import ADBCKit
@testable import SDBUI

final class SessionStoreTests: XCTestCase {
    func testRoundTripPrivatePermissionsAndCorruptStatePreserved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("session.json")
        let store = SessionStore(url: url)
        XCTAssertNil(store.load())
        let state = WorkspaceSession(tabs: [SessionTabState(favoriteID: "Test/Database", sql: "SELECT '🙂'", dirty: true,
            database: "app", table: SessionTableState(catalog: "test", schema: "app", name: "items"), sidebarWidth: 420)], width: 1450, height: 900)
        try store.save(state)
        XCTAssertEqual(store.load(), state)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        let original = Data("bad session".utf8)
        try original.write(to: url)
        let broken = SessionStore(url: url)
        XCTAssertNil(broken.load())
        XCTAssertNotNil(broken.loadError)
        try broken.save(state)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testFutureVersionAndInvalidGeometryArePreserved() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        var future = WorkspaceSession(tabs: [SessionTabState()])
        future.version = 99
        for state in [future, WorkspaceSession(tabs: [SessionTabState()], width: -1)] {
            let data = try JSONEncoder().encode(state)
            try data.write(to: url)
            let store = SessionStore(url: url)
            XCTAssertNil(store.load())
            try store.save(WorkspaceSession(tabs: [SessionTabState()]))
            XCTAssertEqual(try Data(contentsOf: url), data)
        }
    }
}

@MainActor
final class SessionRestorationTests: XCTestCase {
    private func workspace(store: SessionStore? = nil) -> ConnectionWorkspace {
        ConnectionWorkspace(sessionStore: store) { BrowserModel(queryLibrary: QueryLibraryStore(url: nil)) }
    }
    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !predicate() {
            guard Date() < deadline else { throw ADBCError("Timed out restoring session") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
    func testWorkspaceRestoresTabsAndKeepsIndependentSQLAndLayout() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(url: root.appendingPathComponent("session.json"))
        let original = workspace(store: store)
        original.launch()
        original.selectedTab.model.setSQL("SELECT 'first'")
        original.selectedTab.model.updateSidebarWidth(410)
        original.updateWindowSize(width: 1400, height: 950)
        original.addTab()
        original.selectedTab.model.setSQL("SELECT 'second'")
        original.selectedTab.model.adjustQueryFontSize(by: 3)
        original.saveSession()
        let reopened = workspace(store: SessionStore(url: store.url))
        XCTAssertEqual(reopened.windowWidth, 1400)
        XCTAssertEqual(reopened.windowHeight, 950)
        reopened.launch()
        reopened.launch() // Idempotent; no duplicate restored tabs.
        XCTAssertEqual(reopened.tabs.count, 2)
        XCTAssertEqual(reopened.selectedID, reopened.tabs[1].id)
        XCTAssertEqual(reopened.tabs[0].model.sql, "SELECT 'first'")
        XCTAssertEqual(reopened.tabs[0].model.sidebarWidth, 410)
        XCTAssertEqual(reopened.tabs[1].model.sql, "SELECT 'second'")
        XCTAssertEqual(reopened.tabs[1].model.queryFontSize, 16)
        XCTAssertTrue(reopened.tabs[0].model.hasUnsavedSQL)
        XCTAssertNil(reopened.tabs[0].model.connection)
        reopened.close(reopened.selectedID)
        XCTAssertNotNil(reopened.pendingCloseID)
        reopened.cancelClose()
        XCTAssertEqual(reopened.tabs.count, 2)
        reopened.close(reopened.selectedID)
        reopened.confirmClose()
        XCTAssertEqual(reopened.tabs.count, 1)
        XCTAssertEqual(SessionStore(url: store.url).load()?.tabs.count, 1)
    }

    func testMissingFavoritePreservesSQLAndCloseRequiresConfirmation() {
        let model = BrowserModel(queryLibrary: QueryLibraryStore(url: nil))
        model.restoreSession(SessionTabState(favoriteID: "missing-favorite", sql: "SELECT 'keep'", dirty: true))
        XCTAssertNil(model.connection)
        XCTAssertEqual(model.sql, "SELECT 'keep'")
        XCTAssertTrue(model.connectionFeedback.contains("not found"))
        XCTAssertEqual(model.sessionState.favoriteID, "missing-favorite")
        let workspace = workspace()
        workspace.selectedTab.model.setSQL("SELECT 1")
        let id = workspace.selectedID
        workspace.performShortcut(2)
        XCTAssertEqual(workspace.pendingCloseID, id)
        workspace.performShortcut(7)
        XCTAssertNil(workspace.pendingCloseID)
        XCTAssertEqual(workspace.selectedID, id)
        XCTAssertNotNil(workspace.selectedTab.model.saveQuerySnippet(id: nil, name: "Saved"))
        XCTAssertFalse(workspace.selectedTab.model.hasUnsavedSQL)
        workspace.close(id)
        XCTAssertNotEqual(workspace.selectedID, id)
    }

    func testSavedFavoriteRestoresSelectionsWithoutExecutingSQLAndConfirmsRunningClose() async throws {
        guard let uri = ProcessInfo.processInfo.environment["SDBUI_TEST_POSTGRES_URI"] else { throw XCTSkip("Set SDBUI_TEST_POSTGRES_URI") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var draft = ConnectionDraft()
        draft.name = "RestoreTest"; draft.useURI = true; draft.uri = uri
        let url = try draft.save(in: root)
        let profile = try Discovery.loadProfile(at: url)
        let connection = try ADBCConnection.open(.profile(url.path))
        _ = try connection.execute("CREATE SCHEMA restored_app", maxRows: 0)
        _ = try connection.execute("CREATE TABLE restored_app.restore_item (n int)", maxRows: 0)
        defer {
            _ = try? connection.execute("DROP TABLE restored_app.restore_item", maxRows: 0)
            _ = try? connection.execute("DROP SCHEMA restored_app", maxRows: 0)
        }
        let workspace = workspace()
        let model = workspace.selectedTab.model
        defer { model.disconnect() }
        model.profiles = [profile]
        let table = SessionTableState(catalog: "postgres", schema: "restored_app", name: "restore_item")
        model.restoreSession(SessionTabState(favoriteID: profile.id, sql: "DELETE FROM restored_app.restore_item", dirty: true,
            database: "restored_app", table: table, pane: BrowserTab.structure.rawValue))
        try await waitUntil { model.connection != nil && model.selectedTable?.name == "restore_item" }
        XCTAssertEqual(model.sql, "DELETE FROM restored_app.restore_item")
        XCTAssertEqual(model.selectedDatabase, "restored_app")
        XCTAssertEqual(model.selectedTab, .structure)
        XCTAssertNil(model.queryStatus) // Restored editor SQL is never run, even destructive SQL.
        XCTAssertNil(model.pendingQuery)
        XCTAssertTrue(model.hasUnsavedSQL)
        XCTAssertEqual(model.sessionState.favoriteID, profile.id)
        model.selectTab(.query)
        model.setSQL("SELECT 42")
        model.runQuery()
        try await waitUntil { !model.isRunning }
        XCTAssertFalse(model.hasUnsavedSQL)
        model.setSQL("SELECT pg_sleep(10)")
        model.runQuery()
        try await Task.sleep(nanoseconds: 100_000_000)
        workspace.close(workspace.selectedID)
        XCTAssertNotNil(workspace.pendingCloseID)
        XCTAssertTrue(model.isRunning)
        workspace.cancelClose()
        XCTAssertTrue(model.isRunning)
        workspace.close(workspace.selectedID)
        workspace.confirmClose()
        XCTAssertFalse(workspace.selectedTab.model === model)
        XCTAssertNil(model.connection)
        XCTAssertFalse(model.isRunning)
        // disconnect saves the restored connection's draft, too.
        XCTAssertEqual(model.queryLibrary.draft(for: profile.id), "SELECT pg_sleep(10)")
    }
}
