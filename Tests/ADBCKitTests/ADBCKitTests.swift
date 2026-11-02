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
    func testNestedProfilesAndSearchRootPriority() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first")
        let second = root.appendingPathComponent("second")
        for directory in [first, second] {
            try FileManager.default.createDirectory(
                at: directory.appendingPathComponent("Work/Production"),
                withIntermediateDirectories: true)
        }
        let content = "driver = \"mysql\"\n[Options]\nuri = \"mysql://user:secret@localhost/db\"\n"
        for path in ["local.toml", "Work/local.toml", "Work/Production/main.toml"] {
            try content.write(to: first.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }
        try "driver = \"sqlite\"".write(
            to: second.appendingPathComponent("Work/local.toml"), atomically: true, encoding: .utf8)
        try "invalid".write(to: first.appendingPathComponent("broken.toml"), atomically: true, encoding: .utf8)
        let profiles = Discovery.profiles(in: [first, second])
        XCTAssertEqual(profiles.map(\.id), ["local", "Work/local", "Work/Production/main"])
        let nested = try XCTUnwrap(profiles.first { $0.id == "Work/local" })
        XCTAssertEqual(nested.driver, "mysql")
        XCTAssertEqual(nested.name, "local")
        XCTAssertEqual(nested.group, "Work")
        XCTAssertTrue(nested.matches(" WORK "))
        XCTAssertTrue(nested.matches("MYSQL"))
        XCTAssertTrue(nested.matches("localhost"))
        XCTAssertTrue(nested.matches(" "))
        XCTAssertFalse(nested.matches("secret"))
        XCTAssertFalse(nested.matches("missing"))
    }

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

final class SQLDialectTests: XCTestCase {
    let table = TableInfo(catalog: "def", schema: "shop", name: "order items", type: "TABLE")

    func testDialectFromVendor() {
        XCTAssertEqual(SQLDialect(vendorName: "MySQL"), .mysql)
        XCTAssertEqual(SQLDialect(vendorName: "MariaDB"), .mysql)
        XCTAssertEqual(SQLDialect(vendorName: "PostgreSQL"), .postgres)
        XCTAssertEqual(SQLDialect(vendorName: "DuckDB"), .generic)
        XCTAssertEqual(SQLDialect(vendorName: nil), .generic)
    }

