import CADBC
import Foundation

public enum TableExportFormat: String, CaseIterable, Sendable, CustomStringConvertible {
    case csv, json, sql, arrow, parquet
    public var description: String { self == .sql ? "SQL INSERT" : rawValue.uppercased() }
}

public struct CSVImportOptions: Codable, Hashable, Sendable {
    public var delimiter = ","
    public var header = true
    public var nullMarker = "\\N"
    public var emptyIsNull = false
    public init() {}
}

public struct TransferColumn: Codable, Hashable, Sendable {
    public let name: String
    public let type: String
    public let computed: Bool
    public let identity: Bool
}

public struct CSVImportPreview: Codable, Sendable {
    public var headers: [String]
    public var samples: [[String?]]
    public var fingerprint: [Int64]
    public var schema: String
    public var columns: [TransferColumn] = []
    enum CodingKeys: String, CodingKey { case headers, samples, fingerprint, schema }
}

/// Cancellation and progress are shared with the streaming reader without the connection lock.
public final class TransferProgress: @unchecked Sendable {
    let pointer: OpaquePointer
    public init() { pointer = cadbc_transfer_new()! }
    deinit { cadbc_transfer_free(pointer) }
    public func cancel() { cadbc_transfer_cancel(pointer) }
    public var rows: Int64 { cadbc_transfer_rows(pointer) }
    public var isCancelled: Bool { cadbc_transfer_cancelled(pointer) != 0 }
}

/// Optional private Python runtime; plain SQL browsing has no Python dependency.
public struct TransferRuntime: Sendable {
    let library: String
    let home: String
    let site: String
    public static func discover() throws -> TransferRuntime {
        let env = ProcessInfo.processInfo.environment
        let data = env["XDG_DATA_HOME"] ?? NSHomeDirectory() + "/.local/share"
        let candidates = env["SDBUI_PYTHON"].map { [$0] } ?? [
            data + "/sdbui/transfer-python/bin/python3",
            FileManager.default.currentDirectoryPath + "/.build/transfer-python/bin/python3",
        ] + (env["PATH"] ?? "").split(separator: ":").map { String($0) + "/python3" }
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = ["-I", "-c", """
                import json,sys,sysconfig,os,ctypes.util,pyarrow
                lib=os.path.join(sysconfig.get_config_var('LIBDIR') or '',sysconfig.get_config_var('LDLIBRARY') or '')
                if not os.path.isfile(lib):
                    framework=sysconfig.get_config_var('PYTHONFRAMEWORK') or 'Python'
                    candidates=[os.path.join(sys.base_prefix,framework),os.path.join(sysconfig.get_config_var('PYTHONFRAMEWORKPREFIX') or '', framework+'.framework', 'Versions',sysconfig.get_python_version(),framework)]
                    lib=next((p for p in candidates if os.path.isfile(p)),None) or ctypes.util.find_library('python'+sysconfig.get_python_version()) or ctypes.util.find_library(framework)
                print(json.dumps(dict(library=lib,home=sys.base_prefix,site=os.path.dirname(os.path.dirname(pyarrow.__file__)))))
                """]
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                let bytes = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                if process.terminationStatus == 0,
                   let value = try JSONSerialization.jsonObject(with: bytes) as? [String: String],
                   let library = value["library"], let home = value["home"], let site = value["site"] {
                    return TransferRuntime(library: library, home: home, site: site)
                }
            } catch { continue }
        }
        throw ADBCError("Install the optional transfer runtime with: python3 scripts/setup-transfers.py (installed releases: python3 <prefix>/share/sdbui/setup-transfers.py). Python must provide a shared libpython library. Restart after setup.")
    }

    func scope(_ config: [String: Any], progress: TransferProgress) throws -> TransferScope {
        var config = config
        config["site"] = site
        config["token"] = UInt(bitPattern: progress.pointer)
        config["poll"] = cadbc_transfer_poll_address()
        config["progress"] = cadbc_transfer_progress_address()
        let bytes = try JSONSerialization.data(withJSONObject: config)
        guard let script = Bundle.module.url(forResource: "transfer", withExtension: "py") else {
            throw ADBCError("Bundled transfer helper missing. Reinstall SDBUI.")
        }
        var error: UnsafeMutablePointer<CChar>?
        guard let handle = cadbc_python_scope(library, home, script.path, String(decoding: bytes, as: UTF8.self), &error) else {
            defer { cadbc_free_string(error) }
            throw ADBCError(error.map { String(cString: $0) } ?? "Transfer runtime failed.")
        }
        return TransferScope(handle)
    }
}

final class TransferScope {
    let handle: UnsafeMutableRawPointer
    init(_ handle: UnsafeMutableRawPointer) { self.handle = handle }
    deinit { cadbc_python_scope_free(handle) }
    func result<T: Decodable>(_ type: T.Type) throws -> T {
        guard let text = cadbc_python_result(handle) else { throw ADBCError("Transfer returned no result.") }
        defer { cadbc_free_string(text) }
        return try JSONDecoder().decode(type, from: Data(String(cString: text).utf8))
    }
}

extension CSVImportOptions {
    func jsonObject() throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder().encode(self)) }
}
