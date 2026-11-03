import ADBCKit
import Foundation
import SwiftCrossUI

/// The Query tab: toolbar, SQL editor and results. Show rows browses the
/// selected table here, with a filter bar above the results and a pager below.
struct QueryTab: View {
    var model: BrowserModel
    @State private var revision = 0

    var body: some View {
        let _ = revision
        let _ = model.watch("query-library-layout", of: { [AnyHashable(model.librarySection?.rawValue), AnyHashable(model.queryDocumentsRevision), AnyHashable(model.rowEditDraft != nil), AnyHashable(model.transferVisible)] }) { revision &+= 1 }
        VStack(alignment: .leading, spacing: 8) {
            QueryDocumentBar(model: model)
            QueryToolbar(model: model)
            HStack(alignment: .top, spacing: 12) {
                SQLEditor(model: model, height: model.librarySection == nil ? 180 : 360)
                    .frame(maxWidth: .infinity)
                if let section = model.librarySection {
                    QueryLibraryPanel(model: model, section: section)
                        .frame(width: 400, height: 360)
                }
            }
            QuerySafetyConfirmation(model: model)
            BrowseBar(model: model)
            FilterBar(model: model)
            RowEditingBar(model: model)
            if model.transferVisible {
                TransferView(model: model).frame(maxHeight: .infinity)
            } else if model.rowEditDraft != nil {
                RowEditorView(model: model).frame(maxHeight: .infinity)
            } else {
            PaneGrid(
                model: model, pane: model.queryPane, key: "query-grid",
                emptyText: "Ctrl+L: focus editor · Ctrl+Enter: run statement or selection · Run All: execute script\nEsc: cancel · F5: refresh · Ctrl+P: find table\nSelect a table and choose Show rows to browse without changing your SQL."
            )
            .frame(maxHeight: .infinity)
            }
            ContentPager(model: model).disabled(model.rowEditDraft != nil)
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
            of: { [AnyHashable(model.isRunning), model.canRun, model.queryPane.hasColumns, model.librarySection?.rawValue ?? "", model.libraryFeedback, AnyHashable(model.maxRows)] }
        ) {
            revision &+= 1
        }
        HStack(spacing: 8) {
            Button("Run") {
                model.runCurrentStatement(TextEditorSubmission(text: model.sql, selection: model.editorSelection, cursor: model.editorCursor))
            }
            .disabled(!model.canRun).fixedSize()
            if model.isRunning {
                Button("Cancel") { model.cancelQuery() }.fixedSize()
            }
            CommandMenu(title: "Actions", commands: [
                MenuCommand(title: "Run All", enabled: model.canRun) { model.runQuery() },
                MenuCommand(title: "Explain", enabled: model.canRun) { model.explainQuery() },
                MenuCommand(title: "Export loaded CSV…", enabled: model.queryPane.hasColumns) { export() },
                MenuCommand(title: "Import / export…", enabled: model.canRun) { model.toggleTransfers() },
            ]).fixedSize()
            ForEach(QueryLibrarySection.allCases, id: \.rawValue) { section in
                Button(section.rawValue) { model.toggleLibrary(section) }
                    .buttonStyle(model.librarySection == section ? .bordered : .borderless)
                    .fixedSize()
            }
            Spacer()
            if !model.libraryFeedback.isEmpty {
                Text(model.libraryFeedback).font(.caption).lineLimit(1)
            }
            Text("Max rows").fixedSize()
            Picker(of: model.maxRowsOptions, selection: model.binding(\.maxRows)).fixedSize()
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
    @State private var navigation = EditorErrorNavigation()

    var body: some View {
        // Re-render only when code replaces the text (which bumps
        // `sqlRevision`), not on every keystroke.
        let _ = revision
        let _ = model.watch("editor", of: { [AnyHashable(model.sqlRevision), AnyHashable(model.queryErrorLocation?.id), AnyHashable(model.queryFontSize), AnyHashable(model.completionRevision)] }) { revision &+= 1 }
        TextEditor(text: model.binding(\.sql)) { submission in
            model.runCurrentStatement(submission)
        }
            .assistingSQL(model, navigation: navigation)
            .revealingQueryError(model, navigation: navigation)
            .shortcutFocusTarget("editor")
            .font(.system(size: model.queryFontSize, design: .monospaced))
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
