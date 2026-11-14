import Foundation
import SwiftUI
import ExViewerCore

private struct CoveredGalleryContentKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    @Entry var detailSearchDepth = 0
    var coveredGalleryContent: Bool {
        get { self[CoveredGalleryContentKey.self] }
        set { self[CoveredGalleryContentKey.self] = newValue }
    }
}

/// Tag menus share four-character action captions and use no leading icons.
enum TagMenuTitle {
    static let newSearch = "新建搜索"
    static let addToSearch = "加入搜索"
    static let favorite = "加入常用"
    static let unfavorite = "移出常用"
    static let block = "屏蔽标签"
    static let unblock = "解除屏蔽"
}

/// The executed query of a particular results page.
struct ExecutedGallerySearch: Equatable {
    let query: SearchQuery
    let site: GallerySite

    var summary: String { SearchPresentation.conditions(query) }
}

/// Detail tags create a new executed search directly, or prepare additions to an existing query.
struct DetailTagSearchDraft: Identifiable {
    enum Origin: Equatable { case newSearch, currentSearch, discoverSearch }
    let id = UUID()
    let origin: Origin
    let query: SearchQuery
    let site: GallerySite
    let selectedCount: Int
    let addedTagIDs: Set<String>
    let sourceSummary: String?
    let originalExclusions: Set<String>

    var addedCount: Int { addedTagIDs.count }
    var navigationTitle: String {
        switch origin {
        case .newSearch: "新建搜索"
        case .currentSearch: "编辑当前搜索"
        case .discoverSearch: "编辑发现页搜索"
        }
    }

    static func newSearch(tags: [GalleryTag], site: GallerySite) -> Self {
        make(tags: tags, site: site, current: nil, origin: .newSearch)
    }

    static func adding(tags: [GalleryTag], to current: ExecutedGallerySearch, origin: Origin = .currentSearch) -> Self {
        make(tags: tags, site: current.site, current: current, origin: origin)
    }

    private static func make(tags: [GalleryTag], site: GallerySite, current: ExecutedGallerySearch?, origin: Origin) -> Self {
        var seen = Set<String>()
        let selected = tags.filter { !$0.name.isEmpty && seen.insert($0.id).inserted }
        var query = current?.query ?? SearchQuery()
        var represented = Set(query.rules.map(\.id))
        if !query.artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            represented.insert(GalleryTag(namespace: "artist", name: query.artist).id)
        }
        let exclusions = Set(query.rules.filter { $0.match == .exclude && seen.contains($0.id) }.map(\.id))
        var added = Set<String>()
        for tag in selected where represented.insert(tag.id).inserted {
            query.rules.append(.init(tag: tag))
            added.insert(tag.id)
        }
        return Self(origin: origin,
                    query: query, site: site, selectedCount: selected.count, addedTagIDs: added,
                    sourceSummary: current?.summary, originalExclusions: exclusions)
    }
}

/// A draft can only update the exact executed search it was composed against.
@MainActor struct DetailSearchTarget {
    let origin: DetailTagSearchDraft.Origin
    let search: ExecutedGallerySearch
    private let navigation: DiscoveryNavigation
    private let entryID: UUID
    private let generation: UUID
    private let showResults: (GallerySite) -> Void
    private(set) var closeParent: (() -> Void)?

    init?(navigation: DiscoveryNavigation, generation: UUID, origin: DetailTagSearchDraft.Origin,
          showResults: @escaping (GallerySite) -> Void) {
        let entry = navigation.current
        guard entry.didStart, entry.query.hasSettings else { return nil }
        self.navigation = navigation
        self.generation = generation
        self.origin = origin
        self.showResults = showResults
        entryID = entry.id
        search = .init(query: entry.query, site: entry.site)
    }

    var isCurrent: Bool { navigation.current.id == entryID }
    var menuTitle: String { TagMenuTitle.addToSearch }

    func leaving(_ close: @escaping () -> Void) -> Self {
        var target = self
        // The outer presentation can dismiss its entire child chain at once.
        if target.closeParent == nil { target.closeParent = close }
        return target
    }

    func update(query: SearchQuery, site: GallerySite, savedID: UUID?, session: SiteSession, library: LibraryStore) throws {
        guard isCurrent, session.generation == generation else {
            throw ViewerError.invalidQuery("搜索条件应用失败 请重试")
        }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        // Prepare the destination underneath the editor before it is dismissed.
        try withTransaction(transaction) {
            try navigation.execute(query: query, site: site, savedID: savedID, session: session, library: library)
            showResults(navigation.current.site)
        }
    }
}

