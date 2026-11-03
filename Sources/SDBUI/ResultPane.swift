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

    private(set) var hiddenColumns: Set<Int> = []
    private(set) var frozenCount = 0
    var visibleColumns: [Int] { columns.indices.filter { !hiddenColumns.contains($0) } }
    var frozenColumns: [Int] { Array(visibleColumns.prefix(frozenCount)) }
    var scrollingColumns: [Int] { Array(visibleColumns.dropFirst(frozenCount)) }

    /// Commands shared by the native header menu. Clipboard commands return text.
    func headerCommand(_ command: Int32, column: Int) -> String? {
        guard let result, result.columns.indices.contains(column) else { return nil }
        switch command {
        case 0, 1:
            guard isSortable else { return nil }
            requestSort(DataGridSort(column: column, ascending: command == 0))
            return nil
        case 2: return result.columns[column].name
        case 3: return (0..<result.rowCount).map { result.cell($0, column, maxLength: nil) ?? "NULL" }.joined(separator: "\n")
        case 4:
            guard visibleColumns.count > 1 else { return nil }
            hiddenColumns.insert(column)
            frozenCount = min(frozenCount, max(0, visibleColumns.count - 1))
        case 5:
            let characters = (0..<min(result.rowCount, 1000)).map {
                (result.cell($0, column, maxLength: 200) ?? "NULL").prefix(200).count
            }.max() ?? 4
            columns[column].width = min(1600, max(Self.gridColumns(result)[column].width, characters * 8 + 24))
        case 6:
            if let position = visibleColumns.firstIndex(of: column) {
                frozenCount = min(position + 1, max(0, visibleColumns.count - 1))
            }
        case 7: frozenCount = 0
        case 8: hiddenColumns = []
        default: return nil
        }
        revision += 1
        onChange()
        return nil
    }

    var hasColumns: Bool {
        !(result?.columns.isEmpty ?? true)
    }

    /// Show a new result, already in the order `sort` describes (if any).
    func show(_ result: QueryResult?, sortedBy sort: DataGridSort? = nil) {
        let newColumns = result.map(Self.gridColumns) ?? []
        if columns.map(\.title) != newColumns.map(\.title) {
            hiddenColumns = []
            frozenCount = 0
            columns = newColumns
        }
        self.result = result
        unsortedResult = result
        self.sort = sort
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
