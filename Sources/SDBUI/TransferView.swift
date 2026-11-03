import ADBCKit
import Foundation
import SwiftCrossUI

struct TransferView: View {
    var model: BrowserModel
    @State private var revision = 0
    @Environment(\.chooseFile) var chooseFile
    @Environment(\.chooseFileSaveDestination) var chooseDestination

    private var delimiterLabel: String { [",": "Comma", ";": "Semicolon", "\t": "Tab", "|": "Pipe"][model.csvOptions.delimiter] ?? "Comma" }
    var body: some View {
        let _ = revision
        let _ = model.watch("table-transfers", of: { [AnyHashable(model.selectedTableID), model.isRunning, model.transferFormat, model.transferFiltered, model.csvOptions, model.csvURL, model.csvPreview?.schema, model.csvMapping, model.transferMessage] }) { revision &+= 1 }
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Import / export · \(model.selectedTable?.name ?? "Select a table")")
                    Spacer()
                    Button("Close transfers") { model.toggleTransfers() }.disabled(model.isRunning).fixedSize()
                }
                HStack {
                    Text("Whole-table export")
                    Picker(of: model.supportedExportFormats, selection: Binding(get: { Optional(model.transferFormat) }, set: { if let value = $0 { model.transferFormat = value } })).frame(width: 150)
                    Toggle("Apply current filters", isOn: model.binding(\.transferFiltered)).disabled(!model.isBrowsing)
                    Button("Export table…") {
                        Task {
                            guard let table = model.selectedTable else { return }
                            let format = model.transferFormat
                            let connection = model.connection
                            if let url = await chooseDestination(title: "Export whole table", defaultFileName: table.name + "." + format.rawValue), model.selectedTableID == table.id, model.connection === connection, model.transferFormat == format { model.exportTable(to: url) }
                        }
                    }.disabled(!model.canRun || model.selectedTable == nil).fixedSize()
                }.disabled(model.isRunning)
                Text("Streams all matching rows; Max rows and paging do not limit exports. SQL exports data into an existing table.").font(.caption)
                HStack {
                    Text("Append CSV to selected table")
                    Button("Choose CSV…") {
                        Task { if let url = await chooseFile(title: "Import CSV") { model.csvURL = url } }
                    }.disabled(!model.canImportCSV).fixedSize()
                    Text(model.csvURL?.lastPathComponent ?? "No CSV selected")
                }
                HStack {
                    Text("Delimiter")
                    Picker(of: ["Comma", "Semicolon", "Tab", "Pipe"], selection: Binding(get: { Optional(delimiterLabel) }, set: { if let value = $0 { model.csvOptions.delimiter = ["Comma": ",", "Semicolon": ";", "Tab": "\t", "Pipe": "|"][value] ?? "," } })).frame(width: 110)
                    Toggle("Header row", isOn: Binding(get: { model.csvOptions.header }, set: { model.csvOptions.header = $0 }))
                    Text("NULL marker")
                    TextField("NULL marker", text: Binding(get: { model.csvOptions.nullMarker }, set: { model.csvOptions.nullMarker = $0 })).frame(width: 80)
                }.disabled(model.isRunning || model.connectionSafety.readOnly)
                HStack {
                    Toggle("Unquoted empty is NULL", isOn: Binding(get: { model.csvOptions.emptyIsNull }, set: { model.csvOptions.emptyIsNull = $0 }))
                    Button("Preview CSV") { model.previewCSV() }.disabled(model.csvURL == nil || !model.canImportCSV).fixedSize()
                }.disabled(model.isRunning || model.connectionSafety.readOnly)
                Text("UTF-8 CSV · Quoted markers remain literal values. Unmapped columns use database defaults. Imports append within one transaction.").font(.caption)
                if model.connectionSafety.readOnly { Text("CSV import is disabled for this read-only favorite.") }
                if let preview = model.csvPreview {
                    Text("Column mapping · computed columns excluded; identity columns skipped by default")
                    ForEach(Array(preview.headers.indices), id: \.self) { index in
                        CSVMappingRow(model: model, index: index, preview: preview)
                    }
                    Text("First \(preview.samples.count) rows (long preview values truncated):").font(.caption)
                    ForEach(Array(preview.samples.indices), id: \.self) { index in
                        Text(preview.samples[index].map { $0 ?? "NULL" }.joined(separator: "  |  ")).lineLimit(2).font(.system(size: 12, design: .monospaced))
                    }
                    Button("Confirm append to \(model.selectedTable?.name ?? "table")") { model.confirmCSVImport() }.disabled(!model.canConfirmCSV)
                }
                Text(model.transferMessage)
            }.padding(4)
        }
    }
}

private struct CSVMappingRow: View {
    var model: BrowserModel
    let index: Int
    let preview: CSVImportPreview
    // A distinct value prevents a target column named “Skip” colliding with the skip action.
    private var choices: [String] { ["Skip column"] + preview.columns.filter { !$0.computed }.map { "→ " + $0.name } }
    var body: some View {
        HStack {
            Text("\(index + 1). \(preview.headers[index])").frame(width: 220)
            Picker(of: choices, selection: Binding(get: {
                guard model.csvMapping.indices.contains(index), let name = model.csvMapping[index] else { return Optional("Skip column") }
                return Optional("→ " + name)
            }, set: { value in
                guard let value, model.csvMapping.indices.contains(index) else { return }
                model.csvMapping[index] = value == "Skip column" ? nil : String(value.dropFirst(2))
            })).frame(width: 260).disabled(model.isRunning)
        }
    }
}
