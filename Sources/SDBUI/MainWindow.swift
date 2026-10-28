import ADBCKit
import Foundation
import SwiftCrossUI

/// The connected window, laid out like Sequel Ace: a toolbar with the
/// database selector and tabs, the table list on the left and the selected
/// tab on the right.
struct MainWindow: View {
    var model: BrowserModel

    var body: some View {
        VStack(spacing: 0) {
            TopBar(model: model)
                .padding(8)
            Divider()
            // Each pane sits in a GeometryReader, which is exactly the size
            // it's offered, so a pane's content changing size re-lays-out
            // only that pane.
            NavigationSplitView {
                GeometryReader { _ in
                    TableSidebar(model: model)
                }
                .frame(minWidth: 290)
            } detail: {
                GeometryReader { _ in
                    DetailArea(model: model)
                }
            }
            .keepingSidebarWidthOnResize()
        }
    }
}

// MARK: - Toolbar

struct TopBar: View {
    var model: BrowserModel
    @State private var revision = 0

    var body: some View {
        let _ = revision
        let _ = model.watch("topbar", of: { model.selectedTab }) { revision &+= 1 }
        HStack(spacing: 8) {
            Text(model.dialect.namespaceLabel)
                .fixedSize()
            Picker(
                of: model.databases,
                selection: Binding(
                    get: { model.selectedDatabase },
                    set: { model.selectDatabase($0) }
                )
            )
            .fixedSize()
            Spacer()
            HStack(spacing: 2) {
                ForEach(BrowserTab.allCases, id: \.self) { tab in
                    // Bordered for the current tab, flat for the others: a
                    // segmented control (GTK has no segmented picker).
                    // A fixed width keeps flat labels apart and the row from
                    // shifting when the current tab changes.
                    Button(tab.rawValue) { model.selectTab(tab) }
                        .buttonStyle(tab == model.selectedTab ? .bordered : .borderless)
                        .frame(width: 96)
                }
            }
            Spacer()
            Button("Refresh") { model.refreshCurrentTab() }
                .fixedSize()
        }
    }
}

// MARK: - Sidebar

struct TableSidebar: View {
    var model: BrowserModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 0) {
                    Text(model.connectionTitle).font(.headline)
                    Text(model.vendorDescription)
                        .font(.caption)
                        .foregroundColor(.gray)
                }
                Spacer()
                Button("Disconnect") { model.disconnect() }
                    .fixedSize()
            }
            Divider()
            // Filtering re-lays-out only the list (see MainWindow).
            GeometryReader { _ in
                TableBrowser(model: model)
            }
        }
        .padding()
    }
}

/// Table count, the (capped) table list and its filter.
struct TableBrowser: View {
    var model: BrowserModel

    /// Every row costs layout time whenever this list is laid out. Filter to
    /// find others.
    static let tableLimit = 100

    /// The applied filter. It's view-local `@State` rather than a model
    /// property so a change re-renders only this view.
    @State private var filter = ""

    var body: some View {
        let tables = model.visibleTables(matching: filter)
        let shown = Array(tables.prefix(Self.tableLimit))
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                // One label: GTK's ellipsizing labels warn when their text is
                // narrower than "…" (e.g. a lone digit for the count).
                Text(model.tables.isEmpty ? "TABLES" : "TABLES · \(tables.count)")
                    .font(.caption).foregroundColor(.gray)
                    .fixedSize()
                Spacer()
                Button("Reload") { model.refreshTables() }
                    .buttonStyle(.borderless)
                    .fixedSize()
            }
            ScrollView {
                List(
                    shown,
                    selection: Binding(
                        get: { model.selectedTableID },
                        set: { model.selectTable($0) }
                    )
                ) { table in
                    Text(model.label(for: table))
                        .lineLimit(1)
                }
            }
            .frame(maxHeight: .infinity)
            if tables.count > shown.count {
                Text("Showing \(shown.count) of \(tables.count); type to filter.")
                    .font(.caption)
                    .foregroundColor(.gray)
            }
            TextField(
                "Filter tables",
                text: Binding(
                    get: { model.tableFilterDraft },
                    set: { text in model.editTableFilter(text) { filter = $0 } }
                )
            )
        }
    }
}

// MARK: - Detail

struct DetailArea: View {
    var model: BrowserModel

    var body: some View {
        VStack(spacing: 0) {
            TabContent(model: model)
                .frame(maxHeight: .infinity)
            Divider()
            StatusBar(model: model)
                .padding(8)
        }
    }
}

struct TabContent: View {
    var model: BrowserModel
    @State private var revision = 0

    var body: some View {
        let _ = revision
        let _ = model.watch(
            "tab", of: { [AnyHashable(model.selectedTab), model.selectedTableID] }
        ) {
            revision &+= 1
        }
        if model.selectedTab == .query {
            QueryTab(model: model)
        } else if model.selectedTable == nil {
            VStack {
                Spacer()
                Text("Select a table from the list on the left.")
                    .foregroundColor(.gray)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else if model.selectedTab == .content {
            ContentTab(model: model)
        } else if model.selectedTab == .structure {
            StructureTab(model: model)
        } else {
            InfoTab(model: model)
        }
    }
}

struct StatusBar: View {
    var model: BrowserModel
    @State private var revision = 0

    var body: some View {
        let _ = revision
        let _ = model.watch(
            "status",
            of: { [AnyHashable(model.statusMessage), model.errorMessage, model.loadsInFlight] }
        ) {
            revision &+= 1
        }
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(model.loadsInFlight > 0 ? "Loading…  \(model.statusMessage)" : model.statusMessage)
                    .font(.caption)
                Spacer()
            }
            if let error = model.errorMessage {
                Text(error)
                    .foregroundColor(.red)
                    .textSelectionEnabled()
            }
        }
    }
}

