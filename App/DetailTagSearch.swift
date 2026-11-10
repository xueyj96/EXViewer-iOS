import Foundation
import SwiftUI
import ExViewerCore

/// The executed query of a particular results page.
struct ExecutedGallerySearch: Equatable {
    let query: SearchQuery
    let site: GallerySite

    var summary: String { SearchPresentation.conditions(query) }
}

/// Selecting detail tags only prepares a draft. Submission remains the existing
/// composer's explicit Search action, including when an old query is extended.
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
    var statusTitle: String {
        switch origin {
        case .newSearch: "已载入所选标签"
        case .currentSearch: "已加入当前搜索"
        case .discoverSearch: "已加入发现页搜索"
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
    var menuTitle: String { origin == .discoverSearch ? "加入发现页搜索" : "加入当前搜索" }

    func leaving(_ close: @escaping () -> Void) -> Self {
        var target = self
        // The outer presentation can dismiss its entire child chain at once.
        if target.closeParent == nil { target.closeParent = close }
        return target
    }

    func update(query: SearchQuery, site: GallerySite, savedID: UUID?, session: SiteSession, library: LibraryStore) throws {
        guard isCurrent, session.generation == generation else {
            throw ViewerError.invalidQuery("目标搜索已变化，请重新打开条件。")
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
    let search: (DetailSearchRequest) -> Void
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
    func galleryDetailPresentations(inlineSearch: Bool = false, tab: Int? = nil) -> some View {
        modifier(GalleryDetailPresentations(inlineSearch: inlineSearch, tab: tab))
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
    }

    let inlineSearch: Bool
    let tab: Int?
    @State private var search: DetailSearchRequest?
    @State private var reading: Reading?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let base = content
            .environment(\.galleryDetailPresentation, .init(
                search: { search = $0 },
                read: { reading = Reading(gallery: $0, target: $1, openingDetail: $2) },
                readOffline: { reading = Reading(gallery: $0, target: nil, openingDetail: nil, offline: true) }
            ))
            .accessibilityHidden(reading != nil || (inlineSearch && search != nil))
            .allowsHitTesting(!inlineSearch || search == nil)
            .suppressPinnedChromePreferences(inlineSearch && search != nil)
            .hidePinnedChromeForReader(reading != nil)
            .fullScreenCover(item: $reading) { presentation in
                ReaderView(gallery: presentation.gallery, offline: presentation.offline, searchTarget: presentation.target?.leaving { reading = nil },
                           openingDetail: presentation.openingDetail)
                    .localPageChrome()
            }
        if inlineSearch {
            base
                .overlay {
                    if let search {
                        DetailSearchFlow(request: search, onClose: { self.search = nil })
                            .background(Color(uiColor: .systemBackground).ignoresSafeArea())
                            .transition(.move(edge: .trailing))
                    }
                }
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.23), value: search?.id)
                .onChange(of: tab) { _, _ in search = nil }
        } else {
            base.fullScreenCover(item: $search) { DetailSearchFlow(request: $0) }
        }
    }
}

private struct DetailSearchFlow: View {
    let request: DetailSearchRequest
    var onClose: (() -> Void)? = nil
    @EnvironmentObject private var session: SiteSession
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var navigation: DiscoveryNavigation?
    @State private var path = NavigationPath()
    @State private var closing = false

    var body: some View {
        ZStack {
            if let navigation {
                NavigationStack(path: $path) {
                    DiscoverView(navigation: navigation, showsReadingHistory: .constant(false), onClose: close)
                        .navigationDestination(for: Gallery.self) { gallery in
                            GalleryDetailView(gallery: gallery, searchTarget: DetailSearchTarget(
                                navigation: navigation, generation: session.generation, origin: .currentSearch
                            ) { _ in path = NavigationPath() })
                        }
                }
                .galleryDetailPresentations(inlineSearch: onClose != nil)
                .transition(.opacity)
            } else {
                DiscoveryComposerView(query: request.draft.query, site: request.draft.site, savedID: nil,
                                      detailTagSource: request.draft, dismissesOnApply: false,
                                      updatesResults: request.target != nil, onCancel: close, onApply: apply)
                    .transition(.opacity)
            }
        }
        .onDisappear { navigation?.cancelLoading() }
        .onAppear {
            if let pager = navigation?.current.pager, pager.interrupted { pager.retry(session: session) }
        }
    }

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }

    private func apply(_ query: SearchQuery, _ site: GallerySite, _ savedID: UUID?) throws {
        guard !closing, navigation == nil else { return }
        guard request.generation == session.generation, library.owner == session.owner else {
            throw ViewerError.invalidQuery("账号已切换，请重新打开搜索。")
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
