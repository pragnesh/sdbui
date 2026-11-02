import Foundation

/// Application metadata, deliberately separate from driver options.
public struct FavoriteSafety: Sendable, Hashable {
    public var label: String
    public var color: String
    public var readOnly: Bool
    public static let colors = ["None", "Red", "Orange", "Yellow", "Green", "Blue", "Purple"]

    public init(label: String = "", color: String = "None", readOnly: Bool = false) {
        self.label = label
        self.color = Self.colors.contains(color) ? color : "None"
        self.readOnly = readOnly
    }
}

/// Conservative lexical safeguards, not a replacement for database permissions.
public struct SQLSafetyAssessment: Sendable, Equatable {
    public let warnings: [String]
    public let allowsReadOnly: Bool

    public init(_ sql: String, dialect: SQLDialect) {
        let tokens = SafetyLexer.tokens(sql, dialect: dialect)
        var warnings: [String] = []
        for (index, token) in tokens.enumerated() {
            switch token.word {
            case "DROP", "TRUNCATE": warnings.append(token.word)
            case "DELETE", "UPDATE":
                let rest = tokens.dropFirst(index + 1).prefix { $0.depth >= token.depth && $0.word != ";" }
                if !rest.contains(where: { $0.depth == token.depth && $0.word == "WHERE" }) {
                    warnings.append("\(token.word) without WHERE")
                }
            default: break
            }
        }
        // An executable MySQL comment can contain arbitrary SQL. Always ask.
        if tokens.contains(where: { $0.word == "UNSAFE" }) { warnings.append("Executable or unterminated SQL construct") }
        self.warnings = Array(Set(warnings)).sorted()
        let forbidden: Set<String> = ["INSERT", "UPDATE", "DELETE", "MERGE", "REPLACE", "CREATE", "ALTER", "DROP", "TRUNCATE", "INTO", "COPY", "CALL", "DO", "EXEC", "EXECUTE", "SET", "RESET", "BEGIN", "START", "COMMIT", "ROLLBACK", "END", "SAVEPOINT", "RELEASE", "GRANT", "REVOKE", "LOCK", "UNLOCK", "VACUUM", "ANALYZE", "ATTACH", "DETACH", "PRAGMA", "UNSAFE"]
        allowsReadOnly = ["SELECT", "WITH", "SHOW", "VALUES", "TABLE", "EXPLAIN"].contains(tokens.first?.word ?? "")
            && !tokens.contains { forbidden.contains($0.word) || $0.word == ";" }
    }
}

private enum SafetyLexer {
    struct Token { let word: String; let depth: Int }
    static func tokens(_ sql: String, dialect: SQLDialect) -> [Token] {
        let s = Array(sql.unicodeScalars)
        var i = 0, depth = 0
        var result: [Token] = []
        func append(_ word: String) { result.append(Token(word: word, depth: depth)) }
        func wordCharacter(_ c: Unicode.Scalar) -> Bool { CharacterSet.alphanumerics.contains(c) || c == "_" || c == "$" }
        while i < s.count {
            let c = s[i], next = i + 1 < s.count ? s[i + 1] : nil
            if c == "-" && next == "-" && (dialect != .mysql || i + 2 >= s.count || s[i + 2].value <= 32) || c == "#" && dialect == .mysql {
                while i < s.count && s[i] != "\n" { i += 1 }; continue
            }
            if c == "/" && next == "*" {
                if i + 2 < s.count && (s[i + 2] == "!" || s[i + 2] == "+") { append("UNSAFE") }
                i += 2
                var nesting = 1
                while i < s.count && nesting > 0 {
                    if i + 1 < s.count && s[i] == "/" && s[i + 1] == "*" && dialect != .mysql { nesting += 1; i += 2 }
                    else if i + 1 < s.count && s[i] == "*" && s[i + 1] == "/" { nesting -= 1; i += 2 }
                    else { i += 1 }
                }
                if nesting != 0 { append("UNSAFE") }; continue
            }
            if c == "'" || c == "\"" || c == "`" || (c == "[" && dialect == .generic) {
                let quote: Unicode.Scalar = c == "[" ? "]" : c
                // PostgreSQL E'...' and MySQL strings accept backslash escapes.
                let escaped = dialect == .mysql || (i > 0 && (s[i - 1] == "E" || s[i - 1] == "e"))
                i += 1
                var closed = false
                while i < s.count {
                    if s[i] == "\\" && escaped { i += 2 }
                    else if s[i] == quote {
                        i += 1
                        if i < s.count && s[i] == quote { i += 1 } else { closed = true; break }
                    } else { i += 1 }
                }
                if !closed { append("UNSAFE") }; continue
            }
            if c == "$" && dialect != .mysql {
                var end = i + 1
                while end < s.count && (CharacterSet.alphanumerics.contains(s[end]) || s[end] == "_") { end += 1 }
                if end < s.count && s[end] == "$" {
                    let delimiter = Array(s[i...end]); i = end + 1
                    var closed = false
                    while i + delimiter.count <= s.count {
                        if Array(s[i..<(i + delimiter.count)]) == delimiter { i += delimiter.count; closed = true; break }
                        i += 1
                    }
                    if !closed { append("UNSAFE"); i = s.count }; continue
                }
            }
            if c == "(" { depth += 1; i += 1; continue }
            if c == ")" { depth = max(0, depth - 1); i += 1; continue }
            if c == ";" { append(";"); i += 1; continue }
            if wordCharacter(c) {
                let start = i; i += 1
                while i < s.count && wordCharacter(s[i]) { i += 1 }
                append(String(String.UnicodeScalarView(s[start..<i])).uppercased())
            } else { i += 1 }
        }
        return result
    }
}
