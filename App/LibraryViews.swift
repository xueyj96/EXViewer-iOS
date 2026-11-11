import SwiftUI
import ExViewerCore

enum LibrarySelectionPolicy {
    static func filtered(_ galleries: [Gallery], blocked: Set<String>) -> (visible: [Gallery], unknown: Int) {
        var visible: [Gallery] = []; var unknown = 0
        for gallery in galleries {
            switch TagFilter.decision(tags: gallery.tags, blocked: blocked, complete: gallery.tagsComplete) {
            case .visible: visible.append(gallery)
            case .unknown: unknown += 1
            case .blocked: break
            }
        }
        return (visible, unknown)
    }

    static func toggled(_ id: String, in current: Set<String>) -> Set<String> {
        var next = current
        if !next.insert(id).inserted { next.remove(id) }
        return next
    }

    static func selectAllOrClear(_ ids: [String], current: Set<String>) -> Set<String> {
        let target = Set(ids)
        return target.isSubset(of: current) ? current.subtracting(target) : current.union(target)
    }

    static func allSelected(_ ids: [String], current: Set<String>) -> Bool {
        Set(ids).isSubset(of: current)
    }
}

struct TagsView: View {
    var use: (GalleryTag) -> Void
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var scope = 0
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @State private var adding = false
    @State private var undone: GalleryTag?
    private var tags: [GalleryTag] { (scope == 0 ? library.snapshot.favoriteTags : library.snapshot.blockedTags).filter { query.isEmpty || $0.label.localizedCaseInsensitiveContains(query) } }
    var body: some View {
        List {
            HStack(spacing: FeedChrome.contentSpacing) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("搜索标签原名", text: $query,
                          prompt: Text("搜索标签原名").foregroundStyle(Palette.inputPrompt))
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                    .focused($searchFocused)
                    .accessibilityIdentifier("tags.search")
            }
            .accountPageCard(compactRows: true)
            .contentShape(Rectangle())
            .onTapGesture { searchFocused = true }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("tags.search-card")

            CompactFormSegmentPicker(selection: $scope, options: [0, 1],
                                     title: { $0 == 0 ? "常用标签" : "屏蔽标签" },
                                     accessibilityLabel: "标签范围", identifier: "tags.scope")
                .accountPageListRow()

            if let undone {
                HStack {
                    Text("已屏蔽 \(undone.name)").font(.caption)
                    Spacer()
                    Button("撤销") { library.unblock(undone); self.undone = nil }
                }
                .accountPageCard()
            }

            ForEach(tags) { tag in
                TagListRowLabel(tag: tag, symbol: scope == 0 ? "arrow.up.left" : "eye.slash",
                                allowsMultiline: true)
                    .padding(.vertical, FeedChrome.panelSpacing)
                    .frame(minHeight: FeedChrome.compactFormRowHeight)
                    .accountPageCard(compactRows: true)
                .contentShape(Rectangle())
                .onTapGesture { if scope == 0 { use(tag) } }
                .contextMenu {
                    Button("用于组合搜索") { use(tag) }
                    if scope == 0 {
                        Button("屏蔽标签") { library.block(tag); undone = tag }
                        Button("取消常用") { library.unpin(tag) }
                    } else {
                        Button("解除屏蔽") { library.unblock(tag) }
                        Button("加入常用") { library.pin(tag) }
                    }
                }
                .swipeActions {
                    if scope == 0 {
                        Button("取消常用", role: .destructive) { library.unpin(tag) }
                    } else {
                        Button("解除屏蔽") { library.unblock(tag) }.tint(Palette.accent)
                    }
                }
            }
            if tags.isEmpty {
                Text(scope == 0 ? "在画廊详情长按标签，可加入常用。" : "屏蔽按命名空间和标签原名精确匹配。")
                    .foregroundStyle(.secondary)
                    .accountPageCard()
            }
        }
            .scrollDismissesKeyboard(.interactively)
            .accountSubpageHeader("标签与屏蔽", identifier: "account.tags-page") {
                Button { adding = true } label: { Image(systemName: "plus") }
                    .buttonStyle(FeedHeaderButtonStyle())
                    .accessibilityLabel("添加标签").accessibilityIdentifier("tags.add")
            }
            .navigationDestination(isPresented: $adding) {
                TagEntryView { tag, _ in
                    if scope == 0 { library.pin(tag) }
                    else { library.block(tag); undone = tag }
                }
                .dynamicTypeSize(typeSize)
            }
    }
}

private enum DownloadFilter: String, CaseIterable {
    case all, active, needsAttention, complete

    var title: String {
        switch self {
        case .all: "全部下载"
        case .active: "进行中"
        case .needsAttention: "暂停或失败"
        case .complete: "已下载"
        }
    }

    func includes(_ status: DownloadRecord.Status) -> Bool {
        switch self {
        case .all: true
        case .active: status == .waiting || status == .downloading
        case .needsAttention: status == .paused || status == .failed
        case .complete: status == .complete
        }
    }
}

