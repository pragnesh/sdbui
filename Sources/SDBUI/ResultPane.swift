import ADBCKit
import SwiftCrossUI

/// One grid's results, shown with a ``DataGrid`` (which asks for cell text
/// only for the cells it displays).
///
/// Not `@Observable` (see ``BrowserModel``): views watch ``revision`` with
/// ``BrowserModel/watch(_:of:_:)`` and redraw only when it changes.
@MainActor
final class ResultPane {
    private(set) var result: QueryResult?
    /// The result as loaded, before any in-memory sort.
    private var unsortedResult: QueryResult?
    /// The grid's columns, sized from the header and the first rows.
    private(set) var columns: [DataGridColumn] = []
    /// The order shown in the grid's headers.
    private(set) var sort: DataGridSort?
    /// Bumped on every change.
    private(set) var revision = 0
    /// Called after every change.
    var onChange: @MainActor () -> Void = {}
    /// How header clicks are handled: `nil` sorts the loaded rows in memory;
    /// otherwise the owner reloads sorted rows (e.g. with ORDER BY) and shows
    /// them with ``show(_:sortedBy:)``.
    var sortHandler: (@MainActor (DataGridSort) -> Void)?
    /// Whether the column headers are clickable.
    var isSortable = true
    /// The SQL dialect and INSERT target for "Copy as SQL INSERT".
    var copyContext: @MainActor () -> (dialect: SQLDialect, table: String) = {
        (.generic, "table_name")
    }

    var hasColumns: Bool {
        !(result?.columns.isEmpty ?? true)
    }

    /// Show a new result, already in the order `sort` describes (if any).
    func show(_ result: QueryResult?, sortedBy sort: DataGridSort? = nil) {
        self.result = result
        unsortedResult = result
        self.sort = sort
        columns = result.map(Self.gridColumns) ?? []
        revision += 1
        onChange()
    }

    /// A header was clicked.
    func requestSort(_ sort: DataGridSort) {
        if let sortHandler {
            sortHandler(sort)
        } else if let unsortedResult {
            result = unsortedResult.sorted(byColumn: sort.column, ascending: sort.ascending)
            self.sort = sort
            revision += 1
            onChange()
        }
    }

    /// The text to copy for a grid copy request.
    func copyText(for request: DataGridCopyRequest) -> String? {
        guard let result else { return nil }
        let context = copyContext()
        let text = ResultCopy.text(
            for: request, in: result, dialect: context.dialect, table: context.table)
        return text
    }

    /// The display text of a cell, or nil for NULL.
    func cell(row: Int, column: Int) -> String? {
        // Rows are one line high.
        result?.cell(row, column)?.replacingOccurrences(of: "\n", with: "↵")
    }

    private static func gridColumns(_ result: QueryResult) -> [DataGridColumn] {
        zip(result.columns, ResultText.columnWidths(of: result)).map { column, characters in
            // Approximate pixels from characters in the proportional UI font
            // (headers are bold); columns stay resizable.
            let header = max(column.name.count * 11, column.type.count * 8) + 32
            // The type goes on a second header line.
            let title = column.type.isEmpty ? column.name : "\(column.name)\n\(column.type)"
            return DataGridColumn(
                title,
                width: min(max(characters * 8 + 24, header), 420),
                alignment: column.isNumeric ? .trailing : .leading
            )
        }
    }
}
