import Foundation
import SwiftCrossUI
#if canImport(GtkBackend)
import GtkBackend
import CResultValue
#endif

struct MenuCommand {
    let title: String
    var enabled = true
    let action: @MainActor () -> Void
}

#if canImport(GtkBackend)
@MainActor
private final class MenuCommands {
    let commands: [MenuCommand]
    init(_ commands: [MenuCommand]) { self.commands = commands }
}
private let executeMenuCommand: SDBUIFilterApply = { context, index in
    MainActor.assumeIsolated {
        guard let context else { return }
        let commands = Unmanaged<MenuCommands>.fromOpaque(context).takeUnretainedValue().commands
        guard commands.indices.contains(Int(index)), commands[Int(index)].enabled else { return }
        commands[Int(index)].action()
    }
}
private let destroyMenuCommands: SDBUIValueDestroy = { context in
    if let context { Unmanaged<MenuCommands>.fromOpaque(context).release() }
}
#endif

/// Native menus keep their action snapshot alive until dismissal has finished.
struct CommandMenu: View {
    let title: String
    let commands: [MenuCommand]
    var body: some View {
        #if canImport(GtkBackend)
        Button(title) {}
            .inspect([.onCreate, .afterUpdate]) { widget in
                let labels = commands.map { strdup($0.title) }
                defer { labels.forEach { free($0) } }
                let pointers = labels.map { $0.map { UnsafePointer($0) } }
                let enabled = commands.map { Int32($0.enabled ? 1 : 0) }
                pointers.withUnsafeBufferPointer { names in
                    enabled.withUnsafeBufferPointer { flags in
                        sdbui_command_menu(UnsafeMutableRawPointer(widget.widgetPointer), names.baseAddress, flags.baseAddress,
                            UInt32(commands.count), Unmanaged.passRetained(MenuCommands(commands)).toOpaque(),
                            executeMenuCommand, destroyMenuCommands)
                    }
                }
            }
        #else
        Menu(title) {
            ForEach(Array(commands.enumerated()), id: \.offset) { entry in
                Button(entry.element.title) { entry.element.action() }.disabled(!entry.element.enabled)
            }
        }
        #endif
    }
}