private enum ReadLaterFilter: String, CaseIterable {
    case all, unread, started

    var title: String {
        switch self {
        case .all: "全部作品"
        case .unread: "尚未阅读"
        case .started: "有阅读记录"
        }
    }
}

struct LibraryView: View {
    @Environment(\.galleryDetailPresentation) private var presentation
    @Binding var site: GallerySite
    var isActive = true
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var downloads: DownloadManager
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var scope = 0
    @State private var downloadFilter: DownloadFilter = .all
    @State private var readLaterFilter: ReadLaterFilter = .all
    @State private var sortOrders: [LibrarySortSection: LibrarySortOrder] = [:]
    @StateObject private var localSelection = LibrarySelectionStore()
    @State private var selectingLocal = false
    @State private var confirmingLocalRemoval = false
    @State private var removingDownloads = false
    private var matchingReadLater: [Gallery] {
        let saved = library.snapshot.readLater
        guard readLaterFilter != .all else { return saved }
        let started = Set(library.snapshot.history.map(\.id))
        return saved.filter { started.contains($0.id) == (readLaterFilter == .started) }
    }
    private var readLaterVisible: [Gallery] {
        LibrarySelectionPolicy.filtered(matchingReadLater, blocked: library.blockedIDs).visible
    }
    private var sortPreferences: LibrarySortPreferences {
        .init(owner: library.owner, defaults: AppMode.qa ? UserDefaults(suiteName: LibrarySortPreferences.qaSuite)! : .standard)
    }
    private var visibleDownloads: [DownloadRecord] {
        library.snapshot.downloads.filter { downloadFilter.includes($0.status) }
    }
    private var localIDs: Set<String> {
        scope == 3 ? Set(visibleDownloads.map(\.id)) : Set(readLaterVisible.map(\.id))
    }
    private var localSource: LibraryBatchSource { scope == 3 ? .downloads : .readLater }

    var body: some View {
        VStack(spacing: 0) {
            if scope == 1 { CloudFavoritesView(site: $site, scope: $scope, isActive: isActive) }
            else if scope == 2 {
                ReadingHistoryView(placement: .library($scope))
            }
            else { localLibrary }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { sortOrders = sortPreferences.load() }
        .onChange(of: library.owner) { _, _ in sortOrders = sortPreferences.load() }
        .onChange(of: scope) { _, _ in endLocalSelection() }
        .onChange(of: library.owner) { _, _ in
            downloadFilter = .all
            readLaterFilter = .all
            endLocalSelection()
        }
        .onChange(of: isActive) { _, active in if !active { endLocalSelection() } }
        .onChange(of: localIDs) { _, ids in localSelection.updateLoadedIDs(ids) }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if selectingLocal && isActive {
                LibraryBatchToolbar(source: localSource, summary: localSelection.summary, busy: removingDownloads,
                                    galleries: { readLaterVisible.filter { localSelection.selectedIDs.contains($0.id) } },
                                    onRemove: { confirmingLocalRemoval = true })
            }
        }
        .confirmationDialog(scope == 3 ? "移除所选离线副本？" : "从稍后再读移除所选作品？",
                            isPresented: $confirmingLocalRemoval, titleVisibility: .visible) {
            Button(scope == 3 ? "移除本机副本" : "移出所选作品", role: .destructive) {
                let ids = localSelection.selectedIDs
                if scope == 3 {
                    removingDownloads = true
                    Task {
                        let removed = await downloads.remove(ids)
                        removingDownloads = false
                        if removed, scope == 3 { endLocalSelection() }
                    }
                } else if library.removeReadLater(ids) {
                    endLocalSelection()
                }
            }
        } message: {
            Text(scope == 3 ? "将删除所选的本机下载文件。" : "站点收藏、下载文件和阅读进度会保留。")
        }
    }

