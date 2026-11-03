@testable import ADBCKit
@testable import SDBUI
import Foundation
import XCTest

@MainActor
final class TableTransferIntegrationTests: XCTestCase {
    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(15)
        while !predicate() {
            guard Date() < deadline else { throw ADBCError("Timed out waiting for transfer") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
    private func model(readOnly: Bool = false) async throws -> BrowserModel {
        guard let uri = ProcessInfo.processInfo.environment["SDBUI_TEST_POSTGRES_URI"] else { throw XCTSkip("Requires isolated PostgreSQL") }
        let model = BrowserModel(queryLibrary: QueryLibraryStore(url: nil))
        model.connectionDraft.useURI = true; model.connectionDraft.uri = uri; model.connectionDraft.safety.readOnly = readOnly
        model.connectFavorite()
        try await waitUntil { model.canUseConnection }
        return model
    }
    func testPreviewInvalidationImportAndExportPreserveEditor() async throws {
        let model = try await model()
        let connection = try XCTUnwrap(model.connection)
        let name = "ui_transfer_" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        _ = try connection.execute("CREATE TABLE public.\(name) (id int GENERATED ALWAYS AS IDENTITY, value text, calculated int GENERATED ALWAYS AS (id*2) STORED)", maxRows: 0)
        defer { _ = try? connection.execute("DROP TABLE public.\(name)", maxRows: 0); model.disconnect() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        model.refreshTables()
        try await waitUntil { model.tables.contains { $0.name == name } }
        model.selectTable(model.tables.first { $0.name == name }!.id)
        model.sql = "SELECT 'keep draft'"
        model.toggleTransfers()
        XCTAssertTrue(model.transferVisible)
        let input = root.appendingPathComponent("input.csv")
        try "id,value,calculated\n12,hello,24\n".write(to: input, atomically: true, encoding: .utf8)
        model.csvURL = input; model.previewCSV()
        try await waitUntil { !model.isRunning }
        XCTAssertNotNil(model.csvPreview, model.errorMessage ?? "")
        XCTAssertEqual(model.csvMapping, [nil, "value", nil])
        XCTAssertTrue(model.canConfirmCSV)
        model.csvMapping = ["value", "value", nil]
        XCTAssertFalse(model.canConfirmCSV)
        model.csvMapping = [nil, "value", nil]
        model.addQueryDocument()
        XCTAssertFalse(model.canConfirmCSV)
        model.selectQueryDocument(model.queryDocuments[0].id)
        XCTAssertTrue(model.canConfirmCSV)
        model.csvOptions.emptyIsNull = true
        XCTAssertNil(model.csvPreview)
        model.previewCSV(); try await waitUntil { !model.isRunning }
        model.confirmCSVImport(); try await waitUntil { !model.isRunning }
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.sql, "SELECT 'keep draft'")
        XCTAssertEqual(try connection.execute("SELECT id,value,calculated FROM public.\(name)", maxRows: 1).row(0), ["1", "hello", "2"])
        model.maxRows = 1; model.transferFormat = .json
        let output = root.appendingPathComponent("output.json")
        model.exportTable(to: output); try await waitUntil { !model.isRunning }
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        XCTAssertEqual(model.sql, "SELECT 'keep draft'")
    }
    func testReadOnlyFavoriteDisablesImportAndExports() async throws {
        let model = try await model(readOnly: true)
        let connection = try XCTUnwrap(model.connection)
        _ = try connection.execute("CREATE TABLE public.readonly_transfer (id int)", maxRows: 0)
        defer { _ = try? connection.execute("DROP TABLE public.readonly_transfer", maxRows: 0); model.disconnect() }
        model.refreshTables(); try await waitUntil { model.tables.contains { $0.name == "readonly_transfer" } }
        model.selectTable(model.tables.first { $0.name == "readonly_transfer" }!.id)
        XCTAssertFalse(model.canImportCSV)
        XCTAssertFalse(model.canConfirmCSV)
        model.confirmCSVImport()
        XCTAssertFalse(model.isRunning)
    }
}
