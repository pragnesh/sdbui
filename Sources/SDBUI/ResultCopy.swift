import ADBCKit
import SwiftCrossUI

/// The right-click copy commands of result grids, and the text they copy.
enum ResultCopy: Int, CaseIterable {
    case cell
    case rows
    case rowsWithHeader
    case csv
    case sqlInsert

    var title: String {
        switch self {
            case .cell: "Copy Cell"
            case .rows: "Copy Rows"
            case .rowsWithHeader: "Copy Rows with Column Names"
            case .csv: "Copy as CSV"
            case .sqlInsert: "Copy as SQL INSERT"
        }
    }

    static let titles = allCases.map(\.title)

    /// The text for `request` (Ctrl+C copies rows). Values are copied in
    /// full, not as cut for display. `table` names the INSERT target.
    static func text(
        for request: DataGridCopyRequest, in result: QueryResult, dialect: SQLDialect,
        table: String
    ) -> String? {
        let command = request.command.flatMap(ResultCopy.init(rawValue:)) ?? .rows
        let rows = request.rows.map { result.row($0) }
        let names = result.columns.map(\.name)
        switch command {
            case .cell:
                guard let row = request.rows.first, let column = request.column else { return nil }
                return result.cell(row, column, maxLength: nil) ?? "NULL"
            case .rows, .rowsWithHeader:
                let lines = rows.map { $0.map { tabSeparatedField($0) }.joined(separator: "\t") }
                let header = command == .rowsWithHeader ? [names.joined(separator: "\t")] : []
                return (header + lines).joined(separator: "\n")
            case .csv:
                let lines = ([names.map(Optional.some)] + rows).map {
                    $0.map(csvField).joined(separator: ",")
                }
                return lines.joined(separator: "\n") + "\n"
            case .sqlInsert:
                let columns = names.map(dialect.quote).joined(separator: ", ")
                return rows.map { row in
                    let values = zip(row, result.columns).map { value, column in
                        guard let value else { return "NULL" }
                        return column.isNumeric ? value : dialect.literal(value)
                    }
                    return "INSERT INTO \(table) (\(columns)) VALUES (\(values.joined(separator: ", ")));"
                }
                .joined(separator: "\n")
        }
    }

    /// Tabs and line breaks would break the row structure, so they become spaces.
    private static func tabSeparatedField(_ value: String?) -> String {
        guard let value else { return "NULL" }
        return value.replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    static func csvField(_ value: String?) -> String {
        guard let value else { return "" }
        if value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }
}
