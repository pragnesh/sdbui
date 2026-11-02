import ADBCKit
import Foundation
@_spi(Backends) import SwiftCrossUI
#if canImport(GtkBackend)
import GtkBackend
import Gtk
import CResultValue

struct TableSidebarRow: Equatable {
    var id: String
    var label: String
}

@MainActor
private final class TableListSource {
    weak var model: BrowserModel?
    var rows: [TableSidebarRow] = []
    init(_ model: BrowserModel) { self.model = model }
}
private let tableSelected: SDBUITableSelect = { context, index in
    MainActor.assumeIsolated {
        guard let context else { return }
        let source = Unmanaged<TableListSource>.fromOpaque(context).takeUnretainedValue()
        guard source.rows.indices.contains(Int(index)) else { return }
        source.model?.selectTable(source.rows[Int(index)].id)
    }
}
private let destroyTableList: SDBUIValueDestroy = { context in
    if let context { Unmanaged<TableListSource>.fromOpaque(context).release() }
}

/// GTK recycles list items instead of allocating Swift view graphs for every name.
@MainActor
struct VirtualTableList: View {
    var body = EmptyView()
    var rows: [TableSidebarRow]
    var selection: String?
    var model: BrowserModel

    func children<Backend: BaseAppBackend>(backend: Backend, snapshots: [ViewGraphSnapshotter.NodeSnapshot]?,
        environment: EnvironmentValues) -> any ViewGraphNodeChildren { TableListChildren() }

    func layoutableChildren<Backend: BaseAppBackend>(backend: Backend, children: any ViewGraphNodeChildren) -> [LayoutSystem.LayoutableChild] { [] }

    func asWidget<Backend: BaseAppBackend>(_ children: any ViewGraphNodeChildren, backend: Backend) -> Backend.Widget {
        let widget = backend.createContainer()
        if let native = widget as? Gtk.Widget {
            let context = Unmanaged.passRetained(TableListSource(model)).toOpaque()
            sdbui_table_list_install(UnsafeMutableRawPointer(native.widgetPointer), context, tableSelected, destroyTableList)
        }
        return widget
    }

    func computeLayout<Backend: BaseAppBackend>(_ widget: Backend.Widget, children: any ViewGraphNodeChildren, proposedSize: ProposedViewSize,
        environment: EnvironmentValues, backend: Backend) -> ViewLayoutResult {
        .leafView(size: proposedSize.replacingUnspecifiedDimensions(by: ViewSize(200, 200)))
            .with(\.isNeverFocusable, false)
    }

    func commit<Backend: BaseAppBackend>(_ widget: Backend.Widget, children: any ViewGraphNodeChildren, layout: ViewLayoutResult,
        environment: EnvironmentValues, backend: Backend) {
        backend.setSize(of: widget, to: layout.size.vector)
        guard let native = widget as? Gtk.Widget,
              let context = sdbui_table_list_context(UnsafeMutableRawPointer(native.widgetPointer)) else { return }
        let source = Unmanaged<TableListSource>.fromOpaque(context).takeUnretainedValue()
        let replace = source.rows != rows
        source.rows = rows
        let selected = selection.flatMap { id in rows.firstIndex { $0.id == id } }.map(UInt32.init) ?? UInt32.max
        let pointer = UnsafeMutableRawPointer(native.widgetPointer)
        if replace {
            let labels = rows.map { strdup($0.label) }
            defer { labels.forEach { free($0) } }
            let strings = labels.map { $0.map { UnsafePointer($0) } } + [nil]
            strings.withUnsafeBufferPointer { buffer in
                sdbui_table_list_update(pointer, buffer.baseAddress, 1, selected, Int32(layout.size.width), Int32(layout.size.height))
            }
        } else {
            sdbui_table_list_update(pointer, nil, 0, selected, Int32(layout.size.width), Int32(layout.size.height))
        }
        native.sensitive = environment.isEnabled
    }
}
@MainActor
private final class TableListChildren: ViewGraphNodeChildren {
    var widgets: [AnyWidget] { [] }
    var erasedNodes: [ErasedViewGraphNode] { [] }
}
#endif
