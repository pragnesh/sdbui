import ADBCKit
import Foundation

/// A menu snapshot, tied to the connection, table and displayed result revision.
struct CellFilterTarget: Sendable {
    let column: String
    let value: String?
    let tableID: String
    let sessionRevision: Int
    let paneRevision: Int
    var queryID: UUID? = nil

    func filter(for command: Int32) -> SQLDialect.Filter? {
        let op: SQLDialect.Filter.Operator
        switch command {
        case 0: op = value == nil ? .isNull : .equals
        case 1: op = value == nil ? .isNotNull : .notEquals
        case 2: op = .isNull
        default: return nil
        }
        // A C query string cannot carry an embedded NUL. Never silently truncate it.
        if op.needsValue && value?.contains("\0") == true { return nil }
        return SQLDialect.Filter(column: column, op: op, value: op.needsValue ? (value ?? "") : "")
    }
}
