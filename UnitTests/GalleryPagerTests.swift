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
}
