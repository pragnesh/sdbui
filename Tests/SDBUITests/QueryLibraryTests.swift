import ADBCKit
import CSQLite
import Foundation
import SwiftCrossUI
import XCTest
@testable import SDBUI

final class QueryLibraryStoreTests: XCTestCase {
    func testHistoryPersistsExactlyAndIsBounded() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("query-library.sqlite3")
        let store = QueryLibraryStore(url: url, historyLimit: 2)
        try store.record(sql: "SELECT 0", connection: "local")
        try store.record(sql: "SELECT 'é\\n'\n-- multiline SQL", connection: "Work/Test")
        try store.record(sql: "SELECT 2;", connection: "other")
        try store.record(sql: " \n ", connection: "empty")
        let restored = QueryLibraryStore(url: url, historyLimit: 2)
        XCTAssertNil(restored.loadError)
        XCTAssertEqual(restored.history.map(\.sql), ["SELECT 2;", "SELECT 'é\\n'\n-- multiline SQL"])
        XCTAssertEqual(restored.history.last?.connection, "Work/Test")
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        try restored.deleteHistory(restored.history[0].id)
        XCTAssertEqual(QueryLibraryStore(url: url).history.count, 1)
        try restored.clearHistory()
        XCTAssertTrue(QueryLibraryStore(url: url).history.isEmpty)
    }

    func testSnippetCreateUpdateDeleteAndHistoryAreIndependent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("library.sqlite3")
        let store = QueryLibraryStore(url: url)
        try store.record(sql: "SELECT 1", connection: "local")
        let id = try store.saveSnippet(name: " Daily report ", sql: "SELECT 'original'\n-- comment")
        XCTAssertEqual(store.snippets.first?.name, "Daily report")
        let restored = QueryLibraryStore(url: url)
        XCTAssertEqual(restored.snippets.first?.sql, "SELECT 'original'\n-- comment")
        XCTAssertEqual(try restored.saveSnippet(id: id, name: "Updated", sql: "SELECT 2"), id)
        XCTAssertEqual(restored.snippets.count, 1)
        XCTAssertEqual(QueryLibraryStore(url: url).snippets.first?.name, "Updated")
        try restored.clearHistory()
        XCTAssertEqual(restored.snippets.count, 1)
        try restored.deleteSnippet(id)
        XCTAssertTrue(QueryLibraryStore(url: url).snippets.isEmpty)
        XCTAssertThrowsError(try restored.saveSnippet(id: id, name: "Deleted", sql: "SELECT 3"))
        XCTAssertThrowsError(try restored.saveSnippet(name: " ", sql: "SELECT 3"))
        XCTAssertThrowsError(try restored.saveSnippet(name: "Empty", sql: " \n"))
    }

    func testCorruptOrFutureFilesArePreserved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("library.json")
        for input in ["not JSON", #"{"version":99,"history":[],"snippets":[]}"#] {
            try input.write(to: url, atomically: true, encoding: .utf8)
            let store = QueryLibraryStore(url: url)
            XCTAssertNotNil(store.loadError)
            XCTAssertThrowsError(try store.record(sql: "SELECT 1", connection: "test"))
            XCTAssertThrowsError(try store.clearHistory())
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), input)
        }
    }

    func testLegacyJSONMigratesExactlyOnce() throws {
        struct Legacy: Codable {
            let version = 1
            let history: [QueryHistoryEntry]
            let snippets: [QuerySnippet]
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let legacy = root.appendingPathComponent("query-library.json")
        let database = root.appendingPathComponent("query-library.sqlite3")
        let entries = [QueryHistoryEntry(sql: "SELECT 'newest'", connection: "local"),
                       QueryHistoryEntry(sql: "SELECT 'oldest'", connection: "test")]
        let snippet = QuerySnippet(name: "Saved", sql: "SELECT 'snippet'")
        let original = try JSONEncoder().encode(Legacy(history: entries, snippets: [snippet]))
        try original.write(to: legacy)
        let store = QueryLibraryStore(url: database)
        XCTAssertNil(store.loadError)
        XCTAssertEqual(store.history.map(\.id), entries.map(\.id))
        XCTAssertEqual(store.history.map(\.sql), entries.map(\.sql))
        XCTAssertEqual(store.history.map(\.connection), entries.map(\.connection))
        for (actual, expected) in zip(store.history, entries) {
            // Converting Foundation dates to Unix timestamps may round below a microsecond.
            XCTAssertEqual(actual.date.timeIntervalSince1970, expected.date.timeIntervalSince1970, accuracy: 0.000001)
        }
        XCTAssertEqual(store.snippets.first?.id, snippet.id)
        XCTAssertEqual(store.snippets.first?.name, snippet.name)
        XCTAssertEqual(store.snippets.first?.sql, snippet.sql)
        XCTAssertEqual(try XCTUnwrap(store.snippets.first).updated.timeIntervalSince1970,
                       snippet.updated.timeIntervalSince1970, accuracy: 0.000001)
        XCTAssertEqual(try Data(contentsOf: legacy), original)
        try store.clearHistory()
        XCTAssertEqual(QueryLibraryStore(url: database).historyCount, 0)
        XCTAssertEqual(QueryLibraryStore(url: database).snippets.first?.id, snippet.id)
        XCTAssertEqual(QueryLibraryStore(url: database).snippets.first?.sql, snippet.sql)
    }

    func testPagingSearchAndCancellation() throws {
        let store = QueryLibraryStore(url: nil)
        for i in 0..<205 { try store.record(sql: "SELECT \(i)", connection: "test") }
        let first = try store.historyPage()
        XCTAssertEqual(first.entries.count, 100)
        XCTAssertTrue(first.hasMore)
        XCTAssertEqual(first.entries.first?.sql, "SELECT 204")
        let second = try store.historyPage(offset: 100)
        XCTAssertEqual(second.entries.first?.sql, "SELECT 104")
        XCTAssertTrue(second.hasMore)
        let last = try store.historyPage(offset: 200)
        XCTAssertEqual(last.entries.count, 5)
        XCTAssertFalse(last.hasMore)
        try store.record(sql: "SELECT '50%_off'", connection: "search")
        XCTAssertEqual(try store.historyPage(matching: "50%_off").entries.count, 1)
        XCTAssertEqual(try store.historyPage(matching: "SELECT 204").entries.count, 1)
        let cancelled = QuerySearchCancellation()
        cancelled.cancel()
        XCTAssertThrowsError(try store.historyPage(matching: "SELECT", cancellation: cancelled))
    }

    func testOneMillionRowsAreBoundedAndPersisted() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("million.sqlite3")
        let store = QueryLibraryStore(url: url)
        XCTAssertNil(store.loadError)
        var fixture: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &fixture), SQLITE_OK)
        defer { sqlite3_close(fixture) }
        let insert = """
            BEGIN;
            WITH RECURSIVE numbers(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM numbers WHERE n<1000000)
            INSERT INTO history (id,sql,connection,date)
            SELECT printf('00000000-0000-0000-0000-%012d', n), 'SELECT ' || n, 'scale', 0 FROM numbers;
            COMMIT;
            """
        XCTAssertEqual(sqlite3_exec(fixture, insert, nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(store.historyCount, 1_000_000)
        XCTAssertEqual(store.history.count, 100) // Never materialize all million entries.
        XCTAssertEqual(store.history.first?.sql, "SELECT 1000000")
        XCTAssertEqual(try store.historyPage(matching: "SELECT 999999").entries.count, 1)
        let oldest = try store.historyPage(offset: 999_900)
        XCTAssertEqual(oldest.entries.count, 100)
        XCTAssertFalse(oldest.hasMore)
        XCTAssertEqual(oldest.entries.last?.sql, "SELECT 1")
        try store.record(sql: "SELECT 'newest'", connection: "scale")
        XCTAssertEqual(store.historyCount, 1_000_000)
        XCTAssertEqual(try store.historyPage(offset: 999_900).entries.last?.sql, "SELECT 2")
        let reopened = QueryLibraryStore(url: url)
        XCTAssertEqual(reopened.historyCount, 1_000_000)
        XCTAssertEqual(reopened.history.first?.sql, "SELECT 'newest'")
        try reopened.deleteHistory(reopened.history[0].id)
        XCTAssertEqual(store.historyCount, 999_999)
    }

    func testWriteFailureDoesNotChangeMemory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let blocked = root.appendingPathComponent("not-a-directory")
        try Data("blocker".utf8).write(to: blocked)
        let store = QueryLibraryStore(url: blocked.appendingPathComponent("library.sqlite3"))
        XCTAssertThrowsError(try store.record(sql: "SELECT 1", connection: "test"))
        XCTAssertTrue(store.history.isEmpty)
        XCTAssertThrowsError(try store.saveSnippet(name: "Example", sql: "SELECT 2"))
        XCTAssertTrue(store.snippets.isEmpty)
    }
}

