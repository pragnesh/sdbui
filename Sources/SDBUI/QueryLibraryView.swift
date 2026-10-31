import Foundation
import SwiftCrossUI

struct QueryLibraryBar: View {
    var model: BrowserModel
    @State private var revision = 0

    var body: some View {
        let _ = revision
        let _ = model.watch("query-library-bar", of: {
            [model.librarySection?.rawValue ?? "", model.libraryFeedback]
        }) { revision &+= 1 }
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                ForEach(QueryLibrarySection.allCases, id: \.rawValue) { section in
                    Button(section.rawValue) { model.toggleLibrary(section) }
                        .buttonStyle(model.librarySection == section ? .bordered : .borderless)
                }
                Spacer()
                Text("Ctrl+Enter runs the current statement or selection")
                    .font(.caption).foregroundColor(.gray)
            }
            if !model.libraryFeedback.isEmpty {
                Text(model.libraryFeedback).font(.caption)
            }
        }
    }
}

struct QueryLibraryPanel: View {
    var model: BrowserModel
    var section: QueryLibrarySection
    @State private var revision = 0
    @State private var search = ""
    @State private var selectedHistoryID: UUID?
    @State private var selectedSnippetID: UUID?
    @State private var snippetName = ""

    @State private var history: [QueryHistoryEntry] = []
    @State private var historyOffset = 0
    @State private var historyHasMore = false
    @State private var historyLoading = false
    @State private var historyError = ""
    @State private var historyTask: Task<Void, Never>?
    @State private var historyCancellation: QuerySearchCancellation?

    private func reloadHistory(reset: Bool = true, debounce: Bool = false) {
        historyTask?.cancel()
        historyCancellation?.cancel()
        guard section == .history else { return }
        if reset { historyOffset = 0 }
        selectedHistoryID = nil
        history = []
        historyHasMore = false
        historyLoading = true
        historyError = ""
        let cancellation = QuerySearchCancellation()
        historyCancellation = cancellation
        let query = search
        let offset = historyOffset
        let store = model.queryLibrary
        historyTask = Task { @MainActor in
            if debounce {
                do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
            }
            guard !cancellation.isCancelled else { return }
            let outcome = await Task.detached {
                Result { try store.historyPage(matching: query, offset: offset, cancellation: cancellation) }
            }.value
            guard !cancellation.isCancelled else { return }
            historyLoading = false
            switch outcome {
            case .success(let page):
                history = page.entries
                historyHasMore = page.hasMore
            case .failure(let error): historyError = "Could not search history: \(error)"
            }
        }
    }

    private var snippets: [QuerySnippet] {
        model.queryLibrary.snippets.filter {
            search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)
                || $0.sql.localizedCaseInsensitiveContains(search)
        }
    }
    private var selectedSQL: String? {
        section == .history
            ? history.first(where: { $0.id == selectedHistoryID })?.sql
            : snippets.first(where: { $0.id == selectedSnippetID })?.sql
    }
    private func preview(_ sql: String) -> String {
        String(sql.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").prefix(160))
    }

    var body: some View {
        let _ = revision
        let _ = model.watch("query-library-panel", of: { model.libraryRevision }) {
            revision &+= 1
            reloadHistory()
        }
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(section.rawValue).font(.headline)
                Spacer()
                if section == .history {
                    Button("Clear history") {
                        model.clearQueryHistory()
                        selectedHistoryID = nil
                    }
                    .disabled(model.queryLibrary.historyCount == 0)
                } else {
                    Button("New snippet") {
                        selectedSnippetID = nil
                        snippetName = ""
                    }
                }
            }
            TextField(section == .history ? "Search query history" : "Search snippets", text: Binding(
                get: { search },
                set: { value in
                    guard value != search else { return }
                    search = value
                    reloadHistory(debounce: true)
                }
            ))
            if section == .history {
                if history.isEmpty {
                    Text(historyLoading ? "Searching…" : (!historyError.isEmpty ? historyError : (search.isEmpty ? "Manually executed SQL appears here." : "No matching history.")))
                        .foregroundColor(.gray)
                    Spacer()
                } else {
                    ScrollView {
                        List(history, selection: $selectedHistoryID) { entry in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(preview(entry.sql)).lineLimit(2)
                                Text("\(entry.connection) · \(entry.date.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption).foregroundColor(.gray).lineLimit(1)
                            }
                        }
                    }
                    .frame(maxHeight: .infinity)
                }
            } else {
                if snippets.isEmpty {
                    Text(search.isEmpty ? "Name the SQL in your editor and choose Save snippet." : "No matching snippets.")
                        .foregroundColor(.gray)
                    Spacer()
                } else {
                    ScrollView {
                        List(snippets, selection: Binding(
                            get: { selectedSnippetID },
                            set: { id in
                                guard id != selectedSnippetID else { return }
                                selectedSnippetID = id
                                if let item = snippets.first(where: { $0.id == id }) { snippetName = item.name }
                            }
                        )) { snippet in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(snippet.name).lineLimit(1)
                                Text(preview(snippet.sql)).font(.caption).foregroundColor(.gray).lineLimit(1)
                            }
                        }
                    }
                    .frame(maxHeight: .infinity)
                }
            }
            if let sql = selectedSQL {
                Text(sql).font(.system(size: 11, design: .monospaced)).lineLimit(3)
            }
            if section == .snippets {
                TextField("Snippet name", text: $snippetName)
            }
            HStack(spacing: 6) {
                Button("Load into editor") {
                    if let sql = selectedSQL { model.loadLibrarySQL(sql) }
                }
                .disabled(selectedSQL == nil)
                .fixedSize()
                if section == .snippets {
                    Button(selectedSnippetID == nil ? "Save snippet" : "Update from editor") {
                        if let id = model.saveQuerySnippet(id: selectedSnippetID, name: snippetName) {
                            selectedSnippetID = id
                        }
                    }
                    .fixedSize()
                }
                Spacer()
                Button("Delete") {
                    if section == .history, let id = selectedHistoryID {
                        model.deleteHistoryEntry(id)
                        selectedHistoryID = nil
                    } else if let id = selectedSnippetID {
                        model.deleteQuerySnippet(id)
                        selectedSnippetID = nil
                        snippetName = ""
                    }
                }
                .disabled(selectedSQL == nil)
                .fixedSize()
            }
            if section == .history {
                HStack(spacing: 6) {
                    Button("Previous") {
                        historyOffset = max(0, historyOffset - QueryLibraryStore.historyPageSize)
                        reloadHistory(reset: false)
                    }
                    .disabled(historyLoading || historyOffset == 0)
                    Text(history.isEmpty ? "0 shown" : "\(historyOffset + 1)–\(historyOffset + history.count)")
                        .font(.caption)
                    Spacer()
                    Button("Next") {
                        historyOffset += QueryLibraryStore.historyPageSize
                        reloadHistory(reset: false)
                    }
                    .disabled(historyLoading || !historyHasMore)
                }
            }
            Text(section == .history ? "Up to 1,000,000 queries · \(model.queryLibrary.historyCount.formatted()) stored" : "Save and update use the SQL currently in the editor.")
                .font(.caption).foregroundColor(.gray)
        }
        .onAppear { reloadHistory() }
        .onChange(of: section) { reloadHistory() }
        .onDisappear {
            historyTask?.cancel()
            historyCancellation?.cancel()
        }
    }
}
