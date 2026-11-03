import Foundation
import SwiftCrossUI
#if os(Linux)
import Glibc
#else
import Darwin
#endif

struct AppPreferences: Codable, Equatable {
    enum Appearance: String, Codable, CaseIterable { case system = "System", light = "Light", dark = "Dark" }
    static let pageSizes = [50, 100, 250, 500, 1000, 5000, 10000]
    static let rowLimits = [100, 1000, 10000, 100000, 1000000]
    static let fontSizes = Array(9...28)
    var pageSize = 1000
    var fontSize = 13
    var rowLimit = 10000
    var appearance = Appearance.system
    var isValid: Bool { Self.pageSizes.contains(pageSize) && Self.fontSizes.contains(fontSize) && Self.rowLimits.contains(rowLimit) }
}

/// Preferences contain UI choices only; corrupt files are preserved for recovery.
final class PreferencesStore {
    static var defaultURL: URL { QueryLibraryStore.defaultURL.deletingLastPathComponent().appendingPathComponent("preferences.json") }
    let url: URL?
    private(set) var loadError: String?
    init(url: URL? = PreferencesStore.defaultURL) { self.url = url }
    func load() -> AppPreferences {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return AppPreferences() }
        do {
            let value = try JSONDecoder().decode(AppPreferences.self, from: Data(contentsOf: url))
            guard value.isValid else { throw NSError(domain: "SDBUI.Preferences", code: 1) }
            return value
        } catch {
            loadError = "Preferences could not be read. Defaults are in use; the original file is preserved."
            return AppPreferences()
        }
    }
    func save(_ value: AppPreferences) throws {
        guard value.isValid else { throw NSError(domain: "SDBUI.Preferences", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid preferences."]) }
        guard loadError == nil else { throw NSError(domain: "SDBUI.Preferences", code: 3, userInfo: [NSLocalizedDescriptionKey: loadError!]) }
        guard let url else { return }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = directory.appendingPathComponent(".preferences-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let data = try JSONEncoder().encode(value)
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw NSError(domain: "SDBUI.Preferences", code: 4)
        }
        guard rename(temporary.path, url.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }
}

struct PreferencesView: View {
    var workspace: ConnectionWorkspace
    @State private var revision = 0
    var body: some View {
        let _ = revision
        let _ = workspace.tabs.map { tab in
            tab.model.watch("preferences-busy", of: { [tab.model.isRunning, tab.model.isConnecting] }) { revision &+= 1 }
        }
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Preferences").font(.headline)
                Text("Defaults apply to new connections; applying updates all open connections.").font(.caption)
                Spacer()
            }
            HStack {
                Text("Rows per page")
                Picker(of: AppPreferences.pageSizes, selection: Binding(get: { Optional(workspace.preferencesDraft.pageSize) }, set: { if let value = $0 { workspace.preferencesDraft.pageSize = value } })).frame(width: 100)
                Text("SQL/grid font size")
                Picker(of: AppPreferences.fontSizes, selection: Binding(get: { Optional(workspace.preferencesDraft.fontSize) }, set: { if let value = $0 { workspace.preferencesDraft.fontSize = value } })).frame(width: 80)
                Text("Query row limit")
                Picker(of: AppPreferences.rowLimits, selection: Binding(get: { Optional(workspace.preferencesDraft.rowLimit) }, set: { if let value = $0 { workspace.preferencesDraft.rowLimit = value } })).frame(width: 130)
                Text("Appearance")
                Picker(of: AppPreferences.Appearance.allCases, selection: Binding(get: { Optional(workspace.preferencesDraft.appearance) }, set: { if let value = $0 { workspace.preferencesDraft.appearance = value } })).frame(width: 110)
            }
            HStack {
                Button("Reset defaults") { workspace.preferencesDraft = AppPreferences() }.fixedSize()
                Button("Cancel preferences") { workspace.preferencesVisible = false }.fixedSize()
                Button("Apply preferences") { workspace.applyPreferences() }.disabled(!workspace.canApplyPreferences).fixedSize()
                Text(workspace.canApplyPreferences ? "Page-size changes reload table browsing from page 1." : "Wait for connections and queries to finish before applying.").font(.caption)
                Spacer()
            }
            if !workspace.preferencesFeedback.isEmpty { Text(workspace.preferencesFeedback).foregroundColor(.orange) }
        }.padding(8)
    }
}
