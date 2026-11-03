import SwiftCrossUI
#if canImport(GtkBackend)
import GtkBackend
#endif

struct QueryDocumentBar: View {
    var model: BrowserModel
    @State private var revision = 0
    var body: some View {
        let _ = revision
        let _ = model.watch("query-documents", of: {
            model.queryDrafts.map { "\($0.id)|\($0.name)|\($0.dirty)" } + [model.activeQueryDocument.id.uuidString, String(model.isRunning), model.pendingQueryCloseID?.uuidString ?? ""]
        }) { revision &+= 1 }
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                ScrollView(.horizontal) {
                    HStack(spacing: 4) {
                        ForEach(model.queryDrafts, id: \.id) { draft in
                            HStack(spacing: 4) {
                                Button(draft.name + (draft.dirty ? " *" : "")) { model.selectQueryDocument(draft.id) }
                                    .buttonStyle(draft.id == model.activeQueryDocument.id ? .bordered : .borderless)
                                    .fixedSize()
                                Button(action: { model.closeQueryDocument(draft.id) }) {
                                    #if canImport(GtkBackend)
                                    Text("×").inspect { label in label.ellipsize = .none }
                                    #else
                                    Text("×")
                                    #endif
                                }
                                .buttonStyle(.borderless).fixedSize()
                            }
                        }
                    }
                }
                Button("+ Query") { model.addQueryDocument() }.fixedSize()
                    .disabled(model.queryDocuments.count >= 1000)
            }.disabled(model.isRunning)
            if let closing = model.pendingQueryCloseID {
                HStack {
                    Text("Discard unsaved SQL in \(model.queryDocuments.first { $0.id == closing }?.name ?? "this query")?")
                    Button("Keep query") { model.cancelQueryDocumentClose() }
                    Button("Discard query") { model.confirmQueryDocumentClose() }
                }.disabled(model.isRunning)
            }
        }
    }
}
