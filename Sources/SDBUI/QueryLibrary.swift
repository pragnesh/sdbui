import ADBCKit
import CSQLite
import Foundation

enum QueryLibrarySection: String, CaseIterable {
    case history = "History"
    case snippets = "Snippets"
}

struct QueryHistoryEntry: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var sql: String
    var connection: String
    var date = Date()
    var duration: Double? = nil
    var rowCount: Int64? = nil
    var succeeded: Bool? = nil
}

extension QueryHistoryEntry {
    var outcomeLabel: String {
        var parts = [succeeded.map { $0 ? "✓ Succeeded" : "✗ Failed or cancelled" } ?? "Outcome unavailable"]
        if let duration { parts.append(String(format: "%.3f s", duration)) }
        if let rowCount { parts.append("\(rowCount.formatted()) rows") }
        return parts.joined(separator: " · ")
    }
}

struct QuerySnippet: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var sql: String
    var updated = Date()
}

struct QueryHistoryPage: Sendable {
    var entries: [QueryHistoryEntry] = []
    var hasMore = false
}

final class QuerySearchCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); defer { lock.unlock() }; cancelled = true }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

/// SQLite keeps a million queries on disk. Only a bounded page is decoded for
/// display, while WAL readers search independently of the foreground writer.
final class QueryLibraryStore: @unchecked Sendable {
    static let defaultHistoryLimit = 1_000_000
    static let historyPageSize = 100
    static var defaultURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        #if os(macOS)
        let base = home.appendingPathComponent("Library/Application Support")
        #else
        let xdg = ProcessInfo.processInfo.environment["XDG_DATA_HOME"] ?? ""
        let base = xdg.hasPrefix("/") ? URL(fileURLWithPath: xdg) : home.appendingPathComponent(".local/share")
        #endif
        return base.appendingPathComponent("sdbui/query-library.sqlite3")
    }

    private struct LegacyContents: Codable {
        var version: Int
        var history: [QueryHistoryEntry]
        var snippets: [QuerySnippet]
    }
    private let lock = NSRecursiveLock()
    private var database: OpaquePointer?
    let databaseURL: URL?
    private let historyLimit: Int
    private(set) var loadError: String?

    // Compatibility for consumers needing only the most recent page.
    var history: [QueryHistoryEntry] { (try? historyPage().entries) ?? [] }
    var historyCount: Int {
        lock.lock(); defer { lock.unlock() }
        return Int((try? scalar("SELECT value FROM library_meta WHERE key='history_count'")) ?? 0)
    }
    var snippets: [QuerySnippet] {
        lock.lock(); defer { lock.unlock() }
        guard let statement = try? prepare("SELECT id,name,sql,updated FROM snippets ORDER BY rowid DESC") else { return [] }
        defer { sqlite3_finalize(statement) }
        var result: [QuerySnippet] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let id = UUID(uuidString: text(statement, 0)) {
                result.append(.init(id: id, name: text(statement, 1), sql: text(statement, 2), updated: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))))
            }
        }
        return result
    }

    init(url: URL? = QueryLibraryStore.defaultURL, historyLimit: Int = QueryLibraryStore.defaultHistoryLimit) {
        self.historyLimit = max(1, historyLimit)
        self.databaseURL = url?.pathExtension == "json" ? url?.deletingPathExtension().appendingPathExtension("sqlite3") : url
        do {
            if let databaseURL {
                let parent = databaseURL.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                if !FileManager.default.fileExists(atPath: databaseURL.path) {
                    guard FileManager.default.createFile(atPath: databaseURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                        throw ADBCError("Could not create the query library.")
                    }
                }
            }
            guard sqlite3_open_v2(databaseURL?.path ?? ":memory:", &database,
                SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw failure() }
            sqlite3_busy_timeout(database, 2000)
            let version = try scalar("PRAGMA user_version")
            guard (0...2).contains(version) else { throw ADBCError("Unsupported query library version.") }
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA synchronous=NORMAL")
            try transaction {
                try execute("CREATE TABLE IF NOT EXISTS history (seq INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL UNIQUE, sql TEXT NOT NULL, connection TEXT NOT NULL, date REAL NOT NULL)")
                try execute("CREATE TABLE IF NOT EXISTS snippets (id TEXT PRIMARY KEY, name TEXT NOT NULL, sql TEXT NOT NULL, updated REAL NOT NULL)")
                try execute("CREATE TABLE IF NOT EXISTS library_meta (key TEXT PRIMARY KEY, value INTEGER NOT NULL)")
                try execute("CREATE TABLE IF NOT EXISTS drafts (connection TEXT PRIMARY KEY, sql TEXT NOT NULL, updated REAL NOT NULL)")
                if try scalar("SELECT count(*) FROM library_meta WHERE key='history_count'") == 0 {
                    try execute("INSERT INTO library_meta VALUES ('history_count', (SELECT count(*) FROM history))")
                }
                try execute("CREATE TRIGGER IF NOT EXISTS history_added AFTER INSERT ON history BEGIN UPDATE library_meta SET value=value+1 WHERE key='history_count'; END")
                try execute("CREATE TRIGGER IF NOT EXISTS history_deleted AFTER DELETE ON history BEGIN UPDATE library_meta SET value=value-1 WHERE key='history_count'; END")
                if version < 2 {
                    try execute("ALTER TABLE history ADD COLUMN duration REAL")
                    try execute("ALTER TABLE history ADD COLUMN row_count INTEGER")
                    try execute("ALTER TABLE history ADD COLUMN succeeded INTEGER")
                }
                try execute("CREATE TABLE IF NOT EXISTS pinned_tables (connection TEXT NOT NULL, table_id TEXT NOT NULL, PRIMARY KEY(connection,table_id))")
                try execute("CREATE INDEX IF NOT EXISTS history_connection ON history(connection,seq DESC)")
                try execute("PRAGMA user_version=2")
            }
            let legacy = url?.pathExtension == "json" ? url : databaseURL?.deletingPathExtension().appendingPathExtension("json")
            if try scalar("SELECT count(*) FROM library_meta WHERE key='legacy_imported'") == 0 {
                var imported: LegacyContents?
                if let legacy, FileManager.default.fileExists(atPath: legacy.path) {
                    let loaded = try JSONDecoder().decode(LegacyContents.self, from: Data(contentsOf: legacy))
                    guard loaded.version == 1 else { throw ADBCError("Unsupported legacy query library version.") }
                    guard Set(loaded.history.map(\.id)).count == loaded.history.count,
                          Set(loaded.snippets.map(\.id)).count == loaded.snippets.count else {
                        throw ADBCError("Legacy query library contains duplicate identifiers.")
                    }
                    imported = loaded
                }
                try transaction {
                    if let imported {
                        for entry in imported.history.reversed() { try insertHistory(entry) }
                        for snippet in imported.snippets.reversed() {
                            try execute("INSERT OR IGNORE INTO snippets VALUES (?,?,?,?)", [snippet.id.uuidString, snippet.name, snippet.sql, String(snippet.updated.timeIntervalSince1970)])
                        }
                    }
                    try trimHistory()
                    try execute("INSERT INTO library_meta VALUES ('legacy_imported',1)")
                }
            }
        } catch {
            loadError = "Could not open the query library. Existing data has been preserved: \(error)"
        }
    }

    deinit { sqlite3_close(database) }

    @discardableResult
    func record(sql: String, connection: String) throws -> UUID? {
        guard !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        lock.lock(); defer { lock.unlock() }
        try writable()
        let entry = QueryHistoryEntry(sql: sql, connection: connection)
        try transaction {
            try insertHistory(entry)
            try trimHistory()
        }
        return entry.id
    }

    func completeHistory(_ id: UUID, duration: Double, rowCount: Int64?, succeeded: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        try writable()
        try execute("UPDATE history SET duration=?,row_count=?,succeeded=? WHERE id=?",
            [String(max(0, duration)), rowCount.map(String.init), succeeded ? "1" : "0", id.uuidString])
    }

    /// Search is cancellable and bounded. Disk libraries use a separate WAL
    /// reader so a long search never holds the UI's history-writing lock.
    func historyPage(matching search: String = "", offset: Int = 0, limit: Int = QueryLibraryStore.historyPageSize,
                     cancellation: QuerySearchCancellation? = nil, connection: String? = nil) throws -> QueryHistoryPage {
        if let loadError { throw ADBCError(loadError) }
        var reader: OpaquePointer?
        if let databaseURL {
            guard sqlite3_open_v2(databaseURL.path, &reader, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
                sqlite3_close(reader)
                throw ADBCError("Could not read query history.")
            }
            sqlite3_busy_timeout(reader, 2000)
        } else {
            lock.lock()
            reader = database
        }
        defer {
            if databaseURL != nil { sqlite3_close(reader) } else { lock.unlock() }
        }
        if let cancellation {
            sqlite3_progress_handler(reader, 1000, { pointer in
                guard let pointer else { return 0 }
                return Unmanaged<QuerySearchCancellation>.fromOpaque(pointer).takeUnretainedValue().isCancelled ? 1 : 0
            }, Unmanaged.passUnretained(cancellation).toOpaque())
        }
        defer {
            sqlite3_progress_handler(reader, 0, nil, nil)
            withExtendedLifetime(cancellation) {}
        }
        guard cancellation?.isCancelled != true else { throw CancellationError() }
        let pageSize = min(max(1, limit), Self.historyPageSize)
        var conditions: [String] = []
        if !search.isEmpty { conditions.append("(sql LIKE ? ESCAPE '\\' OR connection LIKE ? ESCAPE '\\')") }
        if connection != nil { conditions.append("connection = ?") }
        let filter = conditions.isEmpty ? "" : " WHERE " + conditions.joined(separator: " AND ")
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(reader, "SELECT id,sql,connection,date,duration,row_count,succeeded FROM history\(filter) ORDER BY seq DESC LIMIT ? OFFSET ?", -1, &statement, nil) == SQLITE_OK else {
            throw ADBCError("Could not prepare query-history search.")
        }
        defer { sqlite3_finalize(statement) }
        var index: Int32 = 1
        if !search.isEmpty {
            let escaped = "%" + search.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") + "%"
            bind(escaped, to: statement, at: 1); bind(escaped, to: statement, at: 2)
            index = 3
        }
        if let connection { bind(connection, to: statement, at: index); index += 1 }
        sqlite3_bind_int64(statement, index, Int64(pageSize + 1))
        sqlite3_bind_int64(statement, index + 1, Int64(max(0, offset)))
        var entries: [QueryHistoryEntry] = []
        var code = sqlite3_step(statement)
        while code == SQLITE_ROW {
            guard let id = UUID(uuidString: text(statement, 0)) else { throw ADBCError("Invalid query-history identifier.") }
            entries.append(.init(id: id, sql: text(statement, 1), connection: text(statement, 2), date: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                duration: sqlite3_column_type(statement, 4) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 4),
                rowCount: sqlite3_column_type(statement, 5) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, 5),
                succeeded: sqlite3_column_type(statement, 6) == SQLITE_NULL ? nil : sqlite3_column_int(statement, 6) != 0))
            code = sqlite3_step(statement)
        }
        if code == SQLITE_INTERRUPT { throw CancellationError() }
        guard code == SQLITE_DONE else { throw ADBCError("Could not read query-history search results.") }
        return QueryHistoryPage(entries: Array(entries.prefix(pageSize)), hasMore: entries.count > pageSize)
    }

    func pinnedTables(connection: String) -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        guard let statement = try? prepare("SELECT table_id FROM pinned_tables WHERE connection=?") else { return [] }
        defer { sqlite3_finalize(statement) }
        bind(connection, to: statement, at: 1)
        var result: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW { result.insert(text(statement, 0)) }
        return result
    }
    func setTablePinned(_ table: String, connection: String, pinned: Bool) throws {
        lock.lock(); defer { lock.unlock() }; try writable()
        try execute(pinned ? "INSERT OR IGNORE INTO pinned_tables VALUES (?,?)" : "DELETE FROM pinned_tables WHERE connection=? AND table_id=?",
            [connection, table])
    }

    func deleteHistory(_ id: UUID) throws {
        lock.lock(); defer { lock.unlock() }; try writable()
        try execute("DELETE FROM history WHERE id=?", [id.uuidString])
    }
    func clearHistory() throws {
        lock.lock(); defer { lock.unlock() }; try writable()
        try transaction { try execute("DELETE FROM history") }
    }
    @discardableResult
    func saveSnippet(id: UUID? = nil, name: String, sql: String) throws -> UUID {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ADBCError("Enter a snippet name.") }
        guard !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ADBCError("Enter SQL before saving a snippet.") }
        lock.lock(); defer { lock.unlock() }; try writable()
        if let id {
            try execute("UPDATE snippets SET name=?,sql=?,updated=? WHERE id=?", [name, sql, String(Date().timeIntervalSince1970), id.uuidString])
            guard sqlite3_changes(database) > 0 else { throw ADBCError("This snippet no longer exists. Select New snippet.") }
            return id
        }
        let id = UUID()
        try execute("INSERT INTO snippets VALUES (?,?,?,?)", [id.uuidString, name, sql, String(Date().timeIntervalSince1970)])
        return id
    }
    func deleteSnippet(_ id: UUID) throws {
        lock.lock(); defer { lock.unlock() }; try writable()
        try execute("DELETE FROM snippets WHERE id=?", [id.uuidString])
    }

    /// The editor text last left in `connection`, restored when it's opened again.
    func draft(for connection: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard loadError == nil, let statement = try? prepare("SELECT sql FROM drafts WHERE connection=?") else { return nil }
        defer { sqlite3_finalize(statement) }
        bind(connection, to: statement, at: 1)
        return sqlite3_step(statement) == SQLITE_ROW ? text(statement, 0) : nil
    }
    /// Saving blank text forgets the draft.
    func saveDraft(_ sql: String, for connection: String) throws {
        lock.lock(); defer { lock.unlock() }; try writable()
        if sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try execute("DELETE FROM drafts WHERE connection=?", [connection])
        } else {
            try execute("INSERT OR REPLACE INTO drafts VALUES (?,?,?)", [connection, sql, String(Date().timeIntervalSince1970)])
        }
    }

    private func trimHistory() throws {
        let overflow = try scalar("SELECT value FROM library_meta WHERE key='history_count'") - Int64(historyLimit)
        if overflow > 0 { try execute("DELETE FROM history WHERE seq IN (SELECT seq FROM history ORDER BY seq LIMIT ?)", [String(overflow)]) }
    }
    private func insertHistory(_ entry: QueryHistoryEntry) throws {
        try execute("INSERT OR IGNORE INTO history (id,sql,connection,date) VALUES (?,?,?,?)", [entry.id.uuidString, entry.sql, entry.connection, String(entry.date.timeIntervalSince1970)])
    }
    private func writable() throws { if let loadError { throw ADBCError(loadError) } }
    private func failure() -> ADBCError { ADBCError(database.map { String(cString: sqlite3_errmsg($0)) } ?? "Could not open SQLite.") }
    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw failure() }
        return statement
    }
    private func bind(_ value: String, to statement: OpaquePointer?, at index: Int32) {
        _ = value.withCString { sqlite3_bind_text(statement, index, $0, Int32(value.utf8.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
    }
    private func text(_ statement: OpaquePointer?, _ column: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, column) else { return "" }
        return String(decoding: UnsafeBufferPointer(start: pointer, count: Int(sqlite3_column_bytes(statement, column))), as: UTF8.self)
    }
    private func execute(_ sql: String, _ values: [String?] = []) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() {
            if let value { bind(value, to: statement, at: Int32(index + 1)) }
            else { sqlite3_bind_null(statement, Int32(index + 1)) }
        }
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else { throw failure() }
    }
    private func scalar(_ sql: String) throws -> Int64 {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        let code = sqlite3_step(statement)
        guard code == SQLITE_ROW else { throw failure() }
        return sqlite3_column_int64(statement, 0)
    }
    private func transaction(_ action: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do { try action(); try execute("COMMIT") }
        catch { try? execute("ROLLBACK"); throw error }
    }
}
