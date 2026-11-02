import ADBCKit
import Foundation

/// The last manual run, independent of catalog loading and export feedback.
struct QueryStatus: Hashable {
    var text: String
    var error: String? = nil
    var truncated = false

    static func completed(_ result: QueryResult, elapsed: Duration, statements: Int, maxRows: Int) -> Self {
        let count: String
        if !result.columns.isEmpty {
            count = "\(result.rowCount.formatted()) row\(result.rowCount == 1 ? "" : "s")"
        } else if let affected = result.rowsAffected {
            count = "\(affected.formatted()) row\(affected == 1 ? "" : "s") affected"
        } else { count = "Statement executed" }
        let prefix = statements > 1 ? "\(statements) statements · last result: " : ""
        let limit = result.truncated ? " · truncated at Max rows (\(maxRows.formatted())) ⚠" : ""
        return Self(text: prefix + count + " · " + duration(elapsed) + limit, truncated: result.truncated)
    }

    static func failed(_ error: String, elapsed: Duration, cancelled: Bool) -> Self {
        Self(text: (cancelled ? "Query cancelled" : "Query failed") + " · " + duration(elapsed), error: error)
    }

    static func duration(_ elapsed: Duration) -> String {
        let parts = elapsed.components
        let milliseconds = max(0, Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15)
        if milliseconds < 1_000 { return "\(Int(milliseconds.rounded()).formatted()) ms" }
        return String(format: "%.2f s", milliseconds / 1_000)
    }
}

struct QueryErrorLocation: Equatable {
    let id = UUID()
    let sourceSQL: String
    /// Zero-based Unicode scalar offset, matching GtkTextBuffer and SQLStatement.
    let offset: Int

    static func resolve(position: Int?, statement: SQLStatement, source: String, baseOffset: Int) -> Self? {
        guard let position, position > 0, position - 1 <= statement.text.unicodeScalars.count,
              baseOffset >= 0 else { return nil }
        let (start, firstOverflow) = baseOffset.addingReportingOverflow(statement.range.lowerBound)
        let (offset, secondOverflow) = start.addingReportingOverflow(position - 1)
        guard !firstOverflow, !secondOverflow, offset >= 0, offset <= source.unicodeScalars.count else { return nil }
        return Self(sourceSQL: source, offset: offset)
    }
}
