import ADBCKit
import Foundation
import XCTest
@testable import SDBUI

private final class OpeningGate: @unchecked Sendable {
    private let lock = NSLock()
    private var fail = false
    private var started = false
    let release = DispatchSemaphore(value: 0)
    func setFailure(_ value: Bool) { lock.lock(); defer { lock.unlock() }; fail = value }
    var hasStarted: Bool { lock.lock(); defer { lock.unlock() }; return started }
    func shouldFail() -> Bool { lock.lock(); defer { lock.unlock() }; return fail }
    func markStarted() { lock.lock(); defer { lock.unlock() }; started = true }
}

@MainActor
final class ReconnectionTests: XCTestCase {
    private func makeModel(
        openConnection: @escaping @Sendable (ConnectionSource) throws -> ADBCConnection = { try ADBCConnection.open($0) },
        healthCheckIntervalNanoseconds: UInt64 = 5_000_000_000
    ) -> BrowserModel {
        BrowserModel(openConnection: openConnection, healthCheckIntervalNanoseconds: healthCheckIntervalNanoseconds,
                     queryLibrary: QueryLibraryStore(url: nil))
    }

    private func postgresURI() throws -> String {
        guard let uri = ProcessInfo.processInfo.environment["SDBUI_TEST_POSTGRES_URI"] else {
            throw XCTSkip("Set SDBUI_TEST_POSTGRES_URI for reconnect integration tests.")
        }
        return uri
    }

