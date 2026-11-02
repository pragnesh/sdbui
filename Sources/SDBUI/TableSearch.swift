import ADBCKit
import Foundation

/// Rank names within the selected namespace without building a view per table.
enum TableSearch {
    static func results(_ tables: [TableInfo], namespace: String, query: String) -> [TableInfo] {
        let terms = folded(query).split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let candidates = tables.filter { $0.namespace == namespace }
        guard !terms.isEmpty else { return candidates }
        return candidates.enumerated().compactMap { index, table -> (Int, Int, TableInfo)? in
            let name = folded(table.name)
            var total = 0
            for term in terms {
                guard let score = score(name, term) else { return nil }
                total += score
            }
            return (total, index, table)
        }.sorted { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }.map { $0.2 }
    }

    private static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func score(_ name: String, _ term: String) -> Int? {
        if name == term { return 0 }
        if name.hasPrefix(term) { return 100 + min(name.count, 99) }
        if let range = name.range(of: term) { return 500 + min(name.distance(from: name.startIndex, to: range.lowerBound), 99) }
        let needle = Array(term)
        var matched = 0, first = 0, last = 0, boundaries = 0
        var previous: Character?
        for (index, character) in name.enumerated() {
            if character == needle[matched] {
                if matched == 0 { first = index }
                if previous == nil || previous == "_" || previous == "-" || previous == " " { boundaries += 1 }
                last = index
                matched += 1
                if matched == needle.count {
                    return 1000 + min(500, (last - first + 1 - needle.count) * 5 + first) - min(100, boundaries * 3)
                }
            }
            previous = character
        }
        return nil
    }
}
