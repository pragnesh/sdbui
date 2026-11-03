@testable import SDBUI
import ADBCKit
import Foundation
import XCTest

final class PreferencesStoreTests: XCTestCase {
    func testRoundTripPermissionsAndCorruptFilePreserved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("preferences.json")
        let store = PreferencesStore(url: url)
        XCTAssertEqual(store.load(), AppPreferences())
        var value = AppPreferences(); value.pageSize = 50; value.fontSize = 19; value.rowLimit = 100000; value.appearance = .dark
        try store.save(value)
        XCTAssertEqual(PreferencesStore(url: url).load(), value)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        value.appearance = .light; try store.save(value)
        XCTAssertEqual(PreferencesStore(url: url).load(), value)
        let broken = Data("{invalid".utf8); try broken.write(to: url)
        let invalid = PreferencesStore(url: url)
        XCTAssertEqual(invalid.load(), AppPreferences()); XCTAssertNotNil(invalid.loadError)
        XCTAssertThrowsError(try invalid.save(value)); XCTAssertEqual(try Data(contentsOf: url), broken)
    }
    func testInvalidValuesCannotBePersisted() throws {
        var value = AppPreferences(); value.pageSize = 0
        XCTAssertFalse(value.isValid)
        XCTAssertThrowsError(try PreferencesStore(url: nil).save(value))
    }
}

@MainActor
final class PreferencesWorkspaceTests: XCTestCase {
    func testDefaultsApplyAcrossTabsAndPersistWithoutExecutingSQL() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PreferencesStore(url: root.appendingPathComponent("preferences.json"))
        let workspace = ConnectionWorkspace(preferencesStore: store)
        workspace.selectedTab.model.sql = "SELECT 'untouched'"
        workspace.addTab()
        workspace.preferencesDraft.pageSize = 50; workspace.preferencesDraft.fontSize = 20
        workspace.preferencesDraft.rowLimit = 1000000; workspace.preferencesDraft.appearance = .dark
        workspace.applyPreferences()
        XCTAssertEqual(workspace.preferences.appearance, .dark)
        for tab in workspace.tabs {
            XCTAssertEqual(tab.model.pageSize, 50); XCTAssertEqual(tab.model.queryFontSize, 20)
            XCTAssertEqual(tab.model.maxRows, 1000000); XCTAssertFalse(tab.model.isRunning)
        }
        XCTAssertEqual(workspace.tabs[0].model.sql, "SELECT 'untouched'")
        workspace.addTab(); XCTAssertEqual(workspace.selectedTab.model.pageSize, 50)
        let restored = ConnectionWorkspace(preferencesStore: PreferencesStore(url: store.url))
        XCTAssertEqual(restored.selectedTab.model.queryFontSize, 20)
        XCTAssertEqual(restored.preferences.appearance, .dark)
        XCTAssertTrue(workspace.performShortcut(13)); XCTAssertTrue(workspace.preferencesVisible)
        XCTAssertTrue(workspace.performShortcut(7)); XCTAssertFalse(workspace.preferencesVisible)
        workspace.preferencesDraft.fontSize = 24
        workspace.selectedTab.model.isConnecting = true
        XCTAssertFalse(workspace.canApplyPreferences)
        workspace.applyPreferences(); XCTAssertEqual(workspace.preferences.fontSize, 20)
        workspace.selectedTab.model.isConnecting = false
    }
}

@MainActor
final class PreferencesPagingIntegrationTests: XCTestCase {
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(15)
        while !condition() {
            guard Date() < deadline else { throw NSError(domain: "SDBUI.Tests", code: 1) }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
    func testLargestPageAndInactiveDocumentsReloadAfterPreferenceChange() async throws {
        guard ProcessInfo.processInfo.environment["SDBUI_TEST_EMBEDDED"] == "1" else { throw XCTSkip("Enable embedded fixtures") }
        let connection = try ADBCKit.ADBCConnection.open(.direct(driver: "sqlite", uri: ":memory:"))
        _ = try connection.execute("CREATE TABLE sample(id INTEGER PRIMARY KEY)", maxRows: 0)
        _ = try connection.execute("INSERT INTO sample WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<10002) SELECT x FROM n", maxRows: 0)
        var preferences = AppPreferences(); preferences.pageSize = 10000; preferences.rowLimit = 100
        let model = BrowserModel(openConnection: { _ in connection }, queryLibrary: QueryLibraryStore(url: nil), preferences: preferences)
        model.connectionDraft.driver = "sqlite"; model.connectionDraft.useURI = true; model.connectionDraft.uri = ":memory:"
        model.connectFavorite()
        defer { model.disconnect() }
        try await waitUntil { model.canUseConnection && model.tables.contains { $0.name == "sample" } }
        model.selectTable(model.tables.first { $0.name == "sample" }!.id)
        model.browseSelectedTable(); try await waitUntil { !model.isRunning }
        XCTAssertEqual(model.queryPane.result?.rowCount, 10000)
        XCTAssertTrue(model.contentHasMore)
        model.showContentPage(next: true); try await waitUntil { !model.isRunning }
        XCTAssertEqual(model.queryPane.result?.rowCount, 2)
        let first = model.activeQueryDocument.id
        model.addQueryDocument()
        model.browseSelectedTable(); try await waitUntil { !model.isRunning }
        preferences.pageSize = 50
        model.applyPreferences(preferences); try await waitUntil { !model.isRunning }
        XCTAssertEqual(model.queryPane.result?.rowCount, 50)
        model.selectQueryDocument(first); try await waitUntil { !model.isRunning }
        XCTAssertEqual(model.contentOffset, 0)
        XCTAssertEqual(model.queryPane.result?.rowCount, 50)
        XCTAssertEqual(model.maxRows, 100)
    }
}
