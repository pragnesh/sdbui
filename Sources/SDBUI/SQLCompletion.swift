import ADBCKit
import Foundation

struct SQLCompletion: Sendable {
    let start: Int // Unicode scalar offsets, matching GtkTextBuffer.
    let values: [String]
}

/// A deliberately small SQL lexer: completion never interprets strings/comments
/// as identifiers, and resolves ordinary FROM/JOIN aliases without executing SQL.
enum SQLCompletionEngine {
    static let keywords = "SELECT FROM WHERE JOIN LEFT RIGHT INNER OUTER ON AS AND OR NOT NULL IS IN EXISTS GROUP BY ORDER HAVING LIMIT OFFSET DISTINCT UNION ALL WITH INSERT INTO VALUES UPDATE SET DELETE RETURNING CASE WHEN THEN ELSE END ASC DESC COUNT SUM AVG MIN MAX COALESCE EXPLAIN CREATE TABLE DROP ALTER TRUE FALSE LIKE BETWEEN".split(separator: " ").map(String.init)
    struct Token { let text: String; let start: Int; let end: Int; let quoted: Bool }
    struct Scan { var tokens: [Token]; var blocked: Bool; var identifierStart: Int? }
    static func scan(_ text: String, dialect: SQLDialect = .generic) -> Scan {
        let s = Array(text.unicodeScalars)
        var result: [Token] = [], i = 0
        func word(_ c: Unicode.Scalar) -> Bool { CharacterSet.alphanumerics.contains(c) || c == "_" || c == "$" }
        func string(_ start: Int, _ end: Int) -> String { String(String.UnicodeScalarView(s[start..<end])) }
        while i < s.count {
            let start = i
            if (s[i] == "-" && i + 1 < s.count && s[i + 1] == "-" && (dialect != .mysql || i + 2 >= s.count || s[i + 2].value <= 32)) || (dialect == .mysql && s[i] == "#") {
                i += 1; while i < s.count, s[i] != "\n" { i += 1 }
                if i == s.count { return Scan(tokens: result, blocked: true) }
            } else if s[i] == "/", i + 1 < s.count, s[i + 1] == "*" {
                i += 2; var depth = 1
                while i < s.count, depth > 0 {
                    if i + 1 < s.count, s[i] == "/", s[i + 1] == "*" { depth += 1; i += 2 }
                    else if i + 1 < s.count, s[i] == "*", s[i + 1] == "/" { depth -= 1; i += 2 }
                    else { i += 1 }
                }
                if depth > 0 { return Scan(tokens: result, blocked: true) }
            } else if s[i] == "'" || s[i] == "\"" || s[i] == "`" {
                let quote = s[i]
                let isString = quote == "'" || (quote == "\"" && dialect == .mysql)
                let escapes = dialect == .mysql || (quote == "'" && start > 0 && (s[start - 1] == "E" || s[start - 1] == "e") && (start < 2 || !word(s[start - 2])))
                i += 1; var value = "", closed = false
                while i < s.count {
                    if s[i] == quote {
                        if i + 1 < s.count, s[i + 1] == quote { value.unicodeScalars.append(quote); i += 2 }
                        else { i += 1; closed = true; break }
                    } else if s[i] == "\\", escapes, i + 1 < s.count { i += 2 }
                    else { value.unicodeScalars.append(s[i]); i += 1 }
                }
                if !closed { return Scan(tokens: result, blocked: isString, identifierStart: isString ? nil : start) }
                if !isString { result.append(Token(text: value, start: start, end: i, quoted: true)) }
            } else if s[i] == "$", dialect != .mysql {
                var end = i + 1
                while end < s.count, s[end] == "_" || CharacterSet.alphanumerics.contains(s[end]) { end += 1 }
                if end < s.count, s[end] == "$" {
                    let delimiter = string(i, end + 1); i = end + 1
                    while i < s.count, !string(i, min(s.count, i + delimiter.unicodeScalars.count)).hasPrefix(delimiter) { i += 1 }
                    if i == s.count { return Scan(tokens: result, blocked: true) }
                    i += delimiter.unicodeScalars.count
                } else { i += 1; result.append(Token(text: "$", start: start, end: i, quoted: false)) }
            } else if word(s[i]) {
                i += 1; while i < s.count, word(s[i]) { i += 1 }
                result.append(Token(text: string(start, i), start: start, end: i, quoted: false))
            } else {
                if !CharacterSet.whitespacesAndNewlines.contains(s[i]) { result.append(Token(text: string(i, i + 1), start: i, end: i + 1, quoted: false)) }
                i += 1
            }
        }
        return Scan(tokens: result, blocked: false)
    }