    private var localLibrary: some View {
        FloatingFeedLayout { headerHeight in
            GeometryReader { geometry in
                let viewport = GalleryFeedViewport(space: "local-library-feed", height: geometry.size.height,
                                                   topOcclusion: headerHeight)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        if let error = library.error { StatusMessage(title: error) { library.load(owner: library.owner) } }
                        if scope == 3 { downloadsSection }
                        else { bookmarksSection(viewport: viewport) }
                    }
                    .padding(.top, headerHeight).padding(.bottom, 30)
                }
                .coordinateSpace(name: viewport.space)
                .contentMargins(.top, headerHeight, for: .scrollIndicators)
                .accessibilityIdentifier("library.local")
            }
        } header: {
            LibraryFloatingHeader(selection: $scope, identifier: "library.header.floating", isSelecting: selectingLocal) {
                if selectingLocal {
                    LibraryBatchSelectionHeader(source: localSource, store: localSelection, summary: localSelection.summary,
                                                busy: removingDownloads, onExit: endLocalSelection)
                } else {
                    if typeSize.isAccessibilitySize {
                        AccessibilityHeaderActions { localLeading } trailing: {
                            HStack(spacing: FeedChrome.panelSpacing) { localSort; localAction }
                        }
                    } else {
                        FeedHeaderGrid(spans: [1, 1, 1]) {
                            localLeading
                            localSort
                            localAction
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var localLeading: some View {
        if scope == 3 {
            LibraryFilterMenu(selection: $downloadFilter, options: DownloadFilter.allCases, title: \.title,
                              label: "下载状态筛选", identifier: "downloads.filter", symbol: "line.3.horizontal.decrease")
        } else {
            LibraryFilterMenu(selection: $readLaterFilter, options: ReadLaterFilter.allCases, title: \.title,
                              label: "阅读状态筛选", identifier: "read-later.filter", symbol: "line.3.horizontal.decrease")
        }
    }

    private var localSort: some View {
        sortMenu(scope == 3 ? .downloads : .bookmarks)
    }

    private var localAction: some View {
        LibraryBatchEntryButton(identifier: scope == 3 ? "downloads.select" : "read-later.select") {
            localSelection.clear()
            localSelection.updateLoadedIDs(localIDs)
            selectingLocal = true
        }
        .disabled(localIDs.isEmpty || removingDownloads)
    }

    private var downloadsSection: some View {
        LazyVStack(alignment: .leading, spacing: FeedChrome.contentSpacing) {
            if visibleDownloads.isEmpty {
                StatusMessage(title: downloadFilter == .all ? "暂无下载" : "没有符合该状态的下载",
                              symbol: "arrow.down.circle")
            } else {
                let records = LibrarySorting.downloads(visibleDownloads, order: sortOrders[.downloads] ?? .original,
                                                       history: library.snapshot.history)
                LibraryCardRows(items: records, cover: { record in
                    record.coverSource(in: library)
                }) { record in
                    downloadRow(record)
                        .accessibilityIdentifier("library.download.item.\(record.gallery.ref.gid)")
                }
            }
        }.padding(.horizontal, FeedChrome.contentInset)
            .padding(.top, FeedChrome.contentTopGap)
            .accessibilityElement(children: .contain).accessibilityIdentifier("library.downloads")
    }

    @ViewBuilder private func downloadRow(_ record: DownloadRecord) -> some View {
        if selectingLocal {
            SelectableDownloadRow(record: record, store: localSelection, entry: localSelection.entry(for: record.id))
        } else {
            Group {
                if record.status == .complete {
                    Button { presentation?.readOffline(record.gallery) } label: {
                        DownloadRowLabel(record: record)
                    }
                } else {
                    Button {
                        if record.canPause { downloads.pause(record.id) }
                        else { downloads.enqueue(record.gallery) }
                    } label: { DownloadRowLabel(record: record) }
                }
            }
            .buttonStyle(.plain)
            .highPriorityGesture(LongPressGesture(minimumDuration: 0.55).onEnded { _ in beginLocalSelection(record.id) })
            .accessibilityValue(record.accessibleDownloadStatus)
            .accessibilityHint(record.status == .complete ? "轻点打开离线阅读，长按选择" :
                                record.requiresRetry ? [record.error, "轻点重试，长按选择"].compactMap { $0 }.joined(separator: "。") :
                                record.canPause ? "轻点暂停，长按选择" : "轻点继续，长按选择")
            .accessibilityAction(named: Text("选择并管理")) { beginLocalSelection(record.id) }
            .disabled(removingDownloads)
        }
    }

    private func bookmarksSection(viewport: GalleryFeedViewport) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if library.snapshot.readLater.isEmpty {
                Text("长按发现页的作品，或在详情的更多操作中加入稍后再读。").font(.subheadline).foregroundStyle(.secondary)
                    .padding(.horizontal, FeedChrome.contentInset).padding(.vertical, 14)
                    .accessibilityIdentifier("read-later.empty")
            }
            else if matchingReadLater.isEmpty {
                StatusMessage(title: readLaterFilter == .unread ? "暂无未读作品" : "暂无有阅读记录的作品", symbol: "book")
                    .padding(.horizontal, FeedChrome.contentInset)
                    .padding(.top, FeedChrome.contentTopGap)
            } else {
                GalleryRows(galleries: LibrarySorting.galleries(matchingReadLater, order: sortOrders[.bookmarks] ?? .original, history: library.snapshot.history), layout: .grid,
                            sourceIdentity: library.owner + ":read-later",
                            selectionStore: localSelection, isSelecting: selectingLocal, openIdentifier: "favorites.gallery",
                            onLongPressSelect: { beginLocalSelection($0.id) }, viewport: viewport)
            }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("library.bookmarks")
    }

    private func beginLocalSelection(_ id: String) {
        localSelection.updateLoadedIDs(localIDs)
        selectingLocal = localSelection.beginSelecting(id)
    }

    private func endLocalSelection() {
        selectingLocal = false
        confirmingLocalRemoval = false
        localSelection.clear()
    }

    private func sortMenu(_ section: LibrarySortSection) -> some View {
        Menu {
            ForEach(section.options) { option in
                Button {
                    sortPreferences.set(option, for: section)
                    sortOrders[section] = option
                } label: {
                    if option == (sortOrders[section] ?? section.defaultOrder) { Label(option.title, systemImage: "checkmark") }
                    else { Text(option.title) }
                }.accessibilityIdentifier("library.sort.\(section.rawValue).\(option.rawValue)")
            }
        } label: {
            LibrarySortControlLabel(title: (sortOrders[section] ?? section.defaultOrder).title)
        }
        .buttonStyle(FeedHeaderButtonStyle(truncatesLabel: true, expandsHorizontally: !typeSize.isAccessibilitySize))
        .accessibilityLabel("\(section.title)排序")
        .accessibilityValue((sortOrders[section] ?? section.defaultOrder).title)
        .accessibilityIdentifier("library.sort.\(section.rawValue)")
    }

}

private extension DownloadRecord {
    var canPause: Bool { status == .waiting || status == .downloading }
    var accessibleDownloadStatus: String {
        guard status != .complete else { return downloadStatus }
        if let pageCount, pageCount > 0 {
            return "\(downloadStatus)，已保存 \(completed.count)/\(pageCount) 页"
        }
        return completed.isEmpty ? downloadStatus : "\(downloadStatus)，已保存 \(completed.count) 页"
    }

    @MainActor func coverSource(in library: LibraryStore) -> LibraryCardCover? {
        guard TagFilter.decision(tags: gallery.tags, blocked: library.blockedIDs,
                                 complete: gallery.tagsComplete) == .visible else { return nil }
        return LibraryCardCover(gallery: gallery, localFile: library.downloadedPage(1, in: self)?.url)
    }

    var pageCount: Int? { total ?? gallery.pages }

    var downloadStatus: String {
        if requiresRetry { return "下载失败" }
        return switch status {
        case .waiting: "等待中"
        case .downloading: "下载中"
        case .paused: "已暂停"
        case .complete: "已下载"
        case .failed: "下载失败"
        }
    }
}

private struct DownloadRowLabel: View {
    let record: DownloadRecord
    var selected: Bool? = nil
    @EnvironmentObject private var library: LibraryStore

    private var symbol: String {
        if record.status == .complete { return "chevron.right" }
        if record.requiresRetry { return "arrow.clockwise" }
        return record.canPause ? "pause.fill" : "play.fill"
    }

    private var progress: CGFloat {
        if record.status == .complete { return 1 }
        guard let pageCount = record.pageCount, pageCount > 0 else { return 0 }
        return min(1, CGFloat(record.completed.count) / CGFloat(pageCount))
    }

    var body: some View {
        LibraryGalleryCard(gallery: record.gallery, pageCount: record.pageCount,
                           context: "画廊 #\(record.gallery.ref.gid)", selected: selected,
                           actionSymbol: symbol, progress: progress) {
            cover
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private var coverPlaceholder: some View {
        Image(systemName: "book.closed")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: .tertiarySystemGroupedBackground))
    }

    private var cover: some View {
        Group {
            if let source = record.coverSource(in: library) {
                if let file = source.localFile {
                    ZStack {
                        coverPlaceholder
                        StaticCover(file: file, contextIdentity: library.owner, requestIdentity: record.id,
                                    contentMode: .fill, fitsExtremeAspects: true)
                    }
                } else {
                    CoverView(gallery: source.gallery, contentMode: .fill, showsLoadingIndicator: false,
                              showsRetryButton: false, fitsExtremeAspects: true)
                }
            } else {
                coverPlaceholder
            }
        }
    }
}

private struct SelectableDownloadRow: View {
    let record: DownloadRecord
    let store: LibrarySelectionStore
    @ObservedObject var entry: LibrarySelectionEntry

    var body: some View {
        Button { store.toggle(record.id) } label: { DownloadRowLabel(record: record, selected: entry.isSelected) }
            .buttonStyle(.plain)
            .accessibilityValue(entry.isSelected ? "已选中" : "未选中")
            .accessibilityAddTraits(entry.isSelected ? .isSelected : [])
    }
}

private struct FavoriteSortAnchor: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

struct CloudFavoritesView: View {
    @Binding var site: GallerySite
    @Binding var scope: Int
    var isActive = true
    @EnvironmentObject private var session: SiteSession
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .subheadline) private var sortMenuWidth: CGFloat = 152
    @StateObject private var pager = GalleryPager()
    @StateObject private var selectionStore = LibrarySelectionStore()
    @StateObject private var submission = FavoriteBatchSubmission()
    @State private var web: WebDestination?
    @State private var category = "all"
    @State private var showingSort = false
    @State private var selecting = false
    @State private var initialLayoutReady = false
    @State private var seenRemovals: [String: UUID] = [:]
    @State private var visibleGalleryID: String?
    @State private var anchorAfterRemoval: String?
    @State private var confirmingRemoval = false
    @State private var moveSelection: MoveSelection?
    @State private var qaFavoriteAttemptCount = 0
    private struct MoveSelection: Hashable {
        let references: [GalleryRef]
        let category: String
        let owner: String
        let generation: UUID
    }
    private struct RequestedSource: Equatable {
        let url: URL
        let generation: UUID
        let owner: String
        let favoritesRevision: UUID
    }
    @State private var requestedSource: RequestedSource?
    private var displayedItems: [Gallery] {
        AppMode.qa && ProcessInfo.processInfo.arguments.contains("--qa-library-large-selection")
            ? LibrarySelectionQA.galleries : pager.items
    }
    @State private var preparedVisible: [Gallery]?
    private var visible: [Gallery] { preparedVisible ?? filteredItems() }
    private var selectedGalleries: [Gallery] { visible.filter { selectionStore.selectedIDs.contains($0.id) } }
    private var sortPreferences: LibrarySortPreferences {
        .init(owner: session.owner, defaults: AppMode.qa ? UserDefaults(suiteName: LibrarySortPreferences.qaSuite)! : .standard)
    }
    private var sortOrder: SiteFavoriteOrder { sortPreferences.favoriteOrder(for: site) }
    private var working: Bool { submission.workingCount != nil }
    var body: some View {
        FloatingFeedLayout { headerHeight in
        VStack(spacing: 0) {
            if AppMode.qa && ProcessInfo.processInfo.arguments.contains("--qa-library-large-selection") {
                Text("QA").font(.system(size: 1)).foregroundStyle(.clear).frame(width: 1, height: 1)
                    .accessibilityIdentifier("library.qa.workload")
                    .accessibilityValue("galleries=\(displayedItems.count);blocked=\(library.snapshot.blockedTags.count)")
                    .allowsHitTesting(false)
            }
            if !session.hasCredentials && !AppMode.qa {
                ContentUnavailableView {
                    Label("登录后读取站点收藏", systemImage: "heart")
                } description: {
                    Text("使用自己的站点账号访问收藏。")
                } actions: {
                    Button("打开官方登录页") { web = .login }.buttonStyle(AppActionButtonStyle(tone: .accent))
                }
            } else {
                favoritesFeed(headerHeight: headerHeight)
            }
          }
        } header: {
            favoritesFloatingHeader
        }
        .accessibilityHidden(showingSort)
        .overlayPreferenceValue(FavoriteSortAnchor.self) { anchor in
            if showingSort, let anchor {
                GeometryReader { geometry in
                    let button = geometry[anchor]
                    let inset = FeedChrome.contentInset
                    let width = min(sortMenuWidth, max(0, geometry.size.width - inset * 2))
                    ZStack(alignment: .topLeading) {
                        Color.clear.contentShape(Rectangle())
                            .onTapGesture { showingSort = false }
                            .accessibilityHidden(true)
                        favoriteSortOptions
                            .frame(width: width)
                            .offset(x: max(inset, min(button.maxX - width, geometry.size.width - width - inset)),
                                    y: button.maxY + 3)
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if selecting && isActive {
                LibraryBatchToolbar(source: .favorites, summary: selectionStore.summary, busy: working,
                                    galleries: { selectedGalleries }, onMove: beginMove,
                                    onRemove: { confirmingRemoval = true })
                    .overlay(alignment: .top) {
                        if let count = submission.workingCount {
                            ProgressView("正在处理 \(count) 项…")
                                .font(FeedChrome.labelFont)
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .background(FloatingChrome.background, in: AppShape.control)
                                .alignmentGuide(.top) { $0[.bottom] + 6 }
                                .allowsHitTesting(false)
                        }
                    }
            }
        }
        .navigationDestination(item: $moveSelection) { move in
            FavoriteGroupPicker(count: move.references.count, moving: true, load: {
                (0...9).map { FavoriteGroupChoice(id: $0, name: categoryName($0)) }
            }) { group in
                try confirmMove(move, to: group.id)
            }
        }
        .alert("取消收藏", isPresented: $confirmingRemoval) {
            Button("移除所选收藏", role: .destructive) { perform(.remove, references: selectedGalleries.map(\.ref)) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("从站点收藏移除 \(selectionStore.selectedIDs.count) 项？本机下载和稍后再读会保留。")
        }
        .sheet(item: $web) { OfficialWebView(destination: $0) }
        .task { prepareVisible(); if !selecting { reload(force: false) } }
        .onChange(of: pager.items) { _, _ in prepareVisible() }
        .onChange(of: pager.loading) { _, loading in
            if !loading { submission.finishListRefresh(succeeded: pager.failure == nil && !pager.interrupted) }
        }
        .onChange(of: library.blockedIDs) { _, _ in selectionStore.clear(); selecting = false; prepareVisible() }
        .onChange(of: category) { _, _ in selectionStore.clear(); selecting = false; reload(force: false) }
        .onChange(of: site) { _, _ in showingSort = false; submission.cancel(); submission.dismissNotice(); selectionStore.clear(); selecting = false; category = "all"; reload(force: false) }
        .onChange(of: session.hasCredentials) { _, _ in reload(force: false) }
        .onChange(of: session.favoritesRevision) { _, _ in reload(force: false) }
        .onReceive(session.favoriteStateCache.$confirmedRemovals, perform: applyConfirmedRemovals)
        .onChange(of: session.generation) { _, _ in accountChanged() }
        .onChange(of: session.owner) { _, _ in accountChanged() }
        .onChange(of: isActive) { _, active in
            if active { reload(force: false) }
            else { showingSort = false; initialLayoutReady = false; submission.cancel(); pager.cancel(); selectionStore.clear(); selecting = false }
        }
        .onDisappear {
            guard moveSelection == nil else { return }
            showingSort = false; initialLayoutReady = false; submission.cancel(); pager.cancel(); selectionStore.clear(); selecting = false
        }
    }

    private func favoritesFeed(headerHeight: CGFloat) -> some View {
        GeometryReader { geometry in
            let viewport = GalleryFeedViewport(space: "favorites-feed", height: geometry.size.height, topOcclusion: headerHeight)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        GalleryRows(galleries: displayedItems, layout: .grid,
                                    sourceIdentity: "\(site.rawValue):\(category):\(sortOrder.rawValue)",
                                    selectionStore: selectionStore, isSelecting: selecting,
                                    openIdentifier: "favorites.gallery",
                                    onLongPressSelect: beginSelection(at:),
                                    onNearEnd: {
                                        if isActive && initialLayoutReady && !selecting && anchorAfterRemoval == nil && pager.failure == nil {
                                            pager.more(session: session, prefetch: true)
                                        }
                                    }, viewport: viewport, onVisibleAnchor: {
                                        if anchorAfterRemoval == nil { visibleGalleryID = $0 }
                                    })
                        if !selecting { GalleryContinuationFooter(pager: pager) }
                        if !pager.loading && pager.failure == nil && displayedItems.isEmpty {
                            StatusMessage(title: "当前分组没有收藏结果。", symbol: "heart")
                        }
                    }
                    .padding(.top, headerHeight)
                }
                .coordinateSpace(name: viewport.space)
                .refreshable {
                    if !working {
                        selectionStore.clear()
                        selecting = false
                        reload()
                    }
                }
                .contentMargins(.top, headerHeight, for: .scrollIndicators)
                .task(id: isActive ? headerHeight : -1) {
                    initialLayoutReady = false
                    guard isActive, headerHeight > 0 else { return }
                    await Task.yield()
                    try? await Task.sleep(nanoseconds: 120_000_000)
                    guard !Task.isCancelled, isActive else { return }
                    initialLayoutReady = true
                }
                .task(id: anchorAfterRemoval) {
                    guard let anchor = anchorAfterRemoval else { return }
                    await Task.yield()
                    guard !Task.isCancelled, anchorAfterRemoval == anchor else { return }
                    proxy.scrollTo(GalleryFeedViewport.restorationID(for: anchor), anchor: viewport.restorationAlignment)
                    visibleGalleryID = anchor
                    anchorAfterRemoval = nil
                }
            }
        }
    }

    private func applyConfirmedRemovals(_ revisions: [String: UUID]) {
        guard let requestedSource, requestedSource.owner == session.owner,
              requestedSource.generation == session.generation, requestedSource.url.host == site.host,
              revisions != seenRemovals else { return }
        let ids = Set(revisions.filter { id, revision in
            id.hasPrefix("\(site.rawValue):") && seenRemovals[id] != revision
        }.keys)
        seenRemovals = revisions
        guard !ids.isEmpty else { return }
        let rows = filteredItems()
        if let anchor = anchorAfterRemoval ?? visibleGalleryID,
           let index = rows.firstIndex(where: { $0.id == anchor }),
           rows[...index].contains(where: { ids.contains($0.id) }) {
            anchorAfterRemoval = rows[index...].first { !ids.contains($0.id) }?.id
                ?? rows[..<index].last { !ids.contains($0.id) }?.id
        }
        pager.removeConfirmedFavorites(ids)
    }

    private var favoritesFloatingHeader: some View {
        LibraryFloatingHeader(selection: $scope, scopeEnabled: !working, identifier: "favorites.header.floating", isSelecting: selecting) {
            VStack(spacing: 0) {
                if session.hasCredentials || AppMode.qa {
                    if selecting {
                        LibraryBatchSelectionHeader(source: .favorites, store: selectionStore, summary: selectionStore.summary,
                                                    busy: working) {
                            selecting = false
                            selectionStore.clear()
                            if pager.interrupted { pager.retry(session: session) }
                        }
                    } else {
                        if typeSize.isAccessibilitySize {
                            AccessibilityHeaderActions { groupMenu } trailing: {
                                HStack(spacing: FeedChrome.panelSpacing) { favoriteSortMenu; favoriteSelectButton }
                            }
                        } else {
                            FeedHeaderGrid(spans: [1, 1, 1]) {
                                groupMenu
                                favoriteSortMenu
                                favoriteSelectButton
                            }
                        }
                    }
                }
                if FeedCacheQA.isEnabled { FeedCacheQAStatus(pager: pager, lane: "favorites") }
                if let error = library.error {
                    StatusMessage(title: error) { library.load(owner: library.owner) }
                }
                if let notice = submissionNotice {
                    HStack(alignment: .top) {
                        Text(notice.text).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                        if notice.needsVerification {
                            Button("刷新核实") { submission.dismissNotice(); reload() }
                                .font(.caption.weight(.semibold)).frame(minHeight: 44)
                                .accessibilityIdentifier("favorites.verify-refresh")
                        }
                        Button { submission.dismissNotice() } label: { Image(systemName: "xmark.circle.fill").frame(minWidth: 44, minHeight: 44) }
                            .accessibilityLabel("关闭操作提示")
                    }
                }
                if AppMode.qa && ProcessInfo.processInfo.arguments.contains("--qa-favorites-unknown-response") {
                    Text("QA 模拟提交次数：\(qaFavoriteAttemptCount)")
                        .font(.caption2).foregroundStyle(.secondary)
                        .accessibilityIdentifier("favorites.qa-attempt-count")
                }
            }
        }
    }

    private var submissionNotice: (text: String, needsVerification: Bool)? {
        switch submission.state {
        case .idle, .submitting:
            return nil
        case .refreshingList(let submitted):
            return ("已提交 \(submitted) 项操作，正在更新收藏列表…", false)
        case .listRefreshed:
            return ("收藏列表已更新。", false)
        case .listRefreshFailed:
            return ("操作已发送，列表暂未更新，请刷新。", false)
        case .preview:
            return ("测试模式仅检查多选交互，未修改站点收藏。", false)
        case .interrupted(let submitted, let count, let reason):
            let prefix = submitted > 0 ? "此前已发送 \(submitted) 项操作。" : ""
            switch reason {
            case .needsVerification(let error):
                return (prefix + "本批 \(count) 项结果待确认，已暂停后续操作。\n" + ErrorMessages.message(error), true)
            case .notSent(let error):
                return (prefix + "本批 \(count) 项尚未发送，已暂停后续操作。\n" + ErrorMessages.message(error), false)
            }
        }
    }
    private var groupMenu: some View {
        Menu {
            Picker("收藏分组", selection: $category) {
                Text("全部分组").tag("all")
                ForEach(0...9, id: \.self) { index in
                    Text(categoryName(index)).tag(String(index))
                }
            }
        } label: {
            LibraryMenuLabel(title: selectedGroupName, symbol: "folder")
                .frame(maxWidth: typeSize.isAccessibilitySize ? nil : .infinity)
        }
        .buttonStyle(FeedHeaderButtonStyle(truncatesLabel: true, expandsHorizontally: !typeSize.isAccessibilitySize)).foregroundStyle(.primary)
        .accessibilityLabel("收藏分组").accessibilityValue(selectedGroupName)
        .accessibilityHint("选择要查看的站点收藏分组")
        .accessibilityIdentifier("favorites.group-filter")
        .disabled(working)
    }
    private var favoriteSelectButton: some View {
        LibraryBatchEntryButton(identifier: "favorites.select", action: beginSelection)
            .disabled(working || visible.isEmpty)
    }

    private var favoriteSortMenu: some View {
        Button { showingSort.toggle() } label: {
            LibrarySortControlLabel(title: sortOrder == .siteDefault ? "排序" : sortOrder.title)
        }
        .buttonStyle(FeedHeaderButtonStyle(truncatesLabel: true, expandsHorizontally: !typeSize.isAccessibilitySize))
        .accessibilityLabel("站点收藏排序").accessibilityValue(sortOrder.title)
        .accessibilityIdentifier("favorites.sort")
        .disabled(working)
        .anchorPreference(key: FavoriteSortAnchor.self, value: .bounds) { $0 }
    }
    private var favoriteSortOptions: some View {
        VStack(spacing: 0) {
            ForEach(SiteFavoriteOrder.allCases) { order in
                let selected = order == sortOrder
                Button {
                    showingSort = false
                    sortPreferences.set(order, for: site)
                    reload(force: false)
                } label: {
                    HStack(spacing: 8) {
                        Text(order.title).lineLimit(1)
                        Spacer(minLength: 0)
                        if selected { Image(systemName: "checkmark").accessibilityHidden(true) }
                    }
                    .font(FeedChrome.labelFont)
                    .foregroundStyle(selected ? Color.accentColor : .primary)
                    .padding(.horizontal, 10)
                    .frame(minHeight: 44)
                    .background(selected ? Color.accentColor.opacity(0.12) : .clear, in: AppShape.control)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("favorites.sort.\(order.rawValue)")
            }
        }
        .padding(AppShape.panelInset)
        .background(FloatingChrome.headerBackground, in: AppShape.panel)
        .overlay(AppShape.panel.strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5).allowsHitTesting(false))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("站点收藏排序选项")
        .accessibilityAction(.escape) { showingSort = false }
    }
    private func filteredItems() -> [Gallery] {
        LibrarySelectionPolicy.filtered(displayedItems, blocked: library.blockedIDs).visible
    }
    private func prepareVisible() {
        let items = filteredItems()
        preparedVisible = items
        selectionStore.updateLoadedIDs(Set(items.map(\.id)))
    }
    private var selectedGroupName: String {
        category == "all" ? "全部分组" : categoryName(Int(category) ?? 0)
    }
    private func categoryName(_ index: Int) -> String { pager.categories[String(index)] ?? "分组 \(index + 1)" }
    private func beginSelection() {
        guard !working, !selecting, !visible.isEmpty else { return }
        selectionStore.clear()
        selectionStore.updateLoadedIDs(Set(visible.map(\.id)))
        pager.pauseForSelection()
        selecting = true
    }
    private func beginSelection(at gallery: Gallery) {
        guard !working, !selecting else { return }
        SelectionPerformanceProbe.markAction(id: gallery.id)
        guard selectionStore.beginSelecting(gallery.id) else { return }
        pager.pauseForSelection()
        SelectionPerformanceProbe.markStateSet(id: gallery.id, count: selectionStore.selectedIDs.count)
        selecting = true
    }
    private func accountChanged() {
        showingSort = false; submission.cancel(); submission.dismissNotice(); selectionStore.clear(); selecting = false
        reload(force: false)
    }
    private func beginMove() {
        let references = selectedGalleries.map(\.ref)
        guard !working, !references.isEmpty else { return }
        moveSelection = MoveSelection(references: references, category: category, owner: session.owner, generation: session.generation)
    }
    private func confirmMove(_ move: MoveSelection, to group: Int) throws {
        guard !working, isActive, selecting, move.owner == session.owner, move.generation == session.generation,
              move.category == category, move.references.allSatisfy({ $0.site == site }),
              Set(move.references) == Set(selectedGalleries.map(\.ref)) else {
            throw ViewerError.invalidQuery("所选收藏已变化，请返回后重新选择。")
        }
        perform(.move(group), references: move.references)
    }
    private func perform(_ action: FavoriteAction, references: [GalleryRef]) {
        guard !references.isEmpty, !working else { return }
        let simulateUnknown = AppMode.qa && ProcessInfo.processInfo.arguments.contains("--qa-favorites-unknown-response")
        if AppMode.qa && !simulateUnknown {
            selectionStore.clear()
            selecting = false
            submission.showPreview()
            return
        }
        let generation = session.generation, owner = session.owner, sourceSite = site
        let isCurrent = { generation == session.generation && owner == session.owner && sourceSite == site }
        submission.start(references, isCurrent: isCurrent, invalidateCache: {
            await pager.invalidateFavoriteCache(owner: owner)
        }, submit: { batch in
            if simulateUnknown {
                try await Task.sleep(nanoseconds: 150_000_000)
                guard isCurrent() else { throw ViewerError.stale }
                qaFavoriteAttemptCount += 1
                throw FavoriteMutationFailure(requestMayHaveBeenSent: true,
                                              underlying: NSError(domain: "ExViewer.QA", code: 1,
                                                                  userInfo: [NSLocalizedDescriptionKey: "QA 模拟：服务器响应丢失，结果未知。"]))
            }
            try await session.changeFavorites(batch, site: sourceSite, action: action)
        }, onSubmitted: { batch in
            selectionStore.remove(batch.map(\.id))
        }, onComplete: {
            selecting = false
            selectionStore.clear()
            reload()
        })
    }
    private func reload(force: Bool = true) {
        guard isActive, AppMode.qa || session.hasCredentials, let url = sortOrder.url(site: site, category: category) else { return }
        let source = RequestedSource(url: url, generation: session.generation, owner: session.owner, favoritesRevision: session.favoritesRevision)
        if !force, requestedSource == source {
            applyConfirmedRemovals(session.favoriteStateCache.confirmedRemovals)
            if pager.interrupted { pager.retry(session: session) }
            return
        }
        let replaceInFlight = requestedSource.map { $0.favoritesRevision != source.favoritesRevision } ?? false
        if requestedSource?.url != source.url || requestedSource?.generation != source.generation {
            visibleGalleryID = nil
            anchorAfterRemoval = nil
        }
        requestedSource = source
        seenRemovals = session.favoriteStateCache.confirmedRemovals
        pager.reset(url: url, session: session, qa: AppMode.qa, replaceInFlight: replaceInFlight)
    }
}
