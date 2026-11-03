#if canImport(AppKitBackend)
import AppKit
import AppKitBackend
import ObjectiveC
import SwiftCrossUI

@MainActor
private var macEditorKey: UInt8 = 0
@MainActor
private final class MacEditorSupport: NSObject {
    weak var model: BrowserModel?
    weak var editor: NSTextView?
    init(model: BrowserModel, editor: NSTextView) {
        self.model = model; self.editor = editor
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(positionChanged), name: NSTextView.didChangeSelectionNotification, object: editor)
        NotificationCenter.default.addObserver(self, selector: #selector(positionChanged), name: NSText.didChangeNotification, object: editor)
    }
    @objc func positionChanged() {
        guard let editor, let model else { return }
        let range = editor.selectedRange(), text = editor.string as NSString
        let start = text.substring(to: min(range.location, text.length)).unicodeScalars.count
        let end = text.substring(to: min(NSMaxRange(range), text.length)).unicodeScalars.count
        model.editorCursor = start; model.editorSelection = start == end ? nil : start..<end
    }
}

@MainActor
private func nativeRange(_ range: Range<Int>, in text: String) -> NSRange {
    let positions = Array(text.unicodeScalars.indices) + [text.endIndex]
    let start = min(max(0, range.lowerBound), positions.count - 1)
    let end = min(max(start, range.upperBound), positions.count - 1)
    return NSRange(positions[start]..<positions[end], in: text)
}

extension TextEditor {
    func assistingMacSQL(_ model: BrowserModel, navigation: EditorErrorNavigation) -> some View {
        inspect([.onCreate, .afterUpdate]) { view in
            guard let editor = view as? NSTextView else { return }
            let support: MacEditorSupport
            if let existing = objc_getAssociatedObject(editor, &macEditorKey) as? MacEditorSupport { support = existing }
            else {
                support = MacEditorSupport(model: model, editor: editor)
                objc_setAssociatedObject(editor, &macEditorKey, support, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            }
            let document = model.activeQueryDocument
            if navigation.appliedDocument != document.id {
                navigation.appliedDocument = document.id
                editor.setSelectedRange(nativeRange(document.selection ?? (document.cursor..<document.cursor), in: editor.string))
                support.positionChanged()
            }
        }
    }
}

extension View {
    func revealingMacQueryError(_ model: BrowserModel, navigation: EditorErrorNavigation) -> some View {
        inspect(.afterUpdate) { view in
            guard let editor = view as? NSTextView, let location = model.queryErrorLocation,
                  navigation.appliedID != location.id, location.sourceSQL == model.sql else { return }
            let range = nativeRange(location.offset..<location.offset, in: editor.string)
            editor.setSelectedRange(range); editor.scrollRangeToVisible(range)
            editor.window?.makeFirstResponder(editor); navigation.appliedID = location.id
        }
    }
}
#endif
