import ADBCKit
import Foundation
import SwiftCrossUI

struct RowEditingBar: View {
    var model: BrowserModel
    @State private var revision = 0
    var body: some View {
        let _ = revision
        let _ = model.watch("row-editing-bar", of: { [AnyHashable(model.isBrowsing), model.isRunning, model.editMetadataRevision, model.selectedTableID, model.editFeedback, model.rowEditDraft != nil] }) { revision &+= 1 }
        if model.isBrowsing && (!model.canEditRows || !model.editFeedback.isEmpty) {
            HStack {
                if !model.canEditRows {
                    if model.isRunning { Text("Working…").font(.caption) }
                    else if !model.canUseConnection { Text("Connection unavailable").font(.caption) }
                    else if model.connectionSafety.readOnly { Text("Read-only connection").font(.caption) }
                    else if let id = model.selectedTableID, let metadata = model.editMetadata[id] {
                        Text(metadata.transactional ? "Updates/deletes require a supported primary key." : "This is not a transactional base table.").font(.caption)
                    } else { Text(!model.dialect.supportsTableWrites ? "Row editing supports PostgreSQL and MySQL tables." : (model.editMetadataError.isEmpty ? "Loading row metadata…" : model.editMetadataError)).font(.caption) }
                }
                if !model.editFeedback.isEmpty { Text(model.editFeedback).font(.caption) }
                Spacer()
            }
        }
    }
}
struct RowEditorView: View {
    var model: BrowserModel
    @State private var revision = 0
    var body: some View {
        let _ = revision
        let _ = model.watch("row-editor", of: { [AnyHashable(model.rowEditDraft), AnyHashable(model.isRunning)] }) { revision &+= 1 }
        if let draft = model.rowEditDraft {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(draft.kind.rawValue.capitalized) row · \(draft.table.name)").font(.headline)
                if draft.kind == .delete {
                    Text("Delete this row? Its primary key and loaded values will be checked before the change is committed.")
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if draft.kind != .delete {
                            ForEach(draft.fields) { field in RowEditFieldView(model: model, name: field.id) }
                        } else {
                            ForEach(Array(zip(draft.originalColumns, draft.originalValues).enumerated()), id: \.offset) { item in
                                Text("\(item.element.0): \(item.element.1?.replacingOccurrences(of: "\0", with: "␀") ?? "NULL")").lineLimit(3).textSelectionEnabled()
                            }
                        }
                        if let sql = draft.reviewedSQL {
                            Text("Review SQL before confirming").font(.headline)
                            Text(sql).font(.system(size: 12, design: .monospaced)).textSelectionEnabled()
                        }
                    }
                }.frame(maxHeight: .infinity)
                HStack {
                    Button("Cancel change") { model.cancelRowEdit() }.disabled(model.isRunning)
                    Button("Review change") { model.reviewRowEdit() }.disabled(!model.canRun)
                    if draft.reviewedSQL != nil {
                        Button("Confirm \(draft.kind.rawValue)") { model.confirmRowEdit() }.disabled(!model.canRun)
                    }
                    Text("One row · transaction · SQL editor is preserved").font(.caption)
                }
            }
        }
    }
}
struct RowEditFieldView: View {
    var model: BrowserModel
    let name: String
    private var index: Int? { model.rowEditDraft?.fields.firstIndex { $0.id == name } }
    private func update(_ change: (inout RowEditField) -> Void) {
        guard var draft = model.rowEditDraft, let index else { return }
        change(&draft.fields[index]); draft.reviewedSQL = nil; model.rowEditDraft = draft
    }
    var body: some View {
        if let index, let field = model.rowEditDraft?.fields[index] {
            HStack(alignment: .top) {
                Text("\(name) · \(field.column.type)").frame(width: 180)
                if field.column.generated || field.column.binary || field.unrepresentable {
                    Text(field.column.generated ? "Generated (read-only)" : (field.unrepresentable ? "NUL-containing value (read-only)" : "Binary value (read-only)")).foregroundColor(.gray)
                } else {
                    Picker(of: EditValueMode.allCases.filter { $0 != .null || field.column.nullable }, selection: Binding(get: { Optional(field.mode) }, set: { mode in if let mode { update { $0.mode = mode } } }))
                        .frame(width: 110).disabled(model.isRunning)
                    if field.column.type.contains("text") || field.column.type.contains("json") || field.text.contains("\n") {
                        TextEditor(text: Binding(get: { field.text }, set: { value in update { $0.text = value } }))
                            .frame(height: 64).disabled(field.mode != .value || model.isRunning)
                    } else {
                        TextField("Value", text: Binding(get: { field.text }, set: { value in update { $0.text = value } }))
                            .disabled(field.mode != .value || model.isRunning)
                    }
                }
            }
        }
    }
}

enum SchemaDetailSection: String, CaseIterable { case relations = "Relations", triggers = "Triggers", definition = "View definition" }
struct SchemaDetailsView: View {
    var model: BrowserModel
    @State private var section = SchemaDetailSection.relations
    @State private var revision = 0
    var body: some View {
        let _ = revision
        let _ = model.watch("view-definition", of: { model.viewDefinition }) { revision &+= 1 }
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                ForEach(SchemaDetailSection.allCases, id: \.rawValue) { item in
                    Button(item.rawValue) { section = item }.buttonStyle(item == section ? .bordered : .borderless)
                }
            }
            if model.dialect == .generic {
                Text("Catalog relations, triggers and view definitions require PostgreSQL or MySQL.").foregroundColor(.gray)
            } else {
            switch section {
            case .relations: PaneGrid(model: model, pane: model.relationsPane, key: "relations", emptyText: "No foreign keys (incoming or outgoing).")
            case .triggers: PaneGrid(model: model, pane: model.triggersPane, key: "triggers", emptyText: "No visible user triggers.")
            case .definition:
                if model.viewDefinition.isEmpty { Text("Select a view to inspect its definition. Definitions may require additional database privileges.").foregroundColor(.gray) }
                else { ResultGrid(header: "View definition", rows: model.viewDefinition) }
            }
            }
        }
    }
}
