import SwiftUI
import SwiftData

/// The one explicit search screen across the whole archive, by place and activity.
/// Ordinary Timeline fetches never touch `note`, so a broad note search only ever
/// happens here, and only once the person opts into it — see
/// `VisitHistoryQuery.search` for why that split exists.
struct ArchiveSearchView: View {
    @Environment(\.modelContext) private var context
    @State private var query = ""
    @State private var includeNotes = false
    @State private var results: [ArchiveSearchEntry] = []
    @State private var hasMore = false
    @State private var loadingFirstPage = false
    @State private var loadingNextPage = false
    @State private var reader: VisitArchiveReader?
    @State private var searchTask: Task<Void, Never>?

    static let pageSize = 100

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        List {
            if !trimmedQuery.isEmpty {
                Section {
                    Toggle("Search notes too (slower)", isOn: $includeNotes)
                        .accessibilityIdentifier("archive-search-include-notes")
                } footer: {
                    Text("Notes are free text with nothing to narrow the search on, so this scans every entry's note rather than a short label.")
                }
            }
            if trimmedQuery.isEmpty {
                ContentUnavailableView("Search your archive", systemImage: "magnifyingglass",
                                       description: Text("Find a visit by place or activity. Notes are an optional, slower search."))
            } else if results.isEmpty && !loadingFirstPage {
                ContentUnavailableView.search(text: query)
            } else {
                Section {
                    ForEach(results) { entry in
                        NavigationLink(value: entry.stableID) {
                            resultRow(entry)
                        }
                    }
                    if hasMore {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                        .accessibilityIdentifier("archive-search-loading-more")
                        .onAppear { loadNextPage() }
                    }
                }
            }
        }
        .navigationTitle("Search")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Search places and activities")
        .navigationDestination(for: UUID.self) { ArchiveSearchResultDestination(stableID: $0) }
        .onChange(of: query) { _, _ in restartSearch() }
        .onChange(of: includeNotes) { _, _ in restartSearch() }
        .accessibilityIdentifier("archive-search-screen")
    }

    private func resultRow(_ entry: ArchiveSearchEntry) -> some View {
        VisitRowLabel(title: entry.placeName,
                     subtitle: "\(entry.activity) · \(entry.arrival.formatted(date: .abbreviated, time: .shortened))")
    }

    /// Debounced so a fast typist does not fire one query per keystroke; the
    /// previous in-flight search is cancelled outright rather than left to
    /// finish and race the newer one for `results`.
    private func restartSearch() {
        searchTask?.cancel()
        guard !trimmedQuery.isEmpty else {
            results = []
            hasMore = false
            loadingFirstPage = false
            return
        }
        loadingFirstPage = true
        let text = trimmedQuery
        let notes = includeNotes
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await runSearch(text: text, includeNotes: notes, offset: 0)
        }
    }

    private func loadNextPage() {
        guard !loadingNextPage, hasMore, !trimmedQuery.isEmpty else { return }
        loadingNextPage = true
        let text = trimmedQuery
        let notes = includeNotes
        let offset = results.count
        Task { await runSearch(text: text, includeNotes: notes, offset: offset) }
    }

    private func runSearch(text: String, includeNotes: Bool, offset: Int) async {
        let startedAt = Date.now
        let reader = reader ?? VisitArchiveReader(modelContainer: context.container)
        self.reader = reader
        do {
            let page = try await reader.search(text, includeNotes: includeNotes,
                                               limit: Self.pageSize, offset: offset)
            guard !Task.isCancelled, text == trimmedQuery else { return }
            if offset == 0 {
                results = page.entries
            } else {
                results.append(contentsOf: page.entries)
            }
            hasMore = page.hasMore
            loadingFirstPage = false
            loadingNextPage = false
            Diagnostics.budget(context, subsystem: "Archive Search", operation: "search page",
                               startedAt: startedAt, budget: Diagnostics.PerformanceBudget.archiveSearch,
                               itemCount: page.entries.count)
        } catch is CancellationError {
            return
        } catch {
            loadingFirstPage = false
            loadingNextPage = false
        }
    }
}

/// Search results are `Sendable` snapshots from a background actor, not the real
/// `@Model` instance the editor needs — this resolves the one row by its durable
/// `stableID` once the person actually taps a result, rather than fetching the
/// whole archive as `@Model` objects just to make results tappable.
private struct ArchiveSearchResultDestination: View {
    let stableID: UUID
    @Environment(\.modelContext) private var context
    @State private var visit: Visit?
    @State private var notFound = false

    var body: some View {
        Group {
            if let visit {
                VisitEditor(visit: visit)
            } else if notFound {
                ContentUnavailableView("Visit not found", systemImage: "questionmark.circle",
                                       description: Text("This entry may have been removed or merged."))
            } else {
                ProgressView()
            }
        }
        .task { load() }
    }

    private func load() {
        var descriptor = FetchDescriptor<Visit>(predicate: #Predicate { $0.stableID == stableID })
        descriptor.fetchLimit = 1
        visit = try? context.fetch(descriptor).first
        notFound = visit == nil
    }
}
