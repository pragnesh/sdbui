import Foundation
import XCTest
@testable import ADBCKit

final class ProductionSafetyTests: XCTestCase {
    func testDestructiveStatementsAndWhereScope() {
        for sql in ["DELETE FROM t", "UPDATE t SET x = (SELECT x FROM other WHERE id = 1)",
                    "WITH c AS (SELECT 1 WHERE true) DELETE FROM t", "WITH c AS (DELETE FROM t RETURNING *) SELECT * FROM c",
                    "DROP TABLE t", "TRUNCATE t", "EXPLAIN ANALYZE DELETE FROM t", "DELETE FROM t /* WHERE true */",
                    "UPDATE t SET x = 'WHERE'", "UPDATE t SET x = $$WHERE$$"] {
            XCTAssertFalse(SQLSafetyAssessment(sql, dialect: .postgres).warnings.isEmpty, sql)
        }
        for sql in ["DELETE FROM t WHERE id = 1", "UPDATE t SET x = 1 WHERE id = 2", "SELECT 'DROP TABLE t'",
                    "SELECT \"TRUNCATE\" FROM t", "SELECT $$DELETE FROM t; WHERE$$", "/* DROP t */ SELECT 1",
                    "WITH c AS (DELETE FROM t WHERE id = 1 RETURNING *) SELECT * FROM c"] {
            XCTAssertTrue(SQLSafetyAssessment(sql, dialect: .postgres).warnings.isEmpty, sql)
        }
        XCTAssertFalse(SQLSafetyAssessment("/*! DELETE FROM t */", dialect: .mysql).warnings.isEmpty)
        XCTAssertFalse(SQLSafetyAssessment("UPDATE t SET [WHERE] = 1", dialect: .generic).warnings.isEmpty)
        XCTAssertEqual(SQLDialect.mysql.statements(in: "SELECT 1--1; DELETE FROM t").count, 2)
    }

    func testReadOnlyPolicyAndSQLSplitting() {
        for sql in ["SELECT 1", "WITH c AS (SELECT 1) SELECT * FROM c", "SHOW TABLES", "SELECT 'UPDATE'", "SELECT $$DROP; UPDATE$$"] {
            XCTAssertTrue(SQLSafetyAssessment(sql, dialect: .postgres).allowsReadOnly, sql)
        }
        for sql in ["DELETE FROM t WHERE id = 1", "WITH c AS (DELETE FROM t RETURNING *) SELECT * FROM c",
                    "SELECT * INTO new_table FROM t", "SET transaction_read_only = off", "COMMIT", "CALL p()",
                    "SELECT 1; DELETE FROM t", "EXPLAIN ANALYZE DELETE FROM t", "SELECT 'unterminated"] {
            XCTAssertFalse(SQLSafetyAssessment(sql, dialect: .postgres).allowsReadOnly, sql)
        }
        XCTAssertEqual(SQLDialect.postgres.statements(in: "SELECT $tag$a;b$tag$; DELETE FROM t").count, 2)
        XCTAssertEqual(SQLDialect.postgres.statements(in: "/* outer /* inner */ ; */ SELECT 1; DELETE FROM t").count, 2)
        XCTAssertEqual(SQLDialect.mysql.statements(in: "/*! DELETE FROM t */").count, 1)
    }

    func testFavoriteMetadataRoundTripAndDefaults() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var draft = ConnectionDraft()
        draft.name = "Test"
        draft.safety = FavoriteSafety(label: "Production \"primary\"", color: "Red", readOnly: true)
        let url = try draft.save(in: root)
        let profile = try Discovery.loadProfile(at: url)
        XCTAssertEqual(profile.safety, draft.safety)
        XCTAssertEqual(ConnectionDraft(profile: profile).safety, draft.safety)
        XCTAssertFalse(profile.options.contains { $0.key.contains("read_only") || $0.key == "color" })
        let legacy = root.appendingPathComponent("legacy.toml")
        try "profile_version = 1\ndriver = \"postgresql\"\n[Options]\nuri = \"postgresql://localhost/test\"\n".write(to: legacy, atomically: true, encoding: .utf8)
        XCTAssertEqual(try Discovery.loadProfile(at: legacy).safety, FavoriteSafety())
        XCTAssertEqual(FavoriteSafety(color: "unknown").color, "None")
    }
}
