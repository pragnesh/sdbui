#if canImport(AppKitBackend)
import AppKit
import AppKitBackend
import ObjectiveC
import SwiftCrossUI

@MainActor
private var macWorkspaceKey: UInt8 = 0
@MainActor
private var macFocusKey: UInt8 = 0

@MainActor
private final class MacWorkspaceBindings: NSObject {
    weak var workspace: ConnectionWorkspace?
    weak var root: NSView?
    private var monitor: Any?
    init(workspace: ConnectionWorkspace, root: NSView) {
        self.workspace = workspace; self.root = root
        super.init()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled: Bool = MainActor.assumeIsolated { guard let self else { return false }; return self.handle(event) == nil }
            return handled ? nil : event
        }
        NotificationCenter.default.addObserver(self, selector: #selector(resized), name: NSWindow.didResizeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(closing), name: NSWindow.willCloseNotification, object: nil)
    }
    deinit {
        if let monitor { MainActor.assumeIsolated { NSEvent.removeMonitor(monitor) } }
    }
    @objc private func resized(_ note: Notification) {
        guard let window = root?.window, note.object as? NSWindow === window else { return }
        let size = window.contentLayoutRect.size
        workspace?.updateWindowSize(width: Int(size.width), height: Int(size.height))
    }
    @objc private func closing(_ note: Notification) {
        guard let window = root?.window, note.object as? NSWindow === window else { return }
        workspace?.saveSession()
    }
    private func focus(_ name: String) {
        guard let window = root?.window, let root else { return }
        func target(_ view: NSView) -> NSView? {
            if objc_getAssociatedObject(view, &macFocusKey) as? String == name { return view }
            return view.subviews.lazy.compactMap(target).first
        }
        if let view = target(root) { window.makeFirstResponder(view) }
    }
    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let root, root.window === event.window, let workspace else { return event }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let modified = flags.contains(.command) || flags.contains(.control)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if modified, event.keyCode == 36, let editor = event.window?.firstResponder as? NSTextView,
           objc_getAssociatedObject(editor, &macFocusKey) as? String == "editor" {
            let selection = editor.selectedRange(), text = editor.string as NSString
            let start = text.substring(to: min(selection.location, text.length)).unicodeScalars.count
            let end = text.substring(to: min(NSMaxRange(selection), text.length)).unicodeScalars.count
            workspace.selectedTab.model.runCurrentStatement(.init(text: editor.string, selection: start == end ? nil : start..<end, cursor: start))
            return nil
        }
        let command: Int32?
        if modified, let number = Int(key), (1...9).contains(number) { command = Int32(100 + number) }
        else if modified && event.keyCode == 48 { command = flags.contains(.shift) ? 4 : 3 }
        else if modified {
            switch key {
            case ",": command = 13
            case "t": command = 1
            case "w": command = 2
            case "p", "f": command = 5
            case "l": command = 6
            case "=", "+": command = 11
            case "-": command = 12
            default: command = event.keyCode == 116 ? 9 : event.keyCode == 121 ? 10 : nil
            }
        } else { command = event.keyCode == 53 ? 7 : event.keyCode == 96 ? 8 : nil }
        guard let command, workspace.performShortcut(command) else { return event }
        if command == 5 { focus("table-filter") }
        if command == 6 { DispatchQueue.main.async { [weak self] in self?.focus("editor") } }
        return nil
    }
}

extension View {
    func macWorkspaceShortcuts(_ workspace: ConnectionWorkspace) -> some View {
        inspect([.onCreate, .afterUpdate]) { view in
            if objc_getAssociatedObject(view, &macWorkspaceKey) == nil {
                objc_setAssociatedObject(view, &macWorkspaceKey, MacWorkspaceBindings(workspace: workspace, root: view), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            }
        }
    }
    func macFocusTarget(_ name: String) -> some View {
        inspect([.onCreate, .afterUpdate]) { view in
            objc_setAssociatedObject(view, &macFocusKey, name, .OBJC_ASSOCIATION_COPY_NONATOMIC)
        }
    }
}
#endif

#if canImport(AppKitBackend)
@MainActor
private var macSidebarKey: UInt8 = 0
@MainActor
private final class MacSidebarBinding: NSObject {
    weak var model: BrowserModel?
    weak var split: NSSplitView?
    init(model: BrowserModel, split: NSSplitView) {
        self.model = model; self.split = split
        super.init()
        if split.subviews.count > 1 { split.setPosition(CGFloat(model.sidebarWidth), ofDividerAt: 0) }
        NotificationCenter.default.addObserver(self, selector: #selector(changed), name: NSSplitView.didResizeSubviewsNotification, object: split)
    }
    @objc private func changed() {
        guard let width = split?.subviews.first?.frame.width else { return }
        model?.updateSidebarWidth(Int(width))
    }
}
extension View {
    func persistingMacSidebar(_ model: BrowserModel) -> some View {
        inspect([.onCreate, .afterUpdate]) { view in
            guard let split = view as? NSSplitView, objc_getAssociatedObject(split, &macSidebarKey) == nil else { return }
            objc_setAssociatedObject(split, &macSidebarKey, MacSidebarBinding(model: model, split: split), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }
}
#endif
