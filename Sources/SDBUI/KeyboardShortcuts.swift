import Foundation
import SwiftCrossUI

/// Shared command routing; native key handling never touches background sessions.
enum WorkspaceShortcut: Int32 {
    case newTab = 1, closeTab, nextTab, previousTab, tableFilter, editor, cancel, refresh
    case previousPage, nextPage, largerFont, smallerFont
}

extension ConnectionWorkspace {
    @discardableResult
    func performShortcut(_ code: Int32) -> Bool {
        if (101...109).contains(code) {
            let index = code == 109 ? tabs.count - 1 : Int(code - 101)
            if tabs.indices.contains(index) { select(tabs[index].id) }
            return true
        }
        guard let command = WorkspaceShortcut(rawValue: code) else { return false }
        let model = selectedTab.model
        switch command {
        case .newTab: addTab()
        case .closeTab: close(selectedID)
        case .nextTab, .previousTab:
            guard let index = tabs.firstIndex(where: { $0.id == selectedID }) else { return false }
            let delta = command == .nextTab ? 1 : -1
            select(tabs[(index + delta + tabs.count) % tabs.count].id)
        case .tableFilter: return model.canUseConnection
        case .editor:
            guard model.connection != nil else { return false }
            model.selectTab(.query)
        case .cancel:
            if model.pendingQuery != nil { model.cancelPendingQuery() }
            else if model.isRunning { model.cancelQuery() }
            else { return false }
        case .refresh:
            if model.connection == nil { model.reloadDiscovery() }
            else { model.refreshActiveView() }
        case .previousPage, .nextPage:
            guard model.canUseConnection, !model.isRunning, model.isBrowsing, model.selectedTab == .query else { return true }
            let next = command == .nextPage
            if next ? model.contentHasMore : model.contentOffset > 0 { model.showContentPage(next: next) }
        case .largerFont: model.adjustQueryFontSize(by: 1)
        case .smallerFont: model.adjustQueryFontSize(by: -1)
        }
        return true
    }
}

#if canImport(GtkBackend)
import CResultValue
import GtkBackend

@MainActor
private final class ShortcutSource {
    weak var workspace: ConnectionWorkspace?
    init(_ workspace: ConnectionWorkspace) { self.workspace = workspace }
}

private let shortcutAction: SDBUIShortcutAction = { context, code in
    MainActor.assumeIsolated {
        guard let context else { return 0 }
        let source = Unmanaged<ShortcutSource>.fromOpaque(context).takeUnretainedValue()
        return source.workspace?.performShortcut(code) == true ? 1 : 0
    }
}
private let destroyShortcutSource: SDBUIValueDestroy = { context in
    if let context { Unmanaged<ShortcutSource>.fromOpaque(context).release() }
}
#endif

extension View {
    @ViewBuilder
    func workspaceShortcuts(_ workspace: ConnectionWorkspace) -> some View {
        #if canImport(GtkBackend)
        inspect { widget in
            let context = Unmanaged.passRetained(ShortcutSource(workspace)).toOpaque()
            sdbui_shortcuts_install(UnsafeMutableRawPointer(widget.widgetPointer), context, shortcutAction, destroyShortcutSource)
        }
        #else
        self
        #endif
    }

    @ViewBuilder
    func queryGridFontSize(_ size: Double) -> some View {
        #if canImport(GtkBackend)
        inspect([.onCreate, .afterUpdate]) { widget in
            sdbui_grid_font_size(UnsafeMutableRawPointer(widget.widgetPointer), Int32(size))
        }
        #else
        font(.system(size: size))
        #endif
    }

    @ViewBuilder
    func shortcutFocusTarget(_ name: String) -> some View {
        #if canImport(GtkBackend)
        inspect { widget in sdbui_shortcut_target(UnsafeMutableRawPointer(widget.widgetPointer), name) }
        #else
        self
        #endif
    }
}