    func testQuotingAndLiterals() {
        XCTAssertEqual(SQLDialect.mysql.quote("a`b"), "`a``b`")
        XCTAssertEqual(SQLDialect.postgres.quote("a\"b"), "\"a\"\"b\"")
        XCTAssertEqual(SQLDialect.mysql.literal(#"it's a\b"#), #"'it''s a\\b'"#)
        XCTAssertEqual(SQLDialect.postgres.literal(#"it's a\b"#), #"'it''s a\b'"#)
        XCTAssertEqual(SQLDialect.mysql.qualifiedName(of: table), "`shop`.`order items`")
    }

    func testDefaultNamespaceSQL() {
        XCTAssertEqual(SQLDialect.mysql.useNamespaceSQL("my`db"), "USE `my``db`")
        XCTAssertEqual(SQLDialect.postgres.useNamespaceSQL("sales"), "SET search_path TO \"sales\", public")
        XCTAssertEqual(SQLDialect.postgres.useNamespaceSQL("public"), "SET search_path TO public")
        XCTAssertNil(SQLDialect.generic.useNamespaceSQL("main"))
        XCTAssertEqual(SQLDialect.mysql.currentNamespaceSQL, "SELECT DATABASE()")
        XCTAssertNil(SQLDialect.generic.currentNamespaceSQL)
    }

    func testBrowseSQL() {
        XCTAssertEqual(
            SQLDialect.mysql.browseSQL(table, filter: nil, limit: 101, offset: 0),
            "SELECT * FROM `shop`.`order items` LIMIT 101")
        let filter = SQLDialect.Filter(column: "name", op: .contains, value: "50%_off")
        XCTAssertEqual(
            SQLDialect.mysql.browseSQL(table, filter: filter, limit: 101, offset: 200),
            #"SELECT * FROM `shop`.`order items` WHERE `name` LIKE '%50\\%\\_off%' LIMIT 101 OFFSET 200"#)
        XCTAssertEqual(
            SQLDialect.postgres.browseSQL(
                table, filter: nil, orderBy: ("total", false), limit: 1001, offset: 1000),
            #"SELECT * FROM "shop"."order items" ORDER BY "total" DESC LIMIT 1001 OFFSET 1000"#)
        XCTAssertEqual(
            SQLDialect.postgres.whereClause(for: filter),
            #"CAST("name" AS TEXT) LIKE '%50\%\_off%'"#)
        XCTAssertEqual(
            SQLDialect.postgres.whereClause(for: .init(column: "id", op: .greaterOrEqual, value: "5")),
            #""id" >= '5'"#)
        XCTAssertEqual(
            SQLDialect.mysql.whereClause(for: .init(column: "x", op: .isNull, value: "ignored")),
            "`x` IS NULL")
    }

    func testCatalogQueriesUseLiterals() throws {
        let sql = try XCTUnwrap(SQLDialect.mysql.columnsSQL(
            TableInfo(catalog: nil, schema: "o'shop", name: "t", type: nil)))
        XCTAssertTrue(sql.contains("TABLE_SCHEMA = 'o''shop' AND TABLE_NAME = 't'"))
        XCTAssertNil(SQLDialect.generic.columnsSQL(table))
        XCTAssertNil(SQLDialect.postgres.createTableSQL(table))
    }
}

final class QueryResultTests: XCTestCase {
    let result = QueryResult(
        columns: [.init(name: "id", type: "int64"), .init(name: "name", type: "utf8")],
        rows: [["10", "b"], ["9", nil], [nil, "a"], ["100", "c"]])

    func testCellsAndTruncation() {
        XCTAssertEqual(result.rowCount, 4)
        XCTAssertEqual(result.cell(0, 1), "b")
        XCTAssertNil(result.cell(1, 1))
        XCTAssertNil(result.cell(9, 0))
        let long = QueryResult(columns: [.init(name: "t", type: "utf8")], rows: [["abcdef"]])
        XCTAssertEqual(long.cell(0, 0, maxLength: 3), "abc…")
        XCTAssertEqual(long.cell(0, 0, maxLength: nil), "abcdef")
    }

    func testLimit() {
        var limited = result
        limited.limit(to: 2)
        XCTAssertEqual(limited.rowCount, 2)
        XCTAssertEqual(limited.row(1), ["9", nil])
    }

    func testSortNumericAndText() {
        let byID = result.sorted(byColumn: 0, ascending: true)
        XCTAssertEqual((0..<4).map { byID.cell($0, 0) }, [nil, "9", "10", "100"])
        let byIDDescending = result.sorted(byColumn: 0, ascending: false)
        XCTAssertEqual((0..<4).map { byIDDescending.cell($0, 0) }, ["100", "10", "9", nil])
        let byName = result.sorted(byColumn: 1, ascending: true)
        XCTAssertEqual((0..<4).map { byName.cell($0, 1) }, [nil, "a", "b", "c"])
        // Sorting a sorted result sorts the displayed rows, and limit keeps order.
        var resorted = byName.sorted(byColumn: 0, ascending: false)
        resorted.limit(to: 2)
        XCTAssertEqual(resorted.row(0), ["100", "c"])
        XCTAssertEqual(resorted.row(1), ["10", "b"])
    }

    func testNumericColumnTypes() {
        XCTAssertTrue(ResultColumn(name: "x", type: "decimal(10,2)").isNumeric)
        XCTAssertTrue(ResultColumn(name: "x", type: "uint32").isNumeric)
        XCTAssertFalse(ResultColumn(name: "x", type: "utf8").isNumeric)
        XCTAssertFalse(ResultColumn(name: "x", type: "timestamp[us]").isNumeric)
    }
}

final class SQLStatementsTests: XCTestCase {
    func testSplitsOutsideQuotesAndComments() {
        let script = """
            SELECT 'a;b', "c;d", `e;f` FROM t; -- not; here
            /* also; not */ UPDATE t SET x = 'it''s; fine';
            ;
            SELECT 3
            """
        let texts = SQLDialect.mysql.statements(in: script).map(\.text)
        XCTAssertEqual(texts, [
            #"SELECT 'a;b', "c;d", `e;f` FROM t"#,
            "-- not; here\n/* also; not */ UPDATE t SET x = 'it''s; fine'",
            "SELECT 3",
        ])
    }

    func testCommentOnlyAndEmptyStatementsAreSkipped() {
        XCTAssertEqual(SQLDialect.postgres.statements(in: "-- just a comment\n;  ;").count, 0)
        XCTAssertEqual(SQLDialect.postgres.statements(in: "").count, 0)
    }

    func testMySQLBackslashEscapesAndHashComments() {
        XCTAssertEqual(
            SQLDialect.mysql.statements(in: #"SELECT 'a\';b'; # c;d"#).map(\.text),
            [#"SELECT 'a\';b'"#])
        // In PostgreSQL a backslash doesn't escape and # isn't a comment.
        XCTAssertEqual(
            SQLDialect.postgres.statements(in: #"SELECT 'a\'; SELECT 1 # 2"#).map(\.text),
            [#"SELECT 'a\'"#, "SELECT 1 # 2"])
    }

    func testStatementAtCursor() {
        let script = "SELECT 1;\nSELECT 2;\n\nSELECT 3"
        func at(_ cursor: Int) -> String? {
            SQLDialect.mysql.statement(in: script, at: cursor)?.text
        }
        XCTAssertEqual(at(0), "SELECT 1")
        XCTAssertEqual(at(9), "SELECT 1")  // right after the semicolon
        XCTAssertEqual(at(12), "SELECT 2")
        XCTAssertEqual(at(script.unicodeScalars.count), "SELECT 3")
        XCTAssertNil(SQLDialect.mysql.statement(in: "  ", at: 1))
    }
}