struct DetailSearchRequest: Identifiable {
    let draft: DetailTagSearchDraft
    let generation: UUID
    var target: DetailSearchTarget? = nil
    var id: UUID { draft.id }
}

struct GalleryDetailPresentationActions {
    let search: (DetailSearchRequest) throws -> Void
    let read: (Gallery, DetailSearchTarget?, ReaderOpeningDetail?) -> Void
    let readOffline: (Gallery) -> Void
}

private struct GalleryDetailPresentationKey: EnvironmentKey {
    static let defaultValue: GalleryDetailPresentationActions? = nil
}

extension EnvironmentValues {
    var galleryDetailPresentation: GalleryDetailPresentationActions? {
        get { self[GalleryDetailPresentationKey.self] }
        set { self[GalleryDetailPresentationKey.self] = newValue }
    }
}

extension View {
    func galleryDetailPresentations(tab: Int? = nil, retainsSearchSource: Bool = false, onSearchVisibilityChange: ((Bool) -> Void)? = nil, onNewSearch: ((DetailSearchRequest) throws -> Void)? = nil) -> some View {
        modifier(GalleryDetailPresentations(tab: tab, retainsSearchSource: retainsSearchSource, onSearchVisibilityChange: onSearchVisibilityChange, onNewSearch: onNewSearch))
    }
}

/// Owns presentations outside the navigation path they can update.
private struct GalleryDetailPresentations: ViewModifier {
    private struct Reading: Identifiable {
        let id = UUID()
        let gallery: Gallery
        let target: DetailSearchTarget?
        let openingDetail: ReaderOpeningDetail?
        var offline = false
        var returnPreview: PageReturnPreview? = nil
    }

    let tab: Int?
    var retainsSearchSource: Bool
    var onSearchVisibilityChange: ((Bool) -> Void)?
    var onNewSearch: ((DetailSearchRequest) throws -> Void)? = nil
    @State private var search: DetailSearchRequest?
    @State private var reading: Reading?
    @StateObject private var returnSource = PageReturnPreviewSource()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.galleryDetailPresentation) private var parentPresentation
    @Environment(\.detailSearchDepth) private var searchDepth

    func body(content: Content) -> some View {
        let actions = GalleryDetailPresentationActions(
                search: { request in
                    guard request.target != nil || searchDepth < DiscoveryNavigation.historyLimit else {
                        throw ViewerError.invalidQuery("搜索层级过多 请先返回")
                    }
                    if request.target == nil, let onNewSearch {
                        try onNewSearch(request)
                        search = nil; reading = nil
                    } else if request.target == nil, !retainsSearchSource, let parentPresentation {
                        try parentPresentation.search(request)
                    } else { search = request }
                },
                read: { reading = Reading(gallery: $0, target: $1, openingDetail: $2, returnPreview: returnSource.capture()) },
                readOffline: { reading = Reading(gallery: $0, target: nil, openingDetail: nil, offline: true, returnPreview: returnSource.capture()) }
            )
        let base = content
            .environment(\.galleryDetailPresentation, actions)
            .environment(\.coveredGalleryContent, reading != nil || search != nil)
            .background { returnSource.probe }
            .environment(\.headerSectionSuspended, reading != nil || search != nil)
            .accessibilityHidden(reading != nil || (search != nil))
            .allowsHitTesting(search == nil)
            .suppressPinnedChromePreferences(search != nil)
            .hidePinnedChromeForReader(reading != nil)
            .fullScreenCover(item: $reading) { presentation in
                ReaderView(gallery: presentation.gallery, offline: presentation.offline, searchTarget: presentation.target?.leaving { reading = nil },
                           openingDetail: presentation.openingDetail, returnPreview: presentation.returnPreview)
                    .localPageChrome()
                    .environment(\.galleryDetailPresentation, actions)
                    .environment(\.coveredGalleryContent, false)
            }
        base
                .overlay {
                    if let search {
                        GallerySearchFlow(request: search, onClose: { self.search = nil })
                            .environment(\.galleryDetailPresentation, actions)
                            .environment(\.coveredGalleryContent, false)
                            .background(Color(uiColor: .systemBackground).ignoresSafeArea())
                            .transition(.move(edge: .trailing))
                    }
                }
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.23), value: search?.id)
                .onChange(of: tab) { _, _ in search = nil }
                .onChange(of: search?.id) { _, value in onSearchVisibilityChange?(value != nil) }
    }
}

