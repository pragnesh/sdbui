import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// Editable connection settings, keeping driver-specific options when a favorite is edited.
public struct ConnectionDraft: Equatable, Sendable {
    public var name = ""
    public var driver = "postgresql"
    public var host = "localhost"
    public var port = ""
    public var user = ""
    public var password = ""
    public var database = ""
    public var sslMode = "Default"
    public var useURI = false
    public var uri = ""
    public var ssh = SSHSettings()
    private var options: [ConnectionProfile.Option] = []
    private var queryItems: [URLQueryItem] = []
    public private(set) var originalURL: URL?
    private var originalName: String?

    public init() {}

    public var supportsFields: Bool { ["postgresql", "mysql"].contains(driver) }
    public var sslModes: [String] {
        driver == "mysql"
            ? ["Default", "DISABLED", "PREFERRED", "REQUIRED", "VERIFY_CA", "VERIFY_IDENTITY"]
            : ["Default", "disable", "allow", "prefer", "require", "verify-ca", "verify-full"]
    }
    private var sslKey: String { driver == "mysql" ? "ssl-mode" : "sslmode" }
    public var defaultPort: String { driver == "mysql" ? "3306" : "5432" }

    public init(profile: ConnectionProfile) {
        self.init()
        name = profile.id
        originalName = profile.id
        originalURL = profile.url
        driver = profile.driver
        ssh = profile.ssh
        options = profile.options
        uri = options.last(where: { $0.key == "uri" })?.value ?? ""
        useURI = true
        // Templates and nonstandard connection strings remain editable verbatim.
        guard supportsFields, !uri.contains("{{"),
            let parsed = URLComponents(string: uri),
            Discovery.driverName(forURI: uri) == driver,
            let host = parsed.host, !host.isEmpty,
            parsed.fragment == nil else { return }
        self.host = host
        port = parsed.port.map(String.init) ?? ""
        user = parsed.user ?? ""
        password = parsed.password ?? ""
        database = String(parsed.path.dropFirst())
        queryItems = parsed.queryItems ?? []
        sslMode = queryItems.last(where: { $0.name == sslKey })?.value ?? "Default"
        guard sslModes.contains(sslMode) else { return }
        useURI = false
    }

    public mutating func applyURIFields(from parsed: ConnectionDraft) {
        host = parsed.host
        port = parsed.port
        user = parsed.user
        password = parsed.password
        database = parsed.database
        sslMode = parsed.sslMode
        queryItems = parsed.queryItems
    }

    public mutating func selectDriver(_ value: String) {
        guard value != driver else { return }
        driver = value
        sslMode = "Default"
        queryItems = []
        options = []
        uri = ""
        port = ""
        useURI = !supportsFields
    }

    public func connectionURI() throws -> String {
        if useURI || !supportsFields {
            let value = uri.trimmingCharacters(in: .whitespacesAndNewlines)
            // Some drivers (e.g. SQLite) use options instead of a URI.
            guard !value.isEmpty || !options.isEmpty else { throw ADBCError("Enter a connection URI.") }
            return value
        }
        guard !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ADBCError("Enter a host.")
        }
        var parsed = URLComponents()
        parsed.scheme = driver
        parsed.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if !port.isEmpty {
            guard let number = Int(port), (1...65535).contains(number) else {
                throw ADBCError("Port must be a number between 1 and 65535.")
            }
            parsed.port = number
        }
        if !user.isEmpty { parsed.user = user }
        if !password.isEmpty {
            guard !user.isEmpty else { throw ADBCError("Enter a user for this password.") }
            parsed.password = password
        }
        // Treat the database as one path component, including reserved characters.
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#%")
        parsed.percentEncodedPath = "/" + (database.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
        var items = queryItems.filter { $0.name != sslKey }
        guard sslModes.contains(sslMode) else { throw ADBCError("Choose a valid SSL mode.") }
        if sslMode != "Default" { items.append(URLQueryItem(name: sslKey, value: sslMode)) }
        parsed.queryItems = items.isEmpty ? nil : items
        guard let value = parsed.string, parsed.url != nil else { throw ADBCError("Invalid connection settings.") }
        return value
    }

    public func connectionOptions() throws -> [ConnectionProfile.Option] {
        guard !driver.isEmpty else { throw ADBCError("Choose a driver.") }
        let value = try connectionURI()
        var result = options.filter { $0.key != "uri" }
        if !value.isEmpty { result.insert(.init(key: "uri", value: value), at: 0) }
        return result
    }

    public func source() throws -> ConnectionSource {
        let expanded = try connectionOptions().map {
            ConnectionProfile.Option(key: $0.key, value: try Discovery.substitutingEnvironment(in: $0.value))
        }
        if ssh.enabled {
            try ssh.validate()
            _ = try TunnelDestination(uri: expanded.last(where: { $0.key == "uri" })?.value ?? "", driver: driver)
            return .ssh(driver: driver, options: expanded, settings: ssh)
        }
        return .direct(driver: driver, uri: "", options: expanded)
    }

    public func save(in directory: URL = Discovery.profileSearchDirectories[0]) throws -> URL {
        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({
            !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix(".")
                && !$0.contains("\\") && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        }), name == name.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw ADBCError("Enter a favorite name, optionally grouped as Work/Production. Avoid empty or hidden names and '..'.")
        }
        let values = try connectionOptions()
        if ssh.enabled { try ssh.validate() }
        let destination = originalName == name ? (originalURL ?? directory.appendingPathComponent(name + ".toml"))
            : directory.appendingPathComponent(name + ".toml")
        if FileManager.default.fileExists(atPath: destination.path), destination != originalURL {
            throw ADBCError("A favorite with this name already exists. Choose another name.")
        }
        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let temporary = parent.appendingPathComponent(".sdbui-\(UUID().uuidString).tmp")
        let text = "profile_version = 1\ndriver = \(Self.quoted(driver))\n\n[Options]\n"
            + values.map { "\(Self.quoted($0.key)) = \(Self.quoted($0.value))\n" }.joined()
            + "\n[SDBUI.SSH]\nenabled = \(ssh.enabled)\n"
            + "host = \(Self.quoted(ssh.host))\nport = \(Self.quoted(ssh.port))\n"
            + "user = \(Self.quoted(ssh.user))\nidentity_file = \(Self.quoted(ssh.identityFile))\n"
        guard FileManager.default.createFile(atPath: temporary.path, contents: Data(text.utf8),
                                            attributes: [.posixPermissions: 0o600]) else {
            throw ADBCError("Could not write the connection profile.")
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard rename(temporary.path, destination.path) == 0 else {
            throw ADBCError("Could not save the connection profile: \(String(cString: strerror(errno)))")
        }
        return destination
    }

    private static func quoted(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            case _ where scalar.value < 32 || scalar.value == 127:
                result += String(format: "\\u%04X", scalar.value)
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }
}
