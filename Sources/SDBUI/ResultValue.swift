import Foundation

/// A value snapshot: opening it never changes the result or executes SQL.
struct ResultValue {
    let raw: String?

    var tooltip: String? {
        guard let raw else { return nil }
        let lines = raw.prefix(2_000).split(separator: "\n", omittingEmptySubsequences: false)
        let preview = lines.prefix(12).joined(separator: "\n").replacingOccurrences(of: "\0", with: "␀")
        let truncated = preview.count < raw.count
        return preview + (truncated ? "…" : "") + "\n\nDouble-click to open the full value."
    }

    /// Validate with Foundation, then format the original tokens. Serializing
    /// decoded NSNumber values could round large integers or change exponents.
    var formattedJSON: String? {
        guard let raw, let first = raw.first(where: { !$0.isWhitespace }), first == "{" || first == "[",
              let data = raw.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil else { return nil }
        var output = ""
        var depth = 0
        var quoted = false
        var escaped = false
        var previous: Character?
        func newline() { output += "\n" + String(repeating: "  ", count: depth) }
        for character in raw {
            if quoted {
                output.append(character)
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { quoted = false }
                continue
            }
            if character.isWhitespace { continue }
            switch character {
            case "\"":
                if previous == "{" || previous == "[" { newline() }
                quoted = true
                output.append(character)
            case "{", "[":
                if previous == "{" || previous == "[" { newline() }
                output.append(character)
                depth += 1
            case "}", "]":
                guard previous != "," else { return nil }
                depth -= 1
                if previous != "{" && previous != "[" { newline() }
                output.append(character)
            case ",": output.append(character); newline()
            case ":": output += ": "
            default:
                if previous == "{" || previous == "[" { newline() }
                output.append(character)
            }
            previous = character
        }
        return output
    }
}

#if canImport(GtkBackend)
import CResultValue
import GtkBackend
import SwiftCrossUI

@MainActor
private final class GridValueSource {
    let pane: ResultPane
    weak var model: BrowserModel?
    let columns: [Int]
    init(_ pane: ResultPane, model: BrowserModel, columns: [Int]) { self.pane = pane; self.model = model; self.columns = columns }
    func column(_ index: UInt32) -> Int? { columns.indices.contains(Int(index)) ? columns[Int(index)] : nil }
}

private let valuePreview: SDBUIValuePreview = { context, row, column in
    let preview: String? = MainActor.assumeIsolated {
        guard let context else { return nil }
        let source = Unmanaged<GridValueSource>.fromOpaque(context).takeUnretainedValue()
        guard let column = source.column(column) else { return nil }
        let pane = source.pane
        guard let result = pane.result, Int(row) < result.rowCount else { return nil }
        // Decode only the hovered cell. The preview stays bounded even when the
        // viewer can expose a multi-megabyte value.
        return ResultValue(raw: result.cell(Int(row), column, maxLength: 2_001)).tooltip
    }
    // Only Sendable Swift text leaves the isolated closure; the pointer belongs
    // to the synchronous C caller, which frees it after setting the tooltip.
    return preview.flatMap { strdup($0) }
}

private let activateValue: SDBUIValueActivate = { context, grid, row, column in
    MainActor.assumeIsolated {
        guard let context, let grid else { return }
        let source = Unmanaged<GridValueSource>.fromOpaque(context).takeUnretainedValue()
        guard let column = source.column(column) else { return }
        let pane = source.pane
        guard let result = pane.result, Int(row) < result.rowCount else { return }
        let metadata = result.columns[column]
        let value = ResultValue(raw: result.cell(Int(row), column, maxLength: nil))
        let title = "\(metadata.name) · Row \(Int(row) + 1)" + (metadata.type.isEmpty ? "" : " · \(metadata.type)")
        if let formatted = value.formattedJSON {
            sdbui_value_show(grid, title, value.raw ?? "", value.raw?.utf8.count ?? 0, formatted, value.raw == nil ? 1 : 0)
        } else {
            sdbui_value_show(grid, title, value.raw ?? "NULL", value.raw?.utf8.count ?? 4, nil, value.raw == nil ? 1 : 0)
        }
    }
}

