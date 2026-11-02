import ADBCKit
import SwiftCrossUI
#if canImport(GtkBackend)
import GtkBackend
#endif

struct FavoriteSafetyBadge: View {
    var safety: FavoriteSafety
    private var color: Color {
        switch safety.color {
        case "Red": .red
        case "Orange": .orange
        case "Yellow": .yellow
        case "Green": .green
        case "Blue": .blue
        case "Purple": .purple
        default: .gray
        }
    }
    var body: some View {
        HStack(spacing: 4) {
            if safety.color != "None" {
                #if canImport(GtkBackend)
                Text("●").inspect { label in label.ellipsize = .none }.foregroundColor(color)
                #else
                Text("●").foregroundColor(color)
                #endif
            }
            if !safety.label.isEmpty { Text(safety.label).foregroundColor(color) }
            if safety.readOnly { Text("Read-only").foregroundColor(color) }
        }
        .font(.caption)
        .fixedSize()
    }
}

struct QuerySafetyConfirmation: View {
    var model: BrowserModel
    @State private var revision = 0
    var body: some View {
        let _ = revision
        let _ = model.watch("query-safety", of: { model.pendingQuery?.sql }) { revision &+= 1 }
        if let request = model.pendingQuery {
            VStack(alignment: .leading, spacing: 8) {
                Text("Confirm potentially destructive SQL").font(.headline).foregroundColor(.orange)
                Text("\(model.connectionTitle): \(request.warnings.joined(separator: ", ")). Review the entire batch before executing.")
                ScrollView([.horizontal, .vertical]) {
                    Text(request.sql).font(.system(size: 12, design: .monospaced)).textSelectionEnabled()
                }
                .frame(height: 120)
                HStack {
                    Button("Cancel execution") { model.cancelPendingQuery() }
                    Button("Execute reviewed SQL") { model.confirmPendingQuery() }
                }
            }
            .padding(8)
        }
    }
}
