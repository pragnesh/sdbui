#if canImport(GtkBackend)
    import GtkBackend
#else
    import DefaultBackend
#endif
import Foundation
import SwiftCrossUI

@main
struct SDBUIApp: App {
    @State var model = BrowserModel()

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
            // Each pane sits in a GeometryReader, which is exactly the size
            // it's offered, so a pane's content changing size re-lays-out
            // only that pane.
            NavigationSplitView {
                GeometryReader { _ in
                    SidebarView(model: model)
                }
                .frame(minWidth: 280)
            } detail: {
                GeometryReader { _ in
                    QueryView(model: model)
                }
            }
            .onAppear {
                model.reloadDiscovery()
                model.applyLaunchEnvironment()
            }
        }
        .defaultSize(width: 1200, height: 800)
    }
}