@MainActor
final class QueryLibraryModelTests: XCTestCase {
    func testSnippetCRUDAndLoadingNeverExecuteSQL() throws {
        let store = QueryLibraryStore(url: nil)
        let model = BrowserModel(queryLibrary: store)
        model.setSQL("SELECT 'saved'")
        let id = try XCTUnwrap(model.saveQuerySnippet(id: nil, name: "Example"))
        model.setSQL("SELECT 'updated'")
        XCTAssertEqual(model.saveQuerySnippet(id: id, name: "Renamed"), id)
        XCTAssertEqual(store.snippets.first?.sql, "SELECT 'updated'")
        model.loadLibrarySQL("SELECT 'loaded'")
        XCTAssertEqual(model.sql, "SELECT 'loaded'")
        XCTAssertFalse(model.isRunning)
        XCTAssertNil(model.connection)
        XCTAssertTrue(store.history.isEmpty)
        model.deleteQuerySnippet(id)
        XCTAssertTrue(store.snippets.isEmpty)
    }

    func testHistoryCapturesOnlyAttemptedManualStatementsAndSelections() async throws {
        guard let uri = ProcessInfo.processInfo.environment["SDBUI_TEST_POSTGRES_URI"] else {
            throw XCTSkip("Set SDBUI_TEST_POSTGRES_URI for query-history integration tests.")
        }
        let store = QueryLibraryStore(url: nil)
        let model = BrowserModel(healthCheckIntervalNanoseconds: 50_000_000, queryLibrary: store)
        defer { model.disconnect() }
        model.connectionDraft.useURI = true
        model.connectionDraft.uri = uri
        model.connectFavorite()
        try await waitUntil { model.connection != nil && !model.isConnecting }
        model.setSQL("SELECT 1; SELEC invalid; SELECT 3")
        model.runQuery()
        try await waitUntil { !model.isRunning }
        XCTAssertEqual(store.history.count, 2) // The third statement was never attempted.
        XCTAssertTrue(store.history[0].sql.contains("SELEC invalid"))
        XCTAssertTrue(store.history[1].sql.contains("SELECT 1"))
        XCTAssertTrue(store.history.allSatisfy { $0.connection == "postgresql" })
        model.refreshTables()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(store.history.count, 2) // No metadata queries or idle probes.
        let text = "SELECT 11; SELECT 22;"
        model.runCurrentStatement(.init(text: text, selection: 11..<20, cursor: 20))
        try await waitUntil { !model.isRunning }
        XCTAssertTrue(store.history[0].sql.contains("SELECT 22"))
        XCTAssertEqual(store.history.count, 3)
        model.runCurrentStatement(.init(text: text, selection: nil, cursor: 2))
        try await waitUntil { !model.isRunning }
        XCTAssertTrue(store.history[0].sql.contains("SELECT 11"))
        model.loadLibrarySQL(store.history.last!.sql)
        XCTAssertEqual(store.history.count, 4)
        XCTAssertFalse(model.isRunning)
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(8)
        while !predicate() {
            guard Date() < deadline else { XCTFail("Timed out waiting for query"); throw ADBCError("Test timed out") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
