import ADBCKit
import SwiftCrossUI

/// The window while disconnected: saved profiles and URI connect on the left.
struct DisconnectedView: View {
    var model: BrowserModel

    var body: some View {
        NavigationSplitView {
            GeometryReader { _ in
                ConnectionPanel(model: model)
                    .padding()
            }
            .frame(minWidth: 280)
        } detail: {
            VStack(alignment: .leading) {
                Spacer()
                Text("Choose a profile or enter a URI to connect.")
                    .foregroundColor(.gray)
                Spacer()
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

            TextField("Search favorites", text: $search)

            if model.profiles.isEmpty {
                Text("No saved profiles found. Add a TOML profile to your ADBC profiles folder.")
                    .foregroundColor(.gray)
            } else if visibleProfiles.isEmpty {
                Text("No matching favorites").foregroundColor(.gray)
                Spacer()
            } else {
                ScrollView {
                    List(visibleProfiles, selection: model.binding(\.selectedProfileID)) { profile in
                        VStack(alignment: .leading, spacing: 0) {
                            if startsGroup(profile) {
                                Text(profile.group.isEmpty ? "Ungrouped" : profile.group)
                                    .font(.caption)
                                    .foregroundColor(.gray)
                            }
                            Text(profile.name)
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
            .disabled(!visibleProfiles.contains { $0.id == model.selectedProfileID } || model.isConnecting)

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
