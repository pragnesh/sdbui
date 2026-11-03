import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

struct SessionTabState: Codable, Equatable {
    var favoriteID: String?
    var sql = ""
    var dirty = false
    var database: String?
    var table: SessionTableState?
    var pane = BrowserTab.query.rawValue
    var fontSize = 13.0
    var sidebarWidth = 290
    var queries: [QueryDraftState]? = nil
    var selectedQueryID: UUID? = nil
}

struct SessionTableState: Codable, Equatable {
    var catalog: String?
    var schema: String?
    var name: String
}

struct WorkspaceSession: Codable, Equatable {
    var version = 1
    var tabs: [SessionTabState]
    var selectedIndex = 0
    var width = 1200
    var height = 800
}

/// Private UI state, never connection URIs, passwords, SSH settings, or results.
final class SessionStore {
    static var defaultURL: URL {
        QueryLibraryStore.defaultURL.deletingLastPathComponent().appendingPathComponent("session.json")
    }
    let url: URL
    private(set) var loadError: String?
    init(url: URL = SessionStore.defaultURL) { self.url = url }

    func load() -> WorkspaceSession? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let state = try JSONDecoder().decode(WorkspaceSession.self, from: Data(contentsOf: url))
            guard state.version == 1, !state.tabs.isEmpty, state.tabs.count <= 1000,
                  state.tabs.indices.contains(state.selectedIndex),
                  (640...16384).contains(state.width), (400...16384).contains(state.height),
                  state.tabs.allSatisfy({ tab in
                      (9...28).contains(tab.fontSize) && (180...4000).contains(tab.sidebarWidth)
                      && (tab.queries.map { queries in
                          !queries.isEmpty && queries.count <= 1000 && Set(queries.map(\.id)).count == queries.count
                          && (tab.selectedQueryID == nil || queries.contains { $0.id == tab.selectedQueryID })
                      } ?? (tab.selectedQueryID == nil))
                  }) else {
                throw NSError(domain: "SDBUI.Session", code: 1)
            }
            return state
        } catch {
            loadError = "Session could not be restored. The original session file has been preserved."
            return nil
        }
    }

    func save(_ state: WorkspaceSession) throws {
        guard loadError == nil else { return } // Never overwrite corrupt or newer state.
        let directory = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let temporary = directory.appendingPathComponent(".session-\(UUID().uuidString).tmp")
        let data = try JSONEncoder().encode(state)
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw NSError(domain: "SDBUI.Session", code: 2)
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard rename(temporary.path, url.path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }
}
