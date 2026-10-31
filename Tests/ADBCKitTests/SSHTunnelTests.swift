import Foundation
import XCTest
@testable import ADBCKit

final class SSHTunnelTests: XCTestCase {
    func testSavedSSHSettingsStayOutOfDriverOptions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var draft = ConnectionDraft()
        draft.name = "Work/Tunneled"
        draft.ssh.enabled = true
        draft.ssh.host = "bastion"
        draft.ssh.user = "ssh-user"
        draft.ssh.port = "2222"
        draft.ssh.identityFile = "~/.ssh/my key"
        let url = try draft.save(in: root)
        let profile = try Discovery.loadProfile(at: url)
        XCTAssertEqual(profile.ssh, draft.ssh)
        XCTAssertEqual(profile.options.map(\.key), ["uri"])
        let restored = ConnectionDraft(profile: profile)
        guard case .ssh(let driver, let options, let ssh) = try restored.source() else { return XCTFail() }
        XCTAssertEqual(driver, "postgresql")
        XCTAssertEqual(ssh, draft.ssh)
        XCTAssertEqual(options.map(\.key), ["uri"])
    }

    func testOldProfilesAndDisabledSSH() throws {
        let profile = ConnectionProfile(id: "old", driver: "postgresql",
            options: [.init(key: "uri", value: "postgresql://host/db")], url: URL(fileURLWithPath: "/tmp/old.toml"))
        let draft = ConnectionDraft(profile: profile)
        XCTAssertFalse(draft.ssh.enabled)
        guard case .direct = try draft.source() else { return XCTFail() }
    }

    func testForwardingPreservesPostgresTLSHostAndCredentials() throws {
        let destination = try TunnelDestination(uri: "postgresql://user:p%40ss@db.internal:5433/app?sslmode=verify-full&connect_timeout=2", driver: "postgresql")
        XCTAssertEqual(destination.host, "db.internal")
        XCTAssertEqual(destination.port, 5433)
        let uri = try XCTUnwrap(URLComponents(string: destination.forwardedURI(localPort: 12345)))
        XCTAssertEqual(uri.host, "db.internal")
        XCTAssertEqual(uri.port, 12345)
        XCTAssertEqual(uri.password, "p@ss")
        XCTAssertTrue(uri.queryItems!.contains(.init(name: "hostaddr", value: "127.0.0.1")))
        XCTAssertTrue(uri.queryItems!.contains(.init(name: "sslmode", value: "verify-full")))
        let mysql = try TunnelDestination(uri: "mysql://root@db.internal/demo", driver: "mysql")
        XCTAssertEqual(mysql.port, 3306)
        XCTAssertEqual(URLComponents(string: mysql.forwardedURI(localPort: 12345))?.host, "127.0.0.1")
    }

    func testArgumentsDoNotUseShellOrSharedSSHConnections() throws {
        var settings = SSHSettings()
        settings.host = "bastion"
        settings.user = "user; echo hello"
        let target = try TunnelDestination(uri: "postgresql://[::1]/db", driver: "postgresql")
        let args = try settings.arguments(localPort: 12345, destination: target)
        XCTAssertTrue(args.contains("127.0.0.1:12345:[::1]:5432"))
        XCTAssertTrue(args.contains("BatchMode=yes"))
        XCTAssertTrue(args.contains("ExitOnForwardFailure=yes"))
        XCTAssertTrue(args.contains("StrictHostKeyChecking=yes"))
        XCTAssertTrue(args.contains("ControlPath=none"))
        XCTAssertTrue(args.contains("user; echo hello"))
        XCTAssertEqual(Array(args.suffix(2)), ["--", "bastion"])
        settings.host = "-bad"
        XCTAssertThrowsError(try settings.validate())
        settings.host = "host"
        settings.port = "0"
        XCTAssertThrowsError(try settings.validate())
    }

    func testRejectsAmbiguousOrUnsupportedDestinations() {
        for uri in ["host=localhost dbname=postgres", "postgresql:///db", "postgresql://host/db?hostaddr=1.2.3.4", "postgresql://host/db?port=123"] {
            XCTAssertThrowsError(try TunnelDestination(uri: uri, driver: "postgresql"))
        }
        XCTAssertThrowsError(try TunnelDestination(uri: "/tmp/example.db", driver: "sqlite"))
    }

    func testRealSSHForwardWhenConfigured() throws {
        let env = ProcessInfo.processInfo.environment
        guard let executable = env["SDBUI_TEST_SSH_EXECUTABLE"],
              let uri = env["SDBUI_TEST_POSTGRES_URI"],
              let sshPort = env["SDBUI_TEST_SSH_PORT"] else {
            throw XCTSkip("Set SSH integration variables to exercise a local SSH server.")
        }
        var settings = SSHSettings()
        settings.host = "127.0.0.1"
        settings.port = sshPort
        settings.user = "test"
        let destination = try TunnelDestination(uri: uri, driver: "postgresql")
        let tunnel = try SSHTunnel.start(settings: settings, destination: destination,
            executableURL: URL(fileURLWithPath: executable))
        defer { tunnel.stop() }
        XCTAssertTrue(tunnel.isRunning)
        let connection = try ADBCConnection.open(.direct(driver: "postgresql", uri: destination.forwardedURI(localPort: tunnel.localPort)))
        XCTAssertEqual(try connection.execute("SELECT 42", maxRows: 1).cell(0, 0, maxLength: nil), "42")
        tunnel.stop()
        tunnel.stop()
        XCTAssertFalse(tunnel.isRunning)

        // Exercise the same source and ownership path used by Test/Connect.
        let source = ConnectionSource.ssh(driver: "postgresql", options: [.init(key: "uri", value: uri)], settings: settings)
        var owned: ADBCConnection? = try ADBCConnection.open(source, sshExecutableURL: URL(fileURLWithPath: executable))
        XCTAssertEqual(try owned!.execute("SELECT 1", maxRows: 1).rowCount, 1)
        owned!.stopTunnel()
        XCTAssertThrowsError(try owned!.execute("SELECT 1", maxRows: 1))
        owned = nil
        // Releasing a tested connection without explicitly disconnecting also stops SSH.
        owned = try ADBCConnection.open(source, sshExecutableURL: URL(fileURLWithPath: executable))
        weak var released = owned
        owned = nil
        XCTAssertNil(released)
        let invalid = ConnectionSource.ssh(driver: "postgresql", options: [
            .init(key: "uri", value: uri), .init(key: "sdbui.invalid.option", value: "bad")
        ], settings: settings)
        XCTAssertThrowsError(try ADBCConnection.open(invalid, sshExecutableURL: URL(fileURLWithPath: executable)))
    }

    func testSSHStartupFailureReturnsAnError() throws {
        var settings = SSHSettings()
        settings.host = "unused"
        let destination = try TunnelDestination(uri: "postgresql://host/db", driver: "postgresql")
        XCTAssertThrowsError(try SSHTunnel.start(settings: settings, destination: destination,
            executableURL: URL(fileURLWithPath: "/usr/bin/false"))) { error in
            XCTAssertTrue(String(describing: error).contains("SSH tunnel failed"))
        }
    }
}
