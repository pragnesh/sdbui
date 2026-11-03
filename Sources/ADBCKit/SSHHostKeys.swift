import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// The SSH server's host key isn't known yet, so strict host key checking
/// refused it. ``SSHHostKeys`` can fetch the key for the user to verify.
/// A changed key is a different, ordinary error: it may mean interception.
public struct SSHUnknownHostKeyError: Error, CustomStringConvertible, LocalizedError {
    /// The SSH host as configured (it may be an alias from ~/.ssh/config).
    public let host: String
    public let port: String
    public let message: String
    public var description: String { message }
    public var errorDescription: String? { message }

    init?(settings: SSHSettings, diagnostics: String, detail: String) {
        guard diagnostics.contains("Host key verification failed"),
              !diagnostics.contains("REMOTE HOST IDENTIFICATION HAS CHANGED"),
              diagnostics.contains("host key is known for") || diagnostics.contains("authenticity of host")
        else { return nil }
        host = settings.host
        port = settings.port
        message = "SSH tunnel failed. \(detail)"
    }
}

/// An SSH server's host keys, fetched with `ssh-keyscan` for the user to
/// verify before they're saved to known_hosts.
public struct SSHHostKeyScan: Sendable, Equatable {
    /// The SSH host as configured, and the address `ssh` resolves it to.
    public let host: String
    public let hostName: String
    public let port: Int
    /// For example "ED25519 SHA256:…".
    public let fingerprints: [String]
    /// known_hosts lines, in the form `ssh` looks them up.
    let entries: [String]
    public let knownHostsFile: String
}

public enum SSHHostKeys {
    /// Resolves `host` the way `ssh` does (aliases, HostName, Port, HostKeyAlias,
    /// UserKnownHostsFile) and fetches its host keys.
    public static func scan(host: String, port: String,
                            toolsDirectory: URL = URL(fileURLWithPath: "/usr/bin")) throws -> SSHHostKeyScan {
        var settings = SSHSettings()
        settings.host = host
        settings.port = port
        try settings.validate()
        let config = try run(toolsDirectory.appendingPathComponent("ssh").path, ["-G", "-p", port, "--", host])
        // `ssh -G` prints one "key value" pair per line.
        var options: [String: String] = [:]
        for line in config.split(whereSeparator: \.isNewline) {
            let pair = line.split(separator: " ", maxSplits: 1)
            if pair.count == 2, options[String(pair[0])] == nil { options[String(pair[0])] = String(pair[1]) }
        }
        func value(_ key: String) -> String? { options[key] }
        let hostName = value("hostname") ?? host
        let resolvedPort = value("port").flatMap(Int.init) ?? Int(port) ?? 22
        let alias = value("hostkeyalias").flatMap { $0 == "none" ? nil : $0 }
        let hash = value("hashknownhosts") == "yes" && alias == nil
        let file = (value("userknownhostsfile")?.split(separator: " ").first.map(String.init) ?? "~/.ssh/known_hosts")
        let knownHostsFile = (file as NSString).expandingTildeInPath

        let scanned = try run(toolsDirectory.appendingPathComponent("ssh-keyscan").path,
                              ["-T", "10", "-p", String(resolvedPort)] + (hash ? ["-H"] : []) + ["--", hostName])
        var entries = scanned.split(whereSeparator: \.isNewline).map(String.init)
            .filter { !$0.hasPrefix("#") && $0.split(separator: " ").count >= 3 }
        guard !entries.isEmpty else {
            throw ADBCError("Could not fetch the SSH host key from \(hostName) port \(resolvedPort).")
        }
        if let alias {
            // ssh looks the key up under HostKeyAlias instead of the host name.
            let name = resolvedPort == 22 ? alias : "[\(alias)]:\(resolvedPort)"
            entries = entries.map { name + " " + $0.split(separator: " ", maxSplits: 1)[1] }
        }

        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("sdbui-hostkeys-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: Data((entries.joined(separator: "\n") + "\n").utf8),
                                            attributes: [.posixPermissions: 0o600]) else {
            throw ADBCError("Could not create a temporary file for the host key.")
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let listed = try run(toolsDirectory.appendingPathComponent("ssh-keygen").path, ["-l", "-f", temporary.path])
        // "256 SHA256:abc… host (ED25519)" -> "ED25519 SHA256:abc…"
        let fingerprints = listed.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let fields = line.split(separator: " ")
            guard fields.count >= 3, let type = fields.last else { return nil }
            return type.trimmingCharacters(in: CharacterSet(charactersIn: "()")) + " " + fields[1]
        }
        return SSHHostKeyScan(host: host, hostName: hostName, port: resolvedPort, fingerprints: fingerprints,
                              entries: entries, knownHostsFile: knownHostsFile)
    }

    /// Appends the scanned keys to known_hosts (created owner-only if missing).
    public static func trust(_ scan: SSHHostKeyScan) throws {
        let url = URL(fileURLWithPath: scan.knownHostsFile)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw ADBCError("Could not create \(scan.knownHostsFile).")
            }
        }
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        var text = scan.entries.joined(separator: "\n") + "\n"
        if end > 0 {
            try handle.seek(toOffset: end - 1)
            if handle.readData(ofLength: 1) != Data("\n".utf8) { text = "\n" + text }
            try handle.seekToEnd()
        }
        try handle.write(contentsOf: Data(text.utf8))
    }

    /// Runs a tool to completion (at most 20 seconds) and returns its output.
    static func run(_ executable: String, _ arguments: [String]) throws -> String {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("sdbui-tool-\(UUID().uuidString)")
        let out = base.path + ".out", err = base.path + ".err"
        for path in [out, err] {
            guard FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw ADBCError("Could not create a temporary file.")
            }
        }
        defer { for path in [out, err] { try? FileManager.default.removeItem(atPath: path) } }
        let process = try ChildProcess(executable: executable, arguments: arguments, stdoutPath: out, stderrPath: err)
        let deadline = Date().addingTimeInterval(20)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning {
            process.terminate(gracePeriod: 1)
            throw ADBCError("\((executable as NSString).lastPathComponent) timed out.")
        }
        let output = (try? String(contentsOfFile: out, encoding: .utf8)) ?? ""
        // ssh-keyscan can exit non-zero when one key type fails; keep its keys.
        guard process.exitedSuccessfully || !output.isEmpty else {
            let detail = SSHTunnel.errorDetail((try? String(contentsOfFile: err, encoding: .utf8)) ?? "")
            throw ADBCError("\((executable as NSString).lastPathComponent) failed. \(detail)")
        }
        return output
    }
}
