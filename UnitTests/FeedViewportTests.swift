import XCTest
import Combine
import ExViewerCore
import Observation
@testable import ExViewer

@MainActor final class FeedViewportTests: XCTestCase {
    func testUnchangedViewportStatusDoesNotPublishAnotherLayoutUpdate() async {
        let memory = FeedViewportMemory()
        let change = expectation(description: "Unchanged status does not invalidate the view")
        change.isInverted = true
        withObservationTracking {
            _ = memory.isAtTop; _ = memory.requiresRestore
        } onChange: { change.fulfill() }
        memory.capture(id: "a", offsetBelowHeader: 4, atTop: true)
        memory.capture(id: "a", offsetBelowHeader: 4, atTop: true)
        memory.finishRestore(revision: memory.revision)
        await fulfillment(of: [change], timeout: 0.02)
    }
    func testHistoryDataInvalidationFreezesAnchorBeforePublishingNewRows() {
        let store = HistoryBrowseStore()
        let state = store.state(owner: "a", entrance: .discovery, order: .recent)
        state.viewport.capture(id: "ex:1", offsetBelowHeader: -12, atTop: false)
        let previous = state.viewport.revision
        var before = LibrarySnapshot()
        before.history = [.init(gallery: .init(ref: .init(site: .ex, gid: 1, token: "qa"), title: "Alpha"), page: 1, date: .distantPast)]
        var after = before
        after.history.append(.init(gallery: .init(ref: .init(site: .ex, gid: 2, token: "qa"), title: "Beta"), page: 1, date: .now))
        store.historyWillChange(owner: "other", before: before, after: after)
        XCTAssertEqual(state.viewport.revision, previous)
        store.historyWillChange(owner: "a", before: before, after: after)
        XCTAssertNotEqual(state.viewport.revision, previous)
        XCTAssertEqual(state.viewport.bookmark, .init(id: "ex:1", offsetBelowHeader: -12))
        XCTAssertFalse(state.viewport.isAtTop)
        state.viewport.capture(id: "wrong", offsetBelowHeader: 10, atTop: false)
        XCTAssertEqual(state.viewport.bookmark?.id, "ex:1", "No row may replace the frozen anchor before restoration")
        state.viewport.finishRestore(revision: previous)
        XCTAssertTrue(state.viewport.requiresRestore)
        state.viewport.finishRestore(revision: state.viewport.revision)
        XCTAssertFalse(state.viewport.requiresRestore)
    }
    func testMetadataChangesInvalidateOnlyTheEntranceWhoseDisplayedOrderChanges() {
        let store = HistoryBrowseStore()
        let title = store.state(owner: "a", entrance: .discovery, order: .title)
        let recent = store.state(owner: "a", entrance: .library, order: .recent)
        var before = LibrarySnapshot()
        before.history = [1, 2].map { id in
            .init(gallery: .init(ref: .init(site: .ex, gid: Int64(id), token: "qa"), title: id == 1 ? "Alpha" : "Beta"),
                  page: 1, date: Date(timeIntervalSince1970: Double(id)))
        }
        var after = before; after.history[0].gallery.title = "Zulu"
        let titleRevision = title.viewport.revision, recentRevision = recent.viewport.revision
        store.historyWillChange(owner: "a", before: before, after: after)
        XCTAssertNotEqual(title.viewport.revision, titleRevision)
        XCTAssertEqual(recent.viewport.revision, recentRevision)
        let updated = title.viewport.revision
        var pageOnly = after; pageOnly.history[0].page = 2
        store.historyWillChange(owner: "a", before: after, after: pageOnly)
        XCTAssertEqual(title.viewport.revision, updated)
        XCTAssertEqual(recent.viewport.revision, recentRevision)
    }
    func testHistoryDistanceTracksIdentityAfterReorderAndVisibleFraction() {
        let memory = FeedViewportMemory()
        memory.reconcile(["a", "b", "c"])
        memory.capture(distance: FeedViewportMemory.rowStride + 25, ids: ["a", "b", "c"])
        XCTAssertEqual(memory.bookmark?.id, "b")
        XCTAssertEqual(memory.distance(in: ["c", "a", "b"]), FeedViewportMemory.rowStride * 2 + 25)
        memory.reconcile([])
        XCTAssertEqual(memory.distance(in: []), 0)
    }
    func testHistoryEntrancesKeepTheirOwnDraftAndAccountSwitchClearsNavigationState() {
        let store = HistoryBrowseStore()
        let discovery = store.state(owner: "a", entrance: .discovery, order: .recent)
        discovery.query = "sample"; discovery.period = .month; discovery.order = .title
        discovery.viewport.capture(id: "b", offsetBelowHeader: -24, atTop: false)
        let library = store.state(owner: "a", entrance: .library, order: .recent)
        XCTAssertEqual(library.query, ""); XCTAssertTrue(library.viewport.isAtTop)
        let restored = store.state(owner: "a", entrance: .discovery, order: .recent)
        XCTAssertTrue(restored === discovery)
        XCTAssertEqual(restored.query, "sample"); XCTAssertEqual(restored.period, .month)
        XCTAssertEqual(restored.order, .title)
        XCTAssertEqual(restored.viewport.bookmark, .init(id: "b", offsetBelowHeader: -24))
        let nextAccount = store.state(owner: "b", entrance: .discovery, order: .recent)
        XCTAssertFalse(nextAccount === discovery)
        XCTAssertEqual(nextAccount.query, ""); XCTAssertNil(nextAccount.viewport.bookmark)
    }
    func testRemovedHistoryAnchorUsesNextSurvivingNeighborAndResetClearsOffset() {
        let memory = FeedViewportMemory()
        memory.reconcile(["a", "b", "c", "d"])
        memory.capture(id: "b", offsetBelowHeader: -18, atTop: false)
        memory.reconcile(["d", "a", "c"])
        XCTAssertEqual(memory.bookmark, .init(id: "c", offsetBelowHeader: -18))
        memory.reconcile(["a"])
        XCTAssertEqual(memory.bookmark?.id, "a")
        let old = memory.revision
        memory.reset()
        XCTAssertNotEqual(memory.revision, old)
        XCTAssertTrue(memory.isAtTop); XCTAssertNil(memory.bookmark)
    }
    func testRecordReorderingPreservesTheSameVisibleWorkAndEmptyListReturnsToTop() {
        let memory = FeedViewportMemory()
        memory.reconcile(["a", "b", "c"])
        memory.capture(id: "b", offsetBelowHeader: 12, atTop: false)
        memory.reconcile(["c", "b", "a"])
        XCTAssertEqual(memory.bookmark, .init(id: "b", offsetBelowHeader: 12))
        memory.reconcile([])
        XCTAssertTrue(memory.isAtTop); XCTAssertNil(memory.bookmark)
    }
    func testEqualHeightColumnsAlwaysChooseTheSameAnchorRegardlessOfDictionaryOrder() {
        let viewport = GalleryFeedViewport(space: "qa", height: 800, topOcclusion: 120)
        let cells = [("right", CGRect(x: 200, y: 130, width: 180, height: 200)),
                     ("left", CGRect(x: 10, y: 130, width: 180, height: 300))]
        XCTAssertEqual(viewport.nearestVisibleAnchor(in: Dictionary(uniqueKeysWithValues: cells)), "left")
        XCTAssertEqual(viewport.nearestVisibleAnchor(in: Dictionary(uniqueKeysWithValues: cells.reversed())), "left")
    }