/// A result pane's grid, redrawn only when the pane changes. The grid is
/// virtualized: only displayed cells are formatted and drawn.
struct PaneGrid: View {
    var model: BrowserModel
    var pane: ResultPane
    /// Unique per grid, for ``BrowserModel/watch(_:of:_:)``.
    var key: String
    var emptyText = ""
    @State private var revision = 0

    var body: some View {
        let _ = revision
        let _ = model.watch(key, of: { pane.revision }) { revision &+= 1 }
        if pane.hasColumns {
            grid()
        } else {
            VStack(alignment: .leading) {
                HStack {
                    Text(emptyText).foregroundColor(.gray)
                    Spacer()
                }
                Spacer()
            }
        }
    }

    private func grid() -> DataGrid {
        let pane = pane
        let onSort: (@MainActor (DataGridSort) -> Void)?
        if pane.isSortable {
            onSort = { sort in pane.requestSort(sort) }
        } else {
            onSort = nil
        }
        return DataGrid(
            columns: pane.columns,
            rowCount: pane.result?.rowCount ?? 0,
            contentRevision: pane.revision,
            sort: pane.sort,
            onSort: onSort,
            copyCommands: ResultCopy.titles,
            onCopy: { request in pane.copyText(for: request) },
            cell: { row, column in pane.cell(row: row, column: column) }
        )
    }
}

// MARK: - Content tab

struct ContentTab: View {
    var model: BrowserModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FilterBar(model: model)
            PaneGrid(model: model, pane: model.contentPane, key: "content-grid")
                .frame(maxHeight: .infinity)
            ContentPager(model: model)
        }
        .padding()
    }
}

/// Sequel Ace's content filter: column, operator, value.
struct FilterBar: View {
    var model: BrowserModel
    @State private var revision = 0

    var body: some View {
        let _ = revision
        let _ = model.watch(
            "filter",
            of: {
                [
                    AnyHashable(model.contentColumns), model.filterColumn,
                    model.filterOperator?.rawValue, model.contentFilter == nil,
                ]
            }
        ) {
            revision &+= 1
        }
        let columns = model.contentColumns
        HStack(spacing: 8) {
            Text("Filter")
                .fixedSize()
            Picker(
                of: columns,
                selection: Binding(
                    get: { model.filterColumn ?? columns.first },
                    set: { model.filterColumn = $0 }
                )
            )
            .fixedSize()
            Picker(of: SQLDialect.Filter.Operator.allCases, selection: model.binding(\.filterOperator))
                .fixedSize()
            TextField(
                "Value",
                text: Binding(get: { model.filterValue }, set: { model.filterValue = $0 })
            )
            .onSubmit { model.applyContentFilter() }
            Button("Filter") { model.applyContentFilter() }
                .disabled(columns.isEmpty)
                .fixedSize()
            Button("Clear") { model.clearContentFilter() }
                .disabled(model.contentFilter == nil)
                .fixedSize()
        }
    }
}

struct ContentPager: View {
    var model: BrowserModel
    @State private var revision = 0

    var body: some View {
        let _ = revision
        let _ = model.watch(
            "content-pager",
            of: { [model.contentOffset, model.contentHasMore ? 1 : 0, model.contentPane.revision] }
        ) {
            revision &+= 1
        }
        HStack {
            Button("◀ Previous") { model.showContentPage(next: false) }
                .disabled(model.contentOffset == 0)
                .fixedSize()
            Text(model.contentRowsLabel)
                .fixedSize()
            Button("Next ▶") { model.showContentPage(next: true) }
                .disabled(!model.contentHasMore)
                .fixedSize()
            Spacer()
        }
    }
}

// MARK: - Structure tab

struct StructureTab: View {
    var model: BrowserModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Columns").font(.headline)
            PaneGrid(
                model: model, pane: model.structurePane, key: "structure-grid",
                emptyText: "Loading columns…"
            )
            .frame(maxHeight: .infinity)
            if model.dialect.indexesSQL(model.selectedTable!) != nil {
                Text("Indexes").font(.headline)
                PaneGrid(
                    model: model, pane: model.indexPane, key: "index-grid",
                    emptyText: "No indexes"
                )
                .frame(height: 180)
            }
        }
        .padding()
    }
}

// MARK: - Table Info tab

struct InfoTab: View {
    var model: BrowserModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Table information").font(.headline)
            PaneGrid(model: model, pane: model.infoPane, key: "info-grid", emptyText: "Loading…")
                .frame(height: 300)
            CreateStatement(model: model)
                .frame(maxHeight: .infinity)
        }
        .padding()
    }
}

struct CreateStatement: View {
    var model: BrowserModel
    @State private var revision = 0

    var body: some View {
        let _ = revision
        let _ = model.watch("create-statement", of: { model.createStatement }) {
            revision &+= 1
        }
        if model.createStatement.isEmpty {
            Spacer()
        } else {
            // The grid view keeps narrow text top-left and scrolls both ways.
            ResultGrid(header: "Create statement", rows: model.createStatement)
        }
    }
}
