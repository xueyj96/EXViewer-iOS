import Foundation
import Combine
import ExViewerCore

struct FavoriteBrowsingKey: Hashable {
    let owner: String
    let generation: UUID
    let site: GallerySite
}

struct FavoriteBrowsingRequest: Equatable {
    let url: URL
    let generation: UUID
    let owner: String
    let favoritesRevision: UUID
}

/// A library-owned browsing session outlives the mounted section pane. Only
/// browsing state is retained; selection, dialogs and transfers stay view-local.
@MainActor final class FavoriteBrowsingSession: ObservableObject, Identifiable {
    let id = UUID()
    let key: FavoriteBrowsingKey
    let pager: GalleryPager
    let gridMemory = GalleryGridMemory()
    @Published var category = "all"
    @Published var anchorAfterRemoval: String?
    var visibleGalleryID: String?
    var requestedSource: FavoriteBrowsingRequest?
    var seenRemovals: [String: UUID] = [:]

    init(key: FavoriteBrowsingKey, pager: GalleryPager) {
        self.key = key
        self.pager = pager
    }
}

@MainActor final class FavoriteBrowsingSessions: ObservableObject {
    private var entries: [FavoriteBrowsingKey: FavoriteBrowsingSession] = [:]
    private let makePager: @MainActor () -> GalleryPager

    init(makePager: (@MainActor () -> GalleryPager)? = nil) {
        self.makePager = makePager ?? { GalleryPager() }
    }

    func entry(owner: String, generation: UUID, site: GallerySite) -> FavoriteBrowsingSession {
        let key = FavoriteBrowsingKey(owner: owner, generation: generation, site: site)
        if let existing = entries[key] { return existing }
        let created = FavoriteBrowsingSession(key: key, pager: makePager())
        entries[key] = created
        return created
    }

    /// Called from view lifecycle, rather than cancelling observed pagers while
    /// SwiftUI is constructing an incoming pane. At rest there are at most two.
    func retainScope(owner: String, generation: UUID) {
        for key in Array(entries.keys) where key.owner != owner || key.generation != generation {
            entries.removeValue(forKey: key)?.pager.cancel()
        }
    }
}
