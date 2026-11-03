@testable import ADBCKit
import Foundation
import SwiftCrossUI
import XCTest
@testable import SDBUI

final class SQLCompletionTests: XCTestCase {
    private let users = TableInfo(catalog: "db", schema: "public", name: "users", type: "TABLE")
    private let orders = TableInfo(catalog: "db", schema: "public", name: "orders", type: "TABLE")
    func testAliasColumnsTablesKeywordsAndUnicodeOffsets() throws {
        let tables = [users, orders]
        let columns = [users.id: ["name", "naïve", "id", "odd\"name"]]
        let query = "SELECT u.na FROM public.users AS u JOIN orders o ON u.id = o.user_id"
        let completion = try XCTUnwrap(SQLCompletionEngine.complete(query, cursor: 11, dialect: .postgres,
            tables: tables, namespace: "public", columns: columns))
        XCTAssertEqual(completion.start, 9)
        XCTAssertEqual(completion.values, ["\"name\"", "\"naïve\""].sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
        let refs = SQLCompletionEngine.references(query, tables: tables, namespace: "public")
        XCTAssertEqual(refs["u"], users)
        XCTAssertEqual(refs["o"], orders)
        let table = try XCTUnwrap(SQLCompletionEngine.complete("SELECT * FROM us", cursor: 16, dialect: .postgres, tables: tables, namespace: "public", columns: columns))
        XCTAssertTrue(table.values.contains("\"users\""))
        let keyword = try XCTUnwrap(SQLCompletionEngine.complete("SE", cursor: 2, dialect: .mysql, tables: [], namespace: nil, columns: [:]))
        XCTAssertTrue(keyword.values.contains("SELECT"))
        let unicode = "SELECT '🙂'; SELECT u.na FROM users u"
        let cursor = unicode.unicodeScalars.firstIndex(of: ".")!
        let position = unicode.unicodeScalars.distance(from: unicode.unicodeScalars.startIndex, to: cursor) + 3
        let value = try XCTUnwrap(SQLCompletionEngine.complete(unicode, cursor: position, dialect: .mysql, tables: tables, namespace: "public", columns: columns))
        XCTAssertEqual(value.start, position - 2)
        XCTAssertTrue(value.values.contains("`name`"))
        XCTAssertNil(SQLCompletionEngine.complete(query, cursor: -1, dialect: .postgres, tables: tables, namespace: "public", columns: columns))
    }
    func testCommentsStringsQuotedAliasesAndAmbiguousNames() throws {
        for sql in ["SELECT 'na", "-- na", "/* outer /* nested */ na", "SELECT $tag$ na"] {
            XCTAssertNil(SQLCompletionEngine.complete(sql, cursor: sql.unicodeScalars.count, dialect: .postgres, tables: [users], namespace: "public", columns: [:]))
        }
        for sql in ["# na", "SELECT \"na"] {
            XCTAssertNil(SQLCompletionEngine.complete(sql, cursor: sql.unicodeScalars.count, dialect: .mysql, tables: [users], namespace: "public", columns: [:]))
        }
        let query = "SELECT \"u alias\".na FROM \"public\".\"users\" AS \"u alias\""
        let cursor = "SELECT \"u alias\".na".unicodeScalars.count
        XCTAssertTrue(SQLCompletionEngine.complete(query, cursor: cursor, dialect: .postgres, tables: [users], namespace: "public", columns: [users.id: ["name"]])?.values.contains("\"name\"") == true)
        let other = TableInfo(catalog: "db", schema: "other", name: "users", type: "TABLE")
        XCTAssertTrue(SQLCompletionEngine.references("SELECT * FROM users", tables: [users, other], namespace: nil).isEmpty)
        XCTAssertEqual(SQLCompletionEngine.references("SELECT * FROM other.users", tables: [users, other], namespace: "public")["users"], other)
        let text = "SELECT \"odd"
        XCTAssertTrue(SQLCompletionEngine.complete(text, cursor: text.unicodeScalars.count, dialect: .postgres,
            tables: [users], namespace: "public", columns: [:])?.values.isEmpty == true)
    }
}

@MainActor
final class QueryDocumentTests: XCTestCase {
    func testDraftResultsCloseAndSessionRestoreAreIndependent() throws {
        let model = BrowserModel(queryLibrary: QueryLibraryStore(url: nil))
        model.setSQL("SELECT 'first'")
        let first = model.activeQueryDocument.id
        model.queryPane.show(QueryResult(columns: [.init(name: "value", type: "text")], rows: [["first"]]))
        model.editorCursor = 5
        model.addQueryDocument()
        let second = model.activeQueryDocument.id
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(model.sql, "")
        XCTAssertNil(model.queryPane.result)
        model.setSQL("SELECT 'second'")
        model.selectQueryDocument(first)
        XCTAssertEqual(model.sql, "SELECT 'first'")
        XCTAssertEqual(model.queryPane.result?.cell(0, 0), "first")
        XCTAssertEqual(model.editorCursor, 5)
        let restored = BrowserModel(queryLibrary: QueryLibraryStore(url: nil))
        restored.restoreSession(model.sessionState)
        XCTAssertEqual(restored.queryDrafts.map(\.sql), ["SELECT 'first'", "SELECT 'second'"])
        XCTAssertEqual(restored.activeQueryDocument.id, first)
        XCTAssertTrue(restored.hasUnsavedSQL)
        XCTAssertNil(restored.queryPane.result) // Results aren't persisted or re-executed.
        model.closeQueryDocument(second)
        XCTAssertEqual(model.pendingQueryCloseID, second)
        model.cancelQueryDocumentClose()
        XCTAssertEqual(model.queryDocuments.count, 2)
        model.closeQueryDocument(second); model.confirmQueryDocumentClose()
        XCTAssertEqual(model.queryDocuments.count, 1)
        model.closeQueryDocument(first); model.confirmQueryDocumentClose()
        XCTAssertEqual(model.queryDocuments.count, 1)
        XCTAssertEqual(model.sql, "")
    }
    func testLegacySessionsAndNewDraftsRoundTrip() throws {
        let data = Data(#"{"favoriteID":"missing","sql":"SELECT 1","dirty":true,"pane":"Query","fontSize":13,"sidebarWidth":290}"#.utf8)
        let state = try JSONDecoder().decode(SessionTabState.self, from: data)
        let model = BrowserModel(queryLibrary: QueryLibraryStore(url: nil))
        model.restoreSession(state)
        XCTAssertEqual(model.sql, "SELECT 1")
        XCTAssertEqual(model.queryDocuments.count, 1)
        let roundTrip = try JSONDecoder().decode(SessionTabState.self, from: JSONEncoder().encode(model.sessionState))
        XCTAssertEqual(roundTrip.queries?.first?.sql, "SELECT 1")
    }
}

@MainActor
final class QueryEditorIntegrationTests: XCTestCase {
    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !predicate() {
            guard Date() < deadline else { throw ADBCError("Timed out waiting for editor test") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
    func testExplainSelectionDoesNotExecuteAndMetadataLoadsForAliases() async throws {
        guard let uri = ProcessInfo.processInfo.environment["SDBUI_TEST_POSTGRES_URI"] else { throw XCTSkip("Set SDBUI_TEST_POSTGRES_URI") }
        let model = BrowserModel(queryLibrary: QueryLibraryStore(url: nil))
        defer { model.disconnect() }
        model.connectionDraft.useURI = true; model.connectionDraft.uri = uri
        model.connectFavorite()
        try await waitUntil { model.canUseConnection }
        let connection = try XCTUnwrap(model.connection)
        _ = try connection.execute("CREATE TABLE public.editor_users (id int, name text)", maxRows: 0)
        defer { _ = try? connection.execute("DROP TABLE public.editor_users", maxRows: 0) }
        _ = try connection.execute("INSERT INTO public.editor_users VALUES (1, 'Alice')", maxRows: 0)
        _ = try connection.execute("CREATE TABLE public.editor_other (id int)", maxRows: 0)
        defer { _ = try? connection.execute("DROP TABLE public.editor_other", maxRows: 0) }
        model.refreshTables()
        try await waitUntil { model.tables.contains { $0.name == "editor_users" } }
        model.setSQL("SELECT u.na FROM public.editor_users u")
        let table = model.tables.first { $0.name == "editor_users" }!
        try await waitUntil { model.completionColumns[table.id]?.contains("name") == true }
        XCTAssertTrue(model.editorCompletions(text: model.sql, cursor: 11)?.values.contains("\"name\"") == true)
        model.selectTable(table.id)
        model.browseSelectedTable()
        try await waitUntil { !model.isRunning }
        model.filterColumn = "id"; model.filterOperator = .equals; model.filterValue = "1"
        model.applyContentFilter()
        try await waitUntil { !model.isRunning }
        let original = model.activeQueryDocument.id
        model.addQueryDocument()
        model.selectTable(model.tables.first { $0.name == "editor_other" }!.id)
        model.browseSelectedTable()
        try await waitUntil { !model.isRunning }
        model.selectQueryDocument(original)
        XCTAssertEqual(model.selectedTableID, table.id)
        XCTAssertTrue(model.isBrowsing)
        XCTAssertEqual(model.contentFilter?.column, "id")
        XCTAssertEqual(model.contentFilter?.value, "1")
        XCTAssertEqual(model.queryPane.result?.rowCount, 1)
        let sql = "SELECT pg_sleep(5); SELECT 22"
        model.setSQL(sql)
        model.editorCursor = 2
        model.explainQuery()
        XCTAssertTrue(model.isRunning)
        let first = model.activeQueryDocument.id
        model.addQueryDocument() // One operation per connection: don't orphan an active run.
        XCTAssertEqual(model.activeQueryDocument.id, first)
        try await waitUntil { !model.isRunning }
        XCTAssertNil(model.queryStatus?.error)
        XCTAssertEqual(model.sql, sql)
        XCTAssertTrue(model.hasUnsavedSQL) // Explaining doesn't mark SQL as executed.
        XCTAssertTrue(model.queryPane.result?.cell(0, 0)?.contains("Result") == true)
        XCTAssertTrue(model.queryLibrary.history.first?.sql.hasPrefix("EXPLAIN") == true)
        model.editorSelection = 20..<sql.unicodeScalars.count
        model.explainQuery()
        try await waitUntil { !model.isRunning }
        XCTAssertTrue(model.queryLibrary.history.first?.sql.contains("SELECT 22") == true)
        model.editorSelection = nil
        model.setSQL("EXPLAIN SELECT 44"); model.runQuery()
        try await waitUntil { !model.isRunning }
        XCTAssertNil(model.queryStatus?.error)
        XCTAssertNotNil(model.queryPane.result)
        model.setSQL("DELETE FROM public.editor_users")
        model.editorSelection = nil; model.editorCursor = 1
        model.explainQuery()
        XCTAssertFalse(model.isRunning)
        XCTAssertNotNil(model.queryStatus?.error)
        model.addQueryDocument()
        XCTAssertNil(model.queryPane.result)
        model.setSQL("SELECT 33"); model.runQuery()
        try await waitUntil { !model.isRunning }
        XCTAssertEqual(model.queryPane.result?.cell(0, 0), "33")
        model.selectQueryDocument(first)
        XCTAssertEqual(model.sql, "DELETE FROM public.editor_users")
        XCTAssertNotNil(model.queryPane.result)
        let readOnly = BrowserModel(queryLibrary: QueryLibraryStore(url: nil))
        defer { readOnly.disconnect() }
        readOnly.connectionDraft.useURI = true; readOnly.connectionDraft.uri = uri
        readOnly.connectionDraft.safety.readOnly = true
        readOnly.connectFavorite()
        try await waitUntil { readOnly.canUseConnection }
        readOnly.setSQL("SELECT pg_sleep(5)")
        readOnly.explainQuery()
        try await waitUntil { !readOnly.isRunning }
        XCTAssertNil(readOnly.queryStatus?.error)
        XCTAssertNotNil(readOnly.queryPane.result)
    }
}
