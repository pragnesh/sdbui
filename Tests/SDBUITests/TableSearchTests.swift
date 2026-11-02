import XCTest
@testable import ADBCKit
@testable import SDBUI

final class TableSearchTests: XCTestCase {
    private func table(_ name: String, schema: String = "app") -> TableInfo {
        TableInfo(catalog: "db", schema: schema, name: name, type: "TABLE")
    }
    func testNoCapAndNamespaceIsolation() {
        let tables = (0..<10_000).map { table(String(format: "table_%05d", $0)) } + [table("outside", schema: "other")]
        let result = TableSearch.results(tables, namespace: "app", query: " \n ")
        XCTAssertEqual(result.count, 10_000)
        XCTAssertEqual(result.last?.name, "table_09999")
        XCTAssertEqual(result, Array(tables.prefix(10_000)))
        XCTAssertEqual(TableSearch.results(tables, namespace: "other", query: "").map(\.name), ["outside"])
    }
    func testExactPrefixSubstringThenFuzzyRanking() {
        let tables = [table("user_orders"), table("archived_usrord"), table("usrord_archive"), table("usrord")]
        XCTAssertEqual(TableSearch.results(tables, namespace: "app", query: "USRORD").map(\.name),
            ["usrord", "usrord_archive", "archived_usrord", "user_orders"])
        XCTAssertTrue(TableSearch.results(tables, namespace: "app", query: "zzzz").isEmpty)
    }
    func testMultipleTermsDiacriticsAndStableTies() {
        let tables = [table("user_orders"), table("user_archive"), table("Café_Orders"), table("users_orders")]
        XCTAssertEqual(TableSearch.results(tables, namespace: "app", query: "cafe ord").map(\.name), ["Café_Orders"])
        XCTAssertEqual(TableSearch.results(tables, namespace: "app", query: "usr ord").map(\.name), ["user_orders", "users_orders"])
        let ties = [table("ab_one"), table("ab_two")]
        XCTAssertEqual(TableSearch.results(ties, namespace: "app", query: "ab"), ties)
    }
    func testSelectionIdentityIsIndependentOfFilteredPosition() {
        let tables = [table("order_lines"), table("user_orders"), table("users")]
        let selected = tables[1].id
        XCTAssertEqual(TableSearch.results(tables, namespace: "app", query: "usrord").first?.id, selected)
        XCTAssertFalse(TableSearch.results(tables, namespace: "app", query: "lines").contains { $0.id == selected })
        XCTAssertEqual(TableSearch.results(tables, namespace: "app", query: "")[1].id, selected)
    }
}
