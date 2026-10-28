import CADBC
import Foundation

public struct ResultColumn: Sendable, Hashable {
    public var name: String
    /// Arrow type name, e.g. `int64`, `utf8`, `decimal(10,2)`.
    public var type: String

    public init(name: String, type: String) {
        self.name = name
        self.type = type
    }

    /// Whether values are numbers (for alignment and sorting).
    public var isNumeric: Bool {
        let numericPrefixes = ["int", "uint", "float", "decimal"]
        return numericPrefixes.contains { type.hasPrefix($0) }
    }
}

/// A query result. Cells are formatted on demand: Arrow results keep the
/// driver's record batches and turn a value into text only when it's asked
/// for, so showing a large result costs only what's displayed.
public struct QueryResult: Sendable {
    public var columns: [ResultColumn]
    /// True when the result had more rows than `maxRows` and was cut short.
    public var truncated: Bool
    public var rowsAffected: Int64?
    public var elapsed: Duration

    private let storage: ResultStorage
    private var count: Int
    /// Display order (row → stored row), set by sorting.
    private var order: [Int]?

    /// A result from plain strings (`nil` is SQL NULL).
    public init(
        columns: [ResultColumn], rows: [[String?]], truncated: Bool = false,
        rowsAffected: Int64? = nil, elapsed: Duration = .zero
    ) {
        self.init(
            columns: columns, storage: StringStorage(rows: rows), truncated: truncated,
            rowsAffected: rowsAffected, elapsed: elapsed)
    }

    init(
        columns: [ResultColumn], storage: ResultStorage, truncated: Bool,
        rowsAffected: Int64?, elapsed: Duration
    ) {
        self.columns = columns
        self.storage = storage
        self.count = storage.rowCount
        self.truncated = truncated
        self.rowsAffected = rowsAffected
        self.elapsed = elapsed
    }

    public var rowCount: Int { count }

    /// The text of a cell (`nil` for SQL NULL). Long values are cut to
    /// `maxLength` characters plus "…"; pass `nil` for the full value.
    public func cell(_ row: Int, _ column: Int, maxLength: Int? = 1_000) -> String? {
        guard row >= 0, row < count, columns.indices.contains(column) else { return nil }
        guard var text = storage.text(row: order?[row] ?? row, column: column) else { return nil }
        if let maxLength, text.count > maxLength {
            text = String(text.prefix(maxLength)) + "…"
        }
        return text
    }

    /// A row's cells (full values).
    public func row(_ row: Int) -> [String?] {
        columns.indices.map { cell(row, $0, maxLength: nil) }
    }

    /// Keep only the first `rowCount` rows.
    public mutating func limit(to rowCount: Int) {
        count = min(count, max(rowCount, 0))
        order = order.map { Array($0.prefix(count)) }
    }

    /// The rows sorted by one column, NULLs first; numeric columns compare as
    /// numbers. Sorting is stable and doesn't copy any cells.
    public func sorted(byColumn column: Int, ascending: Bool) -> QueryResult {
        guard columns.indices.contains(column) else { return self }
        let indices = Array(0..<count)
        let stored = indices.map { order?[$0] ?? $0 }
        var sorted = self
        if columns[column].isNumeric {
            let keys = stored.map { storage.text(row: $0, column: column).flatMap(Double.init) }
            sorted.order = indices.sorted { a, b in
                Self.precedes(keys[a], keys[b], ascending: ascending, ties: a < b)
            }.map { stored[$0] }
        } else {
            let keys = stored.map { storage.text(row: $0, column: column) }
            sorted.order = indices.sorted { a, b in
                Self.precedes(keys[a], keys[b], ascending: ascending, ties: a < b)
            }.map { stored[$0] }
        }
        return sorted
    }

    private static func precedes<T: Comparable>(
        _ a: T?, _ b: T?, ascending: Bool, ties: Bool
    ) -> Bool {
        switch (a, b) {
            case (nil, nil): return ties
            case (nil, _): return ascending
            case (_, nil): return !ascending
            case (let a?, let b?):
                if a == b { return ties }
                return ascending ? a < b : a > b
        }
    }
}

// MARK: - Storage

/// Where a result's cells live. Immutable once created.
class ResultStorage: @unchecked Sendable {
    var rowCount: Int { 0 }
    func text(row: Int, column: Int) -> String? { nil }
}

final class StringStorage: ResultStorage {
    private let rows: [[String?]]

    init(rows: [[String?]]) {
        self.rows = rows
    }

    override var rowCount: Int { rows.count }

    override func text(row: Int, column: Int) -> String? {
        rows[row].indices.contains(column) ? rows[row][column] : nil
    }
}

/// Arrow record batches owned until the result is discarded. Values are
/// decoded and formatted per cell, on demand.
final class ArrowStorage: ResultStorage {
    private var arrays: [ArrowArray]
    private let batches: [ArrowArrayView]
    /// The first row of each batch.
    private let starts: [Int]
    private let total: Int

    /// Takes ownership of `arrays` (they're released in `deinit`). Only the
    /// first `rowLimit` rows are exposed.
    init(field: ArrowField, arrays: [ArrowArray], rowLimit: Int) {
        self.arrays = arrays
        batches = arrays.map { ArrowArrayView(field: field, array: $0) }
        var starts: [Int] = []
        var next = 0
        for batch in batches {
            starts.append(next)
            next += batch.length
        }
        self.starts = starts
        total = min(next, rowLimit)
    }

    deinit {
        for index in arrays.indices {
            cadbc_array_release(&arrays[index])
        }
    }

    override var rowCount: Int { total }

    override func text(row: Int, column: Int) -> String? {
        // The last batch that starts at or before `row`.
        var low = 0
        var high = starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= row { low = mid } else { high = mid - 1 }
        }
        let batch = batches[low]
        guard batch.children.indices.contains(column) else { return nil }
        let value = batch.children[column].value(row - starts[low])
        return value.isNull ? nil : value.description
    }
}
