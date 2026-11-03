import SwiftCrossUI
#if canImport(GtkBackend)
import GtkBackend
import CResultValue

@MainActor
private final class LayoutSource {
    weak var workspace: ConnectionWorkspace?
    weak var model: BrowserModel?
    init(workspace: ConnectionWorkspace? = nil, model: BrowserModel? = nil) {
        self.workspace = workspace; self.model = model
    }
}
private let layoutChanged: SDBUILayoutChange = { context, width, height, final in
    MainActor.assumeIsolated {
        guard let context else { return }
        let source = Unmanaged<LayoutSource>.fromOpaque(context).takeUnretainedValue()
        source.workspace?.updateWindowSize(width: Int(width), height: Int(height))
        source.model?.updateSidebarWidth(Int(width))
        if final != 0 { source.workspace?.saveSession() }
    }
}
private let destroyLayout: SDBUIValueDestroy = { context in
    if let context { Unmanaged<LayoutSource>.fromOpaque(context).release() }
}
#endif

extension View {
    @ViewBuilder
    func persistingWorkspaceWindow(_ workspace: ConnectionWorkspace) -> some View {
        #if canImport(GtkBackend)
        inspect { widget in
            let source = Unmanaged.passRetained(LayoutSource(workspace: workspace)).toOpaque()
            sdbui_session_window(UnsafeMutableRawPointer(widget.widgetPointer), source, layoutChanged, destroyLayout)
        }
        #else
        self
        #endif
    }

}

extension NavigationSplitView {
    @ViewBuilder
    func persistingSidebar(_ model: BrowserModel) -> some View {
        #if canImport(GtkBackend)
        inspect { widget in
            widget.resizeStartChild = false
            let source = Unmanaged.passRetained(LayoutSource(model: model)).toOpaque()
            sdbui_session_sidebar(UnsafeMutableRawPointer(widget.widgetPointer), Int32(model.sidebarWidth), source, layoutChanged, destroyLayout)
        }
        #elseif canImport(AppKitBackend)
        persistingMacSidebar(model)
        #else
        self
        #endif
    }
}
