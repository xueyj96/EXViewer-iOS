import XCTest
import ExViewerCore
@testable import ExViewer

@MainActor final class FavoriteBrowsingSessionTests: XCTestCase {
    func testRemountPreservesColumnAssignmentsAfterCoverRatiosResolve() {
        let memory = GalleryGridMemory()
        let source = "aa|ex:3:favorited"
        let ids = (0..<40).map { "ex:\($0)" }
        var initial = memory.placement(for: source)
        initial.update(ids: ids, aspects: [:])
        memory.update(initial, source: source)
        let resolved = Dictionary(uniqueKeysWithValues: ids.enumerated().map {
            ($0.element, $0.offset.isMultiple(of: 2) ? 0.5 : 2.0)
        })
        var remounted = memory.placement(for: source)
        remounted.update(ids: ids, aspects: resolved)
        XCTAssertEqual(remounted.columns, initial.columns)
        var repacked = GalleryGridPlacement()
        repacked.update(ids: ids, aspects: resolved)
        XCTAssertNotEqual(repacked.columns, initial.columns,
                          "Rebuilding the placement from resolved covers changes visible neighbors")
        XCTAssertTrue(memory.placement(for: "bb|ex:3:favorited").order.isEmpty)
        XCTAssertTrue(memory.placement(for: "aa|ex:4:favorited").order.isEmpty)
    }

    func testRemountReusesPagerCategoryAnchorAndRequestInsteadOfStartingNewSession() throws {
        var creations = 0
        let sessions = FavoriteBrowsingSessions {
            creations += 1
            return GalleryPager(loadHTML: { _, _, _ in "" })
        }
        let generation = UUID()
        let first = sessions.entry(owner: "aa", generation: generation, site: .ex)
        first.category = "7"
        first.visibleGalleryID = "ex:42"
        first.anchorAfterRemoval = "ex:43"
        first.requestedSource = FavoriteBrowsingRequest(url: try XCTUnwrap(SiteFavoriteOrder.favorited.url(site: .ex, category: "7")),
                                                       generation: generation, owner: "aa", favoritesRevision: UUID())
        first.seenRemovals = ["ex:41": UUID()]
        let remounted = sessions.entry(owner: "aa", generation: generation, site: .ex)
        XCTAssertTrue(first === remounted)
        XCTAssertTrue(first.pager === remounted.pager)
        XCTAssertEqual(remounted.category, "7")
        XCTAssertEqual(remounted.visibleGalleryID, "ex:42")
        XCTAssertEqual(remounted.anchorAfterRemoval, "ex:43")
        XCTAssertEqual(remounted.requestedSource, first.requestedSource)
        XCTAssertEqual(remounted.seenRemovals, first.seenRemovals)
        XCTAssertEqual(creations, 1)
    }

    func testSitesKeepSeparateBrowsingStateAndAccountsNeverReuseOldEntries() {
        let sessions = FavoriteBrowsingSessions()
        let generation = UUID()
        let ex = sessions.entry(owner: "aa", generation: generation, site: .ex)
        ex.category = "3"; ex.visibleGalleryID = "ex:99"
        let eh = sessions.entry(owner: "aa", generation: generation, site: .eh)
        XCTAssertFalse(ex === eh)
        XCTAssertEqual(eh.category, "all")
        XCTAssertNil(eh.visibleGalleryID)
        XCTAssertTrue(ex === sessions.entry(owner: "aa", generation: generation, site: .ex))
        let nextGeneration = UUID()
        let refreshed = sessions.entry(owner: "aa", generation: nextGeneration, site: .ex)
        XCTAssertFalse(ex === refreshed)
        XCTAssertEqual(refreshed.category, "all")
        sessions.retainScope(owner: "bb", generation: nextGeneration)
        let other = sessions.entry(owner: "bb", generation: nextGeneration, site: .ex)
        XCTAssertNil(other.visibleGalleryID)
        XCTAssertEqual(other.category, "all")
        XCTAssertFalse(ex === sessions.entry(owner: "aa", generation: generation, site: .ex),
                       "Pruning on account change must release the old account session")
    }
}