struct GallerySearchFlow: View {
    let request: DetailSearchRequest
    var onClose: (() -> Void)? = nil
    var showsDetailOrigin = true
    @EnvironmentObject private var session: SiteSession
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.detailSearchDepth) private var searchDepth
    @State private var navigation: DiscoveryNavigation?
    @StateObject private var galleryRoutes = GalleryNavigation()
    @State private var showsReadingHistory = false
    @State private var closing = false
    @State private var visible = false
    @State private var visibilityRevision = UUID()

    init(request: DetailSearchRequest, onClose: (() -> Void)? = nil, showsDetailOrigin: Bool = true) {
        self.request = request
        self.onClose = onClose
        self.showsDetailOrigin = showsDetailOrigin
        // New-search is the user's execution action; only extending an existing query opens its editor.
        _navigation = State(initialValue: request.target == nil ? DiscoveryNavigation(query: request.draft.query, site: request.draft.site) : nil)
    }

    var body: some View {
        ZStack {
            if request.generation != session.generation || library.owner != session.owner {
                Color.clear.onAppear(perform: close)
            } else if let navigation {
                NavigationStack(path: $galleryRoutes.path) {
                    DiscoverView(navigation: navigation, showsReadingHistory: $showsReadingHistory, onClose: close)
                        .navigationDestination(for: Gallery.self) { gallery in
                            GalleryDetailView(gallery: gallery, searchTarget: DetailSearchTarget(
                                navigation: navigation, generation: session.generation, origin: .currentSearch
                            ) { _ in galleryRoutes.returnToList() })
                        }
                }
                .environment(\.galleryNavigation, galleryRoutes)
                .galleryDetailPresentations(retainsSearchSource: true)
                .transition(.opacity)
            } else {
                DiscoveryComposerView(query: request.draft.query, site: request.draft.site,
                                      detailTagSource: showsDetailOrigin ? request.draft : nil, dismissesOnApply: false,
                                      updatesResults: request.target != nil, onCancel: close, onApply: apply)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .topLeading) {
            if AppMode.qa {
                Text("QA").font(.system(size: 1)).frame(width: 1, height: 1)
                    .accessibilityIdentifier("search.flow.qa.\(searchDepth)")
                    .accessibilityValue("path=\(galleryRoutes.path.count);depth=\(searchDepth);query=\(navigation?.current.query.rules.count ?? 0)")
                    .allowsHitTesting(false)
            }
        }
        .environment(\.detailSearchDepth, searchDepth + 1)
        .appMenuHost(enabled: onClose == nil)
        .onDisappear {
            visible = false
            let revision = UUID()
            visibilityRevision = revision
            let leaving = navigation
            // Unmounting a SwiftUI subtree must not synchronously publish pager changes.
            // A quick return supersedes this deferred cancellation.
            Task { @MainActor in
                await Task.yield()
                guard !visible, visibilityRevision == revision else { return }
                leaving?.cancelLoading()
            }
        }
        .onAppear {
            visible = true
            let revision = UUID()
            visibilityRevision = revision
            Task { @MainActor in
                await Task.yield()
                guard visible, visibilityRevision == revision else { return }
                if let pager = navigation?.current.pager, pager.interrupted { pager.retry(session: session) }
            }
        }
    }

    private func close() {
        visible = false
        visibilityRevision = UUID()
        navigation?.cancelLoading()
        if let onClose { onClose() } else { dismiss() }
    }

    private func apply(_ query: SearchQuery, _ site: GallerySite, _ savedID: UUID?) throws {
        guard !closing, navigation == nil else { return }
        guard request.generation == session.generation, library.owner == session.owner else {
            throw ViewerError.invalidQuery("账号已切换 请重新打开搜索")
        }
        if let target = request.target {
            try target.update(query: query, site: site, savedID: savedID, session: session, library: library)
            closing = true
            if let closeParent = target.closeParent {
                closeParent()
                if onClose != nil { close() }
            } else {
                close()
            }
        } else {
            let results = DiscoveryNavigation(query: query, site: site, savedID: savedID)
            try results.execute(query: query, site: site, savedID: savedID, session: session, library: library)
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) { navigation = results }
        }
    }
}
