import ADBCKit
import SwiftCrossUI

/// Connection picker while disconnected, schema browser once connected.
struct SidebarView: View {
    @Bindable var model: BrowserModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.connection == nil {
                ConnectionPanel(model: model)
            } else {
                SchemaPanel(model: model)
            }
        }
        .padding()
    }
}

struct ConnectionPanel: View {
    @Bindable var model: BrowserModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Profiles").font(.headline)
                Spacer()
                Button("Reload") { model.reloadDiscovery() }
            }

            if model.profiles.isEmpty {
                Text("No profiles in ~/.config/adbc/profiles")
                    .foregroundColor(.gray)
            } else {
                ScrollView {
                    List(model.profiles, selection: model.binding(\.selectedProfileID)) { profile in
                        VStack(alignment: .leading, spacing: 0) {
                            Text(profile.id)
                            Text("\(profile.driver) · \(profile.summary)")
                                .font(.caption)
                                .foregroundColor(.gray)
                                .lineLimit(1)
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }

            Button(model.isConnecting ? "Connecting…" : "Connect to profile") {
                model.connectSelectedProfile()
            }
            .disabled(model.selectedProfileID == nil || model.isConnecting)

            Divider()

            Text("Connect with a URI").font(.headline)
            if model.drivers.isEmpty {
                Text("No ADBC drivers found. Install one with `dbc install postgresql`.")
                    .foregroundColor(.gray)
            } else {
                HStack {
                    Text("Driver")
                    Picker(of: model.drivers, selection: model.binding(\.directDriver))
                }
            }
            TextField("postgresql://user:pass@host:5432/db", text: model.binding(\.directURI))
            Button("Connect") {
                model.connectDirect()
            }
            .disabled(model.directURI.isEmpty || model.isConnecting)
        }
    }
}

struct SchemaPanel: View {
    @Bindable var model: BrowserModel

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
            }

            Divider()

            // A GeometryReader is exactly the size it's offered, whatever its
            // content does, so filtering or re-listing tables re-lays-out
            // only this part instead of the whole window.
            GeometryReader { _ in
                TableBrowser(model: model)
            }
            TableColumnsPanel(model: model)
        }
    }
}

/// Table count, filter and the (capped) table list.
struct TableBrowser: View {
    var model: BrowserModel

    /// The applied filter. It's view-local `@State` rather than a model
    /// property on purpose: SwiftCrossUI's observation merges the reads of
    /// child views into their ancestors, so changing an `@Observable` model
    /// property re-renders the whole window, while `@State` updates only this
    /// view (and the GeometryReader around it stops the relayout here).
    @State private var filter = ""

    /// Every row costs layout time whenever this list is laid out (about
    /// 4.5s with 300 rows vs 1.3s with 50 in a debug build). Filter to find
    /// others.
    static let tableLimit = 50

    var body: some View {
        let tables = model.visibleTables(matching: filter)
        let shown = Array(tables.prefix(Self.tableLimit))
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Tables (\(tables.count))").font(.headline)
                Spacer()
                Button("Refresh") { model.refreshTables() }
            }
            TextField(
                "Filter tables",
                text: Binding(
                    get: { model.tableFilterDraft },
                    set: { text in model.editTableFilter(text) { filter = $0 } }
                )
            )
            Toggle("Show system schemas", isOn: model.binding(\.showSystemSchemas))

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
        }
    }
}

/// Columns of the selected table.
struct TableColumnsPanel: View {
    var model: BrowserModel
    /// Bumped when the model's query state changes; see `onQueryStateChange`.
    @State private var queryStateRevision = 0

    var body: some View {
        let _ = queryStateRevision
        let _ = model.onQueryStateChange("columns") { queryStateRevision &+= 1 }
        VStack(alignment: .leading, spacing: 8) {
            if let table = model.selectedTable, !model.selectedTableColumns.isEmpty {
                Divider()
                Text("Columns of \(table.name)").font(.headline)
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(model.selectedTableColumns, id: \.name) { column in
                            HStack {
                                Text(column.name)
                                Spacer()
                                Text(column.type)
                                    .font(.caption)
                                    .foregroundColor(.gray)
                            }
                        }
                    }
                }
                .frame(height: 180)
            }
        }
    }
}
