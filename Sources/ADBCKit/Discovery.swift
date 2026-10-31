import Foundation

/// An ADBC driver installed via `dbc` (or any manifest-based install).
public struct DriverManifest: Sendable, Identifiable, Hashable, CustomStringConvertible {
    /// The name used to refer to the driver, e.g. `postgresql` (the manifest's
    /// file name without `.toml`).
    public var id: String
    /// Human-readable name from the manifest.
    public var displayName: String
    public var version: String?
    /// Path to the shared library for the current platform.
    public var libraryPath: String
    public var entrypoint: String?
    public var manifestURL: URL

    public var description: String { id }
}

/// A saved connection profile (`~/.config/adbc/profiles/<name>.toml`).
///
/// Format (as used by databow / the ADBC driver manager):
///
/// ```toml
/// profile_version = 1
/// driver = "postgresql"
///
/// [Options]
/// uri = "postgresql://user:{{ env_var(PGPASSWORD) }}@localhost/db"
/// ```
public struct ConnectionProfile: Sendable, Identifiable, Hashable {
    public var id: String
    public var driver: String
    /// Database options in file order (`{{ env_var(...) }}` not yet expanded).
    public var options: [Option]
    public var url: URL

    public struct Option: Sendable, Hashable {
        public var key: String
        public var value: String
    }

    /// Names are relative to the profile search root, so equal leaf names in
    /// different folders remain distinct favorites.
    public var name: String { id.split(separator: "/").last.map(String.init) ?? id }
    public var group: String { id.split(separator: "/").dropLast().joined(separator: "/") }

    /// Search only labels that are safe to display, never raw credentials.
    public func matches(_ search: String) -> Bool {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || [id, driver, summary].contains {
            $0.localizedCaseInsensitiveContains(query)
        }
    }

    /// A label safe to show on screen (credentials in the URI are masked).
    public var summary: String {
        guard let uri = options.last(where: { $0.key == "uri" })?.value else {
            return driver
        }
        return Self.maskingPassword(in: uri)
    }

    static func maskingPassword(in uri: String) -> String {
        guard var components = URLComponents(string: uri), components.password != nil else {
            return uri
        }
        components.password = "***"
        return components.string ?? uri
    }
}

public enum Discovery {
    static let environment = ProcessInfo.processInfo.environment

    /// The manifest key for the current platform, e.g. `linux_amd64`.
    public static var platformTuple: String {
        #if os(macOS)
            let os = "macos"
        #elseif os(Windows)
            let os = "windows"
        #else
            let os = "linux"
        #endif
        #if arch(arm64)
            let arch = "arm64"
        #else
            let arch = "amd64"
        #endif
        return "\(os)_\(arch)"
    }

