import SwiftCrossUI

struct DisconnectConfirmation: View {
    var model: BrowserModel
    @State private var revision = 0
    var body: some View {
        let _ = revision
        let _ = model.watch("disconnect-confirmation", of: { model.pendingDisconnect }) { revision &+= 1 }
        if model.pendingDisconnect {
            VStack(alignment: .leading, spacing: 6) {
                Text("Disconnect while a query is running?").font(.headline)
                Text("Cancellation will be requested. Statements already completed are not rolled back; your editor SQL is preserved.")
                HStack {
                    Button("Stay connected") { model.cancelDisconnect() }
                    Button("Cancel query and disconnect") { model.confirmDisconnect() }
                }
            }.padding(8)
        }
    }
}

struct StatementLogView: View {
    var model: BrowserModel
    @State private var revision = 0
    @State private var expanded = true
    var body: some View {
        let _ = revision
        let _ = model.watch("statement-log", of: { model.statementLog }) { revision &+= 1 }
        if !model.statementLog.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Button(expanded ? "Hide statement log" : "Show statement log") { expanded.toggle() }
                if expanded {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(Array(model.statementLog.enumerated()), id: \.offset) { item in
                                Text(item.element).font(.caption).textSelectionEnabled()
                            }
                        }
                    }.frame(height: 80)
                }
            }
        }
    }
}
