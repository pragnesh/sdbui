import Foundation
import SwiftCrossUI
#if canImport(GtkBackend)
import GtkBackend
#endif

#if canImport(Observation)
    import Observation
#endif

/// Owns independent database sessions; switching tabs never replaces a session.
@Observable
@MainActor
final class ConnectionWorkspace {
    struct Tab: Identifiable {
        let id: UUID
        let model: BrowserModel

        @MainActor var title: String {
            if model.connection != nil { return model.connectionTitle }
            if model.isConnecting { return "Connecting…" }
            return "New connection"
        }
    }

    private(set) var tabs: [Tab] = []
    private(set) var selectedID: UUID
    @ObservationIgnored private let makeModel: @MainActor () -> BrowserModel
    @ObservationIgnored private var didLaunch = false

    init(makeModel: @escaping @MainActor () -> BrowserModel = { BrowserModel() }) {
        self.makeModel = makeModel
        let first = Tab(id: UUID(), model: makeModel())
        tabs = [first]
        selectedID = first.id
    }

    var selectedTab: Tab { tabs.first { $0.id == selectedID }! }

    func launch() {
        guard !didLaunch else { return }
        didLaunch = true
        selectedTab.model.reloadDiscovery()
        selectedTab.model.applyLaunchEnvironment()
    }

    @discardableResult
    func addTab() -> UUID {
        let tab = Tab(id: UUID(), model: makeModel())
        tab.model.reloadDiscovery()
        tabs.append(tab)
        selectedID = tab.id
        return tab.id
    }

    func select(_ id: UUID) {
        guard id != selectedID, tabs.contains(where: { $0.id == id }) else { return }
        selectedID = id
        selectedTab.model.refreshQueryLibrary()
    }

    func close(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs[index]
        tab.model.detachViews()
        // Request cancellation before invalidating callbacks and releasing the session.
        tab.model.cancelQuery()
        tab.model.disconnect()
        tabs.remove(at: index)
        if tabs.isEmpty {
            let replacement = Tab(id: UUID(), model: makeModel())
            replacement.model.reloadDiscovery()
            tabs = [replacement]
            selectedID = replacement.id
        } else if selectedID == id {
            selectedID = tabs[min(index, tabs.count - 1)].id
        }
    }
}

struct ConnectionWorkspaceView: View {
    var workspace: ConnectionWorkspace

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ScrollView(.horizontal) {
                    HStack(spacing: 4) {
                        ForEach(workspace.tabs, id: \.id) { tab in
                            HStack(spacing: 2) {
                                Button(tab.title + (tab.model.isConnectionLost ? " · Lost" : "")) {
                                    workspace.select(tab.id)
                                }
                                .buttonStyle(tab.id == workspace.selectedID ? .bordered : .borderless)
                                .fixedSize()
                                Button(action: { workspace.close(tab.id) }) {
                                    #if canImport(GtkBackend)
                                        Text("×").inspect { label in
                                            // Ellipsizing gives this one-character label
                                            // a minimum wider than its natural width.
                                            label.ellipsize = .none
                                        }
                                    #else
                                        Text("×")
                                    #endif
                                }
                                    .buttonStyle(.borderless)
                                    .fixedSize()
                            }
                        }
                    }
                }
                Button("+ New connection") { workspace.addTab() }
                    .fixedSize()
            }
            .padding(8)
            Divider()
            ConnectionPages(tabs: workspace.tabs, selectedID: workspace.selectedID)
            .frame(maxHeight: .infinity)
        }
        .workspaceShortcuts(workspace)
    }
}
