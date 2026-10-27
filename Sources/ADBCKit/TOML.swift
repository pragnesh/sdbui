import Foundation

/// A deliberately small TOML reader covering what ADBC driver manifests and
/// connection profiles use: tables, (dotted/quoted) keys, strings, integers,
/// floats and booleans. Arrays and inline tables are skipped.
struct TOMLDocument {
    enum Value: Equatable {
        case string(String)
        case integer(Int64)
        case float(Double)
        case bool(Bool)

        var stringValue: String {
            switch self {
                case .string(let value): value
                case .integer(let value): String(value)
                case .float(let value): String(value)
                case .bool(let value): String(value)
            }
        }
    }

    /// Entries in file order, each keyed by its full path (table + key).
    private(set) var entries: [(path: [String], value: Value)] = []

    init(parsing text: String) throws {
        var table: [String] = []
        for (lineIndex, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
        {
            var scanner = Scanner(Substring(rawLine))
            scanner.skipWhitespace()
            guard let first = scanner.peek, first != "#" else { continue }

            do {
                if first == "[" {
                    scanner.advance()
                    guard scanner.peek != "[" else {
                        throw TOMLError("arrays of tables are not supported")
                    }
                    table = try scanner.parseKey()
                    scanner.skipWhitespace()
                    try scanner.expect("]")
                } else {
                    let key = try scanner.parseKey()
                    scanner.skipWhitespace()
                    try scanner.expect("=")
                    scanner.skipWhitespace()
                    if let value = try scanner.parseValue() {
                        entries.append((table + key, value))
                    }
                }
                scanner.skipWhitespace()
                if let next = scanner.peek, next != "#" {
                    throw TOMLError("unexpected '\(next)'")
                }
            } catch let error as TOMLError {
                throw TOMLError("line \(lineIndex + 1): \(error.message)")
            }
        }
    }

    init(contentsOf url: URL) throws {
        try self.init(parsing: String(contentsOf: url, encoding: .utf8))
    }

    subscript(_ path: String...) -> Value? {
        entries.last { $0.path == path }?.value
    }

    /// All entries below `table`, keyed by the remaining path joined with ".".
    func entries(in table: String) -> [(key: String, value: Value)] {
        entries
            .filter { $0.path.count > 1 && $0.path[0] == table }
            .map { ($0.path.dropFirst().joined(separator: "."), $0.value) }
    }
}

struct TOMLError: Error, CustomStringConvertible {
    var message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

private struct Scanner {
    private var text: Substring

    init(_ text: Substring) { self.text = text }

    var peek: Character? { text.first }

    mutating func advance() { text = text.dropFirst() }

    mutating func skipWhitespace() {
        text = text.drop { $0 == " " || $0 == "\t" || $0 == "\r" }
    }

    mutating func expect(_ character: Character) throws {
        guard peek == character else {
            throw TOMLError("expected '\(character)'")
        }
        advance()
    }

    mutating func parseKey() throws -> [String] {
        var parts: [String] = []
        while true {
            skipWhitespace()
            switch peek {
                case "\"": parts.append(try parseBasicString())
                case "'": parts.append(try parseLiteralString())
                default:
                    let bare = text.prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
                    guard !bare.isEmpty else { throw TOMLError("expected a key") }
                    parts.append(String(bare))
                    text = text.dropFirst(bare.count)
            }
            skipWhitespace()
            guard peek == "." else { return parts }
            advance()
        }
    }

    mutating func parseValue() throws -> TOMLDocument.Value? {
        switch peek {
            case "\"": return .string(try parseBasicString())
            case "'": return .string(try parseLiteralString())
            case "[", "{":
                // Not needed by ADBC manifests/profiles; skip the rest of the line.
                text = text.suffix(0)
                return nil
            default:
                let token = text.prefix { $0 != " " && $0 != "\t" && $0 != "#" && $0 != "\r" }
                text = text.dropFirst(token.count)
                let cleaned = token.replacingOccurrences(of: "_", with: "")
                if token == "true" { return .bool(true) }
                if token == "false" { return .bool(false) }
                if let integer = Int64(cleaned) { return .integer(integer) }
                if let float = Double(cleaned) { return .float(float) }
                throw TOMLError("unsupported value '\(token)'")
        }
    }

    private mutating func parseLiteralString() throws -> String {
        advance()
        guard let end = text.firstIndex(of: "'") else {
            throw TOMLError("unterminated string")
        }
        let value = String(text[..<end])
        text = text[text.index(after: end)...]
        return value
    }

    private mutating func parseBasicString() throws -> String {
        advance()
        var value = ""
        while let character = peek {
            advance()
            switch character {
                case "\"":
                    return value
                case "\\":
                    guard let escaped = peek else { break }
                    advance()
                    switch escaped {
                        case "n": value.append("\n")
                        case "t": value.append("\t")
                        case "r": value.append("\r")
                        case "\\": value.append("\\")
                        case "\"": value.append("\"")
                        case "u", "U":
                            let digits = text.prefix(escaped == "u" ? 4 : 8)
                            text = text.dropFirst(digits.count)
                            guard let code = UInt32(digits, radix: 16),
                                let scalar = Unicode.Scalar(code)
                            else { throw TOMLError("invalid unicode escape") }
                            value.unicodeScalars.append(scalar)
                        default:
                            throw TOMLError("invalid escape '\\\(escaped)'")
                    }
                default:
                    value.append(character)
            }
        }
        throw TOMLError("unterminated string")
    }
}
