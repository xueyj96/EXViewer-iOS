import XCTest
import ExViewerCore
@testable import ExViewer

@MainActor final class GalleryPagerTests: XCTestCase {
    private func list(count: Int, start: Int = 1) -> String {
        "<div class='itg'><table>" + (start..<(start + count)).map {
            "<tr><td><a href='/g/\($0)/abcdef/'><div class='glink'>Neutral \($0)</div></a></td></tr>"
        }.joined() + "</table></div>"
    }

    private func metadata(_ data: Data, ratings: [Int: String]? = nil) throws -> String {
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let pairs = try XCTUnwrap(request["gidlist"] as? [[Any]])
        let values: [[String: Any]] = try pairs.map { pair in
            let gid = try XCTUnwrap(pair.first as? Int)
            var value: [String: Any] = ["gid": gid, "title": "Enriched \(gid)", "filecount": "10", "tags": ["language:english"]]
            if let rating = ratings?[gid] { value["rating"] = rating }
            return value
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: ["gmetadata": values]), as: UTF8.self)
    }

    private func waitUntil(timeout: TimeInterval = 6, _ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !condition(), Date() < end { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(condition())
    }

    func testLaunchSnapshotWaitsForCoverPreparationWithoutBlockingCurrentList() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("launch-covers-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = FeedSnapshotCache(root: directory), session = SiteSession(qa: true)
        let root = GallerySite.ex.baseURL
        let old = Gallery(ref: .init(site: .ex, gid: 1, token: "abcdef"), title: "Cached first screen")
        await cache.save(.init(owner: session.owner, root: root, items: [old], next: nil, categories: [:]), expectedEpoch: 0)
        var started = false, release = false
        let pager = GalleryPager(loadHTML: { _, search, body in
            if search { return self.list(count: 1, start: 100) }
            return try self.metadata(XCTUnwrap(body))
        }, cache: cache, prepareSnapshotCovers: { _, _ in
            started = true
            while !release {
                if Task.isCancelled { return false }
                try? await Task.sleep(for: .milliseconds(5))
            }
            return true
        })
        defer { release = true; pager.cancel() }
        pager.reset(url: root, session: session, preserveCachedPresentation: true)
        await pager.waitForLoad()
        try await waitUntil { started }
        XCTAssertFalse(pager.loading, "Image preparation must not block pagination or current rows")
        XCTAssertEqual(pager.items.first?.ref.gid, 1)
        let before = await cache.read(owner: session.owner, url: root)
        XCTAssertEqual(before?.items.first?.ref.gid, 1, "A restart during preparation keeps the complete old snapshot")
        release = true
        var saved: FeedSnapshot?
        for _ in 0..<100 {
            saved = await cache.read(owner: session.owner, url: root)
            if saved?.items.first?.ref.gid == 100 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(saved?.items.first?.ref.gid, 100)
        XCTAssertEqual(pager.items.first?.ref.gid, 1, "Background validation must not replace the live presentation")
    }

    func testFailedOrCancelledCoverPreparationPreservesPreviousLaunchSnapshot() async throws {
        for cancel in [false, true] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("launch-cover-failure-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            let cache = FeedSnapshotCache(root: directory), session = SiteSession(qa: true), root = GallerySite.ex.baseURL
            let old = Gallery(ref: .init(site: .ex, gid: 1, token: "abcdef"), title: "Ready old snapshot")
            await cache.save(.init(owner: session.owner, root: root, items: [old], next: nil, categories: [:]), expectedEpoch: 0)
            var started = false, release = false
            let pager = GalleryPager(loadHTML: { _, search, body in
                if search { return self.list(count: 1, start: 100) }
                return try self.metadata(XCTUnwrap(body))
            }, cache: cache, prepareSnapshotCovers: { _, _ in
                started = true
                while !release && !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
                return cancel
            })
            pager.reset(url: root, session: session, preserveCachedPresentation: true)
            await pager.waitForLoad()
            try await waitUntil { started }
            if cancel { pager.cancel() }
            release = true
            try await Task.sleep(for: .milliseconds(30))
            let saved = await cache.read(owner: session.owner, url: root)
            XCTAssertEqual(saved?.items.first?.ref.gid, 1)
            XCTAssertNil(pager.failure)
            pager.cancel()
        }
    }

    func testMetadataFailureRemainsRetryableInsteadOfCompletingUnknownRows() async throws {
        let session = SiteSession(qa: true)
        var metadataCalls = 0
        let pager = GalleryPager(loadHTML: { _, search, body in
            if search { return self.list(count: 2) }
            metadataCalls += 1
            if metadataCalls == 1 { throw ViewerError.network }
            return try self.metadata(XCTUnwrap(body))
        })
        defer { pager.cancel() }
        pager.reset(url: GallerySite.ex.baseURL, session: session)
        await pager.waitForLoad()
        XCTAssertNotNil(pager.failure)
        XCTAssertEqual(pager.items.count, 2)
        let before = LibrarySelectionPolicy.filtered(pager.items, blocked: ["female:fixture"])
        XCTAssertEqual(before.unknown, 2)
        pager.retry(session: session)
        await pager.waitForLoad()
        XCTAssertNil(pager.failure)
        XCTAssertEqual(metadataCalls, 2)
        let after = LibrarySelectionPolicy.filtered(pager.items, blocked: ["female:fixture"])
        XCTAssertEqual(after.unknown, 0); XCTAssertEqual(after.visible.count, 2)
    }

    func testIncompleteMetadataResponseKeepsAnExplicitRetryState() async throws {
        let session = SiteSession(qa: true)
        let pager = GalleryPager(loadHTML: { _, search, _ in
            if search { return self.list(count: 1) }
            return #"{"gmetadata":[{"gid":1,"title":"Partial"}]}"#
        })
        defer { pager.cancel() }
        pager.reset(url: GallerySite.ex.baseURL, session: session)
        await pager.waitForLoad()
        XCTAssertEqual(pager.failure, ViewerError.tagsUnavailable.localizedDescription)
        XCTAssertEqual(pager.items.first?.tagsComplete, false)
    }

    func testCachedUnknownTagsBecomeVisibleWithoutReplacingOrderOrCursor() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tag-recovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = FeedSnapshotCache(root: directory)
        let session = SiteSession(qa: true), root = GallerySite.ex.baseURL
        let items = [2, 1].map { Gallery(ref: .init(site: .ex, gid: Int64($0), token: "abcdef"), title: "Cached") }
        let cursor = try XCTUnwrap(URL(string: "?next=10", relativeTo: root)?.absoluteURL)
        await cache.save(.init(owner: session.owner, root: root, items: items, next: cursor, categories: [:]), expectedEpoch: 0)
        var release = false
        let pager = GalleryPager(loadHTML: { _, search, body in
            if search {
                while !release { try await Task.sleep(nanoseconds: 2_000_000) }
                return self.list(count: 1, start: 100)
            }
            return try self.metadata(XCTUnwrap(body))
        }, cache: cache)
        defer { release = true; pager.cancel() }
        pager.reset(url: root, session: session, preserveCachedPresentation: true)
        try await waitUntil { pager.cachedAt != nil }
        XCTAssertTrue(pager.items.allSatisfy { !$0.tagsComplete })
        release = true
        await pager.waitForLoad()
        XCTAssertNil(pager.failure)
        XCTAssertEqual(pager.items.map(\.ref.gid), [2, 1])
        XCTAssertTrue(pager.items.allSatisfy(\.tagsComplete))
        XCTAssertEqual(pager.next, cursor)
    }

    func testCompletingCachedTagsStillHonorsTheMinimumRating() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tag-rating-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = FeedSnapshotCache(root: directory), session = SiteSession(qa: true)
        var query = SearchQuery(); query.minRating = 4
        let root = try query.url(site: .ex)
        let old = Gallery(ref: .init(site: .ex, gid: 1, token: "abcdef"), title: "Incomplete cached item", rating: 4.5)
        await cache.save(.init(owner: session.owner, root: root, items: [old], next: nil, categories: [:]), expectedEpoch: 0)
        var release = false
        let pager = GalleryPager(loadHTML: { _, search, body in
            if search {
                while !release { try await Task.sleep(nanoseconds: 2_000_000) }
                return self.list(count: 1, start: 100)
            }
            return try self.metadata(XCTUnwrap(body), ratings: [1: "3.0", 100: "3.0"])
        }, cache: cache)
        defer { release = true; pager.cancel() }
        pager.reset(url: root, session: session, preserveCachedPresentation: true)
        try await waitUntil { pager.cachedAt != nil }
        release = true
        await pager.waitForLoad()
        XCTAssertNil(pager.failure)
        XCTAssertTrue(pager.items.isEmpty, "Recovered metadata must not expose an item below the query threshold")
    }

    func testCachedDiscoveryValidationKeepsVisibleRowsAndCursorUntilExplicitRefresh() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("discovery-stability-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = SiteSession(qa: true), root = GallerySite.ex.baseURL
        let cache = FeedSnapshotCache(root: directory)
        let oldCursor = try XCTUnwrap(URL(string: "?next=10", relativeTo: root)?.absoluteURL)
        let newCursor = try XCTUnwrap(URL(string: "?next=100", relativeTo: root)?.absoluteURL)
        let cached = Gallery(ref: .init(site: .ex, gid: 1, token: "abcdef"), title: "Cached")
        await cache.save(.init(owner: session.owner, root: root, items: [cached], next: oldCursor, categories: ["0": "Cached group"]), expectedEpoch: 0)
        var releaseValidation = false
        let pager = GalleryPager(loadHTML: { _, search, body in
            if search {
                while !releaseValidation { try await Task.sleep(nanoseconds: 2_000_000) }
                return self.list(count: 1, start: 100) + "<a id='dnext' href='?next=100'>Next</a>"
            }
            return try self.metadata(XCTUnwrap(body))
        }, cache: cache)
        defer { releaseValidation = true; pager.cancel() }
        pager.reset(url: root, session: session, preserveCachedPresentation: true)
        try await waitUntil { pager.cachedAt != nil }
        let cachedAt = pager.cachedAt
        XCTAssertEqual(pager.items.map(\.ref.gid), [1])
        XCTAssertEqual(pager.next, oldCursor)
        releaseValidation = true
        await pager.waitForLoad()
        XCTAssertEqual(pager.items.map(\.ref.gid), [1], "Background validation must not replace the active presentation")
        XCTAssertEqual(pager.next, oldCursor, "The visible rows must keep their original continuation")
        XCTAssertEqual(pager.categories, ["0": "Cached group"])
        XCTAssertEqual(pager.cachedAt, cachedAt)
        let saved = await cache.read(owner: session.owner, url: root)
        XCTAssertEqual(saved?.items.map(\.ref.gid), [100])
        XCTAssertEqual(saved?.next, newCursor)
        pager.reset(url: root, session: session)
        await pager.waitForLoad()
        XCTAssertEqual(pager.items.map(\.ref.gid), [100])
        XCTAssertEqual(pager.next, newCursor)
        XCTAssertNil(pager.cachedAt)
        XCTAssertNil(pager.failure)
    }

    func testPreparedCachedDiscoveryKeepsCursorAndManualRefreshPromotesItsInFlightValidation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("discovery-promote-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = SiteSession(qa: true), root = GallerySite.ex.baseURL.appendingPathComponent("popular")
        let cache = FeedSnapshotCache(root: directory)
        let cursor = try XCTUnwrap(URL(string: "https://exhentai.org/popular?next=10"))
        let cached = Gallery(ref: .init(site: .ex, gid: 1, token: "abcdef"), title: "Cached")
        await cache.save(.init(owner: session.owner, root: root, items: [cached], next: cursor, categories: [:]), expectedEpoch: 0)
        var requests = 0, metadataStarted = false, releaseMetadata = false
        let pager = GalleryPager(loadHTML: { _, search, body in
            if search { requests += 1; return self.list(count: 1, start: 100) }
            metadataStarted = true
            while !releaseMetadata { try await Task.sleep(nanoseconds: 2_000_000) }
            return try self.metadata(XCTUnwrap(body))
        }, cache: cache)
        defer { releaseMetadata = true; pager.cancel() }
        await pager.prepareCached(url: root, session: session, qa: false)
        XCTAssertEqual(pager.next, cursor)
        pager.reset(url: root, session: session, preserveCachedPresentation: true)
        try await waitUntil { metadataStarted }
        XCTAssertEqual(pager.items.map(\.ref.gid), [1])
        XCTAssertEqual(pager.next, cursor, "Starting a prepared cached pane must retain its cursor")
        pager.reset(url: root, session: session)
        releaseMetadata = true
        await pager.waitForLoad()
        XCTAssertEqual(requests, 1, "Manual refresh promotes the existing request instead of duplicating it")
        XCTAssertEqual(pager.items.map(\.ref.gid), [100])
        XCTAssertNil(pager.cachedAt)
        XCTAssertNil(pager.next)
    }

    func testCancelledCachedDiscoveryValidationRemainsStableWhenItsEntryResumes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("discovery-resume-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = SiteSession(qa: true), root = GallerySite.ex.baseURL
        let cache = FeedSnapshotCache(root: directory)
        let cursor = try XCTUnwrap(URL(string: "?next=10", relativeTo: root)?.absoluteURL)
        let cached = Gallery(ref: .init(site: .ex, gid: 1, token: "abcdef"), title: "Cached")
        await cache.save(.init(owner: session.owner, root: root, items: [cached], next: cursor, categories: [:]), expectedEpoch: 0)
        var requests = 0, metadataCalls = 0, releaseMetadata = false
        let pager = GalleryPager(loadHTML: { _, search, body in
            if search { requests += 1; return self.list(count: 1, start: 100) }
            metadataCalls += 1
            while !releaseMetadata { try await Task.sleep(nanoseconds: 2_000_000) }
            return try self.metadata(XCTUnwrap(body))
        }, cache: cache)
        defer { releaseMetadata = true; pager.cancel() }
        pager.reset(url: root, session: session, preserveCachedPresentation: true)
        try await waitUntil { metadataCalls == 1 }
        pager.cancel()
        XCTAssertTrue(pager.interrupted)
        pager.retry(session: session)
        try await waitUntil { metadataCalls == 2 }
        releaseMetadata = true
        await pager.waitForLoad()
        XCTAssertEqual(requests, 2)
        XCTAssertEqual(pager.items.map(\.ref.gid), [1])
        XCTAssertEqual(pager.next, cursor)
        XCTAssertNotNil(pager.cachedAt)
        XCTAssertFalse(pager.interrupted)
        let saved = await cache.read(owner: session.owner, url: root)
        XCTAssertEqual(saved?.items.map(\.ref.gid), [100])
    }

    func testDiscoveryWithoutCacheStillPublishesItsFirstRequestWhenPreservationIsRequested() async throws {
        let pager = GalleryPager { _, search, body in
            if search { return self.list(count: 1, start: 100) }
            return try self.metadata(XCTUnwrap(body))
        }
        pager.reset(url: GallerySite.ex.baseURL, session: SiteSession(qa: true), preserveCachedPresentation: true)
        await pager.waitForLoad()
        XCTAssertEqual(pager.items.map(\.ref.gid), [100])
        XCTAssertNil(pager.cachedAt)
        XCTAssertNil(pager.failure)
    }

    func testFirstCompletedBatchAppearsBeforeLaterBatchesWithoutChangingCoverage() async throws {
        var requests = 0
        var releaseFollowingBatches = false
        let pager = GalleryPager { _, search, body in
            if search { return self.list(count: 51) }
            requests += 1
            while requests > 1, !releaseFollowingBatches {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            try await Task.sleep(nanoseconds: 30_000_000)
            return try self.metadata(XCTUnwrap(body))
        }
        let start = ProcessInfo.processInfo.systemUptime
        pager.reset(url: GallerySite.ex.baseURL, session: SiteSession(qa: true))
        try await waitUntil(timeout: 2) { pager.items.count == 25 }
        let first = ProcessInfo.processInfo.systemUptime - start
        XCTAssertTrue(pager.loading)
        XCTAssertTrue(pager.items.allSatisfy(\.tagsComplete))
        releaseFollowingBatches = true
        try await waitUntil { !pager.loading }
        let complete = ProcessInfo.processInfo.systemUptime - start
        XCTAssertEqual(pager.items.map(\.ref.gid), (1...51).map(Int64.init))
        XCTAssertEqual(requests, 3)
        XCTAssertNil(pager.failure)
        print("PAGER12_LOCAL_PIPELINE first25=\(first)s all51=\(complete)s; three metadata responses; no network")
    }

    func testLeavingFavoritesDuringEnrichmentRetainsCompletedMetadataOnDisk() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("favorite-progress-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = try XCTUnwrap(SiteFavoriteOrder.siteDefault.url(site: .ex, category: "all"))
        let session = SiteSession(qa: true)
        var metadataCalls = 0
        var followingBatch: CheckedContinuation<String, Error>?
        let pager = GalleryPager(loadHTML: { _, search, body in
            if search { return self.list(count: 26) }
            metadataCalls += 1
            if metadataCalls == 2 { return try await withCheckedThrowingContinuation { followingBatch = $0 } }
            return try self.metadata(XCTUnwrap(body))
        }, cache: FeedSnapshotCache(root: directory))
        defer { followingBatch?.resume(throwing: CancellationError()) }
        pager.reset(url: root, session: session)
        var refreshFinished = false
        let refresh = Task { await pager.waitForLoad(); refreshFinished = true }
        try await waitUntil { followingBatch != nil }
        XCTAssertFalse(refreshFinished, "Pull refresh must wait for enrichment")
        pager.cancel()
        let cached = await FeedSnapshotCache(root: directory).read(owner: session.owner, url: root)
        let snapshot = try XCTUnwrap(cached)
        XCTAssertEqual(snapshot.items.count, 26)
        XCTAssertEqual(snapshot.items.filter(\.tagsComplete).count, 25)
        let filtered = LibrarySelectionPolicy.filtered(snapshot.items, blocked: ["other:blocked"])
        XCTAssertEqual(filtered.visible.count, 25, "Verified cached rows remain usable with blocking enabled")
        XCTAssertEqual(filtered.unknown, 1)
        followingBatch?.resume(throwing: CancellationError()); followingBatch = nil
        await refresh.value
        XCTAssertTrue(refreshFinished)
    }

    func testPartialRevalidationCannotDowngradePreviouslyVerifiedFavoriteSnapshot() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("favorite-retained-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = try XCTUnwrap(SiteFavoriteOrder.siteDefault.url(site: .ex, category: "all"))
        let session = SiteSession(qa: true)
        let cache = FeedSnapshotCache(root: directory)
        let rows = (1...26).map { index in
            var gallery = Gallery(ref: .init(site: .ex, gid: Int64(index), token: "abcdef"), title: "Cached \(index)", tags: [.init(namespace: "language", name: "english")])
            gallery.tagsComplete = true
            return gallery
        }
        await cache.save(.init(owner: session.owner, root: root, items: rows, next: nil, categories: [:]), expectedEpoch: 0)
        var metadataCalls = 0
        var followingBatch: CheckedContinuation<String, Error>?
        let pager = GalleryPager(loadHTML: { _, search, body in
            if search { return self.list(count: 26) }
            metadataCalls += 1
            if metadataCalls == 2 { return try await withCheckedThrowingContinuation { followingBatch = $0 } }
            return try self.metadata(XCTUnwrap(body))
        }, cache: cache)
        defer { followingBatch?.resume(throwing: CancellationError()) }
        pager.reset(url: root, session: session)
        try await waitUntil { followingBatch != nil }
        pager.cancel()
        let cached = await FeedSnapshotCache(root: directory).read(owner: session.owner, url: root)
        XCTAssertEqual(cached?.items.map(\.ref.gid), rows.map(\.ref.gid), "Fresh HTML order remains authoritative")
        XCTAssertEqual(cached?.items.count, rows.count)
        XCTAssertTrue(cached?.items.allSatisfy(\.tagsComplete) == true, "A half-finished refresh must not downgrade verified metadata")
        XCTAssertEqual(cached?.items.last?.tags, rows.last?.tags)
        followingBatch?.resume(throwing: CancellationError()); followingBatch = nil
    }

    func testMetadataFailurePreservesIncompleteRowsAndBlockedUnknownPolicy() async throws {
        var requests = 0
        let pager = GalleryPager { _, search, body in
            if search { return self.list(count: 26) }
            requests += 1
            if requests == 2 { throw URLError(.timedOut) }
            return try self.metadata(XCTUnwrap(body))
        }
        pager.reset(url: GallerySite.ex.baseURL, session: SiteSession(qa: true))
        try await waitUntil { !pager.loading }
        XCTAssertEqual(pager.items.count, 26)
        XCTAssertEqual(pager.items.filter(\.tagsComplete).count, 25)
        let filtered = LibrarySelectionPolicy.filtered(pager.items, blocked: ["other:blocked"])
        XCTAssertEqual(filtered.visible.count, 25)
        XCTAssertEqual(filtered.unknown, 1)
        XCTAssertEqual(pager.items.last?.title, "Neutral 26")
    }

    func testResetDuringMetadataCannotAppendOldSourceAfterNewSource() async throws {
        let session = SiteSession(qa: true)
        var oldMetadataStarted = false
        let pager = GalleryPager { url, search, body in
            if search { return self.list(count: 1, start: url.path == "/new" ? 100 : 1) }
            let payload = try XCTUnwrap(body)
            let isOld = String(decoding: payload, as: UTF8.self).contains("[1,")
            if isOld {
                oldMetadataStarted = true
                // Simulate a transport that finishes despite cancellation.
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            return try self.metadata(payload)
        }
        pager.reset(url: GallerySite.ex.baseURL, session: session)
        try await waitUntil(timeout: 2) { oldMetadataStarted }
        pager.reset(url: URL(string: "https://exhentai.org/new")!, session: session)
        try await waitUntil(timeout: 2) { !pager.loading }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(pager.items.map(\.ref.gid), [100])
        XCTAssertNil(pager.failure)
    }

    func testFavoritesAppendInSiteOrderAndKeepTheScopeOfTheFirstPage() async throws {
        let session = SiteSession(qa: true)
        let root = try XCTUnwrap(SiteFavoriteOrder.favorited.url(site: .ex, category: "7"))
        let link = "/favorites.php?next=12-1760000000&favcat=all&inline_set=fs_p"
        let expected = try XCTUnwrap(URL(string: "https://exhentai.org/favorites.php?next=12-1760000000&inline_set=fs_f&favcat=7"))
        var requests: [URL] = []
        let pager = GalleryPager { url, search, body in
            if search {
                requests.append(url)
                if url == root {
                    return self.list(count: 1, start: 40) + self.list(count: 1, start: 12)
                        + "<a id='dnext' href='\(link)'>Next</a>"
                }
                return self.list(count: 1, start: 90) + self.list(count: 1, start: 8)
                    + "<a id='dnext' href='\(link)'>Next</a>"
            }
            return try self.metadata(XCTUnwrap(body))
        }
        pager.reset(url: root, session: session)
        try await waitUntil { !pager.loading }
        XCTAssertEqual(pager.items.map(\.ref.gid), [40, 12])
        XCTAssertEqual(pager.next, expected)
        pager.more(session: session)
        try await waitUntil { !pager.loading }
        XCTAssertEqual(pager.items.map(\.ref.gid), [40, 12, 90, 8])
        XCTAssertEqual(requests, [root, expected])
        XCTAssertNil(pager.next)
        XCTAssertNil(pager.failure)
    }

    func testFavoritesRefreshCanReplaceAnOlderRequestForTheSameRoot() async throws {
        let session = SiteSession(qa: true)
        let root = try XCTUnwrap(SiteFavoriteOrder.siteDefault.url(site: .ex, category: "all"))
        var oldResponse: CheckedContinuation<String, Never>?
        var requests = 0
        let pager = GalleryPager { _, search, body in
            if search {
                requests += 1
                if requests == 1 {
                    return await withCheckedContinuation { oldResponse = $0 }
                }
                return self.list(count: 1, start: 100)
            }
            return try self.metadata(XCTUnwrap(body))
        }
        defer { oldResponse?.resume(returning: list(count: 1)) }
        pager.reset(url: root, session: session)
        try await waitUntil(timeout: 2) { oldResponse != nil }
        pager.reset(url: root, session: session)
        await Task.yield()
        XCTAssertEqual(requests, 1, "Ordinary refreshes still coalesce")
        pager.reset(url: root, session: session, replaceInFlight: true)
        try await waitUntil(timeout: 2) { !pager.loading }
        XCTAssertEqual(requests, 2)
        XCTAssertEqual(pager.items.map(\.ref.gid), [100])
        oldResponse?.resume(returning: list(count: 1))
        oldResponse = nil
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(pager.items.map(\.ref.gid), [100])
        XCTAssertNil(pager.failure)
    }

    func testConfirmedFavoriteRemovalKeepsLoadedPagesAndIgnoresLateDuplicate() async throws {
        let session = SiteSession(qa: true)
        let root = try XCTUnwrap(SiteFavoriteOrder.siteDefault.url(site: .ex, category: "all"))
        var requests: [URL] = []
        var lastPage: CheckedContinuation<String, Never>?
        let pager = GalleryPager { url, search, body in
            if search {
                requests.append(url)
                switch requests.count {
                case 1: return self.list(count: 2) + "<a id='dnext' href='/favorites.php?next=2'>Next</a>"
                case 2: return self.list(count: 2, start: 3) + "<a id='dnext' href='/favorites.php?next=4'>Next</a>"
                default: return await withCheckedContinuation { lastPage = $0 }
                }
            }
            return try self.metadata(XCTUnwrap(body))
        }
        defer { lastPage?.resume(returning: list(count: 1, start: 5)) }
        pager.reset(url: root, session: session)
        try await waitUntil { !pager.loading }
        pager.more(session: session)
        try await waitUntil { !pager.loading }
        XCTAssertEqual(pager.items.map(\.ref.gid), [1, 2, 3, 4])
        let continuation = try XCTUnwrap(pager.next)

        pager.more(session: session)
        try await waitUntil { lastPage != nil }
        pager.removeConfirmedFavorites(["ex:3"])
        XCTAssertEqual(pager.items.map(\.ref.gid), [1, 2, 4])
        XCTAssertEqual(pager.next, continuation)
        lastPage?.resume(returning: list(count: 1, start: 3) + list(count: 1, start: 5))
        lastPage = nil
        try await waitUntil { !pager.loading }
        XCTAssertEqual(pager.items.map(\.ref.gid), [1, 2, 4, 5])
        XCTAssertEqual(requests.count, 3)
        XCTAssertNil(pager.failure)
    }

    func testInterruptedIncompleteBatchCanRecoverTagsOnRetryWithoutDuplicates() async throws {
        let session = SiteSession(qa: true)
        var requests = 0
        var retrying = false
        let pager = GalleryPager { _, search, body in
            if search { return self.list(count: 26) }
            requests += 1
            if requests == 1 { throw URLError(.timedOut) }
            while requests == 2, !retrying {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            return try self.metadata(XCTUnwrap(body))
        }
        pager.reset(url: GallerySite.ex.baseURL, session: session)
        try await waitUntil(timeout: 2) { pager.items.count == 25 }
        XCTAssertTrue(pager.items.allSatisfy { !$0.tagsComplete })
        pager.cancel()
        XCTAssertTrue(pager.interrupted)
        retrying = true
        pager.retry(session: session)
        try await waitUntil { !pager.loading }
        XCTAssertEqual(pager.items.map(\.ref.gid), (1...26).map(Int64.init))
        XCTAssertTrue(pager.items.allSatisfy(\.tagsComplete))
        XCTAssertEqual(LibrarySelectionPolicy.filtered(pager.items, blocked: ["other:blocked"]).unknown, 0)
    }

    func testMinimumRatingExcludesDecimalsBelowThresholdAcrossContinuationWithoutFilterParameters() async throws {
        let session = SiteSession(qa: true)
        var query = SearchQuery(); query.minRating = 3
        let root = try query.url(site: .ex)
        let cursor = try XCTUnwrap(URL(string: "https://exhentai.org/?next=7"))
        var calls: [URL] = []
        var metadataCalls = 0
        let pager = GalleryPager { url, search, body in
            if search {
                calls.append(url)
                return url == root ? self.list(count: 6) + "<a id='dnext' href='/?next=7'>Next</a>" : self.list(count: 2, start: 7)
            }
            metadataCalls += 1
            return try self.metadata(XCTUnwrap(body), ratings: [1: "2.8", 2: "2.9", 3: "3.0", 4: "3.8", 5: "2.999", 6: "5", 7: "2.9", 8: "3.1"])
        }
        pager.reset(url: root, session: session)
        try await waitUntil { !pager.loading }
        XCTAssertEqual(pager.items.map(\.ref.gid), [3, 4, 6]); XCTAssertNil(pager.failure)
        XCTAssertEqual(pager.next, cursor)
        pager.more(session: session)
        try await waitUntil { !pager.loading }
        XCTAssertEqual(pager.items.map(\.ref.gid), [3, 4, 6, 8]); XCTAssertNil(pager.failure)
        XCTAssertEqual(calls, [root, cursor]); XCTAssertEqual(metadataCalls, 2)
    }

    func testRatingFilterDoesNotFallBackToUnconfirmedRowsWhenMetadataFailsAndCanRetry() async throws {
        let session = SiteSession(qa: true)
        var query = SearchQuery(); query.minRating = 3
        var attempts = 0
        let pager = GalleryPager { _, search, body in
            if search { return self.list(count: 2) }
            attempts += 1
            if attempts == 1 { throw URLError(.timedOut) }
            return try self.metadata(XCTUnwrap(body), ratings: [1: "2.9", 2: "3.0"])
        }
        pager.reset(url: try query.url(site: .ex), session: session)
        try await waitUntil { !pager.loading }
        XCTAssertTrue(pager.items.isEmpty); XCTAssertNotNil(pager.failure)
        XCTAssertEqual(attempts, 1, "No automatic retry storm")
        pager.retry(session: session)
        try await waitUntil { !pager.loading }
        XCTAssertEqual(pager.items.map(\.ref.gid), [2]); XCTAssertNil(pager.failure)
    }

    func testMissingAverageKeepsConfirmedMatchesButReportsIncompletePageWithoutCachingIt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = FeedSnapshotCache(root: directory)
        let session = SiteSession(qa: true)
        var query = SearchQuery(); query.minRating = 3
        let root = try query.url(site: .ex)
        let pager = GalleryPager(loadHTML: { _, search, body in
            if search { return self.list(count: 3) }
            return try self.metadata(XCTUnwrap(body), ratings: [1: "3.0", 2: "2.9"])
        }, cache: cache)
        pager.reset(url: root, session: session)
        try await waitUntil { !pager.loading }
        XCTAssertEqual(pager.items.map(\.ref.gid), [1])
        XCTAssertEqual(pager.failure, ViewerError.ratingUnavailable.localizedDescription)
        XCTAssertNil(pager.next)
        let cached = await cache.read(owner: session.owner, url: root)
        XCTAssertNil(cached, "A partial response must not become a complete cached search")
    }
    func testColdFavoriteHTMLIsSavedAndVisibleBeforeMetadataAndSurvivesCancellation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = FeedSnapshotCache(root: directory)
        let session = SiteSession(qa: true)
        let root = try XCTUnwrap(SiteFavoriteOrder.siteDefault.url(site: .ex, category: "1"))
        var metadataResponse: CheckedContinuation<String, Error>?
        let pager = GalleryPager(loadHTML: { _, search, _ in
            if search { return self.list(count: 26) + "<select name='favcat'><option value='1'>Reading</option></select>" }
            return try await withCheckedThrowingContinuation { metadataResponse = $0 }
        }, cache: cache)
        defer { pager.cancel(); metadataResponse?.resume(throwing: CancellationError()) }
        pager.reset(url: root, session: session)
        try await waitUntil { metadataResponse != nil }
        XCTAssertEqual(pager.items.count, 26, "The complete HTML first page must not wait for metadata")
        XCTAssertTrue(pager.loading); XCTAssertEqual(pager.loadingPresentation, .hidden)
        let snapshot = await cache.read(owner: session.owner, url: root)
        XCTAssertEqual(snapshot?.items.count, 26); XCTAssertEqual(snapshot?.categories["1"], "Reading")
        pager.cancel(); metadataResponse?.resume(throwing: CancellationError()); metadataResponse = nil
        let reopened = GalleryPager(loadHTML: { _, _, _ in throw URLError(.notConnectedToInternet) }, cache: FeedSnapshotCache(root: directory))
        reopened.reset(url: root, session: session)
        try await waitUntil { !reopened.loading }
        XCTAssertEqual(reopened.items.count, 26); XCTAssertNotNil(reopened.cachedAt)
        XCTAssertNotNil(reopened.failure)
    }

    func testConfirmedMoveDuringHTMLReadCannotBeSeededBackIntoTheOldGroup() async throws {
        let session = SiteSession(qa: true)
        let root = try XCTUnwrap(SiteFavoriteOrder.siteDefault.url(site: .ex, category: "1"))
        var response: CheckedContinuation<String, Error>?
        var metadataReads = 0
        let pager = GalleryPager { _, search, body in
            if search { return try await withCheckedThrowingContinuation { response = $0 } }
            metadataReads += 1
            return try self.metadata(XCTUnwrap(body))
        }
        defer { pager.cancel(); response?.resume(throwing: CancellationError()) }
        pager.reset(url: root, session: session)
        try await waitUntil { response != nil }
        let ref = GalleryRef(site: .ex, gid: 1, token: "abcdef")
        let scope = GalleryFavoriteScope(reference: ref, owner: session.owner, generation: session.generation)
        let moved = try GalleryFavoriteForm.read(NativeFavoritesQA.html(reference: ref, group: 2, note: ""), reference: ref)
        XCTAssertTrue(session.favoriteStateCache.put(moved.state, form: moved, scope: scope, force: true))
        response?.resume(returning: list(count: 1)); response = nil
        try await waitUntil { !pager.loading }
        XCTAssertTrue(pager.items.isEmpty); XCTAssertEqual(metadataReads, 0)
        XCTAssertEqual(session.favoriteStateCache.entry(scope)?.form?.selectedGroup, 2)
        XCTAssertEqual(session.favoriteStateCache.entry(scope)?.state, moved.state)
    }

    func testConfirmedRemovalDuringMetadataCannotReappearOrOverwriteLocalState() async throws {
        let session = SiteSession(qa: true)
        let root = try XCTUnwrap(SiteFavoriteOrder.siteDefault.url(site: .ex, category: "all"))
        var response: CheckedContinuation<String, Error>?
        var payload: Data?
        let pager = GalleryPager { _, search, body in
            if search { return self.list(count: 1) }
            payload = body
            return try await withCheckedThrowingContinuation { response = $0 }
        }
        defer { pager.cancel(); response?.resume(throwing: CancellationError()) }
        pager.reset(url: root, session: session)
        try await waitUntil { response != nil }
        XCTAssertEqual(pager.items.count, 1)
        let ref = GalleryRef(site: .ex, gid: 1, token: "abcdef")
        let scope = GalleryFavoriteScope(reference: ref, owner: session.owner, generation: session.generation)
        XCTAssertTrue(session.favoriteStateCache.put(.notFavorited, scope: scope, force: true))
        response?.resume(returning: try metadata(XCTUnwrap(payload))); response = nil
        try await waitUntil { !pager.loading }
        XCTAssertTrue(pager.items.isEmpty)
        XCTAssertEqual(session.favoriteStateCache.entry(scope)?.state, .notFavorited)
    }

    func testReaddingFavoriteAllowsItBackIntoAReopenedSnapshot() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = FeedSnapshotCache(root: directory)
        let session = SiteSession(qa: true)
        let root = try XCTUnwrap(SiteFavoriteOrder.siteDefault.url(site: .ex, category: "all"))
        let ref = GalleryRef(site: .ex, gid: 1, token: "abcdef")
        let gallery = Gallery(ref: ref, title: "Readded")
        await cache.save(.init(owner: session.owner, root: root, items: [gallery], next: nil, categories: [:]), expectedEpoch: 0)
        let scope = GalleryFavoriteScope(reference: ref, owner: session.owner, generation: session.generation)
        XCTAssertTrue(session.favoriteStateCache.put(.notFavorited, scope: scope, force: true))
        let form = try GalleryFavoriteForm.read(NativeFavoritesQA.html(reference: ref, group: 2, note: ""), reference: ref)
        XCTAssertTrue(session.favoriteStateCache.put(form.state, form: form, scope: scope, force: true))
        let pager = GalleryPager(loadHTML: { _, _, _ in throw URLError(.notConnectedToInternet) }, cache: cache)
        pager.reset(url: root, session: session)
        try await waitUntil { !pager.loading }
        XCTAssertEqual(pager.items.map(\.ref.gid), [1])
        XCTAssertEqual(session.favoriteStateCache.entry(scope)?.state, form.state)
    }

    func testFavoriteRefreshPublishesFreshServerOrderBeforeSlowMetadataAndEnrichesInPlace() async throws {
        let session = SiteSession(qa: true)
        let root = try XCTUnwrap(SiteFavoriteOrder.favorited.url(site: .ex, category: "all"))
        var refreshing = false, firstReleased = false, restReleased = false
        var metadataCalls = 0
        let expected: [Int64] = [100] + (1...25).map(Int64.init)
        let pager = GalleryPager { _, search, body in
            if search {
                if !refreshing { return self.list(count: 26) }
                return "<div class='itg'><table>" + expected.map {
                    "<tr><td><a href='/g/\($0)/abcdef/'><div class='glink'>Neutral \($0)</div></a></td></tr>"
                }.joined() + "</table></div>"
            }
            if refreshing {
                metadataCalls += 1
                if metadataCalls == 1 {
                    while !firstReleased { try await Task.sleep(nanoseconds: 2_000_000) }
                } else {
                    while !restReleased { try await Task.sleep(nanoseconds: 2_000_000) }
                }
            }
            let text = try self.metadata(XCTUnwrap(body))
            var response = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            response["gmetadata"] = Array((response["gmetadata"] as! [[String: Any]]).reversed())
            return String(decoding: try JSONSerialization.data(withJSONObject: response), as: UTF8.self)
        }
        defer { firstReleased = true; restReleased = true }
        pager.reset(url: root, session: session)
        try await waitUntil { !pager.loading }
        XCTAssertEqual(pager.items.first?.ref.gid, 1)
        refreshing = true
        pager.reset(url: root, session: session, replaceInFlight: true)
        try await waitUntil { metadataCalls == 1 }
        XCTAssertEqual(pager.items.map(\.ref.gid), expected)
        XCTAssertEqual(pager.items.first?.tagsComplete, false)
        XCTAssertEqual(pager.items.dropFirst().first?.tagsComplete, true, "Previously verified metadata survives reordering")
        firstReleased = true
        try await waitUntil { metadataCalls == 2 }
        XCTAssertTrue(pager.loading)
        XCTAssertEqual(pager.items.first?.tagsComplete, true, "New first item becomes usable before the entire page finishes")
        XCTAssertEqual(pager.items.map(\.ref.gid), expected)
        restReleased = true
        try await waitUntil { !pager.loading }
        XCTAssertEqual(pager.items.map(\.ref.gid), expected)
    }

}
