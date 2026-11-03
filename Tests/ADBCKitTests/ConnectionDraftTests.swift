import Foundation
import XCTest
@testable import ADBCKit

final class ConnectionDraftTests: XCTestCase {
    func testPostgreSQLFormConnectionWhenConfigured() throws {
        guard let uri = ProcessInfo.processInfo.environment["SDBUI_TEST_POSTGRES_URI"] else {
            throw XCTSkip("Set SDBUI_TEST_POSTGRES_URI to exercise a real PostgreSQL connection.")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = ConnectionProfile(id: "Integration/PostgreSQL", driver: "postgresql",
            options: [.init(key: "uri", value: uri)], url: root.appendingPathComponent("Integration/PostgreSQL.toml"))
        let draft = ConnectionDraft(profile: profile)
        XCTAssertFalse(draft.useURI)
        let connection = try ADBCConnection.open(draft.source())
        let result = try connection.execute("SELECT 42 AS answer", maxRows: 1)
        XCTAssertEqual(result.cell(0, 0, maxLength: nil), "42")
        let saved = try draft.save(in: root)
        let reloaded = ConnectionDraft(profile: try Discovery.loadProfile(at: saved))
        let savedConnection = try ADBCConnection.open(reloaded.source())
        XCTAssertEqual(try savedConnection.execute("SELECT 1", maxRows: 1).rowCount, 1)
    }

    func testNetworkURIRoundTripAndSSL() throws {
        var draft = ConnectionDraft()
        draft.name = "Work/Local"
        draft.host = "localhost"
        draft.port = "5433"
        draft.user = "user@company"
        draft.password = "p@ss:/?#% \\\""
        draft.database = "db/with?#% spaces"
        draft.sslMode = "verify-full"
        let uri = try draft.connectionURI()
        let parsed = try XCTUnwrap(URLComponents(string: uri))
        XCTAssertEqual(parsed.user, draft.user)
        XCTAssertEqual(parsed.password, draft.password)
        XCTAssertEqual(parsed.path, "/" + draft.database)
        XCTAssertEqual(parsed.port, 5433)
        XCTAssertEqual(parsed.queryItems, [.init(name: "sslmode", value: "verify-full")])
        let profile = ConnectionProfile(id: draft.name, driver: draft.driver,
            options: [.init(key: "uri", value: uri)], url: URL(fileURLWithPath: "/tmp/local.toml"))
        let loaded = ConnectionDraft(profile: profile)
        XCTAssertFalse(loaded.useURI)
        XCTAssertEqual(loaded.password, draft.password)
        XCTAssertEqual(loaded.database, draft.database)
        XCTAssertEqual(try loaded.connectionURI(), uri)
    }

    func testMySQLModesAndDriverSwitch() throws {
        var draft = ConnectionDraft()
        draft.selectDriver("mysql")
        draft.sslMode = "VERIFY_IDENTITY"
        let parsed = try XCTUnwrap(URLComponents(string: draft.connectionURI()))
        XCTAssertEqual(parsed.scheme, "mysql")
        XCTAssertEqual(parsed.queryItems, [.init(name: "ssl-mode", value: "VERIFY_IDENTITY")])
        XCTAssertEqual(draft.defaultPort, "3306")
        draft.selectDriver("duckdb")
        XCTAssertTrue(draft.useURI)
        XCTAssertEqual(draft.sslMode, "Default")
        draft.uri = "/tmp/example.duckdb"
        XCTAssertEqual(try draft.connectionURI(), draft.uri)
    }

    func testValidation() {
        var draft = ConnectionDraft()
        for port in ["0", "65536", "abc", "-1"] {
            draft.port = port
            XCTAssertThrowsError(try draft.connectionURI())
        }
        draft.port = ""
        draft.host = " "
        XCTAssertThrowsError(try draft.connectionURI())
        draft.host = "localhost"
        draft.password = "secret"
        XCTAssertThrowsError(try draft.connectionURI())
        draft.password = ""
        draft.sslMode = "invalid"
        XCTAssertThrowsError(try draft.connectionURI())
    }

    func testSaveLoadPermissionsCollisionAndRename() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var draft = ConnectionDraft()
        draft.name = "Work/Local"
        draft.user = "name"
        draft.password = "quote\"slash\\newline\n\u{01}"
        let url = try draft.save(in: root)
        XCTAssertEqual(
            url.resolvingSymlinksInPath().standardizedFileURL.path,
            root.appendingPathComponent("Work/Local.toml")
                .resolvingSymlinksInPath().standardizedFileURL.path)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let profile = try XCTUnwrap(Discovery.profiles(in: [root]).first)
        var loaded = ConnectionDraft(profile: profile)
        XCTAssertEqual(loaded.password, draft.password)
        XCTAssertThrowsError(try draft.save(in: root))
        loaded.database = "changed"
        let updatedURL = try loaded.save(in: root)
        XCTAssertEqual(
            updatedURL.resolvingSymlinksInPath().standardizedFileURL.path,
            url.resolvingSymlinksInPath().standardizedFileURL.path)
        loaded.name = "Work/Copy"
        let copy = try loaded.save(in: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNotEqual(url, copy)
        for name in ["", "../escape", "/absolute", "a//b", ".hidden", "a/..", "a\\b", "bad\nname"] {
            draft.name = name
            XCTAssertThrowsError(try draft.save(in: root), name)
        }
    }

    func testPreservesOptionsAndURIParameters() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = ConnectionProfile(id: "existing", driver: "postgresql", options: [
            .init(key: "uri", value: "postgresql://user@host/db?connect_timeout=5&sslmode=require&application_name=sdbui"),
            .init(key: "adbc.postgresql.use_copy", value: "false"),
        ], url: root.appendingPathComponent("existing.toml"))
        var draft = ConnectionDraft(profile: profile)
        XCTAssertFalse(draft.useURI)
        draft.host = "newhost"
        draft.sslMode = "disable"
        let url = try draft.save(in: root)
        let loaded = try Discovery.loadProfile(at: url)
        XCTAssertEqual(loaded.options.last?.key, "adbc.postgresql.use_copy")
        XCTAssertEqual(loaded.options.last?.value, "false")
        let uri = try XCTUnwrap(loaded.options.first?.value)
        let parsed = try XCTUnwrap(URLComponents(string: uri))
        XCTAssertEqual(parsed.host, "newhost")
        XCTAssertTrue(parsed.queryItems?.contains(.init(name: "connect_timeout", value: "5")) == true)
        XCTAssertTrue(parsed.queryItems?.contains(.init(name: "sslmode", value: "disable")) == true)
    }

    func testTemplatesAndNonstandardProfilesStayInURIMode() throws {
        let template = "postgresql://user:{{ env_var(SDBUI_DRAFT_PASSWORD) }}@host/db"
        var draft = ConnectionDraft(profile: .init(id: "template", driver: "postgresql",
            options: [.init(key: "uri", value: template)], url: URL(fileURLWithPath: "/tmp/template.toml")))
        XCTAssertTrue(draft.useURI)
        XCTAssertEqual(try draft.connectionURI(), template)
        setenv("SDBUI_DRAFT_PASSWORD", "password", 1)
        defer { unsetenv("SDBUI_DRAFT_PASSWORD") }
        guard case .direct(let driver, _, let options) = try draft.source() else { return XCTFail() }
        XCTAssertEqual(driver, "postgresql")
        XCTAssertEqual(options.first?.value, "postgresql://user:password@host/db")
        draft = ConnectionDraft(profile: .init(id: "socket", driver: "postgresql",
            options: [.init(key: "uri", value: "host=/tmp dbname=postgres")], url: URL(fileURLWithPath: "/tmp/socket.toml")))
        XCTAssertTrue(draft.useURI)
        XCTAssertEqual(try draft.connectionURI(), "host=/tmp dbname=postgres")
    }
}