    func testAnchorExcludesCoveredAndOffscreenRowsAndPreservesMarkerAlignment() {
        let viewport = GalleryFeedViewport(space: "qa", height: 800, topOcclusion: 120)
        let cells = ["covered": CGRect(x: 0, y: 0, width: 100, height: 110),
                     "visible": CGRect(x: 0, y: 100, width: 100, height: 200),
                     "below": CGRect(x: 0, y: 801, width: 100, height: 200)]
        XCTAssertEqual(viewport.nearestVisibleAnchor(in: cells), "visible")
        XCTAssertEqual(viewport.restorationAlignment.y, 120 / 799.0, accuracy: 0.0001)
        XCTAssertNil(GalleryFeedViewport(space: "qa", height: 100, topOcclusion: 120).nearestVisibleAnchor(in: cells))
    }

    func testMasonryCoverLookaheadStartsAtEachVisibleColumnEdge() {
        func gallery(_ id: Int64) -> Gallery {
            Gallery(ref: GalleryRef(site: .ex, gid: id, token: "test"), title: "Sample")
        }
        let columns = [[1, 3, 5, 7, 9].map(gallery), [2, 4, 6, 8, 10].map(gallery)]
        let viewport = GalleryFeedViewport(space: "qa", height: 800, topOcclusion: 120)
        // Upcoming cards are intentionally missing from the measured frames:
        // the lazy columns need not have instantiated them yet.
        let frames = [
            "ex:1": CGRect(x: 20, y: 100, width: 165, height: 400),
            "ex:3": CGRect(x: 20, y: 520, width: 165, height: 450),
            "ex:2": CGRect(x: 201, y: 100, width: 165, height: 800),
        ]
        let edges = viewport.coverEdges(in: frames)
        XCTAssertEqual(edges.map(\.id), ["ex:3", "ex:2"])
        XCTAssertEqual(edges.flatMap { GalleryFeedViewport.upcomingCovers(after: $0.id, in: columns) }.map(\.id),
                       ["ex:5", "ex:7", "ex:9", "ex:4", "ex:6", "ex:8", "ex:10"])
        XCTAssertTrue(GalleryFeedViewport.upcomingCovers(after: "ex:9", in: columns).isEmpty)
    }

