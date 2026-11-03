import SwiftUI
import ExViewerCore

struct DiscoverView: View {
    @Binding var query: SearchQuery
    @Binding var site: GallerySite
    @Binding var editingSaved: UUID?
    var onSearchQuery: (SearchQuery, GallerySite) -> Void
    var runRevision: UUID? = nil

    @EnvironmentObject private var session: SiteSession
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dynamicTypeSize) private var typeSize
    @StateObject private var navigation: DiscoveryNavigation
    @State private var started = false
    @State private var composing = false
    @State private var composerStart: SearchComposerStart = .main
    @State private var historyShowing = false
    @State private var error: String?
    @State private var web: WebDestination?

    init(query: Binding<SearchQuery>, site: Binding<GallerySite>, editingSaved: Binding<UUID?>, runRevision: UUID? = nil,
         onSearchQuery: @escaping (SearchQuery, GallerySite) -> Void = { _, _ in }) {
        _query = query; _site = site; _editingSaved = editingSaved; self.runRevision = runRevision
        self.onSearchQuery = onSearchQuery
        _navigation = StateObject(wrappedValue: DiscoveryNavigation(query: query.wrappedValue, site: site.wrappedValue, lane: 0, savedID: editingSaved.wrappedValue))
    }

    private var entry: DiscoveryEntry { navigation.current }
    private var hasActiveConditions: Bool { entry.query.hasSettings }
    private var currentSaved: SavedSearch? {
        library.snapshot.saved.first { $0.id == entry.savedID && $0.query == entry.query && $0.site == entry.site }
    }
    private var headerDetails: String { SearchPresentation.headerDetails(entry.query) }

    var body: some View {
        FloatingFeedLayout { headerHeight in
            Group {
                if !session.hasCredentials && !AppMode.qa && !started {
                    VStack {
                        Spacer()
                        VStack(alignment: .leading, spacing: 18) {
                            Image(systemName: "books.vertical").font(.system(size: 40, weight: .ultraLight)).foregroundStyle(Palette.accent)
                            Text("发现画廊").font(.title2.weight(.medium))
                            Text("登录自己的站点账号，或以访客身份开始浏览。")
                                .font(.subheadline).foregroundStyle(.secondary)
                            Button("登录站点账号") { web = .login }.buttonStyle(AppActionButtonStyle(tone: .accent))
                            Button("开始浏览") { startCurrent() }.font(.subheadline)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(24)
                        Spacer()
                    }
                } else {
                    DiscoveryFeedView(entry: entry, topInset: headerHeight, onRefresh: { [id = entry.id] in
                        guard navigation.current.id == id else { return }; refreshCurrent()
                    }, isCurrent: { [id = entry.id] in navigation.current.id == id })
                        .id(entry.id)
                        .environmentObject(session)
                        .environmentObject(library)
                        .modifier(DiscoveryHistoryGesture(topInset: headerHeight,
                                                         canGoBack: navigation.canGoBack, canGoForward: navigation.canGoForward,
                                                         onBack: goBack, onForward: goForward))
                }
            }
        } header: {
            discoverFloatingHeader
        }
        .toolbar(.hidden, for: .navigationBar)
        .sheet(item: $web) { OfficialWebView(destination: $0) }
        .sheet(isPresented: $historyShowing) {
            NavigationStack {
                ReadingHistoryView().navigationDestination(for: Gallery.self) { gallery in
                    GalleryDetailView(gallery: gallery, currentSearch: entry.query.hasSettings ? .init(query: entry.query, site: entry.site) : nil) { query, site in
                        historyShowing = false; onSearchQuery(query, site)
                    }
                }
            }
        }
        .onChange(of: runRevision) { oldValue, newValue in
            guard oldValue != newValue else { return }
            do {
                _ = try navigation.submit(query: query, site: site, lane: entry.lane, savedID: editingSaved, session: session, qa: AppMode.qa)
                started = true
                publish(navigation.current)
                library.recordSearch(query: navigation.current.query, site: navigation.current.site)
                error = nil
            } catch { self.error = message(for: error) }
        }
        .onChange(of: session.hasCredentials) { _, value in if value { startCurrent() } }
        .task {
            guard !started && (AppMode.qa || session.hasCredentials || query.count > 0) else { return }
            if query == entry.query && site == entry.site && editingSaved == entry.savedID { startCurrent() }
            else {
                do {
                    _ = try navigation.submit(query: query, site: site, lane: entry.lane, savedID: editingSaved, session: session, qa: AppMode.qa)
                    started = true; publish(navigation.current)
                    library.recordSearch(query: navigation.current.query, site: navigation.current.site)
                } catch { self.error = message(for: error) }
            }
        }
    }

    private var discoverFloatingHeader: some View {
        FloatingHeaderPanel {
            VStack(spacing: 0) {
                if let error { StatusMessage(title: error) }
                searchEntryRow
                HStack(spacing: 8) {
                    if hasActiveConditions { conditionSummary }
                    else { lanePicker }
                    commonSearchControl
                }
            }
            .floatingHeaderSurface()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("discover.header.floating")
    }

    private var searchEntryRow: some View {
        HStack(spacing: 0) {
            if navigation.canGoBack {
                Button(action: goBack) {
                    Image(systemName: "chevron.left")
                        .font(.body.weight(.medium))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("返回")
                .accessibilityIdentifier("discover.back")
                .contextMenu {
                    if navigation.canGoForward { Button("前进", systemImage: "chevron.right", action: goForward) }
                }
            }
            Button { composerStart = .main; composing = true } label: {
                HStack(spacing: 9) {
                    Image(systemName: "magnifyingglass").font(.body).foregroundStyle(.secondary)
                    Text(SearchPresentation.headerTitle(entry.query, savedName: currentSaved?.name))
                        .font(.subheadline).lineLimit(1).foregroundStyle(hasActiveConditions ? .primary : .secondary)
                    Spacer(minLength: 0)
                }.padding(.leading, 12).padding(.trailing, 8).frame(minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(hasActiveConditions ? "编辑搜索条件" : "搜索关键词、标签与条件")
            .accessibilityValue(hasActiveConditions ? SearchPresentation.conditions(entry.query) : "")
            .accessibilityIdentifier("discover.search-entry")
            Divider().frame(height: 18)
            Button { composerStart = .filters; composing = true } label: {
                Image(systemName: "slider.horizontal.3").font(.body)
                    .frame(width: 44, height: 44).contentShape(Rectangle())
                    .overlay(alignment: .topTrailing) {
                        if entry.query.count > 0 {
                            Text(String(entry.query.count)).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)
                                .padding(2).background(Color.accentColor, in: Circle()).offset(x: -3, y: 5)
                        }
                    }
            }.buttonStyle(.plain)
            .accessibilityLabel("搜索筛选条件")
            .accessibilityValue("\(entry.query.count) 项条件")
            .accessibilityIdentifier("discover.filters")
            Button { historyShowing = true } label: {
                Image(systemName: "clock").font(.body).frame(width: 44, height: 44).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("阅读历史").accessibilityIdentifier("discover.history")
        }
        .appControlSurface(verticalInset: typeSize.isAccessibilitySize ? 0 : 5)
        .sheet(isPresented: $composing) { composerSheet }
    }

    private var commonSearchControl: some View {
        Button { composerStart = .favorites; composing = true } label: {
            Label("常用", systemImage: "bookmark").labelStyle(.titleAndIcon)
        }
        .buttonStyle(FeedHeaderButtonStyle()).foregroundStyle(Color.accentColor)
        .accessibilityLabel("常用组合").accessibilityIdentifier("discover.saved-menu")
    }

    private var conditionSummary: some View {
        Button { composerStart = .filters; composing = true } label: {
            HStack(spacing: 5) {
                Image(systemName: "line.3.horizontal.decrease").font(.subheadline).accessibilityHidden(true)
                Text(headerDetails).font(.subheadline.weight(.medium)).lineLimit(1)
                Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).accessibilityHidden(true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
            .appControlSurface(verticalInset: typeSize.isAccessibilitySize ? 0 : 6)
        }
        .buttonStyle(.plain).foregroundStyle(.primary)
        .accessibilityLabel("当前筛选条件").accessibilityValue(SearchPresentation.conditions(entry.query))
        .accessibilityIdentifier("discover.condition-summary")
    }

    private var lanePicker: some View {
        FeedScopePicker(selection: laneBinding, options: [.init(id: 0, title: "最新", symbol: "clock"), .init(id: 1, title: "热门", symbol: "flame")], identifier: "discover.lane")
    }

    private var laneBinding: Binding<Int> {
        Binding(get: { entry.lane }, set: { lane in submit(entry.query, site: entry.site, lane: lane, savedID: entry.savedID) })
    }

    private var composerSheet: some View {
        return DiscoveryComposerView(query: entry.query, site: entry.site, savedID: currentSaved?.id,
                                     startAt: composerStart, loadedPreset: currentSaved) { query, site, savedID in
            _ = try navigation.submit(query: query, site: site, lane: entry.lane, savedID: savedID, session: session, qa: AppMode.qa)
            started = true
            publish(navigation.current)
            library.recordSearch(query: navigation.current.query, site: navigation.current.site)
            error = nil
        }
        .environmentObject(library)
        .dynamicTypeSize(typeSize)
    }

    private func startCurrent() {
        do {
            let isFirstExecution = !entry.didStart
            try navigation.startCurrent(session: session, qa: AppMode.qa)
            if isFirstExecution { library.recordSearch(query: entry.query, site: entry.site) }
            started = true; error = nil
        } catch { self.error = message(for: error) }
    }

    private func submit(_ query: SearchQuery, site: GallerySite, lane: Int, savedID: UUID?) {
        do {
            _ = try navigation.submit(query: query, site: site, lane: lane, savedID: savedID, session: session, qa: AppMode.qa)
            started = true; publish(navigation.current); error = nil
            library.recordSearch(query: navigation.current.query, site: navigation.current.site)
        } catch { self.error = message(for: error) }
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
        publish(navigation.current)
        startCurrent()
        if entry.pager.interrupted { entry.pager.retry(session: session) }
    }

    private func publish(_ value: DiscoveryEntry) {
        query = value.query; site = value.site; editingSaved = value.savedID
    }

    private func refreshCurrent() {
        entry.pager.reset(url: entry.requestURL, session: session, qa: AppMode.qa)
    }

    private func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? (error as? ViewerError)?.localizedDescription ?? "搜索条件无效"
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
    var onRefresh: () -> Void
    var isCurrent: () -> Bool
    @EnvironmentObject private var session: SiteSession
    @EnvironmentObject private var library: LibraryStore
    @ObservedObject private var pager: GalleryPager
    @State private var restoring = true

    init(entry: DiscoveryEntry, topInset: CGFloat, onRefresh: @escaping () -> Void, isCurrent: @escaping () -> Bool) {
        self.entry = entry; self.topInset = topInset; self.onRefresh = onRefresh; self.isCurrent = isCurrent
        _pager = ObservedObject(wrappedValue: entry.pager)
    }

    var body: some View {
        GeometryReader { viewport in
          ScrollViewReader { proxy in
           ScrollView {
            LazyVStack(spacing: 0) {
                if pager.interrupted {
                    StatusMessage(title: "已暂停之前的加载，可重试继续。") { pager.retry(session: session) }
                }
                GalleryRows(galleries: pager.items, layout: .grid, sourceIdentity: entry.id.uuidString,
                            onNearEnd: { if !restoring && isCurrent() && pager.failure == nil && !pager.interrupted { pager.more(session: session, prefetch: true) } },
                            viewport: .init(space: entry.id.uuidString, height: viewport.size.height, topOcclusion: topInset),
                            onVisibleAnchor: { if !restoring && isCurrent() { entry.updateVisibleAnchor($0) } })
                    .scrollTargetLayout()
                GalleryContinuationFooter(pager: pager)
                if !pager.loading && pager.failure == nil && pager.items.isEmpty && !pager.interrupted {
                    StatusMessage(title: entry.query.count > 0 ? "当前组合没有结果，可调整筛选条件。" : "当前范围没有结果。", symbol: entry.query.count > 0 ? "magnifyingglass" : "tray")
                }
            }
            .padding(.top, topInset)
        }
        .coordinateSpace(name: entry.id.uuidString)
        .accessibilityIdentifier("discover.feed")
        .refreshable(action: onRefresh)
        .contentMargins(.top, topInset, for: .scrollIndicators)
        .task(id: topInset) {
            restoring = true
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
