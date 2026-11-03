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
            if let id = model.restorableProfileID { return id + " · Disconnected" }
            return "New connection"
        }
    }

    private(set) var tabs: [Tab] = []
    private(set) var selectedID: UUID
    @ObservationIgnored private let makeModel: @MainActor () -> BrowserModel
    @ObservationIgnored private var didLaunch = false
    @ObservationIgnored private let sessionStore: SessionStore?
    @ObservationIgnored private var loadedSession: WorkspaceSession?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private(set) var windowWidth = 1200
    @ObservationIgnored private(set) var windowHeight = 800
    private(set) var sessionFeedback = ""
    private(set) var pendingCloseID: UUID?

    @ObservationIgnored private let preferencesStore: PreferencesStore
    private(set) var preferences: AppPreferences
    var preferencesDraft: AppPreferences
    var preferencesVisible = false
    var preferencesFeedback = ""
    var canApplyPreferences: Bool { tabs.allSatisfy { !$0.model.isRunning && !$0.model.isConnecting } && preferencesDraft.isValid }
    func showPreferences() { preferencesDraft = preferences; preferencesVisible.toggle() }
    func applyPreferences() {
        guard canApplyPreferences else { return }
        do {
            try preferencesStore.save(preferencesDraft)
            preferences = preferencesDraft
            for tab in tabs { tab.model.applyPreferences(preferences) }
            preferencesFeedback = "Preferences saved."; preferencesVisible = false
            scheduleSessionSave()
        } catch { preferencesFeedback = "Could not save preferences: \(error.localizedDescription)" }
    }

    var pendingCloseTab: Tab? { tabs.first { $0.id == pendingCloseID } }


    init(sessionStore: SessionStore? = nil, preferencesStore: PreferencesStore = PreferencesStore(), makeModel: @escaping @MainActor () -> BrowserModel = { BrowserModel() }) {
        self.makeModel = makeModel
        self.preferencesStore = preferencesStore
        let storedPreferences = preferencesStore.load()
        self.preferences = storedPreferences
        self.preferencesDraft = storedPreferences
        self.preferencesFeedback = preferencesStore.loadError ?? ""
        self.sessionStore = sessionStore
        loadedSession = sessionStore?.load()
        windowWidth = loadedSession?.width ?? 1200
        windowHeight = loadedSession?.height ?? 800
        sessionFeedback = sessionStore?.loadError ?? ""
        let first = Tab(id: UUID(), model: makeModel())
        tabs = [first]
        selectedID = first.id
        attach(first.model)
    }

    var selectedTab: Tab { tabs.first { $0.id == selectedID }! }

    func launch() {
        guard !didLaunch else { return }
        didLaunch = true
        let environment = ProcessInfo.processInfo.environment
        if environment["SDBUI_PROFILE"] == nil, environment["SDBUI_SQL"] == nil, let session = loadedSession {
            tabs = session.tabs.map { state in
                let model = makeModel()
                model.reloadDiscovery()
                attach(model)
                model.restoreSession(state)
                return Tab(id: UUID(), model: model)
            }
            selectedID = tabs[session.selectedIndex].id
        } else {
            selectedTab.model.reloadDiscovery()
            selectedTab.model.applyLaunchEnvironment()
        }
        loadedSession = nil
        scheduleSessionSave()
    }

    private func attach(_ model: BrowserModel) {
        model.applyPreferences(preferences, refresh: false)
        model.sessionDidChange = { [weak self] in self?.scheduleSessionSave() }
    }

    func scheduleSessionSave() {
        guard didLaunch, sessionStore != nil else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            self?.saveSession()
        }
    }

    func saveSession() {
        guard didLaunch, let sessionStore else { return }
        saveTask?.cancel()
        saveTask = nil
        let index = tabs.firstIndex { $0.id == selectedID } ?? 0
        do {
            try sessionStore.save(WorkspaceSession(tabs: tabs.map { $0.model.sessionState },
                selectedIndex: index, width: windowWidth, height: windowHeight))
        } catch { sessionFeedback = "Session could not be saved: \(error.localizedDescription)" }
    }

    func updateWindowSize(width: Int, height: Int) {
        guard width >= 640, height >= 400, width <= 16384, height <= 16384,
              width != windowWidth || height != windowHeight else { return }
        windowWidth = width
        windowHeight = height
        scheduleSessionSave()
    }

    @discardableResult
    func addTab() -> UUID {
        let tab = Tab(id: UUID(), model: makeModel())
        tab.model.reloadDiscovery()
        attach(tab.model)
        tabs.append(tab)
        selectedID = tab.id
        scheduleSessionSave()
        return tab.id
    }

    func select(_ id: UUID) {
        guard id != selectedID, tabs.contains(where: { $0.id == id }) else { return }
        selectedID = id
        selectedTab.model.refreshQueryLibrary()
        scheduleSessionSave()
    }

    func close(_ id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        if tab.model.hasUnsavedSQL || tab.model.isRunning {
            pendingCloseID = id
            return
        }
        removeTab(id)
    }

    func cancelClose() { pendingCloseID = nil }
    func confirmClose() {
        guard let id = pendingCloseID else { return }
        pendingCloseID = nil
        removeTab(id)
    }

    private func removeTab(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs[index]
        tab.model.sessionDidChange = nil
        tab.model.detachViews()
        // Request cancellation before invalidating callbacks and releasing the session.
        tab.model.cancelQuery()
        tab.model.disconnect()
        tabs.remove(at: index)
        if tabs.isEmpty {
            let replacement = Tab(id: UUID(), model: makeModel())
            replacement.model.reloadDiscovery()
            attach(replacement.model)
            tabs = [replacement]
            selectedID = replacement.id
        } else if selectedID == id {
            selectedID = tabs[min(index, tabs.count - 1)].id
        }
        saveSession()
    }
}

