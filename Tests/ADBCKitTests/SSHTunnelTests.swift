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

    func testErrorDetailSplitsOpenSSHLineEndings() {
        let log = "OpenSSH_9.6p1 Ubuntu, OpenSSL 3.0.13\r\ndebug1: Reading configuration data\r\n"
            + "No ED25519 host key is known for db.example and you have requested strict checking.\r\n"
            + "Host key verification failed.\r\n"
        let detail = SSHTunnel.errorDetail(log)
        XCTAssertTrue(detail.hasPrefix("No ED25519 host key is known for db.example"))
        XCTAssertTrue(detail.contains("Host key verification failed."))
        XCTAssertTrue(detail.contains("Verify and trust the host key when asked"))
        XCTAssertFalse(detail.contains("debug1"))
        XCTAssertFalse(detail.contains("OpenSSH_"))
        XCTAssertEqual(SSHTunnel.errorDetail("debug1: x\r\nPermission denied (publickey).\r\n"),
                       "Permission denied (publickey).")
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

    /// Against the local sshd (skipped when none listens on port 22), with
    /// wrapper tools that use an empty, temporary known_hosts.
    func testUnknownHostKeyCanBeScannedAndTrusted() throws {
        let probe = try SSHHostKeys.run("/bin/sh", ["-c", "(ss -ltn 2>/dev/null || true) | grep -c '127.0.0.1:22 \\|0.0.0.0:22 ' || true"])
        guard (Int(probe.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) > 0 else {
            throw XCTSkip("No local sshd on port 22.")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sdbui-hostkey-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let knownHosts = root.appendingPathComponent("known_hosts")
        let config = root.appendingPathComponent("ssh_config")
        try "Host *\n  UserKnownHostsFile \"\(knownHosts.path)\"\n  GlobalKnownHostsFile /dev/null\n  HashKnownHosts no\n"
            .write(to: config, atomically: true, encoding: .utf8)
        let tools = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        try "#!/bin/sh\nexec /usr/bin/ssh -F '\(config.path)' \"$@\"\n"
            .write(to: tools.appendingPathComponent("ssh"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tools.appendingPathComponent("ssh").path)
        for tool in ["ssh-keyscan", "ssh-keygen"] {
            try FileManager.default.createSymbolicLink(atPath: tools.appendingPathComponent(tool).path, withDestinationPath: "/usr/bin/\(tool)")
        }

        var settings = SSHSettings()
        settings.host = "127.0.0.1"
        settings.user = "sdbui-nonexistent-user"
        let destination = try TunnelDestination(uri: "postgresql://127.0.0.1:5432/db", driver: "postgresql")
        XCTAssertThrowsError(try SSHTunnel.start(settings: settings, destination: destination,
                                                 executableURL: tools.appendingPathComponent("ssh"))) { error in
            let unknown = error as? SSHUnknownHostKeyError
            XCTAssertEqual(unknown?.host, "127.0.0.1")
            XCTAssertTrue(String(describing: error).contains("Host key verification failed"))
        }

        let scan = try SSHHostKeys.scan(host: "127.0.0.1", port: "22", toolsDirectory: tools)
        XCTAssertEqual(scan.knownHostsFile, knownHosts.path)
        XCTAssertEqual(scan.port, 22)
        XCTAssertFalse(scan.fingerprints.isEmpty)
        XCTAssertTrue(scan.fingerprints.allSatisfy { $0.contains(" SHA256:") })
        try SSHHostKeys.trust(scan)
        try SSHHostKeys.trust(scan)  // Appending again keeps the file well-formed.
        let saved = try String(contentsOf: knownHosts, encoding: .utf8)
        XCTAssertTrue(saved.hasPrefix("127.0.0.1 "))
        XCTAssertFalse(saved.contains("\n\n"))

        // Now the host key is accepted; only authentication can fail.
        XCTAssertThrowsError(try SSHTunnel.start(settings: settings, destination: destination,
                                                 executableURL: tools.appendingPathComponent("ssh"))) { error in
            XCTAssertNil(error as? SSHUnknownHostKeyError)
            XCTAssertFalse(String(describing: error).contains("Host key verification failed"))
        }
    }

    func testStoppingOneChildWhileAnotherRunsDoesNotHang() throws {
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("sdbui-child-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: log) }
        let first = try ChildProcess(executable: "/bin/sleep", arguments: ["30"], stderrPath: log.path)
        let second = try ChildProcess(executable: "/bin/sleep", arguments: ["30"], stderrPath: log.path)
        let start = Date()
        second.terminate(gracePeriod: 1)
        XCTAssertFalse(second.isRunning)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
        XCTAssertTrue(first.isRunning)
        first.terminate(gracePeriod: 1)
        XCTAssertFalse(first.isRunning)

        // A child that ignores SIGTERM is killed after the grace period.
        let stubborn = try ChildProcess(executable: "/bin/sh", arguments: ["-c", "trap '' TERM; sleep 30"], stderrPath: log.path)
        Thread.sleep(forTimeInterval: 0.2)
        stubborn.terminate(gracePeriod: 0.2)
        XCTAssertFalse(stubborn.isRunning)
    }
}
