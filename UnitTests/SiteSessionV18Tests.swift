import XCTest
import Foundation
import ExViewerCore
@testable import ExViewer

@MainActor final class SiteSessionV18Tests: XCTestCase {
    private final class PageProtocol: URLProtocol, @unchecked Sendable {
        enum Plan {
            case lost, hold, response(Int, String, [String: String])
            case delayed(Int, String)
        }
        private static let lock = NSLock()
        private static var handler: (String, Int) -> Plan = { _, _ in .response(200, "<html>ok</html>", [:]) }
        private static var counts: [String: Int] = [:]
        private static var starts: [String: [TimeInterval]] = [:]
        private static var acceptHeaders: [String: String] = [:]
        private static var active: [ObjectIdentifier: Bool] = [:]
        private static var peak = 0
        private static var backgroundPeak = 0
        private let stateLock = NSLock()
        private var finished = false

        override class func canInit(with request: URLRequest) -> Bool {
            ["e-hentai.org", "api.e-hentai.org", "exhentai.org"].contains(request.url?.host ?? "")
        }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        static func reset(_ next: @escaping (String, Int) -> Plan) {
            lock.lock(); defer { lock.unlock() }
            handler = next; counts = [:]; starts = [:]; acceptHeaders = [:]; active = [:]; peak = 0; backgroundPeak = 0
        }
        static func count(_ path: String) -> Int { lock.lock(); defer { lock.unlock() }; return counts[path] ?? 0 }
        static func times(_ path: String) -> [TimeInterval] { lock.lock(); defer { lock.unlock() }; return starts[path] ?? [] }
        static func accept(_ path: String) -> String? { lock.lock(); defer { lock.unlock() }; return acceptHeaders[path] }
        static func peaks() -> (Int, Int) { lock.lock(); defer { lock.unlock() }; return (peak, backgroundPeak) }
        static func total() -> Int { lock.lock(); defer { lock.unlock() }; return counts.values.reduce(0, +) }

        override func startLoading() {
            guard let url = request.url else { return }
            let path = url.path
            Self.lock.lock()
            let count = (Self.counts[path] ?? 0) + 1
            Self.counts[path] = count
            Self.starts[path, default: []].append(ProcessInfo.processInfo.systemUptime)
            Self.acceptHeaders[path] = request.value(forHTTPHeaderField: "Accept")
            Self.active[ObjectIdentifier(self)] = path.hasPrefix("/prefetch")
            Self.peak = max(Self.peak, Self.active.count)
            Self.backgroundPeak = max(Self.backgroundPeak, Self.active.values.filter { $0 }.count)
            let plan = Self.handler(path, count)
            Self.lock.unlock()
            switch plan {
            case .hold: return
            case .lost:
                complete()
                client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            case let .response(status, body, headers):
                deliver(status, body, headers, url: url)
            case let .delayed(status, body):
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    self?.deliver(status, body, [:], url: url)
                }
            }
        }
        override func stopLoading() { complete() }
        private func deliver(_ status: Int, _ body: String, _ headers: [String: String], url: URL) {
            guard complete() else { return }
            var headers = headers; headers["Content-Type"] = "text/html; charset=utf-8"
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        @discardableResult private func complete() -> Bool {
            stateLock.lock()
            guard !finished else { stateLock.unlock(); return false }
            finished = true; stateLock.unlock()
            Self.lock.lock(); Self.active.removeValue(forKey: ObjectIdentifier(self)); Self.lock.unlock()
            return true
        }
    }

