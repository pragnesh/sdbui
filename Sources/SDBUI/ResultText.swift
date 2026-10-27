import ADBCKit

/// Lays a result page out as monospaced text.
///
/// One `Text` per page instead of one view per cell keeps the widget count
/// constant — a stack-based grid of 100 rows × N columns meant thousands of
/// GTK widgets to lay out on every update.
enum ResultText {
    static let maxColumnWidth = 48
    static let separator = "  "

    /// Column widths in characters, from the header and the first rows.
    static func columnWidths(of result: QueryResult) -> [Int] {
        let sample = result.rows.prefix(1_000)
        return result.columns.indices.map { column in
            let header = max(result.columns[column].name.count, result.columns[column].type.count)
            let longest = sample.lazy.map { cell($0[column]).count }.max() ?? 0
            return min(max(header, longest, 4), maxColumnWidth)
        }
    }

    static func header(of result: QueryResult, widths: [Int]) -> String {
        let names = line(result.columns.map(\.name), widths: widths)
        let types = line(result.columns.map(\.type), widths: widths)
        return names + "\n" + types
    }

    static func body(of result: QueryResult, rows: Range<Int>, widths: [Int]) -> String {
        rows.map { line(result.rows[$0].map(cell), widths: widths) }
            .joined(separator: "\n")
    }

    private static func cell(_ value: String?) -> String {
        guard let value else { return "NULL" }
        return value.replacingOccurrences(of: "\n", with: "↵")
            .replacingOccurrences(of: "\t", with: " ")
    }

    private static func line(_ cells: [String], widths: [Int]) -> String {
        zip(cells, widths).map { text, width in
            let count = text.count
            if count > width {
                return text.prefix(width - 1) + "…"
            }
            return text + String(repeating: " ", count: width - count)
        }
        .joined(separator: separator)
    }
}
