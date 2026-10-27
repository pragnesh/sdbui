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

    /// Any layout change in the query pane re-lays-out the whole window,
    /// including this list, so its rows cost time on every query run: about
    /// 4.5s with 300 rows vs 1.3s with 50 (debug build). Filter to find others.
    static let tableLimit = 50

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

            let tables = model.visibleTables
            let shown = Array(tables.prefix(Self.tableLimit))
            HStack {
                Text("Tables (\(tables.count))").font(.headline)
                Spacer()
                Button("Refresh") { model.refreshTables() }
            }
            TextField("Filter tables", text: model.binding(\.tableFilterDraft))
            Toggle("Show system schemas", isOn: model.binding(\.showSystemSchemas))

            ScrollView {
                List(shown, selection: model.binding(\.selectedTableID)) { table in
                    Text(model.label(for: table))
                        .lineLimit(1)
                }
            }
            .frame(maxHeight: .infinity)
            .onChange(of: model.selectedTableID) {
                model.openSelectedTable()
            }
            if tables.count > shown.count {
                Text("Showing \(shown.count) of \(tables.count); type to filter.")
                    .font(.caption)
                    .foregroundColor(.gray)
            }

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
