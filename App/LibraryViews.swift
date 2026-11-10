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
            Text("屏蔽应用于本机列表、详情和离线阅读。站点收藏和文件会保留。标签不完整的结果暂时隐藏，可重试补查。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, FeedChrome.sectionSpacing)
                .accountPageListRow()
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

struct LibraryView: View {
    @Environment(\.galleryDetailPresentation) private var presentation
    @Binding var site: GallerySite
    var isActive = true
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var downloads: DownloadManager
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var scope = 0
    @State private var downloadHelp = false
    @State private var sortOrders: [LibrarySortSection: LibrarySortOrder] = [:]
    @StateObject private var localSelection = LibrarySelectionStore()
    @State private var selectingLocal = false
    @State private var confirmingLocalRemoval = false
    @State private var removingDownloads = false
    private var readLaterVisible: [Gallery] {
        LibrarySelectionPolicy.filtered(library.snapshot.readLater, blocked: library.blockedIDs).visible
    }
    private var sortPreferences: LibrarySortPreferences {
        .init(owner: library.owner, defaults: AppMode.qa ? UserDefaults(suiteName: LibrarySortPreferences.qaSuite)! : .standard)
    }
    private var localIDs: Set<String> {
        scope == 3 ? Set(library.snapshot.downloads.map(\.id)) : Set(readLaterVisible.map(\.id))
    }
    private var localSource: LibraryBatchSource { scope == 3 ? .downloads : .readLater }

    var body: some View {
        VStack(spacing: 0) {
            if scope == 1 { CloudFavoritesView(site: $site, scope: $scope, isActive: isActive) }
            else if scope == 2 {
                ReadingHistoryView(libraryScope: $scope)
            }
            else { localLibrary }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { sortOrders = sortPreferences.load() }
        .onChange(of: library.owner) { _, _ in sortOrders = sortPreferences.load() }
        .onChange(of: scope) { _, _ in endLocalSelection() }
        .onChange(of: library.owner) { _, _ in endLocalSelection() }
        .onChange(of: isActive) { _, active in if !active { endLocalSelection() } }
        .onChange(of: localIDs) { _, ids in localSelection.updateLoadedIDs(ids) }
        .sheet(isPresented: $downloadHelp) { DownloadHelpView() }
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
            LibraryFloatingHeader(selection: $scope, identifier: "library.header.floating") {
                if selectingLocal {
                    LibraryBatchSelectionHeader(source: localSource, store: localSelection, summary: localSelection.summary,
                                                busy: removingDownloads, onExit: endLocalSelection)
                } else {
                    if typeSize.isAccessibilitySize {
                        LibraryHeaderActions { localCount } trailing: {
                            HStack(spacing: FeedChrome.panelSpacing) { localSort; localAction }
                        }
                    } else {
                        FeedHeaderGrid(spans: [2, 1, 1]) {
                            localCount
                            localSort
                            localAction
                        }
                    }
                }
            }
        }
    }

    private var localCount: some View {
        let downloads = library.snapshot.downloads
        let title: String
        if scope == 3 {
            let completed = downloads.count(where: { $0.status == .complete })
            title = "\(downloads.count) 项 · \(completed) 项已下载"
        } else {
            title = "已保存 \(library.snapshot.readLater.count) 个作品"
        }
        return LibraryHeaderCount(title: title, symbol: scope == 3 ? "arrow.down.circle" : "text.badge.plus",
                                  fillsWidth: !typeSize.isAccessibilitySize)
            .accessibilityIdentifier("library.count.\(scope == 3 ? "downloads" : "bookmarks")")
    }

    private var localSort: some View {
        sortMenu(scope == 3 ? .downloads : .bookmarks)
    }

    @ViewBuilder private var localAction: some View {
        if scope == 3 {
            Button { downloadHelp = true } label: {
                Image(systemName: "info.circle")
                    .frame(maxWidth: typeSize.isAccessibilitySize ? nil : .infinity)
            }
            .buttonStyle(FeedHeaderButtonStyle(truncatesLabel: true, expandsHorizontally: !typeSize.isAccessibilitySize))
            .accessibilityLabel("下载说明").accessibilityIdentifier("downloads.help")
        } else {
            Button {
                localSelection.clear()
                localSelection.updateLoadedIDs(localIDs)
                selectingLocal = true
            } label: {
                ViewThatFits(in: .horizontal) {
                    Label("选择", systemImage: "checkmark.square").fixedSize()
                    Image(systemName: "checkmark.square")
                }
                .frame(maxWidth: typeSize.isAccessibilitySize ? nil : .infinity)
            }
            .buttonStyle(FeedHeaderButtonStyle(truncatesLabel: true, expandsHorizontally: !typeSize.isAccessibilitySize))
            .foregroundStyle(Color.accentColor)
            .disabled(readLaterVisible.isEmpty)
            .accessibilityLabel("选择").accessibilityIdentifier("read-later.select")
        }
    }

    private var downloadsSection: some View {
        LazyVStack(alignment: .leading, spacing: 8) {
            if library.snapshot.downloads.isEmpty {
                StatusMessage(title: "暂无下载", symbol: "arrow.down.circle")
            } else {
                ForEach(LibrarySorting.downloads(library.snapshot.downloads, order: sortOrders[.downloads] ?? .original, history: library.snapshot.history)) { record in
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
            .accessibilityValue(record.downloadStatus)
            .accessibilityHint(record.status == .complete ? "轻点打开离线阅读，长按选择" :
                                record.requiresRetry ? "轻点重试，长按选择" :
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
            else {
                GalleryRows(galleries: LibrarySorting.galleries(library.snapshot.readLater, order: sortOrders[.bookmarks] ?? .original, history: library.snapshot.history), layout: .grid,
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
            if section != .history { Text("最近阅读：无记录的作品置后，保留原序。") }
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

    private var symbol: String {
        if let selected { return selected ? "checkmark.circle.fill" : "circle" }
        if record.status == .complete { return "chevron.right" }
        if record.requiresRetry { return "arrow.clockwise" }
        return record.canPause ? "pause.fill" : "play.fill"
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(record.gallery.title).font(.subheadline.weight(.medium)).lineLimit(1)
                if record.status == .complete {
                    Text(record.downloadStatus).font(.caption).foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 8) {
                        ProgressView(value: record.total.map { min(1, Double(record.completed.count) / Double(max($0, 1))) })
                        Text("\(record.completed.count)/\(record.total.map(String.init) ?? "–") 页")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary).fixedSize()
                    }
                    if record.requiresRetry {
                        Text(record.error ?? "下载失败").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: symbol).font(.subheadline.weight(.semibold))
                .foregroundStyle(selected == true ? Color.accentColor : Color.secondary)
                .frame(width: 24).accessibilityHidden(true)
        }
        .padding(.horizontal, FeedChrome.sectionSpacing)
        .padding(.vertical, FeedChrome.panelSpacing)
        .frame(maxWidth: .infinity, minHeight: FeedChrome.rowHeight, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: AppShape.card)
        .overlay {
            let paused = selected == nil && !record.canPause && record.status != .complete
            AppShape.card.fill(selected == true ? Color.accentColor.opacity(0.08) : Color.primary.opacity(paused ? 0.04 : 0))
                .allowsHitTesting(false)
        }
        .overlay { AppShape.card.strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5).allowsHitTesting(false) }
        .contentShape(AppShape.card)
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
                                .font(.footnote)
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
        LibraryFloatingHeader(selection: $scope, scopeEnabled: !working, identifier: "favorites.header.floating") {
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
                            LibraryHeaderActions { groupMenu } trailing: {
                                HStack(spacing: FeedChrome.panelSpacing) { favoriteSortMenu; favoriteSelectButton }
                            }
                        } else {
                            FeedHeaderGrid(spans: [2, 1, 1]) {
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
            LibraryMenuLabel(title: selectedGroupName, symbol: "folder", fillsWidth: !typeSize.isAccessibilitySize)
        }
        .buttonStyle(FeedHeaderButtonStyle(truncatesLabel: true, expandsHorizontally: !typeSize.isAccessibilitySize)).foregroundStyle(.primary)
        .accessibilityLabel("收藏分组").accessibilityValue(selectedGroupName)
        .accessibilityHint("选择要查看的站点收藏分组")
        .accessibilityIdentifier("favorites.group-filter")
        .disabled(working)
    }
    private var favoriteSelectButton: some View {
        Button(action: beginSelection) {
            ViewThatFits(in: .horizontal) {
                Label("选择", systemImage: "checkmark.square").fixedSize()
                Image(systemName: "checkmark.square")
            }
            .frame(maxWidth: typeSize.isAccessibilitySize ? nil : .infinity)
        }
        .buttonStyle(FeedHeaderButtonStyle(truncatesLabel: true, expandsHorizontally: !typeSize.isAccessibilitySize))
        .foregroundStyle(Color.accentColor)
        .disabled(working || visible.isEmpty)
        .accessibilityLabel("选择").accessibilityIdentifier("favorites.select")
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
