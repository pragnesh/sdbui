import ADBCKit
import Foundation
import SwiftCrossUI
#if canImport(GtkBackend)
import GtkBackend
import Gtk
import CGtk
#endif

/// Favorites stay in the sidebar; their editable settings occupy the detail pane.
struct DisconnectedView: View {
    var model: BrowserModel

    var body: some View {
        NavigationSplitView {
            GeometryReader { _ in
                ConnectionPanel(model: model).padding()
            }
            .frame(minWidth: 280)
        } detail: {
            VStack(alignment: .leading, spacing: 12) {
                ScrollView {
                    ConnectionForm(model: model).padding()
                }
                StatusBar(model: model)
            }
            .padding()
        }
        .keepingSidebarWidthOnResize()
    }
}

struct ConnectionPanel: View {
    @Bindable var model: BrowserModel
    @State private var search = ""

    private var visibleProfiles: [ConnectionProfile] {
        model.profiles.filter { $0.matches(search) }
    }

    private func startsGroup(_ profile: ConnectionProfile) -> Bool {
        let profiles = visibleProfiles
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return false }
        return index == 0 || profiles[index - 1].group != profile.group
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Favorites").font(.headline)
                Spacer()
                Button("Reload") { model.reloadDiscovery() }
            }
            Button("New connection") { model.newFavorite() }
            TextField("Search favorites", text: $search)
            if model.profiles.isEmpty {
                Text("No favorites yet. Enter connection settings and choose Save.")
                    .foregroundColor(.gray)
                Spacer()
            } else if visibleProfiles.isEmpty {
                Text("No matching favorites").foregroundColor(.gray)
                Spacer()
            } else {
                ScrollView {
                    List(visibleProfiles, selection: Binding(
                        get: { model.selectedProfileID },
                        set: { model.selectFavorite($0) }
                    )) { profile in
                        VStack(alignment: .leading, spacing: 0) {
                            if startsGroup(profile) {
                                Text(profile.group.isEmpty ? "Ungrouped" : profile.group)
                                    .font(.caption).foregroundColor(.gray)
                            }
                            HStack {
                                Text(profile.name)
                                FavoriteSafetyBadge(safety: profile.safety)
                            }
                            Text("\(profile.driver) · \(profile.summary)")
                                .font(.caption).foregroundColor(.gray).lineLimit(1)
                        }
                    }
                    .connectingOnProfileActivation(visibleProfiles, model: model)
                }
                .frame(maxHeight: .infinity)
            }
        }
        .disabled(model.isConnecting)
    }
}

struct ConnectionForm: View {
    @Bindable var model: BrowserModel
    @State private var showSSH = false

    private func field(_ keyPath: WritableKeyPath<ConnectionDraft, String>) -> Binding<String> {
        Binding(get: { model.connectionDraft[keyPath: keyPath] }, set: { value in
            if model.connectionDraft[keyPath: keyPath] != value {
                model.connectionDraft[keyPath: keyPath] = value
                model.connectionFeedback = ""
            }
        })
    }

