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
            NavigationSplitView {
                SidebarView(model: model)
                    .frame(minWidth: 280)
            } detail: {
                QueryView(model: model)
            }
            .onAppear {
                model.reloadDiscovery()
                model.applyLaunchEnvironment()
            }
        }
        .defaultSize(width: 1200, height: 800)
    }
}
