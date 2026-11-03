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
    init(_ pane: ResultPane, model: BrowserModel) { self.pane = pane; self.model = model }
}

private let valuePreview: SDBUIValuePreview = { context, row, column in
    let preview: String? = MainActor.assumeIsolated {
        guard let context else { return nil }
        let pane = Unmanaged<GridValueSource>.fromOpaque(context).takeUnretainedValue().pane
        guard let result = pane.result, Int(row) < result.rowCount, result.columns.indices.contains(Int(column)) else { return nil }
        // Decode only the hovered cell. The preview stays bounded even when the
        // viewer can expose a multi-megabyte value.
        return ResultValue(raw: result.cell(Int(row), Int(column), maxLength: 2_001)).tooltip
    }
    // Only Sendable Swift text leaves the isolated closure; the pointer belongs
    // to the synchronous C caller, which frees it after setting the tooltip.
    return preview.flatMap { strdup($0) }
}

private let activateValue: SDBUIValueActivate = { context, grid, row, column in
    MainActor.assumeIsolated {
        guard let context, let grid else { return }
        let pane = Unmanaged<GridValueSource>.fromOpaque(context).takeUnretainedValue().pane
        guard let result = pane.result, Int(row) < result.rowCount, result.columns.indices.contains(Int(column)) else { return }
        let metadata = result.columns[Int(column)]
        let value = ResultValue(raw: result.cell(Int(row), Int(column), maxLength: nil))
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
        guard let model = source.model,
              let target = model.cellFilterTarget(in: source.pane, row: Int(row), column: Int(column)) else { return nil }
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

extension DataGrid {
    func inspectingValues(in pane: ResultPane, model: BrowserModel) -> some View {
        inspect([.onCreate, .afterUpdate]) { widget in
            let context = Unmanaged.passRetained(GridValueSource(pane, model: model)).toOpaque()
            sdbui_value_install(UnsafeMutableRawPointer(widget.widgetPointer), context,
                                valuePreview, activateValue, destroyValueSource)
            sdbui_value_filters(UnsafeMutableRawPointer(widget.widgetPointer), prepareFilter, applyFilter, destroyFilter)
        }
    }
}
#endif