private let destroyValueSource: SDBUIValueDestroy = { context in
    if let context { Unmanaged<GridValueSource>.fromOpaque(context).release() }
}

@MainActor
private final class PreparedCellFilter {
    weak var model: BrowserModel?
    let target: CellFilterTarget
    init(model: BrowserModel, target: CellFilterTarget) { self.model = model; self.target = target }
}
private let prepareFilter: SDBUIFilterPrepare = { context, row, column in
    let prepared: PreparedCellFilter? = MainActor.assumeIsolated {
        guard let context else { return nil }
        let source = Unmanaged<GridValueSource>.fromOpaque(context).takeUnretainedValue()
        guard let model = source.model, let column = source.column(column),
              let target = model.cellFilterTarget(in: source.pane, row: Int(row), column: column) else { return nil }
        return PreparedCellFilter(model: model, target: target)
    }
    return prepared.map { Unmanaged.passRetained($0).toOpaque() }
}
private let applyFilter: SDBUIFilterApply = { context, command in
    MainActor.assumeIsolated {
        guard let context else { return }
        let prepared = Unmanaged<PreparedCellFilter>.fromOpaque(context).takeUnretainedValue()
        prepared.model?.applyCellFilter(prepared.target, command: command)
    }
}
private let destroyFilter: SDBUIValueDestroy = { context in
    if let context { Unmanaged<PreparedCellFilter>.fromOpaque(context).release() }
}

@MainActor
private final class PreparedHeader {
    let pane: ResultPane
    let column: Int
    let revision: Int
    init(pane: ResultPane, column: Int) { self.pane = pane; self.column = column; revision = pane.revision }
}
private let prepareHeader: SDBUIHeaderPrepare = { context, column in
    let prepared: PreparedHeader? = MainActor.assumeIsolated {
        guard let context else { return nil }
        let source = Unmanaged<GridValueSource>.fromOpaque(context).takeUnretainedValue()
        guard let column = source.column(column) else { return nil }
        return PreparedHeader(pane: source.pane, column: column)
    }
    return prepared.map { Unmanaged.passRetained($0).toOpaque() }
}
private let applyHeader: SDBUIHeaderApply = { context, command in
    let text: String? = MainActor.assumeIsolated {
        guard let context else { return nil }
        let target = Unmanaged<PreparedHeader>.fromOpaque(context).takeUnretainedValue()
        guard target.pane.revision == target.revision else { return nil }
        return target.pane.headerCommand(command, column: target.column)
    }
    return text.flatMap { strdup($0) }
}
private let destroyHeader: SDBUIValueDestroy = { context in
    if let context { Unmanaged<PreparedHeader>.fromOpaque(context).release() }
}

extension View {
    @ViewBuilder
    func synchronizingFrozenGrid() -> some View {
        inspect([.onCreate, .afterUpdate]) { widget in
            sdbui_grid_pair(UnsafeMutableRawPointer(widget.widgetPointer))
        }
    }
}

extension DataGrid {
    func inspectingValues(in pane: ResultPane, model: BrowserModel, columns: [Int]) -> some View {
        inspect([.onCreate, .afterUpdate]) { widget in
            let context = Unmanaged.passRetained(GridValueSource(pane, model: model, columns: columns)).toOpaque()
            sdbui_value_install(UnsafeMutableRawPointer(widget.widgetPointer), context,
                                valuePreview, activateValue, destroyValueSource)
            sdbui_value_filters(UnsafeMutableRawPointer(widget.widgetPointer), prepareFilter, applyFilter, destroyFilter)
            sdbui_value_editing(UnsafeMutableRawPointer(widget.widgetPointer), pane === model.queryPane && model.canEditRows ? 1 : 0)
            sdbui_grid_headers(UnsafeMutableRawPointer(widget.widgetPointer), prepareHeader, applyHeader, destroyHeader)
            sdbui_grid_header_filter_enabled(UnsafeMutableRawPointer(widget.widgetPointer), pane === model.queryPane && model.isBrowsing ? 1 : 0)
        }
    }
}
#else
import SwiftCrossUI
extension View {
    @ViewBuilder func synchronizingFrozenGrid() -> some View {
        #if canImport(AppKitBackend)
        synchronizingMacGrids()
        #else
        self
        #endif
    }
}
#endif
