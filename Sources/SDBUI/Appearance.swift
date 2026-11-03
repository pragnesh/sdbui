import SwiftCrossUI
#if canImport(GtkBackend)
import CGtk
import Foundation
import Observation

private let gtkThemeChanged: @convention(c) (UnsafeMutablePointer<GObject>?, UnsafeMutablePointer<GParamSpec>?, UnsafeMutableRawPointer?) -> Void = { _, spec, context in
    MainActor.assumeIsolated {
        guard let context else { return }
        let property = spec.flatMap { g_param_spec_get_name($0) }.map { String(cString: $0) } ?? ""
        Unmanaged<GTKAppearance>.fromOpaque(context).takeUnretainedValue().systemChanged(property)
    }
}

@Observable @MainActor
final class GTKAppearance {
    static let shared = GTKAppearance()
    private(set) var systemDark = false
    @ObservationIgnored private var theme = "Adwaita"
    @ObservationIgnored private var preferDark: Int32 = 0
    @ObservationIgnored private var applying = false
    @ObservationIgnored private var hasApplied = false
    @ObservationIgnored private var current = AppPreferences.Appearance.system
    private init() {
        captureSystem()
        guard let settings = gtk_settings_get_default() else { return }
        for property in ["notify::gtk-theme-name", "notify::gtk-application-prefer-dark-theme"] {
            _ = g_signal_connect_data(UnsafeMutableRawPointer(settings), property, unsafeBitCast(gtkThemeChanged, to: GCallback.self), Unmanaged.passUnretained(self).toOpaque(), nil, GConnectFlags(rawValue: 0))
        }
    }
    private func captureSystem(_ property: String? = nil) {
        guard let settings = gtk_settings_get_default() else { return }
        var value = GValue()
        if property == nil || property == "gtk-theme-name" {
        g_value_init(&value, g_type_from_name("gchararray"))
        g_object_get_property(UnsafeMutableRawPointer(settings).assumingMemoryBound(to: GObject.self), "gtk-theme-name", &value)
        if let name = g_value_get_string(&value) { theme = String(cString: name) }
        g_value_unset(&value)
        }
        if property == nil || property == "gtk-application-prefer-dark-theme" {
        g_value_init(&value, g_type_from_name("gboolean"))
        g_object_get_property(UnsafeMutableRawPointer(settings).assumingMemoryBound(to: GObject.self), "gtk-application-prefer-dark-theme", &value)
        preferDark = g_value_get_boolean(&value); g_value_unset(&value)
        }
        systemDark = preferDark != 0 || theme.lowercased().contains("dark") || (ProcessInfo.processInfo.environment["GTK_THEME"]?.lowercased().contains("dark") ?? false)
    }
    func systemChanged(_ property: String) {
        guard !applying else { return }
        captureSystem(property)
        if current != .system { apply(current, force: true) }
    }
    func apply(_ appearance: AppPreferences.Appearance, force: Bool = false) {
        guard force || !hasApplied || current != appearance else { return }
        hasApplied = true
        current = appearance
        guard let settings = gtk_settings_get_default() else { return }
        applying = true; defer { applying = false }
        var value = GValue()
        g_value_init(&value, g_type_from_name("gchararray"))
        g_value_set_string(&value, appearance == .system ? theme : "Adwaita")
        g_object_set_property(UnsafeMutableRawPointer(settings).assumingMemoryBound(to: GObject.self), "gtk-theme-name", &value)
        g_value_unset(&value)
        g_value_init(&value, g_type_from_name("gboolean"))
        g_value_set_boolean(&value, appearance == .system ? preferDark : appearance == .dark ? 1 : 0)
        g_object_set_property(UnsafeMutableRawPointer(settings).assumingMemoryBound(to: GObject.self), "gtk-application-prefer-dark-theme", &value)
        g_value_unset(&value)
    }
}
#elseif canImport(AppKitBackend)
import AppKit
import AppKitBackend
#endif

extension View {
    @ViewBuilder func workspaceAppearance(_ appearance: AppPreferences.Appearance) -> some View {
        #if canImport(GtkBackend)
        inspect([.onCreate, .afterUpdate]) { _ in GTKAppearance.shared.apply(appearance) }
        #elseif canImport(AppKitBackend)
        inspect([.onCreate, .afterUpdate]) { view in
            let apply: @MainActor () -> Void = { [weak view] in
                guard let window = view?.window else { return }
                let requested = appearance == .system ? nil : NSAppearance(named: appearance == .dark ? .darkAqua : .aqua)
                if window.appearance?.name != requested?.name { window.appearance = requested }
            }
            apply(); DispatchQueue.main.async(execute: apply)
        }
        #else
        self
        #endif
    }
}
