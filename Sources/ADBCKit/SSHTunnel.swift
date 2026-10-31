import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

public struct SSHSettings: Equatable, Hashable, Sendable {
    public var enabled = false
    public var host = ""
    public var port = "22"
    public var user = ""
    public var identityFile = ""
    public init() {}

    func validate() throws {
        guard !host.isEmpty, !host.hasPrefix("-"),
            !host.contains(where: { $0.isWhitespace || $0.isNewline }),
            !host.contains("@"), !host.contains("/") else {
            throw ADBCError("Enter an SSH host or an alias from ~/.ssh/config.")
        }
        guard let number = Int(port), (1...65535).contains(number) else {
            throw ADBCError("SSH port must be between 1 and 65535.")
        }
    }

    func arguments(localPort: Int, destination: TunnelDestination) throws -> [String] {
        try validate()
        let target = destination.host.contains(":") ? "[\(destination.host)]" : destination.host
        var args = ["-v", "-N", "-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
                    "-o", "ExitOnForwardFailure=yes", "-o", "ConnectTimeout=10",
                    "-o", "ConnectionAttempts=1", "-o", "ServerAliveInterval=15",
                    "-o", "ServerAliveCountMax=3", "-o", "ControlMaster=no",
                    "-o", "ControlPath=none", "-o", "ControlPersist=no", "-o", "ForkAfterAuthentication=no",
                    "-o", "PermitLocalCommand=no", "-p", port,
                    "-L", "127.0.0.1:\(localPort):\(target):\(destination.port)"]
        if !user.isEmpty { args += ["-l", user] }
        if !identityFile.isEmpty {
            let path = (identityFile as NSString).expandingTildeInPath
            guard FileManager.default.isReadableFile(atPath: path) else {
                throw ADBCError("SSH identity file is not readable.")
            }
            args += ["-i", path]
        }
        return args + ["--", host]
    }
}

/// Database endpoint as seen from the SSH server, before forwarding.
struct TunnelDestination {
    let host: String
    let port: Int
    let uri: String
    let driver: String

    init(uri: String, driver: String) throws {
        guard ["postgresql", "mysql"].contains(driver),
            let parsed = URLComponents(string: uri),
            Discovery.driverName(forURI: uri) == driver,
            let host = parsed.host, !host.isEmpty,
            !host.contains(where: { $0.isWhitespace }), !host.contains(","), !host.contains("/"),
            parsed.fragment == nil else {
            throw ADBCError("SSH tunneling needs a PostgreSQL or MySQL URI with a single database host.")
        }
        let overrides: Set<String> = ["host", "hostaddr", "port", "user", "password", "dbname"]
        guard !(parsed.queryItems ?? []).contains(where: { overrides.contains($0.name) }) else {
            throw ADBCError("For SSH, put the database host, port and credentials in the URI fields rather than query parameters.")
        }
        self.host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        self.port = parsed.port ?? (driver == "mysql" ? 3306 : 5432)
        guard (1...65535).contains(self.port) else { throw ADBCError("Invalid database port.") }
        self.uri = uri
        self.driver = driver
    }

    func forwardedURI(localPort: Int) -> String {
        var parsed = URLComponents(string: uri)!
        parsed.port = localPort
        if driver == "postgresql" {
            // libpq connects to hostaddr but verifies SSL against the original host.
            var items = parsed.queryItems ?? []
            items.append(.init(name: "hostaddr", value: "127.0.0.1"))
            parsed.queryItems = items
        } else {
            parsed.host = "127.0.0.1"
        }
        return parsed.string!
    }
}

/// Owns one foreground OpenSSH process. It never invokes a shell or prompts.
final class SSHTunnel: @unchecked Sendable {
    let localPort: Int
    private let process: Process
    private let logURL: URL
    private let lock = NSLock()
    private var stopped = false

    private init(process: Process, port: Int, logURL: URL) {
        self.process = process
        self.localPort = port
        self.logURL = logURL
    }

    var isRunning: Bool { process.isRunning }

