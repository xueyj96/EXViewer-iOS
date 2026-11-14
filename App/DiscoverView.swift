import SwiftUI
import ExViewerCore

struct DiscoverView: View {
    @ObservedObject var navigation: DiscoveryNavigation
    @Binding var showsReadingHistory: Bool
    var onSiteChange: (GallerySite) -> Void = { _ in }
    var onClose: (() -> Void)? = nil
    var isSearchResults = false

    @EnvironmentObject private var session: SiteSession
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // One committed section identity: two separately published flags briefly
    // selected the underlying single-row feed during history → search.
    @State private var displayedLane: Int?
    private var activeLane: Int { displayedLane ?? (showsReadingHistory ? 2 : entry.query.hasSettings ? 3 : entry.lane) }
    private var showsSearchPage: Bool { activeLane == 3 }
    @State private var searchSubmitted = false
    @State private var lastSearch: DiscoveryEntry?
    @State private var started = false
    @State private var preparedSections: [Int: DiscoveryEntry] = [:]
    @State private var composerStart: SearchComposerStart?
    @State private var web: WebDestination?
    @StateObject private var batchSelection = LibrarySelectionStore()
    @State private var selecting = false

    private var entry: DiscoveryEntry { navigation.current }
    private var hasActiveConditions: Bool { entry.query.hasSettings }
    private var currentSaved: SavedSearch? {
        library.snapshot.saved.first { $0.id == entry.savedID && $0.query == entry.query && $0.site == entry.site }
    }
    private var filterConditionCount: Int { SearchPresentation.conditionCount(entry.query) }

