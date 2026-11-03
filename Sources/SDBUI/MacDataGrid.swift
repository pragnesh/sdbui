#if canImport(AppKitBackend)
import AppKit
import AppKitBackend
@_spi(Backends) import SwiftCrossUI

/// App-local backend support: the fork only implements DataGrids for GTK.
/// NSTableView asks for visible cells and recycles their views, even for very large results.
extension AppKitBackend: @retroactive BackendFeatures.DataGrids {
    public func createDataGrid() -> NSView { MacDataGrid(frame: .zero) }

    public func updateDataGrid(_ dataGrid: NSView, columns: [DataGridColumn], rowCount: Int,
        contentRevision: Int, sort: DataGridSort?, onSort: (@MainActor (DataGridSort) -> Void)?,
        copyCommands: [String], onCopy: (@MainActor (DataGridCopyRequest) -> String?)?,
        cell: @escaping @MainActor (Int, Int) -> String?, environment: EnvironmentValues) {
        guard let grid = dataGrid as? MacDataGrid else { return }
        grid.update(columns: columns, rows: rowCount, revision: contentRevision, sort: sort,
                    onSort: onSort, commands: copyCommands, onCopy: onCopy, cell: cell)
        grid.table.isEnabled = environment.isEnabled
        grid.appearance = NSAppearance(named: environment.colorScheme == .dark ? .darkAqua : .aqua)
    }
}

@MainActor
final class MacDataGrid: NSScrollView, NSTableViewDataSource, NSTableViewDelegate {
    let table = MacResultTable()
    private(set) var columns: [DataGridColumn] = []
    private var rowCount = 0
    private(set) var revision: Int?
    private var sort: DataGridSort?
    private var cell: (@MainActor (Int, Int) -> String?)?
    private var sortAction: (@MainActor (DataGridSort) -> Void)?
    var copyAction: (@MainActor (DataGridCopyRequest) -> String?)?
    var copyCommands: [String] = []
    var preview: (@MainActor (Int, Int) -> String?)?
    var activate: (@MainActor (Int, Int) -> Void)?
    var cellMenu: (@MainActor (Int, Int) -> [MacMenuAction])?
    var headerMenu: (@MainActor (Int) -> [MacMenuAction])?
    var fontSize: Double = 13 { didSet { if fontSize != oldValue { table.reloadData() } } }
    weak var pairedGrid: MacDataGrid?
    private var syncing = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        hasVerticalScroller = true; hasHorizontalScroller = true; autohidesScrollers = true
        borderType = .noBorder
        table.owner = self
        table.dataSource = self; table.delegate = self
        table.rowHeight = 24; table.intercellSpacing = NSSize(width: 8, height: 0)
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true; table.allowsEmptySelection = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.headerView = MacGridHeader(frame: .zero)
        table.headerView?.frame.size.height = 40
        table.target = self; table.doubleAction = #selector(openClickedValue)
        documentView = table
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: contentView)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func update(columns: [DataGridColumn], rows: Int, revision: Int, sort: DataGridSort?,
        onSort: (@MainActor (DataGridSort) -> Void)?, commands: [String],
        onCopy: (@MainActor (DataGridCopyRequest) -> String?)?, cell: @escaping @MainActor (Int, Int) -> String?) {
        let changed = self.revision != revision || rowCount != rows || self.columns != columns
        let rebuilding = self.columns != columns
        self.columns = columns; rowCount = max(0, rows); self.revision = revision
        self.sort = sort; sortAction = onSort; copyAction = onCopy; copyCommands = commands; self.cell = cell
        if rebuilding {
            table.tableColumns.forEach { table.removeTableColumn($0) }
            for (index, descriptor) in columns.enumerated() {
                let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(String(index)))
                column.headerCell = NSTableHeaderCell(textCell: descriptor.title)
                column.headerCell.wraps = true; column.headerCell.usesSingleLineMode = false
                column.width = CGFloat(descriptor.width); column.minWidth = 40; column.maxWidth = 2400
                column.resizingMask = .userResizingMask
                table.addTableColumn(column)
            }
        }
        for (index, column) in table.tableColumns.enumerated() {
            table.setIndicatorImage(sort?.column == index ? NSImage(systemSymbolName: sort!.ascending ? "chevron.up" : "chevron.down", accessibilityDescription: nil) : nil, in: column)
        }
        if changed {
            table.deselectAll(nil); table.reloadData()
            contentView.scroll(to: NSPoint(x: contentView.bounds.origin.x, y: 0)); reflectScrolledClipView(contentView)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rowCount }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, let index = Int(tableColumn.identifier.rawValue), columns.indices.contains(index) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("sdbui-cell")
        let text = (tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField) ?? NSTextField(labelWithString: "")
        text.identifier = identifier; text.maximumNumberOfLines = 1
        text.lineBreakMode = .byTruncatingTail; text.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let value = cell?(row, index)
        text.stringValue = value ?? "NULL"; text.textColor = value == nil ? .secondaryLabelColor : .labelColor
        text.alignment = columns[index].alignment == .trailing ? .right : .left
        text.toolTip = preview?(row, index)
        return text
    }
    func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
        guard let column = Int(tableColumn.identifier.rawValue), let sortAction else { return }
        sortAction(DataGridSort(column: column, ascending: sort?.column == column ? !(sort?.ascending ?? true) : true))
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !syncing, let pair = pairedGrid, pair.rowCount == rowCount else { return }
        pair.syncing = true; pair.table.selectRowIndexes(table.selectedRowIndexes, byExtendingSelection: false); pair.syncing = false
    }
    @objc private func scrolled(_ notification: Notification) {
        guard !syncing, let pair = pairedGrid, pair.rowCount == rowCount else { return }
        pair.syncing = true
        pair.contentView.scroll(to: NSPoint(x: pair.contentView.bounds.origin.x, y: contentView.bounds.origin.y))
        pair.reflectScrolledClipView(pair.contentView); pair.syncing = false
    }
    @objc private func openClickedValue() {
        guard table.clickedRow >= 0, table.clickedColumn >= 0 else { return }
        activate?(table.clickedRow, table.clickedColumn)
    }
    func copy(command: Int? = nil, column: Int? = nil, rows: [Int]? = nil) {
        let selected = rows ?? Array(table.selectedRowIndexes)
        guard !selected.isEmpty, let text = copyAction?(.init(command: command, rows: selected, column: column)) else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
    }
}

