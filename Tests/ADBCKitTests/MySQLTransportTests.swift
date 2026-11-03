@testable import ADBCKit
import Foundation
import XCTest

final class MySQLTransportTests: XCTestCase {
    func testFoundrySSLMappingPreservesVerificationAndOtherFields() throws {
        for (mode, expected) in [("DISABLED","false"),("PREFERRED","preferred"),("REQUIRED","skip-verify"),("VERIFY_CA","true"),("VERIFY_IDENTITY","true")] {
            let input = "mysql://test@localhost/db?charset=utf8mb4&ssl-mode=" + mode
            let uri = try XCTUnwrap(URLComponents(string: MySQLTransport.foundryURI(input)))
            XCTAssertEqual(uri.queryItems?.last?.value, expected)
            XCTAssertTrue(uri.queryItems?.contains(.init(name: "charset", value: "utf8mb4")) == true)
            XCTAssertFalse(uri.queryItems?.contains { $0.name == "ssl-mode" } ?? true)
        }
        XCTAssertTrue(try MySQLTransport.foundryURI("mysql://test@localhost/db?ssl-mode=REQUIRED&tls=custom").contains("tls=custom"))
        XCTAssertThrowsError(try MySQLTransport.foundryURI("mysql://test@localhost/db?ssl-mode=unknown"))
    }
}
