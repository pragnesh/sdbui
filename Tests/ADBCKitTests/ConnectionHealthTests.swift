import XCTest
@testable import ADBCKit

final class ConnectionHealthTests: XCTestCase {
    func testTransportErrorsAreRecognized() {
        for message in [
            "Query failed: [IO] [SQLSTATE 08006] connection failure",
            "Query failed: [IO] [SQLSTATE 57P01] server shutdown",
            "Reading results failed (22): [libpq] server closed the connection unexpectedly",
            "Query failed: [IO] [mysql] server has gone away",
            "SSH tunnel closed. Connection reset by peer",
        ] { XCTAssertTrue(ADBCError(message).isConnectionLoss, message) }
    }

    func testSQLAndTransactionErrorsAreNotConnectionLoss() {
        for message in [
            "Query failed: [INVALID_ARGUMENT] [SQLSTATE 42601] syntax error",
            "Query failed: [IO] [SQLSTATE 25P02] current transaction is aborted",
            "Query failed: [IO] [SQLSTATE 42501] permission denied",
            "Query failed: [INVALID_ARGUMENT] [SQLSTATE 42601] syntax error at 'server has gone away'",
            "Query failed: [IO] could not read database file",
            "Query failed: [INVALID_ARGUMENT] [libpq] syntax error at 'server has gone away'",
            "Query cancelled", "Statement timed out", "division by zero",
        ] { XCTAssertFalse(ADBCError(message).isConnectionLoss, message) }
    }
}