@MainActor
struct MacMenuAction {
    let title: String
    let action: @MainActor () -> Void
}

@MainActor
private final class MacMenuItem: NSMenuItem {
    let run: @MainActor () -> Void
    init(_ command: MacMenuAction) {
        run = command.action
        super.init(title: command.title, action: #selector(invoke), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    @objc private func invoke() {
        // Native menu tracking must finish before an action can replace the grid.
        DispatchQueue.main.async { [run] in run() }
    }
}

@MainActor
final class MacResultTable: NSTableView {
    weak var owner: MacDataGrid?
    @objc(copy:) func copySelection(_ sender: Any?) { owner?.copy() }
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection([.command, .control]).isEmpty == false,
           event.charactersIgnoringModifiers?.lowercased() == "c" { owner?.copy(); return }
        if event.keyCode == 36, selectedRow >= 0 { owner?.activate?(selectedRow, max(0, clickedColumn)); return }
        super.keyDown(with: event)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let owner else { return nil }
        let point = convert(event.locationInWindow, from: nil), row = row(at: point), column = column(at: point)
        guard row >= 0, column >= 0 else { return nil }
        if !selectedRowIndexes.contains(row) { selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        let rows = Array(selectedRowIndexes)
        let revision = owner.revision
        let menu = NSMenu()
        // Capture content/mapping in the app's menu factory before native menu tracking starts.
        for command in owner.cellMenu?(row, column) ?? [] { menu.addItem(MacMenuItem(command)) }
        if menu.items.count > 0 { menu.addItem(.separator()) }
        for (index, title) in owner.copyCommands.enumerated() {
            menu.addItem(MacMenuItem(.init(title: title, action: { [weak owner] in
                guard let owner, owner.revision == revision else { return }
                owner.copy(command: index, column: column, rows: rows)
            })))
        }
        return menu
    }
}

@MainActor
private final class MacGridHeader: NSTableHeaderView {
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let owner = (tableView as? MacResultTable)?.owner else { return nil }
        let column = column(at: convert(event.locationInWindow, from: nil))
        guard column >= 0 else { return nil }
        let menu = NSMenu()
        for command in owner.headerMenu?(column) ?? [] { menu.addItem(MacMenuItem(command)) }
        return menu
    }
}

@MainActor
func macGrids(in view: NSView) -> [MacDataGrid] {
    if let grid = view as? MacDataGrid { return [grid] }
    return view.subviews.flatMap(macGrids)
}
#endif
