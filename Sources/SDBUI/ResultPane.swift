import ADBCKit

/// One grid's results: the rows plus the current page rendered as monospaced
/// text (see ``ResultText``).
///
/// Not `@Observable` (see ``BrowserModel``): views watch ``revision`` with
/// ``BrowserModel/watch(_:of:_:)`` and redraw only when it changes.
@MainActor
final class ResultPane {
    let pageSize: Int
    private(set) var result: QueryResult?
    private(set) var page = 0
    private(set) var header = ""
    private(set) var body = ""
    /// Bumped on every change.
    private(set) var revision = 0
    private var widths: [Int] = []
    /// Called after every change.
    var onChange: @MainActor () -> Void = {}

    init(pageSize: Int = 100) {
        self.pageSize = pageSize
    }

    var hasColumns: Bool {
        !(result?.columns.isEmpty ?? true)
    }

    func show(_ result: QueryResult?) {
        self.result = result
        widths = result.map(ResultText.columnWidths(of:)) ?? []
        header = result.map { ResultText.header(of: $0, widths: widths) } ?? ""
        showPage(0)
    }

    func showPage(_ page: Int) {
        self.page = max(0, min(page, pageCount - 1))
        body = result.map { ResultText.body(of: $0, rows: pageRange, widths: widths) } ?? ""
        revision += 1
        onChange()
    }

    var pageCount: Int {
        guard let result, !result.rows.isEmpty else { return 1 }
        return (result.rows.count + pageSize - 1) / pageSize
    }

    var pageRange: Range<Int> {
        guard let result else { return 0..<0 }
        let start = min(page * pageSize, result.rows.count)
        return start..<min(start + pageSize, result.rows.count)
    }
}
