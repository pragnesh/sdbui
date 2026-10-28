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
    /// The grid's columns, sized from the header and the first rows.
    private(set) var columns: [DataGridColumn] = []
    /// Bumped on every change.
    private(set) var revision = 0
    /// Called after every change.
    var onChange: @MainActor () -> Void = {}

    var hasColumns: Bool {
        !(result?.columns.isEmpty ?? true)
    }

    func show(_ result: QueryResult?) {
        self.result = result
        columns = result.map(Self.gridColumns) ?? []
        revision += 1
        onChange()
    }

    /// The display text of a cell, or nil for NULL.
    func cell(row: Int, column: Int) -> String? {
        guard let rows = result?.rows, rows.indices.contains(row),
            rows[row].indices.contains(column)
        else { return nil }
        // Rows are one line high.
        return rows[row][column]?.replacingOccurrences(of: "\n", with: "↵")
    }

    private static func gridColumns(_ result: QueryResult) -> [DataGridColumn] {
        zip(result.columns, ResultText.columnWidths(of: result)).map { column, characters in
            // Approximate pixels from characters in the proportional UI font
            // (headers are bold); columns stay resizable.
            let header = column.name.count * 9 + 32
            return DataGridColumn(column.name, width: min(max(characters * 8 + 24, header), 420))
        }
    }
}
