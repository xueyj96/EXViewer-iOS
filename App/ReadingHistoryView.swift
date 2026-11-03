import SwiftUI
import ExViewerCore

struct ReadingHistoryView: View {
    var libraryScope: Binding<Int>? = nil
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var order: LibrarySortOrder = .recent
    private var preferences: LibrarySortPreferences {
        .init(owner: library.owner, defaults: AppMode.qa ? UserDefaults(suiteName: LibrarySortPreferences.qaSuite)! : .standard)
    }
    private var records: [ReadingRecord] {
        LibrarySorting.history(library.snapshot.history.filter {
            TagFilter.decision(tags: $0.gallery.tags, blocked: library.blockedIDs, complete: $0.gallery.tagsComplete) == .visible
        }, order: order)
    }
    var body: some View {
        FloatingFeedLayout { headerHeight in
            historyList(topInset: headerHeight)
        } header: {
            if let libraryScope {
                LibraryFloatingHeader(selection: libraryScope) { historyControls }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("reading-history.header.floating")
            } else {
                FloatingHeaderPanel { historyControls }
            }
        }
        .navigationTitle("阅读历史").navigationBarTitleDisplayMode(.inline).appNavigationChrome()
        .toolbar(libraryScope == nil ? .visible : .hidden, for: .navigationBar)
        .toolbar {
            if libraryScope == nil { AppToolbarItem(placement: .cancellationAction) {
                Button("完成") { dismiss() }.accessibilityIdentifier("reading-history.close")
            } }
        }
        .onAppear { order = preferences.order(for: .history) }
        .onChange(of: library.owner) { _, _ in order = preferences.order(for: .history) }
    }

    private var historyControls: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 0) { countLabel; sortMenu }
            } else {
                HStack(spacing: 12) { countLabel; Spacer(minLength: 8); sortMenu }
            }
        }
    }

    private func historyList(topInset: CGFloat) -> some View {
        List {
            if let error = library.error { Text(error).font(.subheadline).foregroundStyle(.secondary) }
            if records.isEmpty {
                ContentUnavailableView("暂无阅读记录", systemImage: "clock", description: Text(library.snapshot.history.isEmpty
                    ? "开始阅读后，作品与阅读进度会保存在这里。"
                    : "记录暂时被屏蔽标签隐藏，可在标签设置中调整。"))
                    .listRowSeparator(.hidden)
            }
            ForEach(records) { record in
                NavigationLink(value: record.gallery) {
                    if typeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: 0) {
                            GalleryRow(gallery: record.gallery)
                            Text("第 \(record.page) 页").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.bottom, 12)
                        }
                    } else {
                        HStack(spacing: 0) {
                            GalleryRow(gallery: record.gallery)
                            Text("第 \(record.page) 页").font(.caption).foregroundStyle(.secondary).padding(.trailing, 18)
                        }
                    }
                }.buttonStyle(.plain).accessibilityIdentifier("reading-history.item.\(record.gallery.ref.gid)")
                    .listRowInsets(EdgeInsets())
                    .contextMenu {
                        NavigationLink(value: record.gallery) { Label("打开详情", systemImage: "book.closed") }
                        Button { library.toggleReadLater(record.gallery) } label: {
                            Label(library.containsReadLater(record.gallery) ? "移出稍后再读" : "加入稍后再读", systemImage: "text.badge.plus")
                        }
                    }
            }
        }
        .listStyle(.plain)
        .contentMargins(.top, topInset, for: .scrollContent)
        .accessibilityIdentifier("reading-history")
    }

    private var countLabel: some View {
        LibraryHeaderCount(title: "\(records.count) 条记录", symbol: "clock")
            .accessibilityIdentifier("reading-history.count")
    }

    private var sortMenu: some View {
        Menu {
            ForEach(LibrarySortSection.history.options) { option in
                Button { preferences.set(option, for: .history); order = option } label: {
                    if order == option { Label(option.title, systemImage: "checkmark") } else { Text(option.title) }
                }
            }
        } label: {
            LibrarySortMenuLabel(title: order.title)
        }
        .buttonStyle(FeedHeaderButtonStyle())
        .accessibilityLabel("阅读历史排序").accessibilityValue(order.title).accessibilityIdentifier("reading-history.sort")
    }
}
