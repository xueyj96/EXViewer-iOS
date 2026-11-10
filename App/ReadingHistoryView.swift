import SwiftUI
import ExViewerCore

private enum ReadingHistoryPeriod: String, CaseIterable {
    case all, today, week, month

    var title: String {
        switch self {
        case .all: "全部时间"
        case .today: "今天"
        case .week: "最近 7 天"
        case .month: "最近 30 天"
        }
    }

    func startDate(now: Date, calendar: Calendar) -> Date? {
        let today = calendar.startOfDay(for: now)
        switch self {
        case .all: return nil
        case .today: return today
        case .week: return calendar.date(byAdding: .day, value: -6, to: today)
        case .month: return calendar.date(byAdding: .day, value: -29, to: today)
        }
    }
}

struct ReadingHistoryView: View {
    enum Placement {
        case library(Binding<Int>)
        case discovery(tabs: FeedScopePicker)
    }

    let placement: Placement
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var order: LibrarySortOrder = .recent
    @State private var period: ReadingHistoryPeriod = .all
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @StateObject private var batchSelection = LibrarySelectionStore()
    @State private var selecting = false
    private var preferences: LibrarySortPreferences {
        .init(owner: library.owner, defaults: AppMode.qa ? UserDefaults(suiteName: LibrarySortPreferences.qaSuite)! : .standard)
    }
    private var searchTerm: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var records: [ReadingRecord] {
        let blocked = library.blockedIDs
        let start = period.startDate(now: .now, calendar: .autoupdatingCurrent)
        let term = searchTerm
        return LibrarySorting.history(library.snapshot.history.filter { record in
            (term.isEmpty || record.gallery.title.localizedStandardContains(term)) &&
                (start.map { record.date >= $0 } ?? true) &&
                TagFilter.decision(tags: record.gallery.tags, blocked: blocked, complete: record.gallery.tagsComplete) == .visible
        }, order: order)
    }
    var body: some View {
        FloatingFeedLayout { headerHeight in
            historyList(topInset: headerHeight)
        } header: {
            switch placement {
            case .library(let scope):
                LibraryFloatingHeader(selection: scope, identifier: "reading-history.header.floating", isSelecting: selecting) { historyControls }
            case .discovery(let tabs):
                FloatingTwoRowHeader(identifier: "discover.header.floating", transitionID: "discover",
                                     primaryLayout: "lanes", secondaryLayout: selecting ? "history-selection" : "history") {
                    tabs
                } secondary: {
                    historyControls
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if selecting {
                LibraryBatchToolbar(source: .history, summary: batchSelection.summary, galleries: {
                    records.filter { batchSelection.selectedIDs.contains($0.id) }.map(\.gallery)
                })
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { order = preferences.order(for: .history) }
        .onChange(of: library.owner) { _, _ in
            order = preferences.order(for: .history)
            period = .all
            query = ""
            searchFocused = false
            endSelection()
        }
        .onChange(of: records.map(\.id)) { _, ids in
            if selecting { batchSelection.updateLoadedIDs(Set(ids)) }
        }
    }

    @ViewBuilder
    private var historyControls: some View {
        if selecting {
            LibraryBatchSelectionHeader(source: .history, store: batchSelection, summary: batchSelection.summary, onExit: endSelection)
        } else {
            browsingControls
        }
    }

    @ViewBuilder
    private var browsingControls: some View {
        if typeSize.isAccessibilitySize {
            AccessibilityHeaderActions { searchField } trailing: {
                HStack(spacing: FeedChrome.panelSpacing) { periodMenu; sortMenu }
            }
        } else {
            FeedHeaderGrid(spans: [2, 1, 1]) {
                searchField
                periodMenu
                sortMenu
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: FeedChrome.controlSpacing) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("作品名", text: $query)
                .focused($searchFocused)
                .submitLabel(.search)
                .onSubmit { searchFocused = false }
                .accessibilityIdentifier("reading-history.search-field")
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清空作品名")
                .accessibilityIdentifier("reading-history.clear-search")
            }
        }
        .feedHeaderControl(typeSize: typeSize, expandsHorizontally: true)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reading-history.search")
    }

    private var emptyTitle: String {
        if !searchTerm.isEmpty { return "没有匹配的阅读记录" }
        if period != .all { return "这段时间暂无阅读记录" }
        return library.snapshot.history.isEmpty ? "暂无阅读记录" : "阅读记录已被屏蔽"
    }

    private func historyList(topInset: CGFloat) -> some View {
        let entries = records
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: FeedChrome.contentSpacing) {
                if let error = library.error { Text(error).font(.subheadline).foregroundStyle(.secondary) }
                if entries.isEmpty {
                    ContentUnavailableView(emptyTitle, systemImage: "clock")
                }
                LibraryCardRows(items: entries, cover: { LibraryCardCover(gallery: $0.gallery) }) { record in
                    GallerySelectionLink(gallery: record.gallery, store: batchSelection,
                                         entry: batchSelection.entry(for: record.id), isSelecting: selecting,
                                         openIdentifier: "reading-history.item.\(record.gallery.ref.gid)",
                                         selectionIdentifier: "reading-history.select.\(record.gallery.ref.gid)",
                                         selectionLabel: { record.gallery.title }, onLongPressSelect: { beginSelection(record.id) }) { selected in
                        let lastRead = record.date.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour().minute())
                        LibraryGalleryCard(gallery: record.gallery, context: "读到第 \(record.page) 页 · \(lastRead)", selected: selected) {
                            CoverView(gallery: record.gallery, contentMode: .fill, fitsExtremeAspects: true)
                        }
                    }
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .contentMargins(.top, topInset + FeedChrome.contentTopGap, for: .scrollContent)
        .padding(.horizontal, FeedChrome.contentInset)
        .accessibilityIdentifier("reading-history")
    }

    private func beginSelection(_ id: String) {
        batchSelection.updateLoadedIDs(Set(records.map(\.id)))
        selecting = batchSelection.beginSelecting(id)
    }

    private func endSelection() {
        selecting = false
        batchSelection.clear()
    }

    private var periodMenu: some View {
        LibraryFilterMenu(selection: $period, options: ReadingHistoryPeriod.allCases, title: \.title,
                          label: "阅读时间筛选", identifier: "reading-history.period", symbol: "calendar")
    }

    private var sortMenu: some View {
        Menu {
            ForEach(LibrarySortSection.history.options) { option in
                Button { preferences.set(option, for: .history); order = option } label: {
                    if order == option { Label(option.title, systemImage: "checkmark") } else { Text(option.title) }
                }
            }
        } label: {
            LibrarySortControlLabel(title: order.title)
        }
        .buttonStyle(FeedHeaderButtonStyle(truncatesLabel: true, expandsHorizontally: !typeSize.isAccessibilitySize))
        .accessibilityLabel("阅读历史排序").accessibilityValue(order.title).accessibilityIdentifier("reading-history.sort")
    }
}