    /// Alias -> table. Restrict unqualified names to the active namespace first.
    static func references(_ sql: String, tables: [TableInfo], namespace: String?, dialect: SQLDialect = .generic) -> [String: TableInfo] {
        let tokens = scan(sql, dialect: dialect).tokens
        var references: [String: TableInfo] = [:]
        for i in tokens.indices where !tokens[i].quoted && ["FROM", "JOIN", "UPDATE", "INTO"].contains(tokens[i].text.uppercased()) {
            var j = i + 1
            guard j < tokens.count else { continue }
            let first = tokens[j].text; var name = first; var schema: String?
            j += 1
            if j + 1 < tokens.count, tokens[j].text == "." { schema = first; name = tokens[j + 1].text; j += 2 }
            let matches = tables.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame && (schema == nil || $0.namespace.caseInsensitiveCompare(schema!) == .orderedSame) }
            guard let table = matches.first(where: { $0.namespace == namespace }) ?? (matches.count == 1 ? matches.first : nil) else { continue }
            references[name.lowercased()] = table
            if j < tokens.count, !tokens[j].quoted, tokens[j].text.uppercased() == "AS" { j += 1 }
            if j < tokens.count, tokens[j].quoted || (!keywords.contains(tokens[j].text.uppercased()) && tokens[j].text.rangeOfCharacter(from: .alphanumerics) != nil) {
                references[tokens[j].text.lowercased()] = table
            }
        }
        return references
    }

    static func complete(_ sql: String, cursor: Int, dialect: SQLDialect, tables: [TableInfo], namespace: String?, columns: [String: [String]]) -> SQLCompletion? {
        let scalars = Array(sql.unicodeScalars)
        guard cursor >= 0, cursor <= scalars.count else { return nil }
        let prefixSQL = String(String.UnicodeScalarView(scalars[..<cursor]))
        let scan = scan(prefixSQL, dialect: dialect)
        guard !scan.blocked else { return nil }
        var tokens = scan.tokens
        var start = cursor, prefix = ""
        if let quoted = scan.identifierStart {
            start = quoted; prefix = String(String.UnicodeScalarView(scalars[(quoted + 1)..<cursor]))
        } else if let last = tokens.last, last.end == cursor, last.text != ".",
                  last.quoted || last.text.rangeOfCharacter(from: .alphanumerics) != nil || last.text == "_" {
            start = last.start; prefix = last.text; tokens.removeLast()
        }
        // Aliases may appear after the cursor (SELECT u.na FROM users u).
        let currentStatement = dialect.statement(in: sql, at: cursor)?.text ?? sql
        let refs = references(currentStatement, tables: tables, namespace: namespace, dialect: dialect)
        var candidates: [String] = []
        if tokens.last?.text == ".", tokens.count >= 2 {
            let qualifier = tokens[tokens.count - 2].text
            if let table = refs[qualifier.lowercased()] ?? tables.first(where: { $0.name.caseInsensitiveCompare(qualifier) == .orderedSame && $0.namespace == namespace }) {
                candidates = (columns[table.id] ?? []).filter { $0.lowercased().hasPrefix(prefix.lowercased()) }.map(dialect.quote)
            } else {
                candidates = tables.filter { $0.namespace.caseInsensitiveCompare(qualifier) == .orderedSame && $0.name.lowercased().hasPrefix(prefix.lowercased()) }.map { dialect.quote($0.name) }
            }
        } else {
            candidates += keywords.filter { $0.lowercased().hasPrefix(prefix.lowercased()) }
            candidates += tables.filter { $0.name.lowercased().hasPrefix(prefix.lowercased()) }.map {
                $0.namespace == namespace ? dialect.quote($0.name) : dialect.qualifiedName(of: $0)
            }
            for table in Set(refs.values.map(\.id)) {
                candidates += (columns[table] ?? []).filter { $0.lowercased().hasPrefix(prefix.lowercased()) }.map(dialect.quote)
            }
        }
        let original = String(String.UnicodeScalarView(scalars[start..<cursor]))
        return SQLCompletion(start: start, values: Array(Set(candidates)).filter { $0 != original }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }.prefix(80).map { $0 })
    }
}
