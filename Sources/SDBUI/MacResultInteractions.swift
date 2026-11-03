#if canImport(AppKitBackend)
import AppKit
import AppKitBackend
import SwiftCrossUI

extension DataGrid {
    func inspectingMacValues(in pane: ResultPane, model: BrowserModel, columns: [Int]) -> some View {
        inspect([.onCreate, .afterUpdate]) { widget in
            guard let grid = macGrids(in: widget).first else { return }
            grid.fontSize = model.queryFontSize
            grid.preview = { row, column in
                guard columns.indices.contains(column), let result = pane.result, row < result.rowCount else { return nil }
                return ResultValue(raw: result.cell(row, columns[column], maxLength: 2001)).tooltip
            }
            grid.activate = { row, column in
                guard columns.indices.contains(column), let result = pane.result, row < result.rowCount else { return }
                MacValueWindow.show(title: "\(result.columns[columns[column]].name) · Row \(row + 1)", raw: result.cell(row, columns[column], maxLength: nil))
            }
            grid.cellMenu = { row, column in
                guard columns.indices.contains(column) else { return [] }
                let index = columns[column], revision = pane.revision
                var actions = [MacMenuAction(title: "Open full value", action: { [weak grid] in
                    guard pane.revision == revision else { return }; grid?.activate?(row, column)
                })]
                if let target = model.cellFilterTarget(in: pane, row: row, column: index) {
                    for (command, title) in ["Filter = this value", "Filter ≠ this value", "Filter IS NULL"].enumerated() {
                        actions.append(.init(title: title, action: { model.applyCellFilter(target, command: Int32(command)) }))
                    }
                }
                if pane === model.queryPane, model.canEditRows,
                   let target = model.cellFilterTarget(in: pane, row: row, column: index) {
                    actions.append(.init(title: "Edit row…", action: { model.applyCellFilter(target, command: 3) }))
                    actions.append(.init(title: "Delete row…", action: { model.applyCellFilter(target, command: 4) }))
                }
                return actions
            }
            grid.headerMenu = { column in
                guard columns.indices.contains(column) else { return [] }
                let index = columns[column], revision = pane.revision
                let titles = ["Sort ascending", "Sort descending", "Copy column name", "Copy column values", "Hide column", "Auto-fit width", "Freeze through this column", "Unfreeze columns", "Show all columns", "Filter column…"]
                return titles.enumerated().compactMap { command, title in
                    guard pane.isSortable || command > 1 else { return nil }
                    guard command != 9 || pane.filterHandler != nil else { return nil }
                    return MacMenuAction(title: title, action: {
                        guard pane.revision == revision else { return }
                        if let text = pane.headerCommand(Int32(command), column: index) {
                            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
                        }
                    })
                }
            }
            // Refresh visible native cells after installing value/tooltip providers.
            grid.table.reloadData()
        }
    }
}

extension View {
    func synchronizingMacGrids() -> some View {
        inspect([.onCreate, .afterUpdate]) { view in
            let grids = macGrids(in: view)
            guard grids.count == 2 else { return }
            grids[0].pairedGrid = grids[1]; grids[1].pairedGrid = grids[0]
            grids[1].table.selectRowIndexes(grids[0].table.selectedRowIndexes, byExtendingSelection: false)
        }
    }
}

@MainActor
final class MacValueWindow: NSWindowController, NSWindowDelegate {
    private static var openWindows: [UUID: MacValueWindow] = [:]
    private let id = UUID()
    private let raw: String?
    private let pretty: String?
    private let text = NSTextView()
    private let toggle = NSButton(checkboxWithTitle: "Pretty-print JSON", target: nil, action: nil)
    private init(title: String, raw: String?) {
        self.raw = raw; pretty = ResultValue(raw: raw).formattedJSON
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 520), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = title; window.delegate = self; window.isReleasedWhenClosed = false
        let root = NSStackView(); root.orientation = .vertical; root.spacing = 8
        root.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        let bar = NSStackView(); bar.orientation = .horizontal
        toggle.target = self; toggle.action = #selector(changeFormat); toggle.isHidden = pretty == nil
        let copy = NSButton(title: "Copy original value", target: self, action: #selector(copyRaw))
        bar.addArrangedSubview(toggle); bar.addArrangedSubview(copy)
        text.isEditable = false; text.isSelectable = true; text.isRichText = false
        text.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        text.string = raw ?? "NULL"
        text.frame = NSRect(x: 0, y: 0, width: 736, height: 400)
        text.minSize = .zero
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.isVerticallyResizable = true; text.isHorizontallyResizable = true
        text.textContainer?.containerSize = text.maxSize
        text.textContainer?.widthTracksTextView = false
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.documentView = text
        root.addArrangedSubview(bar); root.addArrangedSubview(scroll)
        window.contentView = root
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([scroll.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -24), scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 250)])
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    static func show(title: String, raw: String?) {
        let viewer = MacValueWindow(title: title, raw: raw)
        openWindows[viewer.id] = viewer; viewer.showWindow(nil); viewer.window?.makeKeyAndOrderFront(nil)
    }
    @objc private func changeFormat() { text.string = toggle.state == .on ? pretty ?? raw ?? "NULL" : raw ?? "NULL" }
    @objc private func copyRaw() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(raw ?? "NULL", forType: .string) }
    func windowWillClose(_ notification: Notification) { Self.openWindows.removeValue(forKey: id) }
}
#endif
