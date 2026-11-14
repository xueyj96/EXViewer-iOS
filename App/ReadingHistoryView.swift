import SwiftUI
import ExViewerCore
import Observation

enum ReadingHistoryPeriod: String, CaseIterable {
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
    var onClose: (() -> Void)? = nil
    @EnvironmentObject private var library: LibraryStore

    var body: some View {
        let key: HistoryBrowseStore.Entrance = switch placement {
        case .library: .library
        case .discovery: .discovery
        }
        ReadingHistoryContent(placement: placement, onClose: onClose,
                              state: library.historyBrowsing.state(owner: library.owner, entrance: key,
                                order: LibrarySortPreferences(owner: library.owner,
                                    defaults: AppMode.qa ? UserDefaults(suiteName: LibrarySortPreferences.qaSuite)! : .standard).order(for: .history)))
            .id(library.owner)
    }
}

@Observable @MainActor final class HistoryBrowseState {
    var order: LibrarySortOrder
    var period: ReadingHistoryPeriod = .all
    var query = ""
    let viewport = FeedViewportMemory()
    init(order: LibrarySortOrder) { self.order = order }
    func records(in snapshot: LibrarySnapshot, now: Date = .now) -> [ReadingRecord] {
        let blocked = Set(snapshot.blockedTags.map(\.id))
        let start = period.startDate(now: now, calendar: .autoupdatingCurrent)
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return LibrarySorting.history(snapshot.history.filter { record in
            (term.isEmpty || record.gallery.title.localizedStandardContains(term)) &&
                (start.map { record.date >= $0 } ?? true) &&
                TagFilter.decision(tags: record.gallery.tags, blocked: blocked, complete: record.gallery.tagsComplete) == .visible
        }, order: order)
    }
}

@MainActor final class HistoryBrowseStore {
    enum Entrance: Hashable { case discovery, library }
    private var owner: String?
    private var states: [Entrance: HistoryBrowseState] = [:]
    func historyWillChange(owner: String, before: LibrarySnapshot, after: LibrarySnapshot) {
        guard self.owner == owner else { return }
        let now = Date.now
        for state in states.values {
            let beforeIDs = state.records(in: before, now: now).map(\.id)
            let afterIDs = state.records(in: after, now: now).map(\.id)
            guard beforeIDs != afterIDs else { continue }
            state.viewport.reconcile(beforeIDs)
            state.viewport.invalidateLayout()
            state.viewport.reconcile(afterIDs)
        }
    }
    func state(owner: String, entrance: Entrance, order: LibrarySortOrder) -> HistoryBrowseState {
        if self.owner != owner { self.owner = owner; states.removeAll() }
        if let state = states[entrance] { return state }
        let state = HistoryBrowseState(order: order); states[entrance] = state
        return state
    }
}

