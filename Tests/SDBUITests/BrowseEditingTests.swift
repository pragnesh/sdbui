@testable import ADBCKit
@testable import SDBUI
import Foundation
import XCTest

final class BrowseSQLTests: XCTestCase {
    func testGroupedFiltersAndWriteLiterals() throws {
        let table = TableInfo(schema: "odd\"schema", name: "odd\"table")
        let expression = SQLDialect.FilterExpression.any([
            .all([.condition(.init(column: "a", op: .equals, value: "O'Reilly")), .condition(.init(column: "b", op: .isNull, value: ""))]),
            .condition(.init(column: "c", op: .greater, value: "10"))])
        let sql = SQLDialect.postgres.browseSQL(table, filter: nil, expression: expression, limit: 100, offset: 200)
        XCTAssertTrue(sql.contains("((\"a\" = 'O''Reilly' AND \"b\" IS NULL) OR \"c\" > '10')"))
        XCTAssertTrue(SQLDialect.postgres.countSQL(table, expression: expression).contains("COUNT(*)"))
        XCTAssertEqual(try SQLDialect.postgres.editLiteral("a'\\b"), "E'a''\\\\b'")
        XCTAssertEqual(try SQLDialect.mysql.editLiteral("a'\\b"), "_utf8mb4 X'61275c62'")
        XCTAssertThrowsError(try SQLDialect.postgres.editLiteral("a\0b"))
        XCTAssertEqual(try TableMutation(table: table, kind: .insert, assignments: []).sql(.postgres), "INSERT INTO \"odd\"\"schema\".\"odd\"\"table\" DEFAULT VALUES")
        XCTAssertTrue(try TableMutation(table: table, kind: .insert, assignments: []).sql(.mysql).hasSuffix("() VALUES ()"))
        XCTAssertThrowsError(try TableMutation(table: table, kind: .delete, assignments: []).sql(.postgres))
        XCTAssertThrowsError(try TableMutation(table: table, kind: .update, assignments: []).sql(.postgres))
        XCTAssertNotNil(SQLDialect.mysql.relationsSQL(table))
        XCTAssertNotNil(SQLDialect.mysql.triggersSQL(table))
        XCTAssertNotNil(SQLDialect.mysql.viewDefinitionSQL(table))
        XCTAssertTrue(SQLDialect.mysql.editableTableSQL(table)?.contains("TRANSACTIONS='YES'") == true)
    }
    func testUnrepresentableValuesRemainUntouched() throws {
        let columns = [TableEditColumn(name: "id", type: "integer", nullable: false), TableEditColumn(name: "name", type: "text", nullable: true)]
        let draft = RowEditDraft(table: TableInfo(schema: "public", name: "rows"), documentID: UUID(), sessionRevision: 1, paneRevision: 1, kind: .update,
            metadata: .init(columns: columns, keys: ["id"], transactional: true), originalColumns: ["id", "name"], originalValues: ["1", "a\0b"],
            fields: [.init(column: columns[0], mode: .value, text: "2"), .init(column: columns[1], mode: .value, text: "a\0b", unrepresentable: true)])
        let mutation = try draft.mutation()
        XCTAssertEqual(mutation.assignments, [.init(column: "id", value: .value("2"))])
        XCTAssertFalse(try mutation.sql(.postgres).contains("\0"))
    }
    func testPinsPersistAndStayConnectionScoped() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("library.sqlite3")
        let store = QueryLibraryStore(url: url)
        try store.setTablePinned("catalog|schema|table", connection: "A", pinned: true)
        try store.setTablePinned("catalog|schema|other", connection: "B", pinned: true)
        let reopened = QueryLibraryStore(url: url)
        XCTAssertEqual(reopened.pinnedTables(connection: "A"), ["catalog|schema|table"])
        XCTAssertEqual(reopened.pinnedTables(connection: "B"), ["catalog|schema|other"])
        try reopened.setTablePinned("catalog|schema|table", connection: "A", pinned: false)
        XCTAssertTrue(reopened.pinnedTables(connection: "A").isEmpty)
    }
}

