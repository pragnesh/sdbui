/// A statement in a SQL script.
public struct SQLStatement: Sendable, Equatable {
    /// The statement's text, trimmed, without the terminating semicolon.
    public var text: String
    /// Where it is in the script, in Unicode scalars: from its first
    /// non-whitespace character through any terminating semicolon.
    public var range: Range<Int>
}

extension SQLDialect {
    /// Splits a script into statements at semicolons that aren't inside
    /// quotes, quoted identifiers or comments. Statements that are empty or
    /// only comments are left out.
    public func statements(in script: String) -> [SQLStatement] {
        let scalars = Array(script.unicodeScalars)
        var statements: [SQLStatement] = []
        var start = 0
        var hasContent = false
        var index = 0

        func finish(at end: Int, includingTerminator: Bool) {
            if hasContent {
                let first = scalars[start..<end].firstIndex { !$0.properties.isWhitespace } ?? start
                var text = String.UnicodeScalarView()
                text.append(contentsOf: scalars[first..<end])
                statements.append(SQLStatement(
                    text: String(text).trimmingSQLWhitespace(),
                    range: first..<(includingTerminator ? end + 1 : end)))
            }
            start = end + 1
            hasContent = false
        }

        while index < scalars.count {
            let scalar = scalars[index]
            let next = index + 1 < scalars.count ? scalars[index + 1] : nil
            switch scalar {
                case "'", "\"", "`":
                    hasContent = true
                    index = endOfQuoted(scalars, from: index, quote: scalar)
                case "-" where next == "-", "#" where self == .mysql:
                    while index < scalars.count, scalars[index] != "\n" { index += 1 }
                case "/" where next == "*":
                    index += 2
                    while index < scalars.count,
                        !(scalars[index] == "*" && index + 1 < scalars.count && scalars[index + 1] == "/")
                    {
                        index += 1
                    }
                    index += 2
                case ";":
                    finish(at: index, includingTerminator: true)
                    index += 1
                default:
                    if !scalar.properties.isWhitespace { hasContent = true }
                    index += 1
            }
        }
        finish(at: scalars.count, includingTerminator: false)
        return statements
    }

    /// The statement the cursor is in (offset in Unicode scalars). After a
    /// statement's semicolon it's still that statement, until the next one
    /// starts — as in Sequel Ace's "Run Current".
    public func statement(in script: String, at cursor: Int) -> SQLStatement? {
        let statements = statements(in: script)
        return statements.last { $0.range.lowerBound <= cursor } ?? statements.first
    }

    /// The index after a quoted string or identifier starting at `start`.
    /// Doubled quotes stay inside; in single-quoted strings, so does a
    /// backslash-escaped character (MySQL).
    private func endOfQuoted(_ scalars: [Unicode.Scalar], from start: Int, quote: Unicode.Scalar) -> Int {
        var index = start + 1
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == "\\" && quote == "'" && self == .mysql {
                index += 2
            } else if scalar == quote {
                if index + 1 < scalars.count && scalars[index + 1] == quote {
                    index += 2
                } else {
                    return index + 1
                }
            } else {
                index += 1
            }
        }
        return index
    }
}

extension String {
    fileprivate func trimmingSQLWhitespace() -> String {
        let scalars = unicodeScalars
        guard let first = scalars.firstIndex(where: { !$0.properties.isWhitespace }),
            let last = scalars.lastIndex(where: { !$0.properties.isWhitespace })
        else { return "" }
        return String(scalars[first...last])
    }
}
