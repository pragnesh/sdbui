#if canImport(GtkBackend)
    import GtkBackend
#else
    import DefaultBackend
#endif
import SwiftCrossUI

@main
struct SDBUIApp: App {
    @State var model = BrowserModel()

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
            }
        }
        .defaultSize(width: 1200, height: 800)
    }
}
