import SwiftUI
import ExViewerCore

struct DiscoverView: View {
    @ObservedObject var navigation: DiscoveryNavigation
    var onSiteChange: (GallerySite) -> Void = { _ in }
    var onOpenHistory: (() -> Void)? = nil
    var onClose: (() -> Void)? = nil

    @EnvironmentObject private var session: SiteSession
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var started = false
    @State private var composerStart: SearchComposerStart?
    @State private var web: WebDestination?
    @StateObject private var batchSelection = LibrarySelectionStore()
    @State private var selecting = false

    private var entry: DiscoveryEntry { navigation.current }
    private var hasActiveConditions: Bool { entry.query.hasSettings }
    private var currentSaved: SavedSearch? {
        library.snapshot.saved.first { $0.id == entry.savedID && $0.query == entry.query && $0.site == entry.site }
    }
    private var headerDetails: String { SearchPresentation.headerDetails(entry.query) }
    private var filterConditionCount: Int { SearchPresentation.conditionCount(entry.query) }

    var body: some View {
        FloatingFeedLayout { headerHeight in
            Group {
                if !session.hasCredentials && !AppMode.qa && !started && !entry.didStart {
                    VStack {
                        Spacer()
                        VStack(alignment: .leading, spacing: 18) {
                            Image(systemName: "books.vertical").font(.system(size: 40, weight: .ultraLight)).foregroundStyle(Palette.accent)
                            Text("发现画廊").font(.title2.weight(.medium))
                            Button("登录站点账号") { web = .login }.buttonStyle(AppActionButtonStyle(tone: .accent))
                            Button("开始浏览") { startCurrent() }.font(.subheadline)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(24)
                        Spacer()
                    }
                } else {
                    DiscoveryFeedView(entry: entry, topInset: headerHeight, selectionStore: batchSelection, isSelecting: selecting,
                                      onLongPressSelect: beginSelection, onRefresh: { [id = entry.id] in
                        guard navigation.current.id == id else { return }; refreshCurrent()
                    }, isCurrent: { [id = entry.id] in navigation.current.id == id })
                        .id(entry.id)
                        .environmentObject(session)
                        .environmentObject(library)
                        .modifier(DiscoveryHistoryGesture(topInset: headerHeight,
                                                         canGoBack: !selecting && navigation.canGoBack,
                                                         canGoForward: !selecting && navigation.canGoForward,
                                                         onBack: goBack, onForward: goForward))
                }
            }
        } header: {
            discoverFloatingHeader
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if selecting {
                LibraryBatchToolbar(source: .discover, summary: batchSelection.summary, galleries: {
                    entry.pager.items.filter { batchSelection.selectedIDs.contains($0.id) }
                })
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .sheet(item: $web) { OfficialWebView(destination: $0) }
        .navigationDestination(item: $composerStart) { composerSheet(startAt: $0) }
        .onChange(of: session.hasCredentials) { _, value in if value { startCurrent() } }
        .onChange(of: entry.id) { _, _ in endSelection(resume: false) }
        .onChange(of: library.blockedIDs) { _, _ in endSelection() }
        .task(id: entry.id) {
            if !entry.didStart && (AppMode.qa || session.hasCredentials || hasActiveConditions) { startCurrent() }
        }
    }

    private var discoverFloatingHeader: some View {
        FloatingHeaderPanel(identifier: "discover.header.floating", twoRows: true) {
            VStack(spacing: FeedChrome.rowSpacing(for: typeSize)) {
                if let error = navigation.submissionError { StatusMessage(title: error) }
                FeedHeaderRows {
                    searchEntryRow
                } secondary: {
                    if selecting {
                        LibraryBatchSelectionHeader(source: .discover, store: batchSelection, summary: batchSelection.summary) {
                            endSelection()
                        }
                    } else {
                        let layout = typeSize.isAccessibilitySize
                            ? AnyLayout(HStackLayout(spacing: FeedChrome.panelSpacing))
                            : AnyLayout(FeedHeaderGrid(spans: [3, 1]))
                        layout {
                            if hasActiveConditions { conditionSummary }
                            else { lanePicker }
                            commonSearchControl
                        }
                    }
                }
            }
        }
    }

    private func beginSelection(_ gallery: Gallery) {
        guard !selecting else { return }
        let visible = LibrarySelectionPolicy.filtered(entry.pager.items, blocked: library.blockedIDs).visible
        batchSelection.updateLoadedIDs(Set(visible.map(\.id)))
        guard batchSelection.beginSelecting(gallery.id) else { return }
        entry.pager.pauseForSelection()
        selecting = true
    }

    private func endSelection(resume: Bool = true) {
        guard selecting else { return }
        selecting = false
        batchSelection.clear()
        if resume, entry.pager.interrupted { entry.pager.retry(session: session) }
    }

    private var searchEntryRow: some View {
        let layout = !typeSize.isAccessibilitySize
            ? AnyLayout(FeedHeaderGrid(spans: [3, 1]))
            : AnyLayout(HStackLayout(spacing: FeedChrome.panelSpacing))
        return layout {
            searchInputControls.disabled(selecting)
            if let onClose {
                Button(action: onClose) {
                    shortcutLabel("关闭", symbol: "xmark")
                }
                .buttonStyle(FeedHeaderButtonStyle(truncatesLabel: true, expandsHorizontally: !typeSize.isAccessibilitySize))
                .accessibilityLabel("关闭搜索结果").accessibilityIdentifier("search.results.close")
            } else if let onOpenHistory {
                Button(action: onOpenHistory) {
                    shortcutLabel("历史", symbol: "clock")
                }
                .buttonStyle(FeedHeaderButtonStyle(truncatesLabel: true, expandsHorizontally: !typeSize.isAccessibilitySize))
                .disabled(selecting)
                .accessibilityLabel("阅读历史").accessibilityIdentifier("discover.history")
            }
        }
    }

    private func shortcutLabel(_ title: String, symbol: String) -> some View {
        ViewThatFits(in: .horizontal) {
            if !typeSize.isAccessibilitySize {
                HStack(spacing: 4) {
                    shortcutIcon(symbol)
                    Text(title).font(FeedChrome.labelFont)
                }
                .fixedSize()
            }
            shortcutIcon(symbol)
        }
        .frame(maxWidth: typeSize.isAccessibilitySize ? nil : .infinity)
    }

    private func shortcutIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(FeedChrome.labelFont)
            .imageScale(.medium)
            .frame(width: 16)
    }

    private var searchInputControls: some View {
        let insets = FeedChrome.surfaceInsets(for: typeSize, row: .primary)
        let contentOffset = FeedChrome.contentOffset(for: insets)
        return HStack(spacing: 0) {
            if navigation.canGoBack {
                Button(action: goBack) {
                    Image(systemName: "chevron.left")
                        .offset(y: contentOffset)
                        .frame(minWidth: FeedChrome.rowHeight, minHeight: FeedChrome.rowHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(onClose == nil ? "返回" : "上一组搜索条件")
                .accessibilityIdentifier("discover.back")
                .contextMenu {
                    if navigation.canGoForward { Button("前进", systemImage: "chevron.right", action: goForward) }
                }
            }
            Button { composerStart = .main } label: {
                HStack(spacing: FeedChrome.controlSpacing) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    Text(SearchPresentation.headerTitle(entry.query, savedName: currentSaved?.name))
                        .lineLimit(1).foregroundStyle(hasActiveConditions ? .primary : .secondary)
                    Spacer(minLength: 0)
                }.padding(.horizontal, FeedChrome.controlSpacing)
                    .offset(y: contentOffset)
                    .frame(minHeight: FeedChrome.rowHeight).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(hasActiveConditions ? "编辑搜索条件" : "搜索关键词、标签与条件")
            .accessibilityValue(hasActiveConditions ? SearchPresentation.conditions(entry.query) : "")
            .accessibilityIdentifier("discover.search-entry")
            Divider().frame(height: 18).offset(y: contentOffset)
            Button { composerStart = .filters } label: {
                Image(systemName: "slider.horizontal.3")
                    .offset(y: contentOffset)
                    .frame(minWidth: FeedChrome.rowHeight, minHeight: FeedChrome.rowHeight).contentShape(Rectangle())
                    .overlay(alignment: .topTrailing) {
                        if filterConditionCount > 0 {
                            Text(String(filterConditionCount)).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)
                                .padding(2).background(Color.accentColor, in: Circle()).offset(x: -3, y: 5 + contentOffset)
                        }
                    }
            }.buttonStyle(.plain)
            .accessibilityLabel("搜索筛选条件")
            .accessibilityValue("\(filterConditionCount) 项筛选条件，不含关键词")
            .accessibilityIdentifier("discover.filters")
        }
        .font(FeedChrome.labelFont)
        .appControlSurface(insets: insets)
    }

    private var commonSearchControl: some View {
        Button { composerStart = .favorites } label: {
            shortcutLabel("常用", symbol: "bookmark")
        }
        .buttonStyle(FeedHeaderButtonStyle(truncatesLabel: true, expandsHorizontally: !typeSize.isAccessibilitySize))
        .accessibilityLabel("常用组合").accessibilityIdentifier("discover.saved-menu")
    }

    private var conditionSummary: some View {
        Button { composerStart = .filters } label: {
            HStack(spacing: 5) {
                Text(headerDetails).lineLimit(1)
                Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).accessibilityHidden(true)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .feedHeaderControl(typeSize: typeSize)
        }
        .buttonStyle(.plain).foregroundStyle(.primary)
        .accessibilityLabel("当前筛选条件").accessibilityValue(SearchPresentation.conditions(entry.query, includeText: false))
        .accessibilityHint("展开查看全部筛选条件")
        .accessibilityIdentifier("discover.condition-summary")
    }

    private var lanePicker: some View {
        FeedScopePicker(selection: laneBinding, options: [.init(id: 0, title: "最新", symbol: "clock"), .init(id: 1, title: "热门", symbol: "flame")], identifier: "discover.lane")
    }

    private var laneBinding: Binding<Int> {
        Binding(get: { entry.lane }, set: { lane in submit(entry.query, site: entry.site, lane: lane, savedID: entry.savedID) })
    }

    private func composerSheet(startAt: SearchComposerStart) -> some View {
        DiscoveryComposerView(query: entry.query, site: entry.site, savedID: currentSaved?.id,
                              startAt: startAt, loadedPreset: currentSaved, updatesResults: hasActiveConditions || onClose != nil,
                              usesParentNavigation: true) { query, site, savedID in
            try navigation.execute(query: query, site: site, savedID: savedID, session: session, library: library)
            started = true
            onSiteChange(navigation.current.site)
        }
        .environmentObject(library)
        .dynamicTypeSize(typeSize)
    }

    private func startCurrent() {
        do {
            let isFirstExecution = !entry.didStart
            try navigation.startCurrent(session: session, qa: AppMode.qa)
            if isFirstExecution { library.recordSearch(query: entry.query, site: entry.site) }
            started = true
            navigation.submissionError = nil
        } catch { navigation.report(error) }
    }

    private func submit(_ query: SearchQuery, site: GallerySite, lane: Int, savedID: UUID?) {
        do {
            try navigation.execute(query: query, site: site, lane: lane, savedID: savedID, session: session, library: library)
            started = true
            onSiteChange(navigation.current.site)
        } catch { navigation.report(error) }
    }

    private func goBack() {
        guard navigation.back() else { return }
        resumeHistoryEntry()
    }

    private func goForward() {
        guard navigation.forward() else { return }
        resumeHistoryEntry()
    }

    private func resumeHistoryEntry() {
        onSiteChange(navigation.current.site)
        startCurrent()
        if entry.pager.interrupted { entry.pager.retry(session: session) }
    }

    private func refreshCurrent() {
        entry.pager.reset(url: entry.requestURL, session: session, qa: AppMode.qa)
    }

}

private struct DiscoveryHistoryGesture: ViewModifier {
    let topInset: CGFloat
    let canGoBack: Bool
    let canGoForward: Bool
    var onBack: () -> Void
    var onForward: () -> Void
    @GestureState(resetTransaction: Transaction(animation: .easeOut(duration: 0.18))) private var drag: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .simultaneousGesture(DragGesture(minimumDistance: 24, coordinateSpace: .local)
                .updating($drag) { value, state, _ in
                    guard value.startLocation.y > topInset,
                          direction(value.translation) != nil else { return }
                    state = value.translation.width
                }
                .onEnded { value in
                    guard value.startLocation.y > topInset,
                          let action = DiscoveryHistorySwipe.committedDirection(
                            horizontal: Double(value.translation.width), vertical: Double(value.translation.height),
                            predictedHorizontal: Double(value.predictedEndTranslation.width),
                            canGoBack: canGoBack, canGoForward: canGoForward) else { return }
                    if action == .back { onBack() } else { onForward() }
                })
            .overlay(alignment: drag >= 0 ? .leading : .trailing) {
                if drag != 0 {
                    Image(systemName: drag > 0 ? "chevron.left" : "chevron.right")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 32, height: 32)
                        .background(FloatingChrome.background, in: Circle())
                        .padding(.horizontal, 10)
                        .opacity(Double(min(1, abs(drag) / 72)))
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            .accessibilityAction(named: Text("返回上一页")) { if canGoBack { onBack() } }
            .accessibilityAction(named: Text("前进下一页")) { if canGoForward { onForward() } }
    }

    private func direction(_ translation: CGSize) -> DiscoveryHistorySwipe.Direction? {
        DiscoveryHistorySwipe.direction(horizontal: Double(translation.width), vertical: Double(translation.height),
                                        canGoBack: canGoBack, canGoForward: canGoForward)
    }
}

private struct DiscoveryFeedView: View {
    @ObservedObject var entry: DiscoveryEntry
    var topInset: CGFloat
    var selectionStore: LibrarySelectionStore
    var isSelecting: Bool
    var onLongPressSelect: (Gallery) -> Void
    var onRefresh: () -> Void
    var isCurrent: () -> Bool
    @EnvironmentObject private var session: SiteSession
    @EnvironmentObject private var library: LibraryStore
    @ObservedObject private var pager: GalleryPager
    @State private var restoring = true

    init(entry: DiscoveryEntry, topInset: CGFloat, selectionStore: LibrarySelectionStore, isSelecting: Bool,
         onLongPressSelect: @escaping (Gallery) -> Void, onRefresh: @escaping () -> Void, isCurrent: @escaping () -> Bool) {
        self.entry = entry; self.topInset = topInset; self.selectionStore = selectionStore
        self.isSelecting = isSelecting
        self.onLongPressSelect = onLongPressSelect; self.onRefresh = onRefresh; self.isCurrent = isCurrent
        _pager = ObservedObject(wrappedValue: entry.pager)
    }

    var body: some View {
        GeometryReader { viewport in
          ScrollViewReader { proxy in
           ScrollView {
            LazyVStack(spacing: 0) {
                if pager.interrupted && !isSelecting {
                    StatusMessage(title: "已暂停之前的加载，可重试继续。") { pager.retry(session: session) }
                }
                GalleryRows(galleries: pager.items, layout: .grid,
                            sourceIdentity: entry.id.uuidString, selectionStore: selectionStore, isSelecting: isSelecting,
                            selectionIdentifier: "discover.select", onLongPressSelect: onLongPressSelect,
                            onNearEnd: { if !isSelecting && !restoring && isCurrent() && pager.failure == nil && !pager.interrupted { pager.more(session: session, prefetch: true) } },
                            viewport: .init(space: entry.id.uuidString, height: viewport.size.height, topOcclusion: topInset),
                            onVisibleAnchor: { if !restoring && isCurrent() { entry.updateVisibleAnchor($0) } })
                    .scrollTargetLayout()
                if !isSelecting { GalleryContinuationFooter(pager: pager) }
                if !pager.loading && pager.failure == nil && pager.items.isEmpty && !pager.interrupted {
                    StatusMessage(title: entry.query.count > 0 ? "当前组合没有结果，可调整筛选条件。" : "当前范围没有结果。", symbol: entry.query.count > 0 ? "magnifyingglass" : "tray")
                }
            }
            .padding(.top, topInset)
        }
        .coordinateSpace(name: entry.id.uuidString)
        .accessibilityIdentifier("discover.feed")
        .refreshable { if !isSelecting { onRefresh() } }
        .contentMargins(.top, topInset, for: .scrollIndicators)
        .task(id: topInset) {
            guard restoring, topInset > 0 else { return }
            // A new feed must finish its initial placement before viewport
            // callbacks can save anchors or request another batch. Appends keep
            // the server's existing order and do not restart this restoration.
            let anchor = entry.scrollAnchor ?? pager.items.first?.id
            await Task.yield()
            guard !Task.isCancelled, isCurrent() else { return }
            if let anchor {
                let viewport = GalleryFeedViewport(space: entry.id.uuidString, height: viewport.size.height, topOcclusion: topInset)
                let target = GalleryFeedViewport.restorationID(for: anchor)
                proxy.scrollTo(target, anchor: viewport.restorationAlignment)
                try? await Task.sleep(nanoseconds: 120_000_000)
                guard !Task.isCancelled, isCurrent() else { return }
                proxy.scrollTo(target, anchor: viewport.restorationAlignment)
            }
            restoring = false
        }
          }
        }
        .overlay(alignment: .topLeading) {
            if FeedCacheQA.isEnabled { FeedCacheQAStatus(pager: pager, lane: "discover") }
        }
    }
}
