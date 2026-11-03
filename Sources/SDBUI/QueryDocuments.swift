import ADBCKit
import Foundation
import SwiftCrossUI

/// Persist only drafts; result buffers remain in memory for the life of the connection.
struct QueryDraftState: Codable, Equatable {
    var id = UUID()
    var name: String
    var sql: String
    var dirty: Bool
}

@MainActor
final class QueryDocument {
    let id: UUID
    var name: String
    var sql = ""
    var baseline: String? = ""
    let pane: ResultPane
    var status: QueryStatus?
    var statusText = "Ready"
    var error: String?
    var errorLocation: QueryErrorLocation?
    var log: [String] = []
    var browsing = false
    var browseSQL = ""
    var browsePageSize = 1000
    var offset = 0
    var hasMore = false
    var expression: SQLDialect.FilterExpression?
    var total: Int64?
    var filterGroups: [FilterGroupDraft] = []
    var filterJoin: FilterJoin = .any
    var filter: SQLDialect.Filter?
    var sort: DataGridSort?
    var columns: [String] = []
    var filterColumn: String?
    var filterOperator: SQLDialect.Filter.Operator? = .contains
    var filterValue = ""
    var tableID: String?
    var cursor = 0
    var selection: Range<Int>?
    var dirty: Bool { baseline.map { $0 != sql } ?? true }
    init(id: UUID = UUID(), name: String, pane: ResultPane) { self.id = id; self.name = name; self.pane = pane }
}
