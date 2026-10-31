@testable import ADBCKit
import Foundation
import XCTest
@testable import SDBUI

private final class ProfileOpens: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []
    var opened: [String] { lock.lock(); defer { lock.unlock() }; return paths }
    func open(_ source: ConnectionSource) throws -> ADBCConnection {
        if case .profile(let path) = source {
            lock.lock(); paths.append(path); lock.unlock()
        }
        throw ADBCError("Test connection unavailable")
    }
}

@MainActor
final class ProfileActivationTests: XCTestCase {
    func testSingleSelectionOnlyEditsAndActivationOpensSavedProfileOnce() async throws {
        let opens = ProfileOpens()
        let model = BrowserModel(openConnection: { try opens.open($0) }, queryLibrary: QueryLibraryStore(url: nil))
        let profile = ConnectionProfile(id: "Work/Example", driver: "postgresql",
            options: [.init(key: "uri", value: "postgresql://localhost/example")],
            url: URL(fileURLWithPath: "/tmp/sdbui-activation-example.toml"))
        model.profiles = [profile]
        model.selectFavorite(profile.id)
        XCTAssertEqual(model.selectedProfileID, profile.id)
        XCTAssertEqual(model.connectionDraft.database, "example")
        XCTAssertTrue(opens.opened.isEmpty)
        XCTAssertFalse(model.isConnecting)
        model.connectionDraft.host = "unsaved.invalid"
        model.activateFavorite(profile.id)
        XCTAssertTrue(model.isConnecting)
        model.activateFavorite(profile.id) // Duplicate activation while opening is ignored.
        let deadline = Date().addingTimeInterval(3)
        while model.isConnecting {
            guard Date() < deadline else { return XCTFail("Timed out opening activated profile") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(opens.opened, [profile.url.path])
        XCTAssertNil(model.connection)
        XCTAssertNotNil(model.errorMessage)
    }

    func testStaleActivationDoesNotOpenOrChangeSelection() {
        let opens = ProfileOpens()
        let model = BrowserModel(openConnection: { try opens.open($0) }, queryLibrary: QueryLibraryStore(url: nil))
        model.activateFavorite("removed/profile")
        XCTAssertNil(model.selectedProfileID)
        XCTAssertFalse(model.isConnecting)
        XCTAssertTrue(opens.opened.isEmpty)
    }
}
