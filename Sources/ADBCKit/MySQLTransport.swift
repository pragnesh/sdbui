import Foundation

/// Translate the form's libmysql-style SSL mode for the Foundry Go driver.
/// Legacy drivers retain their original URI. Verification is never weakened.
enum MySQLTransport {
    static func foundryURI(_ uri: String) throws -> String {
        guard var components = URLComponents(string: uri), let items = components.queryItems,
              let mode = items.last(where: { $0.name == "ssl-mode" })?.value else { return uri }
        var result = items.filter { $0.name != "ssl-mode" }
        if !result.contains(where: { $0.name == "tls" }) {
            let tls: String
            switch mode.uppercased() {
            case "DISABLED": tls = "false"
            case "PREFERRED": tls = "preferred"
            case "REQUIRED": tls = "skip-verify" // Encrypted, matching SSL_MODE_REQUIRED.
            case "VERIFY_CA", "VERIFY_IDENTITY": tls = "true" // CA and hostname are both verified.
            default: throw ADBCError("Unsupported MySQL SSL mode.")
            }
            result.append(.init(name: "tls", value: tls))
        }
        components.queryItems = result
        guard let value = components.string else { throw ADBCError("Invalid MySQL transport settings.") }
        return value
    }
}