    private func session(interval: TimeInterval = 0, limit: Int = 2) -> SiteSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PageProtocol.self]
        return SiteSession(qa: true, configuration: config, searchInterval: interval, pageConcurrencyLimit: { limit })
    }
    private func url(_ path: String) -> URL { URL(string: "https://e-hentai.org\(path)")! }
    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<200 { if condition() { return true }; try? await Task.sleep(nanoseconds: 5_000_000) }
        return condition()
    }

    private final class BackgroundExecution: DownloadBackgroundWork {
        private var shortExpiration: (@MainActor () -> Void)?
        private var continuedExpiration: (@MainActor () -> Void)?
        var canContinue: Bool { shortExpiration != nil || continuedExpiration != nil }

        func beginShort(_ name: String, expired: @escaping @MainActor () -> Void) {
            if !canContinue { shortExpiration = expired }
        }

        func requestContinuation(expired: @escaping @MainActor () -> Void) {
            continuedExpiration = expired
            shortExpiration = nil
        }

        func report(completed: Int, total: Int?) {}

        func finish(success: Bool) {
            shortExpiration = nil
            continuedExpiration = nil
        }

        func expireContinuation() {
            let expired = continuedExpiration
            continuedExpiration = nil
            expired?()
        }

        func expireShort() {
            let expired = shortExpiration
            shortExpiration = nil
            expired?()
        }
    }

    func testMockLoginCapturesOnlyCompleteSessionAndVerifiesEHAndEXSeparately() async throws {
        let session = session()
        let initialGeneration = session.generation
        let operation = try session.beginWebOperation()
        func put(_ name: String, _ value: String) async throws {
            let cookie = try XCTUnwrap(HTTPCookie(properties: [
                .name: name, .value: value, .domain: "e-hentai.org", .path: "/", .secure: "TRUE"
            ]))
            await session.webStore.httpCookieStore.setCookie(cookie)
        }

        try await put("ipb_member_id", "123456")
        do {
            try await session.captureWebSession(operation: operation)
            XCTFail("A partial login must not activate an account")
        } catch { XCTAssertEqual(error as? ViewerError, .authentication) }
        XCTAssertEqual(session.generation, initialGeneration)
        XCTAssertFalse(session.hasCredentials)

        PageProtocol.reset { _, _ in .response(200, "<p>No hits found</p>", [:]) }
        await session.verify()
        XCTAssertEqual(session.ehStatus, "访客可访问")
        XCTAssertEqual(session.exStatus, "需要登录")
        XCTAssertEqual(PageProtocol.count("/"), 1)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LoginDownload-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LibraryStore(qa: true, storageRoot: root)
        let gallery = Gallery(ref: .init(site: .eh, gid: 56, token: "fixture"), title: "Login download", pages: 2)
        let files = library.offlineDirectory(gallery)
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
        try png.write(to: files.appendingPathComponent("page-1.media"))
        let preview = "<h1 id='gn'>Fixture</h1><table id='gdd'><tr><td class='gdt1'>Length:</td><td class='gdt2'>2 pages</td></tr></table><div id='gdt'><a href='/s/fixture/56-1'>Page 1</a><a href='/s/fixture/56-2'>Page 2</a></div>"
        PageProtocol.reset { path, _ in path.hasPrefix("/g/") ? .response(200, preview, [:]) : .hold }
        let preferences = try XCTUnwrap(UserDefaults(suiteName: "LoginDownload-\(UUID())"))
        preferences.register(defaults: [DownloadLoadPolicy.concurrencyKey: 1])
        let downloads = DownloadManager(session: session, library: library, preferences: preferences)
        defer { downloads.pauseAll() }
        XCTAssertTrue(downloads.enqueue(gallery))
        let downloadStarted = await waitUntil { PageProtocol.count("/s/fixture/56-2") == 1 }
        XCTAssertTrue(downloadStarted)
        XCTAssertEqual(library.download(for: gallery.ref)?.completed, [1: "page-1.media"])
        XCTAssertTrue(LibraryStore(qa: true, storageRoot: root).download(for: gallery.ref)?.completed.isEmpty == true)

        try await put("ipb_pass_hash", "mock-value-no-authorization")
        try await session.captureWebSession(operation: operation)
        XCTAssertTrue(session.hasCredentials)
        XCTAssertNotEqual(session.owner, "guest")
        XCTAssertNotEqual(session.generation, initialGeneration)
        let previousRunStopped = await waitUntil { downloads.running == nil }
        XCTAssertTrue(previousRunStopped)
        ExViewerApp.applySessionChange(session: session, library: library, downloads: downloads)
        XCTAssertEqual(library.owner, session.owner)
        XCTAssertTrue(library.snapshot.downloads.isEmpty)
        XCTAssertNil(downloads.running)
        let previousDownload = LibraryStore(qa: true, storageRoot: root).download(for: gallery.ref)
        XCTAssertEqual(previousDownload?.status, .paused)
        XCTAssertEqual(previousDownload?.completed, [1: "page-1.media"])

        PageProtocol.reset { path, _ in
            path == "/favorites.php" ? .response(200, "<p>No favorites found</p>", [:])
                : .response(403, "<p>Just a moment...</p>", ["cf-mitigated": "challenge"])
        }
        await session.verify()
        XCTAssertEqual(session.ehStatus, "站点收藏可读取")
        XCTAssertNotEqual(session.exStatus, "EX 画廊可访问")
        XCTAssertEqual(PageProtocol.count("/"), 1)

        PageProtocol.reset { _, _ in .response(200, "<p>No hits found</p>", [:]) }
        await session.verify()
        XCTAssertEqual(session.exStatus, "EX 画廊可访问")
        XCTAssertEqual(PageProtocol.count("/favorites.php"), 1)

        let signedInOwner = session.owner
        library.bookmark(gallery)
        let signedInGeneration = session.generation
        try await session.captureWebSession(operation: operation)
        ExViewerApp.applySessionChange(session: session, library: library, downloads: downloads)
        XCTAssertNotEqual(session.generation, signedInGeneration)
        XCTAssertEqual(library.owner, signedInOwner)
        XCTAssertTrue(library.containsReadLater(gallery))

        try await session.logout()
        ExViewerApp.applySessionChange(session: session, library: library, downloads: downloads)
        XCTAssertFalse(session.hasCredentials)
        XCTAssertEqual(session.owner, "guest")
        XCTAssertEqual(library.owner, "guest")
        XCTAssertFalse(library.containsReadLater(gallery))
        XCTAssertEqual(library.download(for: gallery.ref)?.completed, [1: "page-1.media"])
        XCTAssertEqual(session.exStatus, "未验证")
        let remaining = await session.webStore.httpCookieStore.allCookies()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testSiteVerificationSummarizesConnectionFailure() async {
        let session = session()
        PageProtocol.reset { _, _ in .lost }

        await session.verify()

        XCTAssertEqual(session.ehStatus, "连接失败")
        XCTAssertEqual(session.exStatus, "需要登录")
    }

    func testMockQuotaRefreshKeepsLastValidValueWhenSiteReturnsInvalidData() async throws {
        PageProtocol.reset { _, request in
            request == 1
                ? .response(200, "<p>You are currently at 1200 towards a limit of 10000.</p>", [:])
                : .response(200, "<p>Unknown account layout.</p>", [:])
        }
        let session = session()
        try await session.refreshQuota()
        XCTAssertEqual(session.quota.remaining, 8800)
        XCTAssertNil(session.error)
        do {
            try await session.refreshQuota()
            XCTFail("An unrecognized response must reach the requesting page")
        } catch is ViewerError {}
        XCTAssertEqual(session.quota.remaining, 8800)
        XCTAssertNil(session.error)
        XCTAssertEqual(PageProtocol.count("/home.php"), 2)
    }

    func testCancelledQuotaRefreshLeavesQuotaAndSharedErrorUnchanged() async throws {
        PageProtocol.reset { _, request in
            request == 1
                ? .response(200, "<p>You are currently at 1200 towards a limit of 10000.</p>", [:])
                : .hold
        }
        let session = session()
        try await session.refreshQuota()
        let request = Task { try await session.refreshQuota() }
        let started = await waitUntil { PageProtocol.count("/home.php") == 2 }
        XCTAssertTrue(started)
        request.cancel()
        do {
            try await request.value
            XCTFail("Cancellation must reach the caller")
        } catch is CancellationError {}
        XCTAssertEqual(session.quota.remaining, 8800)
        XCTAssertNil(session.error)
    }

    func testQuotaReadersShareRequestAndOneCanCancelIndependently() async throws {
        PageProtocol.reset { _, _ in
            .delayed(200, "<p>You are currently at 1200 towards a limit of 10000.</p>")
        }
        let session = session()
        let first = Task { try await session.refreshQuota() }
        let started = await waitUntil { PageProtocol.count("/home.php") == 1 }
        XCTAssertTrue(started)
        var secondStarted = false
        let second = Task {
            secondStarted = true
            try await session.refreshQuota()
        }
        let joined = await waitUntil { secondStarted }
        XCTAssertTrue(joined)
        first.cancel()
        do {
            try await first.value
            XCTFail("Cancelling the first caller must cancel its own wait")
        } catch is CancellationError {}
        try await second.value
        XCTAssertEqual(PageProtocol.count("/home.php"), 1)
        XCTAssertEqual(session.quota.remaining, 8800)
        XCTAssertNil(session.error)
    }

    func testReaderAndDownloadShareOnePageResolutionWhenReaderCancels() async throws {
        let imageHTML = #"<div id="i3"><img id="img" src="https://ehgt.org/fixture.png"></div>"#
        PageProtocol.reset { _, _ in .delayed(200, imageHTML) }
        let session = session()
        let page = url("/s/fixture/55-1")
        let reader = Task { try await session.imageSource(page, request: MediaRequestDemand(priority: .prefetch), recoverConnection: false) }
        let started = await waitUntil { PageProtocol.count(page.path) == 1 }
        XCTAssertTrue(started)
        let download = Task { try await session.imageSource(page, request: MediaRequestDemand()) }
        try await Task.sleep(nanoseconds: 25_000_000)
        reader.cancel()
        do { _ = try await reader.value; XCTFail("The cancelled reader should exit") }
        catch { XCTAssertTrue(error is CancellationError) }
        let resolved = try await download.value
        XCTAssertEqual(resolved.url.path, "/fixture.png")
        XCTAssertEqual(PageProtocol.count(page.path), 1, "The surviving download should keep the shared page request")
    }

    func testPageCacheScopeChangesWithEffectiveSiteSettingsOnly() async throws {
        PageProtocol.reset { _, count in
            let value = count == 3 ? "layout-b" : "layout-a"
            return .response(200, "<html>settings</html>", ["Set-Cookie": "uconfig=\(value); Path=/; Secure; Max-Age=\(60 + count)"])
        }
        let session = session()
        let initial = session.pageReadScope
        _ = try await session.html(url("/settings-fixture"))
        let saved = session.pageReadScope
        XCTAssertNotEqual(saved, initial)
        _ = try await session.html(url("/settings-fixture"))
        XCTAssertEqual(session.pageReadScope, saved, "Renewing the same setting should keep existing cached pages")
        _ = try await session.html(url("/settings-fixture"))
        XCTAssertNotEqual(session.pageReadScope, saved)
        XCTAssertEqual(session.pageReadScope.generation, saved.generation)
    }

    func testGalleryMetadataSharesIdenticalBatchesAndPacesTheNextDistinctBatch() async throws {
        let first = #"{"gmetadata":[{"gid":55,"rating":"4.31","tags":[]}]}"#
        let second = #"{"gmetadata":[{"gid":56,"rating":"3.15","tags":[]}]}"#
        PageProtocol.reset { _, count in count == 1 ? .delayed(200, first) : .response(200, second, [:]) }
        let session = session()
        let ref = GalleryRef(site: .eh, gid: 55, token: "fixture")
        let cover = Task { try await session.galleryMetadata([Gallery(ref: ref, title: "Cover fallback")], priority: .thumbnail) }
        let started = await waitUntil { PageProtocol.count("/api.php") == 1 }
        XCTAssertTrue(started)
        let list = try await session.galleryMetadata([Gallery(ref: ref, title: "Search fallback")], priority: .foreground)
        let coverResult = try await cover.value
        XCTAssertEqual(coverResult.first?.title, "Cover fallback")
        XCTAssertEqual(list.first?.title, "Search fallback")
        XCTAssertEqual(list.first?.rating, 4.31)
        XCTAssertEqual(PageProtocol.accept("/api.php"), "application/json")
        XCTAssertEqual(PageProtocol.count("/api.php"), 1)

        let next = Gallery(ref: GalleryRef(site: .eh, gid: 56, token: "fixture"), title: "Next")
        let nextResult = try await session.galleryMetadata([next], priority: .foreground)
        XCTAssertEqual(nextResult.first?.rating, 3.15)
        let times = PageProtocol.times("/api.php")
        XCTAssertEqual(times.count, 2)
        if times.count == 2 { XCTAssertGreaterThanOrEqual(times[1] - times[0], 1.28) }
    }

    func testDownloadCheckpointsAndRecoversFilesNewerThanItsLastSave() async throws {
        let reference = GalleryRef(site: .eh, gid: 57, token: "fixture")
        let gallery = Gallery(ref: reference, title: "Checkpoint fixture", pages: 12)
        func preview(_ pages: ClosedRange<Int>, next: Bool) -> String {
            let links = pages.map { "<a href='/s/fixture/57-\($0)'>Page \($0)</a>" }.joined()
            return "<h1 id='gn'>Fixture</h1><table id='gdd'><tr><td class='gdt1'>Length:</td><td class='gdt2'>12 pages</td></tr></table>" +
                "<div id='gdt'>\(links)</div>" + (next ? "<div class='ptt'><a href='?p=1' rel='next'>Next</a></div>" : "")
        }
        let first = preview(1...10, next: true), second = preview(11...12, next: false)
        PageProtocol.reset { _, count in count == 1 ? .response(200, first, [:]) : .hold }
        let session = session()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DownloadCheckpoint-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LibraryStore(qa: true, storageRoot: root)
        let files = library.offlineDirectory(gallery)
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
        for page in 1...12 { try png.write(to: files.appendingPathComponent("page-\(page).media")) }
        let download = DownloadManager(session: session, library: library)
        download.enqueue(gallery)
        let pausedAtNextPage = await waitUntil { PageProtocol.count(reference.url.path) == 2 }
        XCTAssertTrue(pausedAtNextPage)
        XCTAssertEqual(library.snapshot.downloads.first?.completed.count, 10)
        let reopened = LibraryStore(qa: true, storageRoot: root)
        XCTAssertEqual(reopened.snapshot.downloads.first?.status, .waiting)
        XCTAssertEqual(reopened.snapshot.downloads.first?.completed.count, 8, "Disk should only contain the last checkpoint")

        download.suspendForBackground()
        let suspended = LibraryStore(qa: true, storageRoot: root)
        XCTAssertEqual(suspended.snapshot.downloads.first?.status, .waiting)
        XCTAssertEqual(suspended.snapshot.downloads.first?.completed.count, 10)

        download.pause(gallery.id)
        let explicitPause = LibraryStore(qa: true, storageRoot: root)
        XCTAssertEqual(explicitPause.snapshot.downloads.first?.status, .paused)
        XCTAssertEqual(explicitPause.snapshot.downloads.first?.completed.count, 10)
        let manuallyPaused = DownloadManager(session: session, library: explicitPause)
        manuallyPaused.resumeQueuedDownloads()
        XCTAssertNil(manuallyPaused.running)

        PageProtocol.reset { _, count in .response(200, count == 1 ? first : second, [:]) }
        let resumed = DownloadManager(session: session, library: reopened)
        resumed.resumeQueuedDownloads()
        let completed = await waitUntil { resumed.running == nil }
        XCTAssertTrue(completed)
        let final = LibraryStore(qa: true, storageRoot: root)
        XCTAssertEqual(final.snapshot.downloads.first?.status, .complete)
        XCTAssertEqual(final.snapshot.downloads.first?.completed.count, 12)
        XCTAssertEqual(PageProtocol.total(), 2, "Recovering saved files should only fetch the two gallery indexes")
    }

    func testDownloadKeepsRunningOnForegroundReturnAndResumesAfterBackgroundExpiration() async throws {
        let gallery = Gallery(ref: .init(site: .eh, gid: 58, token: "fixture"), title: "Background fixture", pages: 1)
        let preview = """
        <h1 id="gn">Fixture</h1><table id="gdd"><tr><td class="gdt1">Length:</td><td class="gdt2">1 page</td></tr></table>
        <div id="gdt"><a href="/s/fixture/58-1">Page 1</a></div>
        """
        PageProtocol.reset { _, count in count == 1 ? .hold : .response(200, preview, [:]) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DownloadTransition-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LibraryStore(qa: true, storageRoot: root)
        let files = library.offlineDirectory(gallery)
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
        try png.write(to: files.appendingPathComponent("page-1.media"))
        let background = BackgroundExecution()
        let download = DownloadManager(session: session(), library: library, backgroundWork: background)
        defer { if download.running != nil { download.pauseAll() } }
        XCTAssertTrue(download.enqueue(gallery))
        let firstRequest = await waitUntil { PageProtocol.total() == 1 }
        XCTAssertTrue(firstRequest)

        download.suspendForBackground()
        XCTAssertEqual(library.download(for: gallery.ref)?.status, .downloading)
        download.resumeQueuedDownloads()
        background.expireContinuation()
        XCTAssertEqual(download.running, gallery.id)
        XCTAssertEqual(library.download(for: gallery.ref)?.status, .downloading)
        XCTAssertTrue(background.canContinue, "A late expiration should restore the short background grant")
        XCTAssertEqual(PageProtocol.total(), 1, "Returning to the app should keep the original request")

        download.suspendForBackground()
        XCTAssertEqual(download.running, gallery.id)
        background.expireShort()
        XCTAssertNil(download.running)
        let persisted = LibraryStore(qa: true, storageRoot: root)
        XCTAssertEqual(persisted.download(for: gallery.ref)?.status, .waiting)
        download.resumeQueuedDownloads()
        let completed = await waitUntil { library.download(for: gallery.ref)?.status == .complete }
        XCTAssertTrue(completed)
        XCTAssertEqual(library.download(for: gallery.ref)?.completed, [1: "page-1.media"])
        XCTAssertEqual(PageProtocol.total(), 2, "Resuming should only request the gallery index and reuse the saved page")
    }

    func testSearchConnectionLossRetriesOnceAndEveryActualDispatchRemainsPaced() async throws {
        XCTAssertEqual(URLError.networkConnectionLost.rawValue, -1005)
        PageProtocol.reset { _, count in count == 1 ? .lost : .response(200, "<html>recovered</html>", [:]) }
        let session = session(interval: 0.65)
        let result = try await session.html(url("/search-recover"), search: true)
        XCTAssertTrue(result.contains("recovered"))
        XCTAssertEqual(PageProtocol.count("/search-recover"), 2)
        let times = PageProtocol.times("/search-recover")
        XCTAssertEqual(times.count, 2)
        XCTAssertGreaterThanOrEqual(times[1] - times[0], 0.64, "The retry must re-enter actual search dispatch pacing")
    }

    func testPersistentSearchConnectionLossStopsAfterTwoAttempts() async {
        PageProtocol.reset { _, _ in .lost }
        let session = session()
        do { _ = try await session.html(url("/search-lost"), search: true); XCTFail("Expected bounded failure") }
        catch { XCTAssertEqual(error as? RequestFailure, .transport(.page, -1005)) }
        XCTAssertEqual(PageProtocol.count("/search-lost"), 2)
    }

    func testFavoritePostConnectionLossIsNeverRetried() async {
        PageProtocol.reset { _, _ in .lost }
        let session = session()
        do {
            _ = try await session.html(url("/favorites.php"), method: "POST", body: Data("fixture=local".utf8))
            XCTFail("Expected uncertain POST failure")
        } catch { XCTAssertEqual(error as? RequestFailure, .transport(.page, -1005)) }
        XCTAssertEqual(PageProtocol.count("/favorites.php"), 1)
    }

    func testAuthenticationChallengeQuotaAndRateLimitDoNotRetry() async {
        let cases: [(Int, String, [String: String])] = [
            (401, "<html>auth</html>", [:]), (429, "<html>rate</html>", [:]),
            (503, "<html>unavailable</html>", [:]), (509, "<html>quota</html>", [:]),
            (403, "<html>just a moment...</html>", ["cf-mitigated": "challenge"])
        ]
        for (status, body, headers) in cases {
            PageProtocol.reset { _, _ in .response(status, body, headers) }
            let session = session()
            do { _ = try await session.html(url("/protected"), search: true); XCTFail("Expected failure for \(status)") }
            catch { XCTAssertFalse(error is CancellationError) }
            XCTAssertEqual(PageProtocol.count("/protected"), 1, "HTTP \(status) must not auto-retry")
        }
    }

    func testGalleryResponseWithCommentAuthWordsReachesTheDetailParser() async throws {
        let html = "<h1 id='gn'>Neutral art book</h1><div id='gdt'><a href='/s/neutral/42-1'>Page 1</a></div><div id='cdiv'><div class='c3'>sadpanda</div><p>This page requires you to log on.</p></div>"
        PageProtocol.reset { _, _ in .response(200, html, [:]) }
        let session = session()
        let reference = GalleryRef(site: .eh, gid: 42, token: "neutral")
        let response = try await session.html(reference.url)
        let detail = try EHParser.detail(response, reference: reference)
        XCTAssertEqual(detail.gallery.title, "Neutral art book")
        XCTAssertEqual(detail.pages.map(\.index), [1])
        XCTAssertEqual(PageProtocol.count(reference.url.path), 1)
    }

    func testReaderReusesFreshDetailAndStillLoadsTheNextPreviewPage() async throws {
        let first = """
        <h1 id="gn">Neutral art book</h1>
        <table id="gdd"><tr><td class="gdt1">Length:</td><td class="gdt2">2 pages</td></tr></table>
        <table id="taglist"><tr><td class="tc">artist:</td><td><div class="gt"><a>sample</a></div></td></tr></table>
        <div id="gdt"><a href="/s/neutral/42-1">Page 1</a></div>
        <div class="ptt"><a href="?p=1" rel="next">Next</a></div>
        """
        let next = """
        <h1 id="gn">Neutral art book</h1>
        <table id="gdd"><tr><td class="gdt1">Length:</td><td class="gdt2">2 pages</td></tr></table>
        <div id="gdt"><a href="/s/neutral/42-2">Page 2</a></div>
        """
        let reference = GalleryRef(site: .eh, gid: 42, token: "neutral")
        let session = session()
        let library = LibraryStore(qa: true)

        PageProtocol.reset { _, _ in .response(200, first, [:]) }
        let initial = try EHParser.detail(await session.html(reference.url), reference: reference)
        let baseline = ReaderModel(qa: false)
        await baseline.load(gallery: initial.gallery, offline: false, session: session, library: library)
        XCTAssertEqual(PageProtocol.total(), 2, "Detail followed by a reader with no handoff fetches the root twice")
        XCTAssertNotNil(baseline.next)

        PageProtocol.reset { _, count in .response(200, count == 1 ? first : next, [:]) }
        let parsed = try EHParser.detail(await session.html(reference.url), reference: reference)
        let opening = ReaderOpeningDetail(detail: parsed, generation: session.generation, owner: library.owner)
        let reader = ReaderModel(qa: false)
        await reader.load(gallery: parsed.gallery, offline: false, session: session, library: library, openingDetail: opening)
        XCTAssertEqual(PageProtocol.total(), 1, "The reader should start from the detail response already fetched")
        XCTAssertEqual(reader.pages, baseline.pages)
        XCTAssertEqual(reader.total, baseline.total)
        XCTAssertEqual(reader.next, baseline.next)
        XCTAssertNil(reader.error)

        await reader.more(gallery: parsed.gallery, session: session, library: library)
        XCTAssertEqual(PageProtocol.total(), 2)
        XCTAssertEqual(reader.pages.map(\.index), [1, 2])
        XCTAssertNil(reader.next)

        library.block(GalleryTag(namespace: "artist", name: "sample"))
        let blocked = ReaderModel(qa: false)
        await blocked.load(gallery: parsed.gallery, offline: false, session: session, library: library, openingDetail: opening)
        XCTAssertTrue(blocked.pages.isEmpty)
        XCTAssertNotNil(blocked.error)
        XCTAssertEqual(PageProtocol.total(), 2)
    }

    func testReaderStopsRepeatedPreviewCursorAndKeepsLoadedPages() async throws {
        let reference = GalleryRef(site: .eh, gid: 42, token: "neutral")
        let session = session()
        let library = LibraryStore(qa: true)
        var gallery = Gallery(ref: reference, title: "Neutral art book", pages: 3)
        gallery.tagsComplete = true
        let page = GalleryPage(index: 1, url: try XCTUnwrap(URL(string: "https://e-hentai.org/s/neutral/42-1")))
        let detail = GalleryDetail(gallery: gallery, pages: [page], next: reference.url, archive: nil, favoriteName: nil)
        let opening = ReaderOpeningDetail(detail: detail, generation: session.generation, owner: library.owner)
        let reader = ReaderModel(qa: false)
        await reader.load(gallery: gallery, offline: false, session: session, library: library, openingDetail: opening)
        XCTAssertEqual(reader.pages, [page])
        XCTAssertNil(reader.next)
        XCTAssertNotNil(reader.error)
    }

    func testOpeningReaderDuringSlowDetailSharesOneRequestAndReopenUsesCache() async throws {
        let html = """
        <h1 id="gn">Neutral art book</h1>
        <table id="taglist"><tr><td class="tc">artist:</td><td><div class="gt"><a>sample</a></div></td></tr></table>
        <div id="gdt"><a href="/s/neutral/42-1">Page 1</a></div>
        """
        PageProtocol.reset { _, _ in .delayed(200, html) }
        let reference = GalleryRef(site: .eh, gid: 42, token: "neutral")
        let session = session()
        let library = LibraryStore(qa: true)
        let reader = ReaderModel(qa: false)
        let entry = Gallery(ref: reference, title: "Neutral art book")
        XCTAssertNil(session.cachedGalleryDetail(for: reference))

        async let pendingDetail = session.galleryDetail(for: reference)
        await reader.load(gallery: entry, offline: false, session: session, library: library)
        let detail = try await pendingDetail
        XCTAssertEqual(reader.pages, detail.detail.pages)
        XCTAssertEqual(detail.detail.gallery.tags, [.init(namespace: "artist", name: "sample")])
        XCTAssertEqual(PageProtocol.count(reference.url.path), 1)

        let cached = try XCTUnwrap(session.cachedGalleryDetail(for: reference))
        let reopened = try await session.galleryDetail(for: reference)
        XCTAssertEqual(reopened.fetchedAt, cached.fetchedAt)
        XCTAssertEqual(PageProtocol.count(reference.url.path), 1)
        _ = try await session.galleryDetail(for: reference, refresh: true)
        XCTAssertEqual(PageProtocol.count(reference.url.path), 2)
    }

    func testReaderRefetchesWhenTheOpeningDetailIsExpiredOrFromAnotherSession() async throws {
        let html = """
        <h1 id="gn">Neutral art book</h1>
        <div id="gdt"><a href="/s/neutral/42-1">Page 1</a></div>
        """
        let reference = GalleryRef(site: .eh, gid: 42, token: "neutral")
        let detail = try EHParser.detail(html, reference: reference)
        let library = LibraryStore(qa: true)
        let invalid: [(SiteSession) -> ReaderOpeningDetail] = [
            { _ in .init(detail: detail, generation: UUID(), owner: library.owner) },
            { .init(detail: detail, generation: $0.generation, owner: "a1") },
            { .init(detail: detail, generation: $0.generation, owner: library.owner, fetchedAt: .distantPast) }
        ]

        for makeOpening in invalid {
            PageProtocol.reset { _, _ in .response(200, html, [:]) }
            let coldSession = session()
            let opening = makeOpening(coldSession)
            let reader = ReaderModel(qa: false)
            await reader.load(gallery: detail.gallery, offline: false, session: coldSession, library: library, openingDetail: opening)
            XCTAssertEqual(PageProtocol.total(), 1)
            XCTAssertEqual(reader.pages, detail.pages)
            XCTAssertNil(reader.error)
        }
    }

    func testRealLoginResponseRetainsAuthenticationAndDoesNotRetry() async {
        for status in [200, 401] {
            PageProtocol.reset { _, _ in .response(status, "<p>This page requires you to <b>log on</b>.</p>", [:]) }
            let session = session()
            do { _ = try await session.html(url("/actual-login")); XCTFail("Expected authentication") }
            catch { XCTAssertEqual(error as? ViewerError, .authentication) }
            XCTAssertEqual(PageProtocol.count("/actual-login"), 1)
        }
    }

    func testForbiddenResponseIsNotRelabeledByACommentUsername() async {
        PageProtocol.reset { _, _ in .response(403, "<h1 id='gn'>Neutral</h1><div id='cdiv'>sadpanda</div>", [:]) }
        let session = session()
        do { _ = try await session.html(url("/forbidden-gallery")); XCTFail("Expected HTTP 403") }
        catch { XCTAssertEqual(error as? RequestFailure, .http(.page, 403)) }
        XCTAssertEqual(PageProtocol.count("/forbidden-gallery"), 1)
    }

    func testReadingPipelineKeepsOneTwoAttemptBudgetWithoutNestedGetRetries() async {
        PageProtocol.reset { _, _ in .lost }
        let session = session()
        let page = GalleryPage(index: 1, url: url("/s/fixture/55-1"))
        do {
            _ = try await PageMediaLoader.readerFile(page, session: session, owner: session.owner,
                                                    request: MediaRequestDemand(), isCurrent: { true })
            XCTFail("Expected bounded page failure")
        } catch { XCTAssertEqual(error as? RequestFailure, .transport(.page, -1005)) }
        XCTAssertEqual(PageProtocol.count(page.url.path), 2, "PageMediaLoader and the shared resolver must not multiply into four requests")
    }

    func testSixteenSpeculativePagesUseOneBackgroundSlotAndSearchPasses() async throws {
        PageProtocol.reset { path, _ in path.hasPrefix("/prefetch") ? .hold : .response(200, "<html>foreground</html>", [:]) }
        let session = session()
        let speculative = (0..<16).map { index in
            Task { try await session.html(self.url("/prefetch/\(index)"), request: MediaRequestDemand(priority: .prefetch)) }
        }
        defer { speculative.forEach { $0.cancel() } }
        let started = await waitUntil { PageProtocol.total() == 1 }
        XCTAssertTrue(started)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(PageProtocol.total(), 1, "Speculative HTML must not burst sixteen requests before media gating")
        let result = try await session.html(url("/foreground-search"), search: true)
        XCTAssertTrue(result.contains("foreground"))
        XCTAssertEqual(PageProtocol.count("/foreground-search"), 1)
        let peaks = PageProtocol.peaks()
        XCTAssertLessThanOrEqual(peaks.0, 2)
        XCTAssertEqual(peaks.1, 1)
        speculative.forEach { $0.cancel() }
        for request in speculative { _ = try? await request.value }
        XCTAssertEqual(PageProtocol.total(), 2, "Canceled queued prefetches must not reach transport")
    }
}
