import ADBCKit
import Foundation
import SwiftCrossUI

/// The connected window, laid out like Sequel Ace: a toolbar with the tabs,
/// the database and table lists on the left and the selected tab on the
/// right.
struct MainWindow: View {
    var model: BrowserModel

    var body: some View {
        VStack(spacing: 0) {
            TopBar(model: model)
                .padding(8)
            Divider()
            DisconnectConfirmation(model: model)
            if model.isConnectionLost {
                HStack(spacing: 8) {
                    Text(model.isConnecting ? "Reconnecting…" : "Connection lost. Your SQL is preserved.")
                        .foregroundColor(.red)
                    Spacer()
                    Button(model.isConnecting ? "Reconnecting…" : "Reconnect") { model.reconnect() }
                        .disabled(model.isConnecting)
                }
                .padding(8)
                Divider()
            }
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
            .keepingSidebarWidthOnResize(model: model)
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
            FavoriteSafetyBadge(safety: model.connectionSafety)
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
                .disabled(!model.canUseConnection)
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
                Button("Disconnect") { model.requestDisconnect() }
                    .fixedSize()
            }
            Divider()
            // Drag the divider to share the height between the lists.
            // Filtering re-lays-out only its list (see MainWindow).
            VSplitView(topHeight: 200) {
                GeometryReader { _ in
                    DatabaseList(model: model)
                        .padding(.bottom, 8)
                }
                .frame(minHeight: 110)
            } bottom: {
                GeometryReader { _ in
                    TableBrowser(model: model)
                        .padding(.top, 8)
                }
                .frame(minHeight: 140)
            }
            .disabled(!model.canUseConnection)
        }
        .padding()
    }
}

/// The databases (MySQL) or schemas (PostgreSQL) that contain tables;
/// selecting one shows its tables below.
struct DatabaseList: View {
    var model: BrowserModel
    @State private var filter = ""

    var body: some View {
        let all = model.databases
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        let databases = needle.isEmpty ? all : all.filter { $0.lowercased().contains(needle) }
        VStack(alignment: .leading, spacing: 8) {
            Text(
                all.isEmpty
                    ? "\(model.dialect.namespaceLabel.uppercased())S"
                    : "\(model.dialect.namespaceLabel.uppercased())S · \(databases.count)"
            )
            .font(.caption).foregroundColor(.gray)
            .fixedSize()
            ScrollView {
                List(
                    databases,
                    id: \.self,
                    selection: Binding(
                        get: { model.selectedDatabase },
                        // A list can clear its selection; keep showing a database.
                        set: { if let database = $0 { model.selectDatabase(database) } }
                    )
                ) { database in
                    Text(database)
                        .lineLimit(1)
                }
            }
            .frame(maxHeight: .infinity)
            TextField("Filter \(model.dialect.namespaceLabel.lowercased())s", text: $filter)
        }
    }
}

/// Table count, virtualized names and fuzzy filter.
struct TableBrowser: View {
    var model: BrowserModel

    /// Redraw only this view after typing pauses. The text stays in the
    /// session model so returning to a connection restores its filter.
    @State private var filterRevision = 0