    var body: some View {
        Group {
            if isSearchResults {
                feedLayout(lane: 3, active: true)
            } else {
                HeaderSectionPages(selection: laneBinding.wrappedValue,
                                   topInset: FeedChrome.headerClearance(twoRows: activeLane == 2 || activeLane == 3)) { lane, active in
                    if lane == 2 {
                        ReadingHistoryView(placement: .discovery(tabs: lanePicker), onClose: onClose)
                    } else { feedLayout(lane: lane, active: active) }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if selecting {
                LibraryBatchToolbar(source: .discover, summary: batchSelection.summary, galleries: {
                    entry.pager.items.filter { batchSelection.selectedIDs.contains($0.id) }
                })
            }
        }
        .exitMultiSelectionOnRightSwipe(selecting, action: { endSelection() })
        .headerSectionWillChange { endSelection() }
        .headerSectionPaging(selection: laneBinding, count: 4,
                             identifier: "discover.lane", enabled: composerStart == nil && !isSearchResults,
                             identity: entry.id, prepare: prepareSection)
        .toolbar(.hidden, for: .navigationBar)
        .officialWebPage(item: $web)
        .accessibilityHidden(composerStart != nil)
        .allowsHitTesting(composerStart == nil)
        .suppressPinnedChromePreferences(composerStart != nil)
        .overlay {
            if let composerStart {
                composerSheet(startAt: composerStart)
                .background(Palette.background.ignoresSafeArea())
                .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : ChromeMotion.replace, value: composerStart != nil)
        .onChange(of: session.hasCredentials) { _, value in if value { startCurrent() } }
        .onChange(of: entry.id) { _, _ in
            if !isSearchResults, entry.query.hasSettings {
                displayedLane = 3
                showsReadingHistory = false
                searchSubmitted = true
                lastSearch = entry
            }
            endSelection(resume: false)
        }
        .onChange(of: entry.site) { _, _ in preparedSections.removeAll() }
        .onChange(of: session.generation) { _, _ in
            preparedSections.removeAll()
            displayedLane = nil; searchSubmitted = false; lastSearch = nil
        }
        .onChange(of: showsReadingHistory) { _, history in
            if history { displayedLane = 2 }
            else if activeLane == 2 { displayedLane = entry.query.hasSettings ? 3 : entry.lane }
        }
        .onChange(of: library.blockedIDs) { _, _ in endSelection() }
        .task(id: entry.id) {
            if entry.query.hasSettings, !searchSubmitted {
                searchSubmitted = true; lastSearch = entry
            }
            if !entry.didStart && (AppMode.qa || session.hasCredentials || hasActiveConditions) { startCurrent() }
        }
    }

    private func sectionEntry(_ lane: Int) -> DiscoveryEntry? {
        if isSearchResults { return entry }
        if lane == 3 { return entry.query.hasSettings ? entry : lastSearch }
        if lane != laneBinding.wrappedValue, let prepared = preparedSections[lane] { return prepared }
        if entry.lane == lane && !entry.query.hasSettings { return entry }
        return preparedSections[lane]
    }

    private func prepareSection(_ lane: Int) {
        guard lane == 0 || lane == 1 else { return }
        do { preparedSections[lane] = try navigation.preparedEntry(query: SearchQuery(), site: entry.site, lane: lane) }
        catch { navigation.report(error) }
    }

    private func feedLayout(lane: Int, active: Bool) -> some View {
        let displayed = sectionEntry(lane)
        let retainsViewport = displayed?.scrollAnchor.map { $0 != displayed?.pager.items.first?.id } ?? false
        return FloatingFeedLayout(twoRows: !isSearchResults && lane == 3, retainsViewport: retainsViewport) { headerHeight in
            Group {
                if !isSearchResults && lane == 3 && lastSearch == nil && !searchSubmitted {
                    Color.clear.accessibilityIdentifier("discover.search.empty")
                } else if !session.hasCredentials && !AppMode.qa && !started && sectionEntry(lane)?.didStart != true {
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
                } else if let displayed = sectionEntry(lane) {
                    DiscoveryFeedView(entry: displayed, topInset: headerHeight, selectionStore: batchSelection, isSelecting: selecting,
                                      onLongPressSelect: beginSelection, onRefresh: { [id = displayed.id] in
                        guard active, navigation.current.id == id else { return }; await refreshCurrent()
                    }, isCurrent: { [id = displayed.id] in active && navigation.current.id == id })
                        .id(displayed.id)
                        .modifier(DiscoveryHistoryGesture(topInset: headerHeight,
                            excludesEdges: !displayed.query.hasSettings,
                            canGoBack: isSearchResults && !selecting && navigation.canGoBack,
                            canGoForward: isSearchResults && !selecting && navigation.canGoForward,
                            onBack: goBack, onForward: goForward))
                }
            }
        } header: { discoverFloatingHeader(lane: lane) }
    }

    @ViewBuilder private func discoverFloatingHeader(lane: Int) -> some View {
        if !isSearchResults && lane == 3 {
            FloatingTwoRowHeader(identifier: "discover.header.floating", transitionID: "discover",
                                 primaryLayout: "lanes", secondaryLayout: selecting ? "selection" : "search") {
                lanePicker
            } secondary: {
                if selecting {
                    LibraryBatchSelectionHeader(source: .discover, store: batchSelection, summary: batchSelection.summary) { endSelection() }
                } else {
                    searchEntryRow(row: .secondary)
                }
            }
        } else {
            FloatingHeaderPanel(identifier: "discover.header.floating",
                                transitionID: isSearchResults ? "search-results" : "discover",
                                contentID: "\(isSearchResults)-\(selecting)") {
                Group {
                    if selecting {
                        LibraryBatchSelectionHeader(source: .discover, store: batchSelection, summary: batchSelection.summary) { endSelection() }
                    } else if isSearchResults {
                        searchEntryRow(row: .single)
                    } else {
                        lanePicker
                    }
                }
                .environment(\.feedHeaderRow, .single)
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

    private func searchEntryRow(row: FeedHeaderRow) -> some View {
        let layout = !typeSize.isAccessibilitySize
            ? AnyLayout(FeedHeaderGrid(spans: isSearchResults ? [3, 1] : [1, 3]))
            : AnyLayout(HStackLayout(spacing: FeedChrome.panelSpacing))
        return layout {
            if !isSearchResults { searchShortcutGroup(row: row).disabled(selecting) }
            searchInputControls(row: row).disabled(selecting)
            if isSearchResults { commonSearchControl.disabled(selecting) }
        }
    }

    private func searchShortcutGroup(row: FeedHeaderRow) -> some View {
        let insets = FeedChrome.surfaceInsets(for: typeSize, row: row)
        let offset = FeedChrome.contentOffset(for: insets)
        return HStack(spacing: 0) {
            Button {
                if navigation.backToPreviousSearch() { resumeHistoryEntry() }
                else { onClose?() }
            } label: {
                Image(systemName: "chevron.left")
                    .offset(y: offset)
                    .frame(maxWidth: .infinity, minHeight: FeedChrome.rowHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!navigation.canGoBackToSearch && onClose == nil)
            .opacity(navigation.canGoBackToSearch || onClose != nil ? 1 : 0.38)
            .accessibilityLabel(navigation.canGoBackToSearch ? "返回上一搜索" : "返回来源")
            .accessibilityIdentifier("discover.previous-search")
            Divider().frame(height: 18).offset(y: offset)
            Button { composerStart = .favorites } label: {
                Image(systemName: "bookmark")
                    .offset(y: offset)
                    .frame(maxWidth: .infinity, minHeight: FeedChrome.rowHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("常用组合")
            .accessibilityIdentifier("discover.saved-menu")
        }
        .font(FeedChrome.labelFont)
        .imageScale(FeedChrome.iconScale)
        .foregroundStyle(.primary)
        .appControlSurface(insets: insets)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("discover.search-shortcuts")
    }

    private func shortcutLabel(_ title: String, symbol: String) -> some View {
        ViewThatFits(in: .horizontal) {
            if !typeSize.isAccessibilitySize {
                HStack(spacing: FeedChrome.iconLabelSpacing) {
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
            .imageScale(FeedChrome.iconScale)
            .frame(width: 16)
    }

    private func searchInputControls(row: FeedHeaderRow) -> some View {
        let insets = FeedChrome.surfaceInsets(for: typeSize, row: row)
        let contentOffset = FeedChrome.contentOffset(for: insets)
        let hasBack = isSearchResults && (navigation.canGoBack || onClose != nil)
        return HStack(spacing: 0) {
                Button {
                    if navigation.canGoBack { goBack() }
                    else { onClose?() }
                } label: { Image(systemName: "chevron.left") }
                .buttonStyle(FeedHeaderButtonStyle())
                .environment(\.pageHeaderAction, true)
                .frame(width: FeedChrome.pageActionWidth)
                .accessibilityLabel("返回").accessibilityIdentifier(onClose == nil ? "discover.back" : "search.results.close")
                .appContextMenu(enabled: navigation.canGoForward) {
                    AppMenuItem(title: "前进", systemImage: "chevron.right", action: goForward)
                }
                .opacity(hasBack ? 1 : 0)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.12).delay(hasBack ? 0.05 : 0), value: hasBack)
                .allowsHitTesting(hasBack)
                .accessibilityHidden(!hasBack)
                .frame(width: hasBack ? FeedChrome.pageActionWidth + FeedChrome.panelSpacing : 0, alignment: .leading)
                .clipped()
            HStack(spacing: 0) {
                Button { composerStart = .main } label: {
                    HStack(spacing: FeedChrome.controlSpacing) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        Text(SearchPresentation.headerTitle(entry.query, savedName: currentSaved?.name))
                            .lineLimit(1).truncationMode(.tail).foregroundStyle(hasActiveConditions ? .primary : .secondary)
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
            .imageScale(FeedChrome.iconScale)
            .appControlSurface(insets: insets)
        }
        .animation(reduceMotion ? nil : ChromeMotion.control, value: hasBack)
    }

    private var commonSearchControl: some View {
        Button { composerStart = .favorites } label: {
            shortcutLabel("常用", symbol: "bookmark")
        }
        .buttonStyle(FeedHeaderButtonStyle(truncatesLabel: true, expandsHorizontally: !typeSize.isAccessibilitySize))
        .accessibilityLabel("常用组合").accessibilityIdentifier("discover.saved-menu")
    }

    private var lanePicker: FeedScopePicker {
        FeedScopePicker(selection: laneBinding, options: [
            .init(id: 0, title: "最新", symbol: "clock"),
            .init(id: 1, title: "热门", symbol: "flame"),
            .init(id: 2, title: "历史", symbol: "clock.arrow.circlepath"),
            .init(id: 3, title: "搜索", symbol: "")
        ], identifier: "discover.lane", alignsToHeaderGrid: true,
           highlightsSelection: !isSearchResults)
    }

    private var laneBinding: Binding<Int> {
        Binding(get: { activeLane }, set: { lane in
            if showsSearchPage && searchSubmitted { lastSearch = entry }
            displayedLane = lane
            showsReadingHistory = lane == 2
            endSelection()
            if lane == 3 {
                searchSubmitted = lastSearch != nil
                if let lastSearch {
                    do {
                        try navigation.submit(query: lastSearch.query, site: lastSearch.site, lane: 0, savedID: lastSearch.savedID,
                                              session: session, qa: AppMode.qa, prepared: lastSearch)
                    } catch { navigation.report(error) }
                }
            } else if lane != 2, lane != entry.lane || hasActiveConditions {
                do {
                    try navigation.submit(query: SearchQuery(), site: entry.site, lane: lane, savedID: nil,
                                          session: session, qa: AppMode.qa, prepared: preparedSections[lane])
                    started = true
                    onSiteChange(navigation.current.site)
                } catch { navigation.report(error) }
            }
        })
    }

    private func composerSheet(startAt: SearchComposerStart) -> some View {
        DiscoveryComposerView(query: !isSearchResults && showsSearchPage && !searchSubmitted ? SearchQuery() : entry.query, site: entry.site,
                              startAt: startAt, loadedPreset: currentSaved, dismissesOnApply: false,
                              updatesResults: searchSubmitted || isSearchResults,
                              onCancel: { composerStart = nil }) { query, site, savedID in
            if AppMode.qa && ProcessInfo.processInfo.arguments.contains("--qa-reject-search-commit") {
                throw ViewerError.invalidQuery("QA: search destination rejected the action")
            }
            try navigation.execute(query: query, site: site, lane: 0, savedID: savedID, session: session, library: library)
            started = true
            showsReadingHistory = false
            if !isSearchResults {
                displayedLane = 3; searchSubmitted = true; lastSearch = navigation.current
            }
            onSiteChange(navigation.current.site)
            composerStart = nil
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

    private func refreshCurrent() async {
        entry.pager.reset(url: entry.requestURL, session: session, qa: AppMode.qa)
        await entry.pager.waitForLoad()
    }

}

private struct DiscoveryHistoryGesture: ViewModifier {
    let topInset: CGFloat
    let excludesEdges: Bool
    let canGoBack: Bool
    let canGoForward: Bool
    var onBack: () -> Void
    var onForward: () -> Void
    @State private var viewportWidth: CGFloat = 0
    @GestureState(resetTransaction: Transaction(animation: .easeOut(duration: 0.18))) private var drag: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .background {
                GeometryReader { geometry in
                    Color.clear.onAppear { viewportWidth = geometry.size.width }
                        .onChange(of: geometry.size.width) { _, width in viewportWidth = width }
                }
            }
            .simultaneousGesture(DragGesture(minimumDistance: 24, coordinateSpace: .local)
                .updating($drag) { value, state, _ in
                    guard acceptsStart(value.startLocation),
                          direction(value.translation) != nil else { return }
                    state = value.translation.width
                }
                .onEnded { value in
                    guard acceptsStart(value.startLocation),
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

    private func acceptsStart(_ point: CGPoint) -> Bool {
        guard point.y > topInset else { return false }
        return !excludesEdges || (point.x > HeaderSectionSwipePolicy.edgeWidth &&
                                  point.x < viewportWidth - HeaderSectionSwipePolicy.edgeWidth)
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
    var onRefresh: () async -> Void
    var isCurrent: () -> Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var session: SiteSession
    @EnvironmentObject private var library: LibraryStore
    @ObservedObject private var pager: GalleryPager
    @State private var restoring = true
    @StateObject private var pullRefresh = FeedPullRefresh()

    init(entry: DiscoveryEntry, topInset: CGFloat, selectionStore: LibrarySelectionStore, isSelecting: Bool,
         onLongPressSelect: @escaping (Gallery) -> Void, onRefresh: @escaping () async -> Void, isCurrent: @escaping () -> Bool) {
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
                if pager.interrupted && pager.items.isEmpty && !isSelecting {
                    GalleryContinuationFooter(pager: pager)
                }
                GalleryRows(galleries: pager.items,
                            sourceIdentity: entry.id.uuidString, selectionStore: selectionStore, isSelecting: isSelecting,
                            isLoading: pager.loading, loadFailure: pager.failure,
                            selectionIdentifier: "discover.select", onLongPressSelect: onLongPressSelect,
                            onNearEnd: { if !isSelecting && !restoring && isCurrent() && pager.failure == nil && !pager.interrupted { pager.more(session: session, prefetch: true) } },
                            viewport: .init(space: entry.id.uuidString, height: viewport.size.height, topOcclusion: topInset),
                            onVisibleAnchor: { if !restoring && isCurrent() { entry.updateVisibleAnchor($0) } })
                    .scrollTargetLayout()
                if !isSelecting && !pager.items.isEmpty { GalleryContinuationFooter(pager: pager) }
            }
            .background(alignment: .topLeading) {
                if AppMode.qa { ChromePositionQA(identifier: "discover.content.motion").frame(width: 1, height: 1) }
            }
            .padding(.top, topInset)
            .padding(.bottom, FeedChrome.sectionSpacing)
            .id("discover.section-top")
            .feedRefreshProbe(pullRefresh, enabled: !isSelecting && isCurrent())
        }
        .overlay {
            if !isSelecting { GalleryFeedStatus(pager: pager).padding(.top, topInset) }
        }
        .onHeaderReselection {
            guard isCurrent(), !isSelecting else { return }
            withAnimation(reduceMotion ? nil : ChromeMotion.control) { proxy.scrollTo("discover.section-top", anchor: .top) }
            await pullRefresh.refresh(enabled: isCurrent()) { await onRefresh() }
        }
        .coordinateSpace(name: entry.id.uuidString)
        .accessibilityIdentifier("discover.feed")
        .feedPullRefresh(pullRefresh, topInset: topInset, enabled: !isSelecting && isCurrent(), action: onRefresh)
        .contentMargins(.top, topInset, for: .scrollIndicators)
        .task(id: topInset) {
            guard restoring, topInset > 0 else { return }
            // Restore this pane while it is still incoming, before the selection commits.
            // This only moves its own scroll view; active-only callbacks below remain guarded.
            // A new feed must finish its initial placement before viewport
            // callbacks can save anchors or request another batch. Appends keep
            // the server's existing order and do not restart this restoration.
            let anchor = entry.scrollAnchor ?? pager.items.first?.id
            await Task.yield()
            guard !Task.isCancelled else { return }
            if let anchor {
                let viewport = GalleryFeedViewport(space: entry.id.uuidString, height: viewport.size.height, topOcclusion: topInset)
                let target = GalleryFeedViewport.restorationID(for: anchor)
                proxy.scrollTo(target, anchor: viewport.restorationAlignment)
                try? await Task.sleep(nanoseconds: 120_000_000)
                guard !Task.isCancelled else { return }
                proxy.scrollTo(target, anchor: viewport.restorationAlignment)
            }
            restoring = false
        }
          }
        }
        .task(id: entry.id) {
            if !entry.didStart { await pager.prepareCached(url: entry.requestURL, session: session, qa: AppMode.qa) }
        }
        .overlay(alignment: .topLeading) {
            if FeedCacheQA.isEnabled { FeedCacheQAStatus(pager: pager, lane: "discover") }
        }
    }
}
