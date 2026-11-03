import Foundation
import Observation
import SwiftCrossUI
#if canImport(GtkBackend)
import CGtk
import CResultValue
import GtkBackend
#elseif canImport(AppKit)
import AppKit
#endif

struct QueryStatusLine: View {
    var model: BrowserModel
    @State private var revision = 0

    var body: some View {
        let _ = revision
        let _ = model.watch("query-status", of: { model.queryStatus }) { revision &+= 1 }
        if let status = model.queryStatus {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(status.text)
                        .font(.caption)
                        .foregroundColor(status.truncated ? .orange : .gray)
                    Spacer()
                    if let error = status.error { CopyErrorButton(error: error) }
                }
                if let error = status.error {
                    Text(error).foregroundColor(.red).textSelectionEnabled().lineLimit(5)
                }
            }
        }
    }
}

struct CopyErrorButton: View {
    let error: String
    @State private var copied = false

    var body: some View {
        Button(copied ? "Copied" : "Copy error") {
            #if canImport(GtkBackend)
                if let display = gdk_display_get_default(), let clipboard = gdk_display_get_clipboard(display) {
                    gdk_clipboard_set_text(clipboard, error)
                    copied = true
                }
            #elseif canImport(AppKit)
                NSPasteboard.general.clearContents()
                copied = NSPasteboard.general.setString(error, forType: .string)
            #endif
        }
        .fixedSize()
        .onChange(of: error) { copied = false }
    }
}

@Observable
@MainActor
final class EditorErrorNavigation {
    @ObservationIgnored var appliedID: UUID?
    @ObservationIgnored var appliedDocument: UUID?
}

extension View {
    @ViewBuilder
    func revealingQueryError(_ model: BrowserModel, navigation: EditorErrorNavigation) -> some View {
        #if canImport(GtkBackend)
            inspect(.afterUpdate) { widget in
                guard let location = model.queryErrorLocation, navigation.appliedID != location.id,
                      location.sourceSQL == model.sql, let offset = Int32(exactly: location.offset) else { return }
                if sdbui_editor_reveal(UnsafeMutableRawPointer(widget.widgetPointer), offset) != 0 {
                    navigation.appliedID = location.id
                }
            }
        #elseif canImport(AppKitBackend)
            revealingMacQueryError(model, navigation: navigation)
        #else
            self
        #endif
    }
}
