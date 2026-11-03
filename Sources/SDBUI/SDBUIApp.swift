#if canImport(GtkBackend)
    import GtkBackend
#elseif canImport(AppKitBackend)
    import AppKitBackend
#else
    import DefaultBackend
#endif
import ADBCKit
import Foundation
import SwiftCrossUI

@main
struct SDBUIApp: App {
    @State var workspace = ConnectionWorkspace(sessionStore: SessionStore())

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
        .defaultSize(width: workspace.windowWidth, height: workspace.windowHeight)
    }
}

/// Switches between the connection screen and the connected main window.
struct RootView: View {
    var model: BrowserModel

    var body: some View {
        VStack(spacing: 0) {
            if let scan = model.hostKeyPrompt {
                HStack {
                    HostKeyPrompt(model: model, scan: scan)
                    Spacer()
                }
                Divider()
            }
            if model.connection == nil {
                DisconnectedView(model: model)
            } else {
                MainWindow(model: model)
            }
        }
    }
}

/// Asks whether to trust an SSH server's unknown host key, like OpenSSH's
/// "authenticity of host can't be established" question.
struct HostKeyPrompt: View {
    var model: BrowserModel
    var scan: SSHHostKeyScan

    var body: some View {
        let port = scan.port == 22 ? "" : " port \(scan.port)"
        let address = scan.hostName == scan.host ? "" : " (\(scan.hostName))"
        VStack(alignment: .leading, spacing: 8) {
            Text("The authenticity of SSH host \(scan.host)\(address)\(port) can't be established.")
                .font(.headline)
            Text("Its host key isn't in \(scan.knownHostsFile) yet. Compare the fingerprint with the one the server's administrator gives you; trust it only if they match.")
            Text(scan.fingerprints.joined(separator: "\n"))
                .font(.system(size: 12, design: .monospaced))
                .textSelectionEnabled()
            HStack {
                Button("Trust and connect") { model.trustHostKey() }
                    .fixedSize()
                Button("Cancel") { model.dismissHostKeyPrompt() }
                    .fixedSize()
            }
        }
        .padding(8)
    }
}

extension NavigationSplitView {
    /// Give extra window width to the detail pane instead of sharing it with
    /// the sidebar (GTK's default for a `Paned`). The divider stays draggable.
    @ViewBuilder
    func keepingSidebarWidthOnResize(model: BrowserModel) -> some View {
        #if canImport(GtkBackend) || canImport(AppKitBackend)
            persistingSidebar(model)
        #else
            self
        #endif
    }
}