    func testCoverLookaheadIsBoundedAndSkipsTheVisibleCard() {
        let column = (1...1000).map { Gallery(ref: GalleryRef(site: .ex, gid: Int64($0), token: "test"), title: "Sample") }
        let next = GalleryFeedViewport.upcomingCovers(after: "ex:20", in: [column])
        XCTAssertEqual(next.map(\.ref.gid), [21, 22, 23, 24, 25, 26])
        XCTAssertEqual(next.count, GalleryFeedViewport.coverLookaheadPerColumn)
        XCTAssertTrue(GalleryFeedViewport.upcomingCovers(after: "missing", in: [column]).isEmpty)
        XCTAssertEqual(GalleryFeedViewport.upcomingCovers(after: "ex:999", in: [column]).count, 1)
    }

    func testRepeatedViewportFramesPublishOnlyActualAnchorTransitions() throws {
        let anchors = (0..<240).map { "ex:\($0 / 40 + 1)" }
        func entry() -> DiscoveryEntry {
            .init(query: SearchQuery(), site: .ex, lane: 0, savedID: nil, requestURL: GallerySite.ex.baseURL)
        }
        let before = entry(), after = entry()
        var directEvents = 0, deduplicatedEvents = 0
        let oldSubscription = before.objectWillChange.sink { directEvents += 1 }
        let newSubscription = after.objectWillChange.sink { deduplicatedEvents += 1 }
        for anchor in anchors { before.scrollAnchor = anchor; after.updateVisibleAnchor(anchor) }
        XCTAssertEqual(directEvents, 240)
        XCTAssertEqual(deduplicatedEvents, 6)
        XCTAssertEqual(before.scrollAnchor, after.scrollAnchor)
        withExtendedLifetime((oldSubscription, newSubscription)) {}
        let data = try JSONSerialization.data(withJSONObject: ["viewport_frames": anchors.count, "direct_publications": directEvents, "deduplicated_publications": deduplicatedEvents, "same_latest_anchor": before.scrollAnchor == after.scrollAnchor], options: .prettyPrinted)
        let evidence = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        evidence.name = "feed-anchor-publication-comparison"; evidence.lifetime = .keepAlways; add(evidence)
    }
    func testCoverWindowIgnoresLazyConstructionAndRetainsOnlyNearbyCards() {
        let column = (1...30).map { Gallery(ref: GalleryRef(site: .ex, gid: Int64($0), token: "qa"), title: "Sample") }
        let viewport = GalleryFeedViewport(space: "qa", height: 800, topOcclusion: 100)
        // Even if SwiftUI reports all thirty constructed rows, only rows 10-11
        // intersect the viewport. Rows far above/below must not fetch covers.
        let frames = Dictionary(uniqueKeysWithValues: column.enumerated().map { index, gallery in
            (gallery.id, CGRect(x: 0, y: 100 + (index - 9) * 400, width: 180, height: 390))
        })
        let window = viewport.coverWindow(in: frames, columns: [column])
        XCTAssertEqual(window.visible, ["ex:10", "ex:11"])
        XCTAssertEqual(window.nearby, Set([8, 9, 12, 13, 14, 15, 16, 17].map { "ex:\($0)" }))
        XCTAssertEqual(window.priority(for: "ex:10"), .thumbnail)
        XCTAssertEqual(window.priority(for: "ex:12"), .thumbnailPrefetch)
        XCTAssertNil(window.priority(for: "ex:1"))
        XCTAssertNil(window.priority(for: "ex:30"))
    }

    func testFastScrollAndReverseReplaceCoverWindowWithoutRetainingDistantRequests() {
        let column = (1...40).map { Gallery(ref: GalleryRef(site: .ex, gid: Int64($0), token: "qa"), title: "Sample") }
        let viewport = GalleryFeedViewport(space: "qa", height: 800, topOcclusion: 100)
        func window(top: Int) -> GalleryFeedViewport.CoverWindow {
            let frames = Dictionary(uniqueKeysWithValues: column.enumerated().map { index, gallery in
                (gallery.id, CGRect(x: 0, y: 100 + (index + 1 - top) * 400, width: 180, height: 390))
            })
            return viewport.coverWindow(in: frames, columns: [column])
        }
        let initial = window(top: 1), advanced = window(top: 20), reversed = window(top: 18)
        XCTAssertEqual(initial.priority(for: "ex:2"), .thumbnail)
        XCTAssertNil(advanced.priority(for: "ex:2"))
        XCTAssertEqual(advanced.priority(for: "ex:18"), .thumbnailPrefetch)
        XCTAssertEqual(reversed.priority(for: "ex:18"), .thumbnail)
        XCTAssertEqual(reversed.priority(for: "ex:20"), .thumbnailPrefetch)
        XCTAssertLessThanOrEqual(advanced.visible.count + advanced.nearby.count, 10)
    }

}