private struct ReadingHistoryContent: View {
    let placement: ReadingHistoryView.Placement
    var onClose: (() -> Void)? = nil
    @Bindable var state: HistoryBrowseState
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dynamicTypeSize) private var typeSize
    @FocusState private var searchFocused: Bool
    @StateObject private var batchSelection = LibrarySelectionStore()
    @State private var selecting = false
    private var preferences: LibrarySortPreferences {
        .init(owner: library.owner, defaults: AppMode.qa ? UserDefaults(suiteName: LibrarySortPreferences.qaSuite)! : .standard)
    }
    private var records: [ReadingRecord] {
        state.records(in: library.snapshot)
    }
    var body: some View {
        FloatingFeedLayout(twoRows: true, retainsViewport: !state.viewport.isAtTop) { headerHeight in
            historyList(topInset: headerHeight)
        } header: {
            switch placement {
            case .library(let scope):
                LibraryFloatingHeader(selection: scope, identifier: "reading-history.header.floating", isSelecting: selecting) { historyControls }
            case .discovery(let tabs):
                FloatingTwoRowHeader(identifier: "discover.header.floating", transitionID: "discover",
                                     primaryLayout: "lanes", secondaryLayout: selecting ? "history-selection" : "history") {
                    HStack(spacing: FeedChrome.panelSpacing) {
                        if let onClose {
                            Button(action: onClose) { Image(systemName: "chevron.left") }
                                .buttonStyle(FeedHeaderButtonStyle())
                                .environment(\.pageHeaderAction, true)
                                .frame(width: FeedChrome.pageActionWidth)
                                .accessibilityLabel("返回").accessibilityIdentifier("search.results.close")
                        }
                        tabs
                    }
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
        .exitMultiSelectionOnRightSwipe(selecting, action: endSelection)
        .headerSectionWillChange { endSelection() }
        .headerSectionGestureLocked(searchFocused)
        .toolbar(.hidden, for: .navigationBar)
        .onChange(of: state.query) { _, _ in state.viewport.reset() }
        .onChange(of: state.period) { _, _ in state.viewport.reset() }
        .onChange(of: state.order) { _, _ in state.viewport.reset() }
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
            TextField("作品名", text: $state.query)
                .focused($searchFocused)
                .submitLabel(.search)
                .onSubmit { searchFocused = false }
                .accessibilityIdentifier("reading-history.search-field")
            if !state.query.isEmpty {
                Button { state.query = "" } label: {
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

    private func historyList(topInset: CGFloat) -> some View {
        let entries = records
        return RememberedFeedScroll(memory: state.viewport, revision: state.viewport.revision,
                                    ids: entries.map(\.id), topInset: topInset,
                                    identifier: "reading-history") {
            LazyVStack(alignment: .leading, spacing: FeedChrome.contentSpacing) {
                LibraryCardRows(items: entries, cover: { LibraryCardCover(gallery: $0.gallery) }) { record in
                    GallerySelectionLink(gallery: record.gallery, store: batchSelection,
                                         entry: batchSelection.entry(for: record.id), isSelecting: selecting,
                                         openIdentifier: "reading-history.item.\(record.gallery.ref.gid)",
                                         selectionIdentifier: "reading-history.select.\(record.gallery.ref.gid)",
                                         selectionLabel: { record.gallery.title }, onLongPressSelect: { beginSelection(record.id) }) { selected in
                        ReadingHistoryCard(record: record, selected: selected)
                            .frame(height: LibraryCardMetrics.height)
                    }
                    .id(record.id)
                }
            }
        }
        .id(state.viewport.revision)
        .overlay {
            if library.error == nil && entries.isEmpty {
                GalleryEmptyState().accessibilityIdentifier("reading-history.empty").padding(.top, topInset)
            }
        }
        .appToast(message: library.error, identifier: "reading-history.error")
        .padding(.horizontal, FeedChrome.contentInset)
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
        LibraryFilterMenu(selection: $state.period, options: ReadingHistoryPeriod.allCases, title: \.title,
                          label: "阅读时间筛选", identifier: "reading-history.period", symbol: "calendar")
    }

    private var sortMenu: some View {
        AppMenu {
            ForEach(LibrarySortSection.history.options) { option in
                AppMenuItem(title: option.title, isSelected: state.order == option) {
                    preferences.set(option, for: .history); state.order = option
                }
            }
        } label: {
            LibrarySortControlLabel(title: state.order.title)
        }
        .buttonStyle(FeedHeaderButtonStyle(truncatesLabel: true, expandsHorizontally: !typeSize.isAccessibilitySize))
        .accessibilityLabel("阅读历史排序").accessibilityValue(state.order.title).accessibilityIdentifier("reading-history.sort")
    }
}

struct ReadingHistoryCard: View {
    let record: ReadingRecord
    var selected: Bool? = nil
    var body: some View {
        let lastRead = record.date.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour().minute())
        LibraryGalleryCard(gallery: record.gallery, context: "读到第 \(record.page) 页 · \(lastRead)", selected: selected) {
            CoverView(gallery: record.gallery, contentMode: .fill, fitsExtremeAspects: true)
        }
    }
}