@MainActor
final class BrowseEditingIntegrationTests: XCTestCase {
    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !predicate() {
            guard Date() < deadline else { throw ADBCError("Timed out waiting for browsing test") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
    private func model(readOnly: Bool = false) async throws -> BrowserModel {
        guard let uri = ProcessInfo.processInfo.environment["SDBUI_TEST_POSTGRES_URI"] else { throw XCTSkip("Set SDBUI_TEST_POSTGRES_URI") }
        let model = BrowserModel(queryLibrary: QueryLibraryStore(url: nil))
        model.connectionDraft.useURI = true; model.connectionDraft.uri = uri; model.connectionDraft.safety.readOnly = readOnly
        model.connectFavorite()
        try await waitUntil { model.canUseConnection }
        return model
    }
    private func browse(_ model: BrowserModel, table: String) async throws {
        model.refreshTables()
        try await waitUntil { model.tables.contains { $0.name == table } }
        model.selectTable(model.tables.first { $0.name == table }!.id)
        model.browseSelectedTable()
        try await waitUntil { !model.isRunning && model.selectedTableID.flatMap { model.editMetadata[$0] } != nil }
    }
    func testGroupedFiltersCountsAndPinnedFuzzySidebar() async throws {
        let model = try await model()
        defer { model.disconnect() }
        let connection = try XCTUnwrap(model.connection)
        _ = try connection.execute("CREATE TABLE public.browse_groups (id int PRIMARY KEY, name text, qty int)", maxRows: 0)
        defer { _ = try? connection.execute("DROP TABLE public.browse_groups", maxRows: 0) }
        _ = try connection.execute("CREATE TABLE public.aaa_unpinned_pin_test(id int)", maxRows: 0)
        defer { _ = try? connection.execute("DROP TABLE public.aaa_unpinned_pin_test", maxRows: 0) }
        _ = try connection.execute("INSERT INTO public.browse_groups VALUES (1,'alpha',1),(2,'alpha',20),(3,'beta',30),(4,NULL,40)", maxRows: 0)
        try await browse(model, table: "browse_groups")
        model.filterGroups = [
            .init(conditions: [.init(filter: .init(column: "name", op: .equals, value: "alpha")), .init(filter: .init(column: "qty", op: .greater, value: "10"))]),
            .init(conditions: [.init(filter: .init(column: "name", op: .isNull, value: ""))])]
        model.filterGroupJoin = .any
        let sql = model.sql
        model.applyAdvancedFilters()
        try await waitUntil { !model.isRunning }
        XCTAssertEqual(model.queryPane.result?.rowCount, 2)
        model.countContentRows()
        try await waitUntil { !model.isRunning }
        XCTAssertEqual(model.contentTotal, 2)
        XCTAssertTrue(model.contentRowsLabel.contains("(exact)"))
        XCTAssertEqual(model.sql, sql)
        model.addQueryDocument()
        model.selectQueryDocument(model.queryDocuments[0].id)
        XCTAssertNotNil(model.contentExpression)
        XCTAssertEqual(model.contentTotal, 2)
        model.toggleSelectedTablePin()
        XCTAssertTrue(model.pinnedTableIDs.contains(model.selectedTableID!))
        XCTAssertEqual(model.visibleTables(matching: "").first?.name, "browse_groups")
        XCTAssertEqual(model.visibleTables(matching: "brgr").first?.name, "browse_groups")
        XCTAssertTrue(model.label(for: model.selectedTable!).hasPrefix("★"))
        model.toggleSelectedTablePin()
        XCTAssertFalse(model.pinnedTableIDs.contains(model.selectedTableID!))
        model.clearContentFilter()
        try await waitUntil { !model.isRunning }
        XCTAssertNil(model.contentExpression)
        XCTAssertNil(model.contentTotal)
        XCTAssertEqual(model.queryPane.result?.rowCount, 4)
    }
    func testReviewedInsertUpdateDeleteDefaultsNullsAndReadOnly() async throws {
        let model = try await model()
        defer { model.disconnect() }
        let connection = try XCTUnwrap(model.connection)
        _ = try connection.execute("CREATE TABLE public.browse_rows (id int GENERATED ALWAYS AS IDENTITY PRIMARY KEY, name text NOT NULL, qty int DEFAULT 7 CHECK(qty>=0), note text, doubled int GENERATED ALWAYS AS(qty*2) STORED)", maxRows: 0)
        defer { _ = try? connection.execute("DROP TABLE public.browse_rows", maxRows: 0) }
        try await browse(model, table: "browse_rows")
        XCTAssertTrue(model.canEditRows)
        let editorSQL = model.sql
        model.beginRowEdit(kind: .insert)
        var draft = try XCTUnwrap(model.rowEditDraft)
        let index = draft.fields.firstIndex { $0.id == "name" }!
        draft.fields[index].mode = .value; draft.fields[index].text = "O'Reilly\\value\n🙂"
        model.rowEditDraft = draft
        model.confirmRowEdit() // No review: no write.
        XCTAssertEqual(try connection.execute("SELECT count(*) FROM public.browse_rows", maxRows: 1).cell(0, 0), "0")
        model.reviewRowEdit(); XCTAssertNotNil(model.rowEditDraft?.reviewedSQL)
        model.confirmRowEdit()
        try await waitUntil { !model.isRunning && model.rowEditDraft == nil }
        XCTAssertEqual(model.queryPane.result?.cell(0, 1), "O'Reilly\\value\n🙂")
        XCTAssertEqual(model.queryPane.result?.cell(0, 2), "7")
        XCTAssertEqual(model.queryPane.result?.cell(0, 4), "14")
        try await waitUntil { model.canEditRows }
        let target = try XCTUnwrap(model.cellFilterTarget(in: model.queryPane, row: 0, column: 1))
        model.applyCellFilter(target, command: 3)
        draft = try XCTUnwrap(model.rowEditDraft)
        let note = draft.fields.firstIndex { $0.id == "note" }!
        draft.fields[note].mode = .value; draft.fields[note].text = "NULL"
        let name = draft.fields.firstIndex { $0.id == "name" }!
        draft.fields[name].text = String(repeating: "long", count: 3000)
        model.rowEditDraft = draft; model.reviewRowEdit(); model.confirmRowEdit()
        try await waitUntil { !model.isRunning && model.rowEditDraft == nil }
        XCTAssertEqual(model.queryPane.result?.cell(0, 1, maxLength: nil)?.count, 12000)
        XCTAssertEqual(model.queryPane.result?.cell(0, 3), "NULL")
        XCTAssertEqual(model.sql, editorSQL)
        try await waitUntil { model.canEditRows }
        model.beginRowEdit(kind: .delete, row: 0)
        model.reviewRowEdit(); model.confirmRowEdit()
        try await waitUntil { !model.isRunning && model.rowEditDraft == nil }
        XCTAssertEqual(model.queryPane.result?.rowCount, 0)
        let readOnly = try await self.model(readOnly: true)
        defer { readOnly.disconnect() }
        try await browse(readOnly, table: "browse_rows")
        XCTAssertFalse(readOnly.canInsertRows)
        XCTAssertFalse(readOnly.canEditRows)
        readOnly.beginRowEdit(kind: .insert)
        XCTAssertNil(readOnly.rowEditDraft)
    }
    func testAtomicWritesRejectStaleRowsConstraintsAndManualTransactions() async throws {
        let model = try await model()
        defer { model.disconnect() }
        let connection = try XCTUnwrap(model.connection)
        let table = TableInfo(schema: "public", name: "browse_atomic")
        _ = try connection.execute("CREATE TABLE public.browse_atomic (a int, b int, name text, qty int CHECK(qty>=0), PRIMARY KEY(a,b))", maxRows: 0)
        defer { _ = try? connection.execute("DROP TABLE public.browse_atomic", maxRows: 0) }
        _ = try connection.execute("INSERT INTO public.browse_atomic VALUES (1,2,'original',3)", maxRows: 0)
        func change(_ assignments: [TableAssignment], original: QueryResult) -> TableMutation {
            .init(table: table, kind: .update, assignments: assignments, keys: [.init(column: "a", value: .value("1")), .init(column: "b", value: .value("2"))], originalColumns: original.columns.map(\.name), originalValues: original.row(0))
        }
        let original = try connection.execute("SELECT * FROM public.browse_atomic", maxRows: 1)
        XCTAssertThrowsError(try connection.applyTableMutation(change([.init(column: "qty", value: .value("-1"))], original: original)))
        XCTAssertEqual(try connection.execute("SELECT qty FROM public.browse_atomic", maxRows: 1).cell(0, 0), "3")
        _ = try connection.execute("UPDATE public.browse_atomic SET name='someone else'", maxRows: 0)
        XCTAssertThrowsError(try connection.applyTableMutation(change([.init(column: "name", value: .value("overwrite"))], original: original)))
        XCTAssertEqual(try connection.execute("SELECT name FROM public.browse_atomic", maxRows: 1).cell(0, 0), "someone else")
        let fresh = try connection.execute("SELECT * FROM public.browse_atomic", maxRows: 1)
        _ = try connection.execute("BEGIN", maxRows: 0)
        _ = try connection.execute("INSERT INTO public.browse_atomic VALUES (8,9,'uncommitted',1)", maxRows: 0)
        XCTAssertThrowsError(try connection.applyTableMutation(change([.init(column: "qty", value: .value("5"))], original: fresh)))
        _ = try connection.execute("ROLLBACK", maxRows: 0)
        XCTAssertEqual(try connection.execute("SELECT count(*) FROM public.browse_atomic", maxRows: 1).cell(0, 0), "1")
        try connection.applyTableMutation(change([.init(column: "name", value: .value("after rollback"))], original: fresh))
        XCTAssertEqual(try connection.execute("SELECT name FROM public.browse_atomic", maxRows: 1).cell(0, 0), "after rollback")
        _ = try connection.execute("UPDATE public.browse_atomic SET name=E'é'", maxRows: 0)
        let composed = try connection.execute("SELECT * FROM public.browse_atomic", maxRows: 1)
        _ = try connection.execute("UPDATE public.browse_atomic SET name=" + (try SQLDialect.postgres.editLiteral("e\u{301}")), maxRows: 0)
        XCTAssertThrowsError(try connection.applyTableMutation(change([.init(column: "qty", value: .value("6"))], original: composed)))

    }
    func testRelationsTriggersViewDefinitionsAndNoPrimaryKey() async throws {
        let model = try await model()
        defer { model.disconnect() }
        let connection = try XCTUnwrap(model.connection)
        _ = try connection.execute("CREATE TABLE public.browse_parent (a int, b int, PRIMARY KEY(a,b))", maxRows: 0)
        _ = try connection.execute("CREATE TABLE public.browse_child (a int,b int, FOREIGN KEY(a,b) REFERENCES public.browse_parent(a,b))", maxRows: 0)
        _ = try connection.execute("CREATE VIEW public.browse_view AS SELECT a FROM public.browse_parent", maxRows: 0)
        _ = try connection.execute("CREATE FUNCTION public.browse_trigger_fn() RETURNS trigger LANGUAGE plpgsql AS $$BEGIN RETURN NEW; END$$", maxRows: 0)
        _ = try connection.execute("CREATE TRIGGER browse_trigger BEFORE INSERT ON public.browse_parent FOR EACH ROW EXECUTE FUNCTION public.browse_trigger_fn()", maxRows: 0)
        defer {
            for sql in ["DROP VIEW public.browse_view", "DROP TABLE public.browse_child", "DROP TABLE public.browse_parent", "DROP FUNCTION public.browse_trigger_fn()"] { _ = try? connection.execute(sql, maxRows: 0) }
        }
        try await browse(model, table: "browse_parent")
        model.selectTab(.info)
        try await waitUntil { model.relationsPane.result?.rowCount == 2 && model.triggersPane.result?.rowCount == 1 }
        XCTAssertTrue(model.triggersPane.result?.cell(0, 2)?.contains("CREATE TRIGGER") == true)
        model.selectTab(.query)
        model.selectTable(model.tables.first { $0.name == "browse_child" }!.id)
        model.browseSelectedTable()
        try await waitUntil { !model.isRunning && model.selectedTableID.flatMap { model.editMetadata[$0] } != nil }
        XCTAssertTrue(model.canInsertRows)
        XCTAssertFalse(model.canEditRows)
        model.selectTable(model.tables.first { $0.name == "browse_view" }!.id)
        model.selectTab(.info)
        try await waitUntil { model.viewDefinition.contains("browse_parent") }
        model.selectTab(.query); model.browseSelectedTable()
        try await waitUntil { !model.isRunning && model.selectedTableID.flatMap { model.editMetadata[$0] } != nil }
        XCTAssertFalse(model.canInsertRows)
    }
}
