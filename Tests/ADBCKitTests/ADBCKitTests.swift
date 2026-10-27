import XCTest

@testable import ADBCKit

final class TOMLTests: XCTestCase {
    func testDriverManifest() throws {
        let toml = try TOMLDocument(parsing: """
            manifest_version = 1
            name = 'ASF PostgreSQL Driver'
            version = '1.12.0'

            [ADBC]
            version = '1.1.0'

            [Driver]
            [Driver.shared]
            linux_amd64 = '/drivers/libadbc_driver_postgresql.so'
            """)
        XCTAssertEqual(toml["name"], .string("ASF PostgreSQL Driver"))
        XCTAssertEqual(toml["manifest_version"], .integer(1))
        XCTAssertEqual(toml["Driver", "shared", "linux_amd64"], .string("/drivers/libadbc_driver_postgresql.so"))
        XCTAssertEqual(toml["ADBC", "version"], .string("1.1.0"))
    }

    func testProfileOptions() throws {
        let toml = try TOMLDocument(parsing: """
            # comment
            profile_version = 1
            driver = "mysql"   # trailing comment

            [Options]
            uri = "mysql://user:p#ss@localhost:3306/"
            "adbc.mysql.flag" = true
            adbc.other.size = 1_000
            """)
        XCTAssertEqual(toml["driver"], .string("mysql"))
        let options = toml.entries(in: "Options")
        XCTAssertEqual(options.map(\.key), ["uri", "adbc.mysql.flag", "adbc.other.size"])
        XCTAssertEqual(options[0].value, .string("mysql://user:p#ss@localhost:3306/"))
        XCTAssertEqual(options[1].value.stringValue, "true")
        XCTAssertEqual(options[2].value, .integer(1000))
    }

    func testEscapes() throws {
        let toml = try TOMLDocument(parsing: #"key = "a\"b\\cé""#)
        XCTAssertEqual(toml["key"], .string("a\"b\\cé"))
    }

    func testInvalid() {
        XCTAssertThrowsError(try TOMLDocument(parsing: "key = \"unterminated"))
        XCTAssertThrowsError(try TOMLDocument(parsing: "key = 1 2"))
    }
}

final class DiscoveryTests: XCTestCase {
    func testEnvironmentSubstitution() throws {
        setenv("SDBUI_TEST_PASSWORD", "s3cret", 1)
        XCTAssertEqual(
            try Discovery.substitutingEnvironment(
                in: "postgresql://me:{{ env_var(SDBUI_TEST_PASSWORD) }}@host/db"),
            "postgresql://me:s3cret@host/db")
        XCTAssertEqual(try Discovery.substitutingEnvironment(in: "plain"), "plain")
        XCTAssertThrowsError(try Discovery.substitutingEnvironment(in: "{{ nope() }}"))
    }

    func testDriverNameFromURI() {
        XCTAssertEqual(Discovery.driverName(forURI: "postgres://localhost/db"), "postgresql")
        XCTAssertEqual(Discovery.driverName(forURI: "mysql://root@localhost/"), "mysql")
        XCTAssertNil(Discovery.driverName(forURI: "no-scheme"))
    }

    func testMaskPassword() {
        XCTAssertEqual(
            ConnectionProfile.maskingPassword(in: "mysql://user:secret@host:3306/db"),
            "mysql://user:***@host:3306/db")
        XCTAssertEqual(ConnectionProfile.maskingPassword(in: "mysql://host/db"), "mysql://host/db")
    }
}

final class ArrowFormattingTests: XCTestCase {
    func testDecimal() {
        XCTAssertEqual(ArrowArrayView.formatDecimal(littleEndianWords: [12345, 0], scale: 2), "123.45")
        XCTAssertEqual(ArrowArrayView.formatDecimal(littleEndianWords: [5, 0], scale: 3), "0.005")
        XCTAssertEqual(ArrowArrayView.formatDecimal(littleEndianWords: [0, 0], scale: 0), "0")
        // -1 in two's complement
        XCTAssertEqual(
            ArrowArrayView.formatDecimal(littleEndianWords: [.max, .max], scale: 1), "-0.1")
        // 2^64 = 18446744073709551616
        XCTAssertEqual(
            ArrowArrayView.formatDecimal(littleEndianWords: [0, 1], scale: 0), "18446744073709551616")
        XCTAssertEqual(ArrowArrayView.formatDecimal(littleEndianWords: [7, 0], scale: -2), "700")
    }

    func testDates() {
        XCTAssertEqual(ArrowArrayView.formatDate(days: 0), "1970-01-01")
        XCTAssertEqual(ArrowArrayView.formatDate(days: 19_723), "2024-01-01")
        XCTAssertEqual(ArrowArrayView.formatDate(days: -1), "1969-12-31")
        XCTAssertEqual(ArrowArrayView.formatDate(days: 11_016), "2000-02-29")
    }

    func testTimes() {
        XCTAssertEqual(ArrowArrayView.formatTime(3_723, perSecond: 1), "01:02:03")
        XCTAssertEqual(ArrowArrayView.formatTime(3_723_500_000, perSecond: 1_000_000), "01:02:03.5")
        XCTAssertEqual(ArrowArrayView.formatTime(1, perSecond: 1_000_000_000), "00:00:00.000000001")
    }

    func testFloorDivide() {
        XCTAssertEqual(ArrowArrayView.floorDivide(-1, 1000), -1)
        XCTAssertEqual(ArrowArrayView.floorDivide(1999, 1000), 1)
        XCTAssertEqual(ArrowArrayView.floorDivide(-1000, 1000), -1)
    }
}