    private func waitUntil(_ predicate: () -> Bool, timeout: TimeInterval = 8) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() {
            guard Date() < deadline else { XCTFail("Timed out waiting for connection state"); throw ADBCError("Test timed out") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func connect(_ model: BrowserModel, uri: String) async throws {
        model.connectionDraft.useURI = true
        model.connectionDraft.uri = uri
        model.connectFavorite()
        try await waitUntil { model.connection != nil && !model.isConnecting }
        XCTAssertFalse(model.isConnectionLost)
    }

    private func terminate(_ model: BrowserModel, using admin: ADBCConnection) throws {
        let pid = try XCTUnwrap(model.connection?.execute("SELECT pg_backend_pid()", maxRows: 1).cell(0, 0, maxLength: nil))
        _ = try admin.execute("SELECT pg_terminate_backend(\(pid))", maxRows: 1)
    }

    func testIdleLossReconnectPreservesSQLWithoutReplayingWrites() async throws {
        let uri = try postgresURI()
        let admin = try ADBCConnection.open(.direct(driver: "postgresql", uri: uri))
        let table = "reconnect_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        _ = try admin.execute("CREATE TABLE \(table) (value INTEGER)", maxRows: 1)
        defer { _ = try? admin.execute("DROP TABLE \(table)", maxRows: 1) }
        let model = makeModel(healthCheckIntervalNanoseconds: 50_000_000)
        defer { model.disconnect() }
        try await connect(model, uri: uri)
        let sql = "INSERT INTO \(table) VALUES (1)"
        model.setSQL(sql)
        let editorRevision = model.sqlRevision
        model.runQuery()
        try await waitUntil { !model.isRunning }
        try terminate(model, using: admin)
        try await waitUntil { model.isConnectionLost }
        XCTAssertNotNil(model.connection) // Keep the editor and window alive.
        XCTAssertFalse(model.canRun)
        XCTAssertEqual(model.sql, sql)
        model.reconnect()
        try await waitUntil { !model.isConnecting && !model.isConnectionLost }
        XCTAssertTrue(model.canRun)
        XCTAssertEqual(model.sql, sql)
        XCTAssertEqual(model.sqlRevision, editorRevision)
        XCTAssertEqual(try admin.execute("SELECT count(*) FROM \(table)", maxRows: 1).cell(0, 0, maxLength: nil), "1")
    }

    func testQueryFailureDetectsLossAndSQLTransactionErrorsDoNot() async throws {
        let uri = try postgresURI()
        let admin = try ADBCConnection.open(.direct(driver: "postgresql", uri: uri))
        let model = makeModel(healthCheckIntervalNanoseconds: 50_000_000)
        defer { model.disconnect() }
        try await connect(model, uri: uri)
        model.setSQL("SELEC invalid syntax")
        model.runQuery()
        try await waitUntil { !model.isRunning }
        XCTAssertFalse(model.isConnectionLost)
        model.setSQL("BEGIN; SELECT 1/0")
        model.runQuery()
        try await waitUntil { !model.isRunning }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(model.isConnectionLost)
        model.setSQL("ROLLBACK")
        model.runQuery()
        try await waitUntil { !model.isRunning }
        try terminate(model, using: admin)
        model.setSQL("SELECT 1")
        model.runQuery()
        try await waitUntil { model.isConnectionLost }
        XCTAssertFalse(model.isRunning)
    }

    func testFailedReconnectCanBeRetried() async throws {
        let uri = try postgresURI()
        let admin = try ADBCConnection.open(.direct(driver: "postgresql", uri: uri))
        let gate = OpeningGate()
        let model = makeModel(openConnection: { source in
            if gate.shouldFail() { throw ADBCError("Test server unavailable") }
            return try ADBCConnection.open(source)
        }, healthCheckIntervalNanoseconds: 50_000_000)
        defer { model.disconnect() }
        try await connect(model, uri: uri)
        model.setSQL("SELECT 123")
        try terminate(model, using: admin)
        try await waitUntil { model.isConnectionLost }
        gate.setFailure(true)
        model.reconnect()
        try await waitUntil { !model.isConnecting }
        XCTAssertTrue(model.isConnectionLost)
        XCTAssertFalse(model.canRun)
        XCTAssertEqual(model.sql, "SELECT 123")
        gate.setFailure(false)
        model.reconnect()
        try await waitUntil { !model.isConnecting && !model.isConnectionLost }
        XCTAssertTrue(model.canRun)
    }

    func testDisconnectIgnoresAnInFlightOpen() async throws {
        let uri = try postgresURI()
        let gate = OpeningGate()
        let model = makeModel(openConnection: { source in
            gate.markStarted()
            gate.release.wait()
            return try ADBCConnection.open(source)
        })
        model.connectionDraft.useURI = true
        model.connectionDraft.uri = uri
        model.connectFavorite()
        try await waitUntil { gate.hasStarted }
        model.disconnect()
        gate.release.signal()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNil(model.connection)
        XCTAssertFalse(model.isConnecting)
        XCTAssertEqual(model.statusMessage, "Not connected")
        model.reconnect()
        XCTAssertNil(model.connection)
    }

    func testOldQueryDoesNotOverwriteANewConnection() async throws {
        let uri = try postgresURI()
        let model = makeModel()
        defer { model.disconnect() }
        try await connect(model, uri: uri)
        model.setSQL("SELECT pg_sleep(0.5)")
        model.runQuery()
        try await Task.sleep(nanoseconds: 100_000_000)
        model.disconnect()
        try await connect(model, uri: uri)
        model.setSQL("SELECT 456")
        model.runQuery()
        try await waitUntil { !model.isRunning }
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(model.queryPane.result?.cell(0, 0, maxLength: nil), "456")
        XCTAssertEqual(model.sql, "SELECT 456")
        XCTAssertEqual(model.loadsInFlight, 0)
    }

    func testReconnectRestartsSSH() async throws {
        let uri = try postgresURI()
        let env = ProcessInfo.processInfo.environment
        guard let executable = env["SDBUI_TEST_SSH_EXECUTABLE"], let port = env["SDBUI_TEST_SSH_PORT"] else {
            throw XCTSkip("Set SSH integration variables for the tunnel reconnect test.")
        }
        let model = makeModel(openConnection: { source in
            try ADBCConnection.open(source, sshExecutableURL: URL(fileURLWithPath: executable))
        }, healthCheckIntervalNanoseconds: 50_000_000)
        defer { model.disconnect() }
        model.connectionDraft.ssh.enabled = true
        model.connectionDraft.ssh.host = "127.0.0.1"
        model.connectionDraft.ssh.port = port
        model.connectionDraft.ssh.user = "test"
        try await connect(model, uri: uri)
        model.setSQL("SELECT 789")
        model.connection?.stopTunnel()
        try await waitUntil { model.isConnectionLost }
        model.reconnect()
        try await waitUntil { !model.isConnecting && !model.isConnectionLost }
        XCTAssertEqual(model.sql, "SELECT 789")
        model.runQuery()
        try await waitUntil { !model.isRunning }
        XCTAssertEqual(model.queryPane.result?.cell(0, 0, maxLength: nil), "789")
    }
}