    var body: some View {
        let _ = filterRevision
        let tables = model.visibleTables(matching: model.tableFilterDraft)
        let _ = model.watch("table-sidebar-selection", of: { model.selectedTableID }) { filterRevision &+= 1 }
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
            #if canImport(GtkBackend)
            VirtualTableList(rows: tables.map { TableSidebarRow(id: $0.id, label: model.label(for: $0)) },
                selection: model.selectedTableID, model: model)
                .frame(maxHeight: .infinity)
            #else
            ScrollView {
                List(tables, selection: Binding(get: { model.selectedTableID }, set: { model.selectTable($0) })) { table in
                    Text(model.label(for: table)).lineLimit(1)
                }
            }
            .frame(maxHeight: .infinity)
            #endif
            TextField(
                "Filter tables",
                text: Binding(
                    get: { model.tableFilterDraft },
                    set: { text in model.editTableFilter(text) { _ in filterRevision &+= 1 } }
                )
            )
            .shortcutFocusTarget("table-filter")
            .onSubmit { model.flushTableFilter(); filterRevision &+= 1 }
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
            of: { [AnyHashable(model.statusMessage), model.errorMessage, model.loadsInFlight, model.selectedTab, model.queryStatus] }
        ) {
            revision &+= 1
        }
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(model.loadsInFlight > 0 && !model.isConnectionLost ? "Loading…  \(model.statusMessage)" : model.statusMessage)
                    .font(.caption)
                Spacer()
            }
            if let error = model.errorMessage,
               model.selectedTab != .query || model.queryStatus?.error != error {
                HStack(spacing: 8) {
                    Text(error).foregroundColor(.red).textSelectionEnabled()
                    Spacer()
                    CopyErrorButton(error: error)
                }
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
        let _ = model.watch(key, of: { [AnyHashable(pane.revision), AnyHashable(ObjectIdentifier(pane)), AnyHashable(model.queryFontSize)] }) { revision &+= 1 }
        if pane.hasColumns {
            VStack(alignment: .leading, spacing: 4) {
                if !pane.hiddenColumns.isEmpty || pane.frozenCount > 0 {
                    HStack {
                        if !pane.hiddenColumns.isEmpty {
                            Button("Show all columns") { _ = pane.headerCommand(8, column: pane.visibleColumns[0]) }
                        }
                        if pane.frozenCount > 0 {
                            Button("Unfreeze columns") { _ = pane.headerCommand(7, column: pane.visibleColumns[0]) }
                        }
                        Spacer()
                    }
                }
                if pane.frozenCount > 0 {
                    HStack(spacing: 0) {
                        grid(columns: pane.frozenColumns)
                            .frame(width: Double(min(400, pane.frozenColumns.reduce(0) { $0 + pane.columns[$1].width })))
                        Divider()
                        grid(columns: pane.scrollingColumns).frame(maxWidth: .infinity)
                    }
                    .synchronizingFrozenGrid()
                } else {
                    grid(columns: pane.visibleColumns)
                }
            }
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

    private func grid(columns: [Int]) -> some View {
        let pane = pane
        let onSort: (@MainActor (DataGridSort) -> Void)?
        if pane.isSortable {
            onSort = { sort in
                guard columns.indices.contains(sort.column) else { return }
                pane.requestSort(DataGridSort(column: columns[sort.column], ascending: sort.ascending))
            }
        } else {
            onSort = nil
        }
        let grid = DataGrid(
            columns: columns.map { pane.columns[$0] },
            rowCount: pane.result?.rowCount ?? 0,
            contentRevision: pane.revision,
            sort: pane.sort.flatMap { sort in columns.firstIndex(of: sort.column).map { DataGridSort(column: $0, ascending: sort.ascending) } },
            onSort: onSort,
            copyCommands: ResultCopy.titles,
            onCopy: { request in
                pane.copyText(for: DataGridCopyRequest(command: request.command, rows: request.rows,
                    column: request.column.flatMap { columns.indices.contains($0) ? columns[$0] : nil }))
            },
            cell: { row, column in pane.cell(row: row, column: columns[column]) }
        )
        #if canImport(GtkBackend)
            return grid.inspectingValues(in: pane, model: model, columns: columns).queryGridFontSize(model.queryFontSize)
        #else
            return grid
        #endif
    }
}

// MARK: - Table browsing controls (shown in the Query tab)

/// Show rows for the selected table, and while browsing, the SELECT behind
/// the rows. Browsing leaves the SQL editor alone.
struct BrowseBar: View {
    var model: BrowserModel
    @State private var revision = 0

    var body: some View {
        let _ = revision
        let _ = model.watch(
            "browse-bar",
            of: { [AnyHashable(model.isBrowsing), model.selectedTableID, model.browseSQL, model.canRun] }
        ) {
            revision &+= 1
        }
        if let table = model.selectedTable {
            HStack(spacing: 8) {
                if !model.isBrowsing {
                    Button("Show rows") { model.browseSelectedTable() }
                        .disabled(!model.canRun)
                        .fixedSize()
                }
                Text(model.isBrowsing ? model.browseSQL : "Rows of \(table.name)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.gray)
                    .lineLimit(1)
                Spacer()
            }
        }
    }
}

/// Sequel Ace's content filter (column, operator, value), shown while the
/// Query tab is browsing a table.
struct FilterBar: View {
    var model: BrowserModel
    @State private var revision = 0

    var body: some View {
        let _ = revision
        let _ = model.watch(
            "filter",
            of: {
                [
                    AnyHashable(model.isBrowsing), model.contentColumns, model.filterColumn,
                    model.filterOperator?.rawValue, model.contentFilter == nil, model.filterValue,
                ]
            }
        ) {
            revision &+= 1
        }
        let columns = model.contentColumns
        if model.isBrowsing {
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
                .disabled(model.filterOperator?.needsValue == false)
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
}

struct ContentPager: View {
    var model: BrowserModel
    @State private var revision = 0
    @State private var page = ""

    var body: some View {
        let _ = revision
        let _ = model.watch(
            "content-pager",
            of: {
                [
                    model.isBrowsing ? 1 : 0, model.contentOffset, model.contentHasMore ? 1 : 0,
                    model.queryPane.revision, model.selectedTableID.flatMap { model.rowEstimates[$0] }.map(Int.init) ?? -1, model.isRunning ? 1 : 0,
                ]
            }
        ) {
            revision &+= 1
        }
        if model.isBrowsing {
            HStack {
                Button("◀ Previous") { model.showContentPage(next: false) }
                    .disabled(!model.canRun || model.contentOffset == 0)
                    .fixedSize()
                Text(model.contentRowsLabel)
                    .fixedSize()
                Text("Page \(model.contentPage)").font(.caption)
                TextField("Go to page", text: $page)
                    .onSubmit { model.goToContentPage(page) }
                    .frame(width: 100)
                    .disabled(!model.canRun)
                Button("Go") { model.goToContentPage(page) }.disabled(!model.canRun)
                Button("Next ▶") { model.showContentPage(next: true) }
                    .disabled(!model.canRun || !model.contentHasMore)
                    .fixedSize()
                Spacer()
            }
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
