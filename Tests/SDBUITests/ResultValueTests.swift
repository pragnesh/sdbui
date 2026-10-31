import Foundation
import XCTest
@testable import SDBUI

final class ResultValueTests: XCTestCase {
    func testJSONPreservesTokensAndFormatsNestedValues() throws {
        let raw = #"{"n":123456789012345678901234567890,"exp":1.2300e+12,"nested":[true,null,{},[],"a,}\\\"b"],"unicode":"你好"}"#
        let formatted = try XCTUnwrap(ResultValue(raw: raw).formattedJSON)
        XCTAssertTrue(formatted.contains("\n  \"n\": 123456789012345678901234567890,"))
        XCTAssertTrue(formatted.contains("1.2300e+12"))
        XCTAssertTrue(formatted.contains("    {},\n    [],"))
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(formatted.utf8)))
        // Removing whitespace outside JSON strings should preserve every token.
        XCTAssertEqual(ResultValue(raw: formatted).formattedJSON, formatted)
        XCTAssertEqual(ResultValue(raw: raw).raw, raw)
    }

    func testOrdinaryTextInvalidJSONNullAndEmptyValues() {
        for raw in ["", "hello", "{broken}", "[1,]", "null", "42", "\"string\""] {
            XCTAssertNil(ResultValue(raw: raw).formattedJSON)
        }
        XCTAssertTrue(ResultValue(raw: "a\0b").tooltip!.contains("a␀b"))
        XCTAssertNil(ResultValue(raw: nil).tooltip)
        XCTAssertNil(ResultValue(raw: nil).formattedJSON)
        XCTAssertNotNil(ResultValue(raw: "").tooltip)
        XCTAssertEqual(ResultValue(raw: "{}").formattedJSON, "{}")
        XCTAssertEqual(ResultValue(raw: "[]").formattedJSON, "[]")
    }

    func testTooltipIsBoundedAndPreservesLiteralText() throws {
        let long = String(repeating: "x", count: 10_000)
        let tooltip = try XCTUnwrap(ResultValue(raw: long).tooltip)
        XCTAssertLessThan(tooltip.count, 2_100)
        XCTAssertTrue(tooltip.contains("…"))
        let multiline = try XCTUnwrap(ResultValue(raw: String(repeating: "line\n", count: 100)).tooltip)
        XCTAssertLessThan(multiline.split(separator: "\n").count, 16)
        XCTAssertTrue(ResultValue(raw: "<b>literal</b>").tooltip!.hasPrefix("<b>literal</b>"))
    }
}
