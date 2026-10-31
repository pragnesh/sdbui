import ADBCKit
import Foundation
import SwiftCrossUI

/// The Query tab: toolbar, SQL editor and results. Clicking a table browses
/// it here, with a filter bar above the results and a pager below.
struct QueryTab: View {
    var model: BrowserModel
    @State private var revision = 0

    var body: some View {
        let _ = revision
        let _ = model.watch("query-library-layout", of: { model.librarySection?.rawValue }) { revision &+= 1 }
        VStack(alignment: .leading, spacing: 8) {
            QueryToolbar(model: model)
            QueryLibraryBar(model: model)
            HStack(alignment: .top, spacing: 12) {
                SQLEditor(model: model, height: model.librarySection == nil ? 180 : 360)
                    .frame(maxWidth: .infinity)
                if let section = model.librarySection {
                    QueryLibraryPanel(model: model, section: section)
                        .frame(width: 400, height: 360)
                }
            }
            FilterBar(model: model)
            PaneGrid(
                model: model, pane: model.queryPane, key: "query-grid",
                emptyText: "Click a table, or write a query and press Run All."
            )
            .frame(maxHeight: .infinity)
            ContentPager(model: model)
        }
        .padding()
    }
}

struct QueryToolbar: View {
    var model: BrowserModel
    @State private var revision = 0

    @Environment(\.chooseFileSaveDestination) var chooseFileSaveDestination

    var body: some View {
        let _ = revision
        let _ = model.watch(
            "query-toolbar",
            of: { [AnyHashable(model.isRunning), model.canRun, model.queryPane.hasColumns] }
        ) {
            revision &+= 1
        }
        // Controls keep their natural size: squeezed below it in a narrow
        // window, GTK's ellipsizing button labels report inconsistent sizes
        // ("natural size must be >= min size" warnings).
        HStack {
            // A constant label: a size change here would re-lay-out the pane
            // twice per query (the status bar already says "Running…").
            Button("Run All") { model.runQuery() }
                .disabled(!model.canRun)
                .fixedSize()
            Button("Cancel") { model.cancelQuery() }
                .disabled(!model.isRunning)
                .fixedSize()
            Button("Export CSV") { export() }
                .disabled(!model.queryPane.hasColumns)
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
            model.exportCSV(model.queryPane, to: url)
        }
    }
}

struct SQLEditor: View {
    var model: BrowserModel
    var height: Double = 180
    @State private var revision = 0

    var body: some View {
        // Re-render only when code replaces the text (which bumps
        // `sqlRevision`), not on every keystroke.
        let _ = revision
        let _ = model.watch("editor", of: { model.sqlRevision }) { revision &+= 1 }
        TextEditor(text: model.binding(\.sql)) { submission in
            model.runCurrentStatement(submission)
        }
            .font(.system(size: 13, design: .monospaced))
            .padding(4)
            .background(Color.adaptive(light: Color(white: 0.95), dark: Color(white: 0.15)))
            .cornerRadius(4)
            .frame(height: height)
    }
}

/// Monospaced text that scrolls both ways and stays in the top-leading
/// corner when it's smaller than the viewport (used for CREATE statements).
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