struct ConnectionWorkspaceView: View {
    var workspace: ConnectionWorkspace
    @Environment(\.colorScheme) private var systemColorScheme
    private var appearance: ColorScheme {
        switch workspace.preferences.appearance {
        case .system:
            #if canImport(GtkBackend)
            return GTKAppearance.shared.systemDark ? .dark : .light
            #else
            return systemColorScheme
            #endif
        case .light: return .light
        case .dark: return .dark
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ScrollView(.horizontal) {
                    HStack(spacing: 4) {
                        ForEach(workspace.tabs, id: \.id) { tab in
                            HStack(spacing: 2) {
                                ConnectionTabButton(tab: tab, selected: tab.id == workspace.selectedID) { workspace.select(tab.id) }
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
                Button("Preferences") { workspace.showPreferences() }.fixedSize()
                Button("+ New connection") { workspace.addTab() }
                    .fixedSize()
            }
            .padding(8)
            Divider()
            if !workspace.sessionFeedback.isEmpty { Text(workspace.sessionFeedback).foregroundColor(.orange).padding(8) }
            if let tab = workspace.pendingCloseTab {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Close \(tab.title)?").font(.headline)
                    if tab.model.isRunning {
                        Text("A query is running. Closing this tab requests cancellation; statements already completed are not rolled back.")
                    }
                    if tab.model.hasUnsavedSQL {
                        Text("This connection has query tabs with SQL changes that have not been successfully run or saved as snippets.")
                    }
                    HStack {
                        Button("Keep tab open") { workspace.cancelClose() }
                        Button("Close tab") { workspace.confirmClose() }
                    }
                }
                .padding(8)
                Divider()
            }
            if workspace.preferencesVisible { PreferencesView(workspace: workspace); Divider() }
            ConnectionPages(tabs: workspace.tabs, selectedID: workspace.selectedID)
            .frame(maxHeight: .infinity)
        }
        .environment(\.colorScheme, appearance)
        .workspaceAppearance(workspace.preferences.appearance)
        .workspaceShortcuts(workspace)
        .persistingWorkspaceWindow(workspace)
    }
}

struct ConnectionTabButton: View {
    let tab: ConnectionWorkspace.Tab
    let selected: Bool
    let select: @MainActor @Sendable () -> Void
    @State private var revision = 0
    var body: some View {
        let _ = revision
        let _ = tab.model.watch("connection-tab-indicator", of: { [tab.model.isRunning, tab.model.isConnectionLost] }) { revision &+= 1 }
        HStack(spacing: 4) {
            if tab.model.isConnectionLost { Text("⚠ Lost").foregroundColor(.red).fontWeight(.bold).fixedSize() }
            else if tab.model.isRunning { Text("● Running").foregroundColor(.orange).font(.caption).fixedSize() }
            Button(tab.title, action: select)
                .buttonStyle(selected ? .bordered : .borderless)
                .fixedSize()
        }
    }
}
