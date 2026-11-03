import Foundation
import ExViewerCore

/// A value snapshot of the executed Discover query, never an in-progress editor.
struct ExecutedGallerySearch: Equatable {
    let query: SearchQuery
    let site: GallerySite

    var summary: String { SearchPresentation.conditions(query) }
}

/// Selecting detail tags only prepares a draft. Submission remains the existing
/// composer's explicit Search action, including when an old query is extended.
struct DetailTagSearchDraft: Identifiable {
    enum Origin: Equatable { case newSearch, currentSearch }
    let id = UUID()
    let origin: Origin
    let query: SearchQuery
    let site: GallerySite
    let selectedCount: Int
    let addedCount: Int
    let sourceSummary: String?
    let originalExclusions: Set<String>

    var navigationTitle: String { origin == .newSearch ? "新建搜索" : "编辑当前搜索" }
    var statusTitle: String { origin == .newSearch ? "已载入所选标签" : "已加入当前搜索" }

    static func newSearch(tags: [GalleryTag], site: GallerySite) -> Self {
        make(tags: tags, site: site, current: nil)
    }

    static func adding(tags: [GalleryTag], to current: ExecutedGallerySearch) -> Self {
        make(tags: tags, site: current.site, current: current)
    }

    private static func make(tags: [GalleryTag], site: GallerySite, current: ExecutedGallerySearch?) -> Self {
        var seen = Set<String>()
        let selected = tags.filter { !$0.name.isEmpty && seen.insert($0.id).inserted }
        var query = current?.query ?? SearchQuery()
        var represented = Set(query.rules.map(\.id))
        if !query.artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            represented.insert(GalleryTag(namespace: "artist", name: query.artist).id)
        }
        let exclusions = Set(query.rules.filter { $0.match == .exclude && seen.contains($0.id) }.map(\.id))
        var added = 0
        for tag in selected where represented.insert(tag.id).inserted {
            query.rules.append(.init(tag: tag)); added += 1
        }
        return Self(origin: current == nil ? .newSearch : .currentSearch,
                    query: query, site: site, selectedCount: selected.count, addedCount: added,
                    sourceSummary: current?.summary, originalExclusions: exclusions)
    }
}
