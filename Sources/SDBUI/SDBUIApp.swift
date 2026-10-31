#if canImport(GtkBackend)
    import GtkBackend
#else
    import DefaultBackend
#endif
import Foundation
import SwiftCrossUI

@main
struct SDBUIApp: App {
    @State var workspace = ConnectionWorkspace()

    #if canImport(GtkBackend)
        /// GTK hands a second launch with the same ID to the running instance;
        /// `SDBUI_APP_ID` lets a separate copy run (e.g. for profiling).
        var backend: GtkBackend {
            GtkBackend(
                appIdentifier: ProcessInfo.processInfo.environment["SDBUI_APP_ID"]
                    ?? "dev.sdbui.QueryBrowser")
        }
    #endif

    var body: some Scene {
        WindowGroup("SDB Query Browser") {
            ConnectionWorkspaceView(workspace: workspace)
                .onAppear { workspace.launch() }
        }
        .defaultSize(width: 1200, height: 800)
    }
}

/// Switches between the connection screen and the connected main window.
struct RootView: View {
    var model: BrowserModel

    var body: some View {
        if model.connection == nil {
            DisconnectedView(model: model)
        } else {
            MainWindow(model: model)
        }
    }
}

extension NavigationSplitView {
    /// Give extra window width to the detail pane instead of sharing it with
    /// the sidebar (GTK's default for a `Paned`). The divider stays draggable.
    @ViewBuilder
    func keepingSidebarWidthOnResize() -> some View {
        #if canImport(GtkBackend)
            inspect { paned in
                paned.resizeStartChild = false
            }
        #else
            self
        #endif
    }
}