    private static var userConfigDirectory: URL {
        #if os(macOS)
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/ADBC")
        #else
            if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
                return URL(fileURLWithPath: xdg).appendingPathComponent("adbc")
            }
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config/adbc")
        #endif
    }

    /// Directories searched for driver manifests, highest priority first.
    public static var driverSearchDirectories: [URL] {
        var directories: [URL] = []
        if let paths = environment["ADBC_DRIVER_PATH"] {
            directories += paths.split(separator: ":").map { URL(fileURLWithPath: String($0)) }
        }
        for prefix in ["VIRTUAL_ENV", "CONDA_PREFIX"] {
            if let path = environment[prefix] {
                directories.append(URL(fileURLWithPath: path).appendingPathComponent("etc/adbc/drivers"))
            }
        }
        #if os(macOS)
            directories.append(userConfigDirectory.appendingPathComponent("Drivers"))
            directories.append(URL(fileURLWithPath: "/Library/Application Support/ADBC/Drivers"))
        #else
            directories.append(userConfigDirectory.appendingPathComponent("drivers"))
            // Older dbc releases put manifests directly in the config directory.
            directories.append(userConfigDirectory)
            directories.append(URL(fileURLWithPath: "/etc/adbc/drivers"))
        #endif
        return directories
    }

    /// Directories searched for connection profiles, highest priority first.
    public static var profileSearchDirectories: [URL] {
        var directories: [URL] = []
        if let paths = environment["ADBC_PROFILE_PATH"] {
            directories += paths.split(separator: ":").map { URL(fileURLWithPath: String($0)) }
        }
        #if os(macOS)
            directories.append(userConfigDirectory.appendingPathComponent("Profiles"))
        #else
            directories.append(userConfigDirectory.appendingPathComponent("profiles"))
        #endif
        return directories
    }

    // MARK: Drivers

    /// All installed drivers, de-duplicated by name (first match wins).
    public static func installedDrivers() -> [DriverManifest] {
        var seen = Set<String>()
        var drivers: [DriverManifest] = []
        for url in tomlFiles(in: driverSearchDirectories) {
            let name = url.deletingPathExtension().lastPathComponent
            guard !seen.contains(name), let manifest = try? loadManifest(at: url) else { continue }
            seen.insert(name)
            drivers.append(manifest)
        }
        return drivers.sorted { $0.id < $1.id }
    }

    public static func loadManifest(at url: URL) throws -> DriverManifest {
        let toml = try TOMLDocument(contentsOf: url)
        let library =
            toml["Driver", "shared", platformTuple]?.stringValue
            ?? toml["Driver", "shared"]?.stringValue
        guard let library else {
            throw ADBCError("Manifest \(url.path) has no driver library for \(platformTuple)")
        }
        return DriverManifest(
            id: url.deletingPathExtension().lastPathComponent,
            displayName: toml["name"]?.stringValue ?? url.deletingPathExtension().lastPathComponent,
            version: toml["version"]?.stringValue,
            libraryPath: library,
            entrypoint: toml["Driver", "entrypoint"]?.stringValue,
            manifestURL: url
        )
    }

    /// Resolve a driver reference (name, manifest path or library path) to a
    /// loadable library, the way the ADBC driver manager does.
    public static func resolveDriver(_ reference: String) throws -> (library: String, entrypoint: String?) {
        if reference.hasSuffix(".toml") {
            let manifest = try loadManifest(at: URL(fileURLWithPath: expandingTilde(reference)))
            return (manifest.libraryPath, manifest.entrypoint)
        }
        if reference.contains("/") {
            return (expandingTilde(reference), nil)
        }
        for directory in driverSearchDirectories {
            let url = directory.appendingPathComponent("\(reference).toml")
            if FileManager.default.fileExists(atPath: url.path) {
                let manifest = try loadManifest(at: url)
                return (manifest.libraryPath, manifest.entrypoint)
            }
        }
        // Fall back to the system library search path, e.g.
        // libadbc_driver_postgresql.so installed by a package manager.
        #if os(macOS)
            return ("libadbc_driver_\(reference).dylib", nil)
        #else
            return ("libadbc_driver_\(reference).so", nil)
        #endif
    }

    /// Infer a driver name from a URI scheme (`postgresql://…` → `postgresql`).
    public static func driverName(forURI uri: String) -> String? {
        guard let colon = uri.firstIndex(of: ":") else { return nil }
        let scheme = uri[..<colon].lowercased()
        guard !scheme.isEmpty else { return nil }
        let aliases = ["postgres": "postgresql", "sqlite3": "sqlite", "file": "sqlite"]
        return aliases[scheme] ?? scheme
    }

    // MARK: Profiles

    public static func profiles() -> [ConnectionProfile] {
        profiles(in: profileSearchDirectories)
    }

    /// Discover nested favorites; earlier search roots win for the same relative name.
    public static func profiles(in directories: [URL]) -> [ConnectionProfile] {
        var seen = Set<String>()
        var profiles: [ConnectionProfile] = []
        for directory in directories {
            guard let files = FileManager.default.enumerator(
                at: directory, includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in files {
                guard url.pathExtension == "toml",
                    (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                    var profile = try? loadProfile(at: url) else { continue }
                let root = directory.standardizedFileURL.path
                let path = url.deletingPathExtension().standardizedFileURL.path
                let name = String(path.dropFirst(root.count + (root.hasSuffix("/") ? 0 : 1)))
                guard seen.insert(name).inserted else { continue }
                profile.id = name
                profiles.append(profile)
            }
        }
        return profiles.sorted {
            if $0.group != $1.group {
                return $0.group.localizedCaseInsensitiveCompare($1.group) == .orderedAscending
            }
            return $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending
        }
    }

    public static func loadProfile(at url: URL) throws -> ConnectionProfile {
        let toml = try TOMLDocument(contentsOf: url)
        guard let driver = toml["driver"]?.stringValue else {
            throw ADBCError("Profile \(url.path) does not name a driver")
        }
        return ConnectionProfile(
            id: url.deletingPathExtension().lastPathComponent,
            driver: driver,
            options: toml.entries(in: "Options").map { .init(key: $0.key, value: $0.value.stringValue) },
            url: url
        )
    }

    /// Look a profile up by name, or load it directly if given a path.
    public static func profile(named reference: String) throws -> ConnectionProfile {
        if let profile = profiles().first(where: { $0.id == reference }) {
            return profile
        }
        if reference.contains("/") || reference.hasSuffix(".toml") {
            return try loadProfile(at: URL(fileURLWithPath: expandingTilde(reference)))
        }
        for directory in profileSearchDirectories {
            let url = directory.appendingPathComponent("\(reference).toml")
            if FileManager.default.fileExists(atPath: url.path) {
                return try loadProfile(at: url)
            }
        }
        throw ADBCError("No profile named '\(reference)' in \(profileSearchDirectories.map(\.path).joined(separator: ", "))")
    }

    /// Expand ADBC's `{{ env_var(NAME) }}` placeholders.
    public static func substitutingEnvironment(in value: String) throws -> String {
        var result = ""
        var rest = Substring(value)
        while let open = rest.range(of: "{{") {
            result += rest[..<open.lowerBound]
            guard let close = rest[open.upperBound...].range(of: "}}") else {
                throw ADBCError("Unterminated '{{' in profile value")
            }
            let expression = rest[open.upperBound..<close.lowerBound]
                .trimmingCharacters(in: .whitespaces)
            guard expression.hasPrefix("env_var("), expression.hasSuffix(")") else {
                throw ADBCError("Unsupported profile expression '{{ \(expression) }}'")
            }
            let name = expression.dropFirst("env_var(".count).dropLast()
                .trimmingCharacters(in: .whitespaces)
            result += environment[name] ?? ""
            rest = rest[close.upperBound...]
        }
        return result + rest
    }

    // MARK: Helpers

    private static func tomlFiles(in directories: [URL]) -> [URL] {
        directories.flatMap { directory -> [URL] in
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)) ?? []
            return contents
                .filter { $0.pathExtension == "toml" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
    }

    private static func expandingTilde(_ path: String) -> String {
        guard path.hasPrefix("~/") else { return path }
        return FileManager.default.homeDirectoryForCurrentUser.path + path.dropFirst()
    }
}

public struct ADBCError: Error, CustomStringConvertible, LocalizedError {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
    public var errorDescription: String? { message }
}