    private var driverNames: [String] {
        Array(Set(model.drivers.map(\.id) + ["postgresql", "mysql", "sqlite", "duckdb", model.connectionDraft.driver])).sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.selectedProfileID == nil ? "New connection" : "Connection settings").font(.title2)
            Text("Name (required to save; use Group/Name to organize favorites)")
            TextField("Work/Production", text: field(\.name))
            Text("Environment label")
            TextField("Production, Staging, Development…", text: Binding(
                get: { model.connectionDraft.safety.label },
                set: { model.connectionDraft.safety.label = $0 }))
            Text("Environment color")
            Picker(of: FavoriteSafety.colors, selection: Binding(
                get: { Optional(model.connectionDraft.safety.color) },
                set: { if let value = $0 { model.connectionDraft.safety.color = value } }))
            Toggle("Read-only connection", isOn: Binding(
                get: { model.connectionDraft.safety.readOnly },
                set: { model.connectionDraft.safety.readOnly = $0 }))
            Text("Read-only queries run in database-enforced read-only transactions on PostgreSQL and MySQL. Other drivers are blocked in this mode.")
                .font(.caption).foregroundColor(.gray)
            HStack(spacing: 8) {
                Button("Connection") { showSSH = false }
                Button(model.connectionDraft.ssh.enabled ? "SSH Tunnel (enabled)" : "SSH Tunnel") { showSSH = true }
            }
            if showSSH {
                SSHTunnelForm(model: model)
            } else {
                Text("Driver")
                Picker(of: driverNames, selection: Binding(
                    get: { Optional(model.connectionDraft.driver) },
                    set: { value in
                        guard let value, value != model.connectionDraft.driver else { return }
                        model.connectionDraft.selectDriver(value)
                        model.connectionFeedback = ""
                    }
                ))
                if !model.drivers.contains(where: { $0.id == model.connectionDraft.driver }) {
                    Text("Driver not discovered. Install it with dbc, then choose Reload.")
                        .font(.caption).foregroundColor(.gray)
                }
                if model.connectionDraft.supportsFields {
                    Toggle("Use connection URI", isOn: Binding(
                        get: { model.connectionDraft.useURI },
                        set: { value in
                            guard value != model.connectionDraft.useURI else { return }
                            if value {
                                do { model.connectionDraft.uri = try model.connectionDraft.connectionURI() }
                                catch { model.connectionFeedback = "\(error)"; return }
                            } else {
                                // Reparse edited URI fields while retaining driver-specific options.
                                do {
                                    let temporary = ConnectionProfile(
                                        id: model.connectionDraft.name, driver: model.connectionDraft.driver,
                                        options: try model.connectionDraft.connectionOptions(),
                                        url: model.connectionDraft.originalURL ?? URL(fileURLWithPath: "/"))
                                    let parsed = ConnectionDraft(profile: temporary)
                                    guard !parsed.useURI else {
                                        model.connectionFeedback = "This URI needs URI mode (for example, templates or socket options)."
                                        return
                                    }
                                    model.connectionDraft.applyURIFields(from: parsed)
                                } catch { model.connectionFeedback = "\(error)"; return }
                            }
                            model.connectionDraft.useURI = value
                            model.connectionFeedback = ""
                        }
                    ))
                }
                if model.connectionDraft.useURI || !model.connectionDraft.supportsFields {
                    Text("Connection URI")
                    SecureField("Enter connection URI", text: field(\.uri))
                    Text("URI credentials are hidden. Environment placeholders in saved profiles are supported.")
                        .font(.caption).foregroundColor(.gray)
                } else {
                    Text("Host")
                    TextField("localhost", text: field(\.host))
                    Text("Port")
                    TextField(model.connectionDraft.defaultPort, text: field(\.port))
                    Text("User")
                    TextField("Username", text: field(\.user))
                    Text("Password")
                    SecureField("Password", text: field(\.password))
                    Text("Database")
                    TextField("Database", text: field(\.database))
                    Text("SSL mode")
                    Picker(of: model.connectionDraft.sslModes, selection: Binding(
                        get: { Optional(model.connectionDraft.sslMode) },
                        set: { value in
                            if let value, value != model.connectionDraft.sslMode {
                                model.connectionDraft.sslMode = value
                                model.connectionFeedback = ""
                            }
                        }
                    ))
                }
            }
            Text("Saved favorites store passwords in plain text in your ADBC profiles folder.")
                .font(.caption).foregroundColor(.gray)
            HStack(spacing: 8) {
                Button("Test") { model.testFavorite() }
                Button("Save") { model.saveFavorite() }
                Spacer()
                Button(model.isConnecting ? "Connecting…" : "Connect") { model.connectFavorite() }
            }
            if !model.connectionFeedback.isEmpty { Text(model.connectionFeedback) }
        }
        .disabled(model.isConnecting)
        .frame(maxWidth: 640)
    }
}


struct SSHTunnelForm: View {
    @Bindable var model: BrowserModel

    private func field(_ keyPath: WritableKeyPath<SSHSettings, String>) -> Binding<String> {
        Binding(get: { model.connectionDraft.ssh[keyPath: keyPath] }, set: { value in
            guard value != model.connectionDraft.ssh[keyPath: keyPath] else { return }
            model.connectionDraft.ssh[keyPath: keyPath] = value
            model.connectionFeedback = ""
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SSH tunnel").font(.headline)
            Toggle("Connect through SSH", isOn: Binding(
                get: { model.connectionDraft.ssh.enabled },
                set: { value in
                    guard value != model.connectionDraft.ssh.enabled else { return }
                    model.connectionDraft.ssh.enabled = value
                    model.connectionFeedback = ""
                }
            ))
            VStack(alignment: .leading, spacing: 12) {
                Text("SSH host or config alias")
                TextField("bastion.example.com", text: field(\.host))
                Text("SSH port")
                TextField("22", text: field(\.port))
                Text("SSH username (optional; defaults to SSH configuration)")
                TextField("Username", text: field(\.user))
                Text("Identity file (optional; uses SSH agent and default keys if empty)")
                TextField("~/.ssh/id_ed25519", text: field(\.identityFile))
            }
            .disabled(!model.connectionDraft.ssh.enabled || model.isConnecting)
            Text("Set the database host and port on the Connection tab as seen from the SSH server. The local forwarding port is chosen automatically.")
                .font(.caption).foregroundColor(.gray)
            Text("Uses OpenSSH keys or your SSH agent. Trust the server in your terminal first; password and key-passphrase prompts are not shown here.")
                .font(.caption).foregroundColor(.gray)
        }
    }
}

private extension View {
    @ViewBuilder
    func connectingOnProfileActivation(_ profiles: [ConnectionProfile], model: BrowserModel) -> some View {
        #if canImport(GtkBackend)
            inspect([.onCreate, .afterUpdate]) { widget in
                guard let list = widget as? Gtk.ListBox else { return }
                // GTK's row activation also supports Enter on the selected row.
                // Refresh the mapping after filtering, rather than indexing all favorites.
                list.activateOnSingleClick = false
                list.rowActivated = { _, row in
                    let index = Int(gtk_list_box_row_get_index(row))
                    guard profiles.indices.contains(index) else { return }
                    model.activateFavorite(profiles[index].id)
                }
            }
        #else
            self
        #endif
    }
}