    static func start(settings: SSHSettings, destination: TunnelDestination,
                      executableURL: URL = URL(fileURLWithPath: "/usr/bin/ssh")) throws -> SSHTunnel {
        try settings.validate()
        for attempt in 0..<3 {
            let port = try freePort()
            let log = FileManager.default.temporaryDirectory.appendingPathComponent("sdbui-ssh-\(UUID().uuidString).log")
            let arguments = try settings.arguments(localPort: port, destination: destination)
            guard FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw ADBCError("Could not create SSH diagnostics file.")
            }
            let handle = try FileHandle(forWritingTo: log)
            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = handle
            do { try process.run() } catch {
                try? handle.close()
                try? FileManager.default.removeItem(at: log)
                throw ADBCError("Could not start OpenSSH: \(error)")
            }
            try? handle.close()
            SSHProcessRegistry.shared.add(process, logURL: log)
            let tunnel = SSHTunnel(process: process, port: port, logURL: log)
            let deadline = Date().addingTimeInterval(15)
            while process.isRunning && Date() < deadline {
                // OpenSSH reports this only after authentication and forwarding setup.
                // Avoid a second Process while the long-lived ssh process is active:
                // some Foundation versions serialize child reaping on Linux.
                let diagnostics = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
                if diagnostics.contains("Entering interactive session."),
                   diagnostics.contains("Local forwarding listening on 127.0.0.1 port \(port)"),
                   process.isRunning, listening(port: port) { return tunnel }
                Thread.sleep(forTimeInterval: 0.05)
            }
            let message = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            let timedOut = process.isRunning
            tunnel.stop()
            if message.contains("Address already in use"), attempt < 2 { continue }
            let detail = errorDetail(message)
            throw ADBCError(timedOut
                ? "SSH tunnel timed out. Check the host, SSH agent and identity file."
                : "SSH tunnel failed. \(detail.isEmpty ? "OpenSSH exited before forwarding was ready." : detail)")
        }
        throw ADBCError("Could not allocate a local SSH tunnel port.")
    }

    private static func errorDetail(_ diagnostics: String) -> String {
        let lines = diagnostics.split(separator: "\n").filter {
            !$0.hasPrefix("debug") && !$0.hasPrefix("OpenSSH_")
        }
        return String(lines.suffix(8).joined(separator: "\n").suffix(2000))
    }

    func check() throws {
        guard process.isRunning else {
            let detail = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
            throw ADBCError("SSH tunnel closed. \(Self.errorDetail(detail))")
        }
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return }
        stopped = true
        if process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(1)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }
        SSHProcessRegistry.shared.remove(process)
        try? FileManager.default.removeItem(at: logURL)
        try? FileManager.default.removeItem(atPath: logURL.path + ".sock")
    }

    deinit { stop() }

    private static func socketFD() -> Int32 {
        #if os(Linux)
        return socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        return socket(AF_INET, SOCK_STREAM, 0)
        #endif
    }

    private static func address(port: Int) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return address
    }

    private static func freePort() throws -> Int {
        let fd = socketFD()
        guard fd >= 0 else { throw ADBCError("Could not create a local tunnel socket.") }
        defer { _ = close(fd) }
        var addr = address(port: 0)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        guard bound == 0, withUnsafeMutablePointer(to: &addr, { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) }
        }) == 0 else { throw ADBCError("Could not reserve a local tunnel port.") }
        return Int(UInt16(bigEndian: addr.sin_port))
    }

    private static func listening(port: Int) -> Bool {
        let fd = socketFD()
        guard fd >= 0 else { return false }
        defer { _ = close(fd) }
        var addr = address(port: port)
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
    }
}

/// Normal application exit also stops tunnels if the UI still owns a connection.
private final class SSHProcessRegistry: @unchecked Sendable {
    static let shared = SSHProcessRegistry()
    private let lock = NSLock()
    private var processes: [Int32: (process: Process, log: URL)] = [:]
    private init() { atexit { SSHProcessRegistry.shared.stopAll() } }
    func add(_ process: Process, logURL: URL) {
        lock.lock(); defer { lock.unlock() }
        processes[process.processIdentifier] = (process, logURL)
    }
    func remove(_ process: Process) {
        lock.lock(); defer { lock.unlock() }
        processes[process.processIdentifier] = nil
    }
    private func stopAll() {
        lock.lock(); defer { lock.unlock() }
        for entry in processes.values {
            if entry.process.isRunning { entry.process.terminate() }
            try? FileManager.default.removeItem(at: entry.log)
            try? FileManager.default.removeItem(atPath: entry.log.path + ".sock")
        }
    }
}
