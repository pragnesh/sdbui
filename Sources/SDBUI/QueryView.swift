import ADBCKit
import Foundation
import SwiftCrossUI

/// SQL editor, toolbar, status line and paged results.
struct QueryView: View {
    @Bindable var model: BrowserModel

    @Environment(\.chooseFileSaveDestination) var chooseFileSaveDestination

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(model.isRunning ? "Running…" : "Run") { model.runQuery() }
                    .disabled(!model.canRun)
                Button("Cancel") { model.cancelQuery() }
                    .disabled(!model.isRunning)
                Button("Export CSV") { export() }
                    .disabled(model.result?.columns.isEmpty ?? true)
                Spacer()
                Text("Max rows")
                Picker(of: model.maxRowsOptions, selection: $model.maxRows)
            }

            TextEditor(text: $model.sql)
                .font(.system(size: 13, design: .monospaced))
                .padding(4)
                .background(Color.adaptive(light: Color(white: 0.95), dark: Color(white: 0.15)))
                .cornerRadius(4)
                .frame(height: 180)

            Text(model.statusMessage)
                .font(.caption)
            if let error = model.errorMessage {
                Text(error)
                    .foregroundColor(.red)
                    .textSelectionEnabled()
            }

            Divider()

            if let result = model.result, !result.columns.isEmpty {
                ResultGrid(result: result, rows: model.pageRange)
                    .frame(maxHeight: .infinity)
                HStack {
                    Button("◀ Previous") { model.page -= 1 }
                        .disabled(model.page == 0)
                    Text(pageLabel(result))
                    Button("Next ▶") { model.page += 1 }
                        .disabled(model.page + 1 >= model.pageCount)
                    Spacer()
                }
            } else {
                Text(model.connection == nil
                    ? "Connect to a database from the sidebar to start querying."
                    : "Write a query and press Run.")
                    .foregroundColor(.gray)
                Spacer()
            }
        }
        .padding()
    }

    private func pageLabel(_ result: QueryResult) -> String {
        let range = model.pageRange
        guard !range.isEmpty else { return "No rows" }
        return "Rows \(range.lowerBound + 1)–\(range.upperBound) of \(result.rows.count)"
            + (result.truncated ? "+" : "")
    }

    private func export() {
        Task {
            guard let url = await chooseFileSaveDestination(
                title: "Export results", defaultFileName: "results.csv")
            else { return }
            model.exportCSV(to: url)
        }
    }
}

/// A scrollable grid of result cells with fixed-width columns.
///
/// SwiftCrossUI's `Table` needs its columns at compile time, so query results
/// (whose columns are only known at runtime) are laid out with stacks.
struct ResultGrid: View {
    var result: QueryResult
    var rows: Range<Int>

    private var widths: [Double] {
        // Size each column from the header and a sample of rows.
        let sample = result.rows.prefix(200)
        return result.columns.indices.map { column in
            let header = max(result.columns[column].name.count, result.columns[column].type.count)
            let longest = sample.map { ($0[column] ?? "NULL").count }.max() ?? 0
            return Double(min(max(header, longest, 4), 48)) * 8 + 16
        }
    }

    var body: some View {
        let widths = self.widths
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    ForEach(Array(result.columns.indices), id: \.self) { column in
                        VStack(alignment: .leading, spacing: 0) {
                            Text(result.columns[column].name)
                                .fontWeight(.bold)
                                .lineLimit(1)
                            Text(result.columns[column].type)
                                .font(.caption)
                                .foregroundColor(.gray)
                                .lineLimit(1)
                        }
                        .padding(4)
                        .frame(width: widths[column], alignment: .leading)
                    }
                }
                Divider()
                ForEach(Array(rows), id: \.self) { row in
                    HStack(spacing: 0) {
                        ForEach(Array(result.columns.indices), id: \.self) { column in
                            cell(result.rows[row][column])
                                .padding(4)
                                .frame(width: widths[column], alignment: .leading)
                        }
                    }
                    .background(row % 2 == 0
                        ? Color.adaptive(light: Color(white: 1), dark: Color(white: 0.11))
                        : Color.adaptive(light: Color(white: 0.96), dark: Color(white: 0.14)))
                }
            }
            .font(.system(size: 12, design: .monospaced))
        }
    }

    @ViewBuilder
    private func cell(_ value: String?) -> some View {
        if let value {
            Text(value.replacingOccurrences(of: "\n", with: "↵"))
                .lineLimit(1)
                .textSelectionEnabled()
        } else {
            Text("NULL")
                .foregroundColor(.gray)
                .lineLimit(1)
        }
    }
}
