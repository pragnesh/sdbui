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
