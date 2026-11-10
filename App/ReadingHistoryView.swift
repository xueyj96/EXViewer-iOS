import SwiftUI
import ExViewerCore

struct ReadingHistoryView: View {
    var libraryScope: Binding<Int>? = nil
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.defaultMinListRowHeight) private var defaultListRowHeight
    @State private var order: LibrarySortOrder = .recent
    @StateObject private var batchSelection = LibrarySelectionStore()
    @State private var selecting = false
    private var preferences: LibrarySortPreferences {
        .init(owner: library.owner, defaults: AppMode.qa ? UserDefaults(suiteName: LibrarySortPreferences.qaSuite)! : .standard)
    }
    private var records: [ReadingRecord] {
        let blocked = library.blockedIDs
        return LibrarySorting.history(library.snapshot.history.filter {
            TagFilter.decision(tags: $0.gallery.tags, blocked: blocked, complete: $0.gallery.tagsComplete) == .visible
        }, order: order)
    }
    var body: some View {
        FloatingFeedLayout { headerHeight in
            historyList(topInset: headerHeight)
        } header: {
            if let libraryScope {
                LibraryFloatingHeader(selection: libraryScope, identifier: "reading-history.header.floating") { historyControls }
            } else {
                FloatingHeaderPanel(identifier: "reading-history.header.floating") {
                    Group {
                        if selecting {
                            LibraryBatchSelectionHeader(source: .history, store: batchSelection, summary: batchSelection.summary,
                                                        compact: true, onExit: endSelection)
                        } else {
                            FloatingPageTitleRow(title: "阅读历史", identifier: "reading-history.title") {
                                Button { dismiss() } label: { Image(systemName: "chevron.left") }
                                    .buttonStyle(FeedHeaderButtonStyle())
                                    .accessibilityLabel("返回")
                                    .accessibilityIdentifier("reading-history.close")
                            } trailing: {
                                sortMenu
                            }
                        }
                    }
                    .environment(\.feedHeaderRow, .single)
                }
            }
        }
        .appNavigationChrome(backButton: libraryScope == nil, showsToolbarBackButton: false)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if selecting {
                LibraryBatchToolbar(source: .history, summary: batchSelection.summary, galleries: {
                    records.filter { batchSelection.selectedIDs.contains($0.id) }.map(\.gallery)
                })
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { order = preferences.order(for: .history) }
        .onChange(of: library.owner) { _, _ in order = preferences.order(for: .history); endSelection() }
        .onChange(of: records.map(\.id)) { _, ids in
            if selecting { batchSelection.updateLoadedIDs(Set(ids)) }
        }
    }

    @ViewBuilder
    private var historyControls: some View {
        if selecting {
            LibraryBatchSelectionHeader(source: .history, store: batchSelection, summary: batchSelection.summary, onExit: endSelection)
        } else if typeSize.isAccessibilitySize {
            LibraryHeaderActions { countLabel } trailing: { sortMenu }
        } else {
            FeedHeaderGrid(spans: [3, 1]) {
                countLabel
                sortMenu
            }
        }
    }

    private func historyList(topInset: CGFloat) -> some View {
        let entries = records
        return List {
            if let error = library.error { Text(error).font(.subheadline).foregroundStyle(.secondary) }
            if libraryScope == nil && !entries.isEmpty {
                let summary = historySummary(entries)
                HStack {
                    Text(summary.count)
                    Spacer(minLength: FeedChrome.panelSpacing)
                    if let latest = summary.latest { Text(latest).multilineTextAlignment(.trailing) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, FeedChrome.contentSpacing)
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("reading-history.summary")
            }
            if entries.isEmpty {
                ContentUnavailableView("暂无阅读记录", systemImage: "clock", description: Text(library.snapshot.history.isEmpty
                    ? "开始阅读后，作品与阅读进度会保存在这里。"
                    : "记录暂时被屏蔽标签隐藏，可在标签设置中调整。"))
                    .listRowSeparator(.hidden)
            }
            ForEach(entries) { record in
                GallerySelectionLink(gallery: record.gallery, store: batchSelection,
                                     entry: batchSelection.entry(for: record.id), isSelecting: selecting,
                                     openIdentifier: "reading-history.item.\(record.gallery.ref.gid)",
                                     selectionIdentifier: "reading-history.select.\(record.gallery.ref.gid)",
                                     selectionLabel: { record.gallery.title }, onLongPressSelect: { beginSelection(record.id) }) {
                    ReadingHistoryRowLabel(record: record, selected: $0, isFirst: record.id == entries.first?.id)
                }
                .listRowInsets(EdgeInsets())
            }
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, libraryScope == nil ? 0 : defaultListRowHeight)
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

    private var countLabel: some View {
        let summary = historySummary(records)
        return LibraryHeaderCount(title: summary.count, symbol: "clock",
                                  fillsWidth: !typeSize.isAccessibilitySize, detail: summary.latest)
            .accessibilityIdentifier("reading-history.count")
    }

    private func historySummary(_ entries: [ReadingRecord]) -> (count: String, latest: String?) {
        let latest = entries.lazy.map(\.date).max().map {
            "最近阅读 \($0.formatted(.dateTime.month().day().hour().minute()))"
        }
        return ("\(entries.count) 条阅读记录", latest)
    }

    private var sortMenu: some View {
        Menu {
            ForEach(LibrarySortSection.history.options) { option in
                Button { preferences.set(option, for: .history); order = option } label: {
                    if order == option { Label(option.title, systemImage: "checkmark") } else { Text(option.title) }
                }
            }
        } label: {
            if libraryScope == nil {
                Image(systemName: "arrow.up.arrow.down")
            } else {
                LibrarySortControlLabel(title: order.title)
            }
        }
        .buttonStyle(FeedHeaderButtonStyle(truncatesLabel: true, expandsHorizontally: libraryScope != nil && !typeSize.isAccessibilitySize))
        .accessibilityLabel("阅读历史排序").accessibilityValue(order.title).accessibilityIdentifier("reading-history.sort")
    }
}

private struct ReadingHistoryRowLabel: View {
    let record: ReadingRecord
    let selected: Bool?
    let isFirst: Bool
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
        layout {
            GalleryRow(gallery: record.gallery, horizontalInset: 0,
                       topInset: isFirst ? 0 : FeedChrome.contentSpacing,
                       bottomInset: FeedChrome.contentSpacing)
            Text("第 \(record.page) 页")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, typeSize.isAccessibilitySize ? 0 : 8)
                .padding(.bottom, typeSize.isAccessibilitySize ? FeedChrome.contentSpacing : 0)
        }
        .background(selected == true ? Color.accentColor.opacity(0.10) : .clear, in: AppShape.control)
        .overlay(alignment: .topLeading) {
            if let selected {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .frame(width: 26, height: 26)
                    .background(FloatingChrome.background, in: Circle())
                    .padding(5)
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
    }
}
