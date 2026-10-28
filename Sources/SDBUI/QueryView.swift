import ADBCKit
import Foundation
import SwiftCrossUI

/// SQL editor, toolbar, status line and paged results.
///
/// SwiftCrossUI re-renders a view (and lays out all of its children) when any
/// model property its `body` read changes, so this view reads nothing itself
/// and each part observes only what it shows — typing in the editor must not
/// re-layout the results.
struct QueryView: View {
    var model: BrowserModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            QueryToolbar(model: model)
            SQLEditor(model: model)
            StatusLine(model: model)
            Divider()
            ResultsPane(model: model)
        }
        .padding()
    }
}

struct QueryToolbar: View {
    var model: BrowserModel
    /// Bumped when the model's query state changes; see `onQueryStateChange`.
    @State private var queryStateRevision = 0

    @Environment(\.chooseFileSaveDestination) var chooseFileSaveDestination

    var body: some View {
        let _ = queryStateRevision
        let _ = model.onQueryStateChange("toolbar", of: { [AnyHashable(model.isRunning), model.canRun, model.result?.columns.isEmpty ?? true] }) {
            queryStateRevision &+= 1
        }
        // Controls keep their natural size: squeezed below it in a narrow
        // window, GTK's ellipsizing button labels report inconsistent sizes
        // ("natural size must be >= min size" warnings).
        HStack {
            // A constant label: a size change here would re-lay-out the pane
            // twice per query (the status line already says "Running…").
            Button("Run") { model.runQuery() }
                .disabled(!model.canRun)
                .fixedSize()
            Button("Cancel") { model.cancelQuery() }
                .disabled(!model.isRunning)
                .fixedSize()
            Button("Export CSV") { export() }
                .disabled(model.result?.columns.isEmpty ?? true)
                .fixedSize()
            Spacer()
            Text("Max rows")
                .fixedSize()
            Picker(of: model.maxRowsOptions, selection: model.binding(\.maxRows))
                .fixedSize()
        }
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

struct SQLEditor: View {
    var model: BrowserModel
    /// Bumped when the model's query state changes; see `onQueryStateChange`.
    @State private var queryStateRevision = 0

    var body: some View {
        // Re-render only when code replaces the text (which bumps
        // `sqlRevision`), not on every keystroke.
        let _ = queryStateRevision
        let _ = model.onQueryStateChange("editor", of: { model.sqlRevision }) {
            queryStateRevision &+= 1
        }
        TextEditor(text: model.binding(\.sql))
            .font(.system(size: 13, design: .monospaced))
            .padding(4)
            .background(Color.adaptive(light: Color(white: 0.95), dark: Color(white: 0.15)))
            .cornerRadius(4)
            .frame(height: 180)
    }
}

struct StatusLine: View {
    var model: BrowserModel
    /// Bumped when the model's query state changes; see `onQueryStateChange`.
    @State private var queryStateRevision = 0

    var body: some View {
        let _ = queryStateRevision
        let _ = model.onQueryStateChange("status", of: { [model.statusMessage, model.errorMessage ?? ""] }) {
            queryStateRevision &+= 1
        }
        VStack(alignment: .leading, spacing: 4) {
            Text(model.statusMessage)
                .font(.caption)
            if let error = model.errorMessage {
                Text(error)
                    .foregroundColor(.red)
                    .textSelectionEnabled()
            }
        }
    }
}

struct ResultsPane: View {
    var model: BrowserModel
    /// Bumped when the model's query state changes; see `onQueryStateChange`.
    @State private var queryStateRevision = 0

    var body: some View {
        let _ = queryStateRevision
        let _ = model.onQueryStateChange("results", of: { [model.resultRevision, model.page] }) {
            queryStateRevision &+= 1
        }
        if let result = model.result, !result.columns.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ResultGrid(header: model.gridHeader, rows: model.gridBody)
                    .frame(maxHeight: .infinity)
                HStack {
                    Button("◀ Previous") { model.showPage(model.page - 1) }
                        .disabled(model.page == 0)
                        .fixedSize()
                    Text(pageLabel(result))
                        .fixedSize()
                    Button("Next ▶") { model.showPage(model.page + 1) }
                        .disabled(model.page + 1 >= model.pageCount)
                        .fixedSize()
                    Spacer()
                }
            }
        } else {
            VStack(alignment: .leading) {
                Text(model.connection == nil
                    ? "Connect to a database from the sidebar to start querying."
                    : "Write a query and press Run.")
                    .foregroundColor(.gray)
                Spacer()
            }
        }
    }

    private func pageLabel(_ result: QueryResult) -> String {
        let range = model.pageRange
        guard !range.isEmpty else { return "No rows" }
        return "Rows \(range.lowerBound + 1)–\(range.upperBound) of \(result.rows.count)"
            + (result.truncated ? "+" : "")
    }
}

/// The current result page as two monospaced labels (see ``ResultText``).
struct ResultGrid: View {
    var header: String
    var rows: String

    /// Last real size of the viewport, used to pad the content to fill it.
    @State private var viewportWidth = 0.0
    @State private var viewportHeight = 0.0

    var body: some View {
        GeometryReader { proxy in
            let _ = remember(proxy.size)
            ScrollView([.horizontal, .vertical]) {
                // A two-axis ScrollView centres content smaller than itself, so
                // invisible struts make the content at least viewport-sized and
                // the stacks pin the grid to the top-leading corner.
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top, spacing: 0) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(header)
                                .fontWeight(.bold)
                            Divider()
                            Text(rows)
                                .textSelectionEnabled()
                        }
                        .font(.system(size: 12, design: .monospaced))
                        .padding(4)
                        Color.clear.frame(width: 1, height: max(viewportHeight - 2, 1))
                    }
                    Color.clear.frame(width: max(viewportWidth - 2, 1), height: 1)
                }
            }
        }
    }

    /// The strut sizes can't come straight from the proxy: a ScrollView keeps
    /// its content's first layout of an update (its proposal never changes),
    /// and the first pass sees a probing size. So keep the real size in state
    /// and apply it on the next update, where every pass agrees.
    private func remember(_ size: ViewSize) {
        let width = size.width
        let height = size.height
        guard width.isFinite, height.isFinite, width > 0, height > 0,
            width != viewportWidth || height != viewportHeight
        else { return }
        Task { @MainActor in
            viewportWidth = width
            viewportHeight = height
        }
    }
}
