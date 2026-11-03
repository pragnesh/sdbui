#if canImport(AppKitBackend)
import AppKit
import AppKitBackend
import XCTest
import SwiftCrossUI
@testable import SDBUI

@MainActor
final class MacDataGridTests: XCTestCase {
    func testMillionRowGridOnlyRequestsVisibleCells() {
        _ = NSApplication.shared
        let grid = MacDataGrid(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        var calls = 0
        grid.update(columns: [.init("id\nbigint", alignment: .trailing), .init("value\ntext")], rows: 1_000_000, revision: 1,
                    sort: nil, onSort: nil, commands: [], onCopy: nil, cell: { row, column in
            calls += 1; return column == 0 ? String(row) : nil
        })
        grid.layoutSubtreeIfNeeded()
        XCTAssertEqual(grid.table.numberOfRows, 1_000_000)
        XCTAssertLessThan(calls, 1000)
        let value = grid.tableView(grid.table, viewFor: grid.table.tableColumns[0], row: 999_999) as? NSTextField
        XCTAssertEqual(value?.stringValue, "999999")
        XCTAssertEqual(value?.alignment, .right)
        let null = grid.tableView(grid.table, viewFor: grid.table.tableColumns[1], row: 0) as? NSTextField
        XCTAssertEqual(null?.stringValue, "NULL")
        XCTAssertEqual(null?.textColor, .secondaryLabelColor)
    }
    func testSortingCopyAndRevisionPreserveOrResetSelection() {
        _ = NSApplication.shared
        let grid = MacDataGrid(frame: .zero)
        var sorts: [DataGridSort] = []
        var request: DataGridCopyRequest?
        func update(_ revision: Int, sort: DataGridSort? = nil) {
            grid.update(columns: [.init("value")], rows: 4, revision: revision, sort: sort,
                        onSort: { sorts.append($0) }, commands: ["Copy cell"],
                        onCopy: { request = $0; return "full\nvalue" }, cell: { _, _ in "display" })
        }
        update(1)
        grid.table.selectRowIndexes(IndexSet([1, 3]), byExtendingSelection: false)
        grid.copy(command: 0, column: 0)
        XCTAssertEqual(request?.rows, [1, 3]); XCTAssertEqual(request?.column, 0)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "full\nvalue")
        update(1)
        XCTAssertEqual(grid.table.selectedRowIndexes, IndexSet([1, 3]))
        grid.tableView(grid.table, didClick: grid.table.tableColumns[0])
        XCTAssertEqual(sorts, [.init(column: 0, ascending: true)])
        update(2, sort: .init(column: 0, ascending: true))
        XCTAssertTrue(grid.table.selectedRowIndexes.isEmpty)
        grid.tableView(grid.table, didClick: grid.table.tableColumns[0])
        XCTAssertEqual(sorts.last, .init(column: 0, ascending: false))
    }
    func testFrozenSelectionAndScrollSynchronization() {
        _ = NSApplication.shared
        let left = MacDataGrid(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let right = MacDataGrid(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        for grid in [left, right] {
            grid.update(columns: [.init("value")], rows: 1000, revision: 1, sort: nil, onSort: nil, commands: [], onCopy: nil, cell: { row, _ in String(row) })
            grid.layoutSubtreeIfNeeded()
        }
        left.pairedGrid = right; right.pairedGrid = left
        left.table.selectRowIndexes(IndexSet(integer: 25), byExtendingSelection: false)
        XCTAssertEqual(right.table.selectedRowIndexes, IndexSet(integer: 25))
        left.contentView.scroll(to: NSPoint(x: 0, y: 200))
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: left.contentView)
        XCTAssertEqual(right.contentView.bounds.origin.y, left.contentView.bounds.origin.y)
    }
}
#endif
