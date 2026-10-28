import ADBCKit

/// Text sizing for result grids.
enum ResultText {
    static let maxColumnWidth = 48

    /// Column widths in characters, from the header and the first rows.
    static func columnWidths(of result: QueryResult) -> [Int] {
        let sample = result.rows.prefix(200)
        return result.columns.indices.map { column in
            let header = max(result.columns[column].name.count, result.columns[column].type.count)
            let longest = sample.lazy.map { cell($0[column]).count }.max() ?? 0
            return min(max(header, longest, 4), maxColumnWidth)
        }
    }

    private static func cell(_ value: String?) -> String {
        guard let value else { return "NULL" }
        return value.replacingOccurrences(of: "\n", with: "↵")
            .replacingOccurrences(of: "\t", with: " ")
    }
}
