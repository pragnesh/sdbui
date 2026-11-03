import ADBCKit
import Foundation

struct TableEditMetadata: Hashable, Sendable {
    var columns: [TableEditColumn]
    var keys: [String]
    var transactional: Bool
    var canIdentifyRows: Bool { !keys.isEmpty && keys.allSatisfy { key in columns.contains { $0.name == key && !$0.binary } } }
}
enum EditValueMode: String, CaseIterable, CustomStringConvertible { case value = "Value", null = "NULL", `default` = "DEFAULT"; var description: String { rawValue } }
struct RowEditField: Identifiable, Hashable {
    let column: TableEditColumn
    var mode: EditValueMode
    var text: String
    var unrepresentable = false
    var id: String { column.name }
    var value: TableEditValue { switch mode { case .value: return .value(text); case .null: return .null; case .default: return .default } }
}
struct RowEditDraft: Hashable {
    let table: TableInfo
    let documentID: UUID
    let sessionRevision: Int
    let paneRevision: Int
    let kind: TableMutation.Kind
    let metadata: TableEditMetadata
    let originalColumns: [String]
    let originalValues: [String?]
    var fields: [RowEditField]
    var reviewedSQL: String?
    func mutation() throws -> TableMutation {
        let assignments = try fields.enumerated().compactMap { _, field -> TableAssignment? in
            if field.column.generated || field.column.binary || field.unrepresentable { return nil }
            if kind == .delete { return nil }
            if field.mode == .null && !field.column.nullable { throw ADBCError("\(field.column.name) cannot be NULL.") }
            if kind == .update, let index = originalColumns.firstIndex(of: field.column.name) {
                if field.mode == .null && originalValues[index] == nil { return nil }
                if field.mode == .value, let original = originalValues[index], field.text.utf8.elementsEqual(original.utf8) { return nil }
            }
            return TableAssignment(column: field.column.name, value: field.value)
        }
        let keys: [TableAssignment] = try kind == .insert ? [] : metadata.keys.map { key in
            guard let index = originalColumns.firstIndex(of: key), let value = originalValues[index] else { throw ADBCError("The original primary key is missing.") }
            return TableAssignment(column: key, value: .value(value))
        }
        return TableMutation(table: table, kind: kind, assignments: assignments, keys: keys,
            originalColumns: originalColumns, originalValues: originalValues)
    }
}
