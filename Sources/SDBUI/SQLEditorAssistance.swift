import Foundation
import SwiftCrossUI
#if canImport(GtkBackend)
import CResultValue
import GtkBackend

@MainActor
private final class EditorSource {
    weak var model: BrowserModel?
    init(_ model: BrowserModel) { self.model = model }
}
private let editorCompletion: SDBUIEditorComplete = { context, text, cursor, start in
    let completion: SQLCompletion? = MainActor.assumeIsolated {
        guard let context, let text else { return nil }
        return Unmanaged<EditorSource>.fromOpaque(context).takeUnretainedValue().model?
            .editorCompletions(text: String(cString: text), cursor: Int(cursor))
    }
    guard let completion else { return nil }
    start?.pointee = Int32(completion.start)
    let values = completion.values.filter { !$0.contains("\n") && !$0.contains("\0") }
    return values.isEmpty ? nil : strdup(values.joined(separator: "\n"))
}
private let editorPosition: SDBUIEditorPosition = { context, cursor, start, end in
    MainActor.assumeIsolated {
        guard let context, let model = Unmanaged<EditorSource>.fromOpaque(context).takeUnretainedValue().model else { return }
        model.editorCursor = Int(cursor)
        model.editorSelection = start >= 0 && end >= start ? Int(start)..<Int(end) : nil
    }
}
private let editorDestroy: SDBUIValueDestroy = { context in
    if let context { Unmanaged<EditorSource>.fromOpaque(context).release() }
}
#endif

extension TextEditor {
    @ViewBuilder
    func assistingSQL(_ model: BrowserModel, navigation: EditorErrorNavigation) -> some View {
        #if canImport(GtkBackend)
        inspect([.onCreate, .afterUpdate]) { widget in
            let pointer = UnsafeMutableRawPointer(widget.widgetPointer)
            let source = Unmanaged.passRetained(EditorSource(model)).toOpaque()
            sdbui_sql_editor_install(pointer, source, editorCompletion, editorPosition, editorDestroy,
                model.dialect == .mysql ? 1 : 2)
            let document = model.activeQueryDocument
            if navigation.appliedDocument != document.id {
                navigation.appliedDocument = document.id
                sdbui_sql_editor_select(pointer, Int32(clamping: document.cursor),
                    document.selection.map { Int32(clamping: $0.lowerBound) } ?? -1,
                    document.selection.map { Int32(clamping: $0.upperBound) } ?? -1, 1)
            }
        }
        #else
        self
        #endif
    }
}
