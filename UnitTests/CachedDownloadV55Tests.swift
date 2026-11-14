import XCTest
import CryptoKit
import ImageIO
import ExViewerCore
@testable import ExViewer

final class CachedDownloadV55Tests: XCTestCase {
    @MainActor private final class BackgroundGrant: DownloadBackgroundWork {
        var canContinue = false
        var begins = 0, requests = 0, finishes = 0
        var endings: [DownloadBackgroundCompletion] = []
        var expiration: (@MainActor () -> Void)?
        var shortExpiration: (@MainActor () -> Void)?
        var progress: [Int] = []
        func beginShort(_ name: String, expired: @escaping @MainActor () -> Void) {
            guard !canContinue else { return }
            begins += 1; canContinue = true; shortExpiration = expired
        }
        func requestContinuation(stopped: @escaping @MainActor () -> Void) { requests += 1; expiration = stopped }
        func report(completed: Int, total: Int?) { progress.append(completed) }
        func finish(_ completion: DownloadBackgroundCompletion) { finishes += 1; endings.append(completion); canContinue = false }
        func expire() { canContinue = false; expiration?() }
    }

    @MainActor private final class BackgroundRig {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "DownloadBackgroundTests." + UUID().uuidString
        let defaults: UserDefaults
        let library: LibraryStore
        let session: SiteSession
        let manager: DownloadManager
        let repository: MediaRepository
        let grant = BackgroundGrant()
        let first = Gallery(ref: .init(site: .eh, gid: 159, token: "fixture"), title: "First", pages: 1)
        let second = Gallery(ref: .init(site: .eh, gid: 160, token: "fixture"), title: "Second", pages: 1)
        init(enabled: Bool) {
            defaults = UserDefaults(suiteName: suite)!
            defaults.set(enabled, forKey: DownloadLoadPolicy.backgroundKey)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [OfflineTraffic.self]
            session = SiteSession(qa: true, configuration: configuration)
            library = LibraryStore(qa: true, storageRoot: root)
            repository = MediaRepository(root: root.appendingPathComponent("Browse"), configuration: configuration)
            manager = DownloadManager(session: session, library: library, repository: repository, preferences: defaults, backgroundWork: grant)
        }
        func clean() {
            manager.pauseAll(); defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        func wait(_ condition: () -> Bool) async throws {
            for _ in 0..<500 { if condition() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
            XCTAssertTrue(condition())
        }
    }

    @MainActor func testBackgroundEndingsDistinguishGracefulPauseFromFailureWithoutFakingProgress() {
        for completion in [DownloadBackgroundCompletion.paused, .waiting, .foregroundOnly] {
            let end = DownloadBackgroundEnd(completion: completion, completed: 3, total: 10)
            XCTAssertTrue(completion.systemSuccess)
            XCTAssertTrue(end.subtitle.contains("3/10"))
            XCTAssertNotEqual(completion.title, DownloadBackgroundCompletion.completed.title)
        }
        XCTAssertFalse(DownloadBackgroundCompletion.failed.systemSuccess)
        XCTAssertEqual(DownloadBackgroundCompletion.failed.title, "下载失败")
    }

    @MainActor func testLateContinuationPreservesItsOriginalEndingAndDoesNotChangeTheNewRequest() throws {
        for completion in [DownloadBackgroundCompletion.paused, .waiting, .failed, .completed] {
            let old = DownloadBackgroundRequestState(identifier: "old")
            old.finish(completion, completed: 3, total: 10)
            let next = DownloadBackgroundRequestState(identifier: "next")
            old.finish(.failed, completed: 0, total: nil)
            let end = try XCTUnwrap(old.end)
            XCTAssertEqual(end, .init(completion: completion, completed: 3, total: 10))
            XCTAssertEqual(end.completion.systemSuccess, completion != .failed)
            XCTAssertNil(next.end)
        }
    }

    @MainActor func testManualPauseKeepsSavedPagesAndNeverReportsSystemFailureOrAutoResumes() async throws {
        OfflineTraffic.reset(delay: 200)
        let rig = BackgroundRig(enabled: true); defer { rig.clean() }
        let gallery = Gallery(ref: .init(site: .eh, gid: 158, token: "fixture"), title: "Partial", pages: OfflineTraffic.pageCount)
        XCTAssertTrue(rig.manager.enqueue(gallery))
        try await rig.wait { (rig.library.download(for: gallery.ref)?.completed.count ?? 0) > 0 }
        rig.manager.pause(gallery.id)
        let saved = try XCTUnwrap(rig.library.download(for: gallery.ref))
        XCTAssertEqual(saved.status, .paused); XCTAssertNil(saved.error)
        XCTAssertFalse(saved.completed.isEmpty); XCTAssertLessThan(saved.completed.count, OfflineTraffic.pageCount)
        XCTAssertEqual(rig.grant.endings.last, .paused)
        rig.manager.resumeQueuedDownloads()
        XCTAssertNil(rig.manager.running)
        try await Task.sleep(nanoseconds: 100_000_000)
        let restored = LibraryStore(qa: true, storageRoot: rig.root)
        XCTAssertEqual(restored.download(for: gallery.ref)?.status, .paused)
        XCTAssertEqual(restored.download(for: gallery.ref)?.completed, saved.completed)
        XCTAssertNil(restored.download(for: gallery.ref)?.error)
    }

    @MainActor func testPausingAWaitingJobClearsItsOldErrorAndFailurePresentation() throws {
        let rig = BackgroundRig(enabled: true); defer { rig.clean() }
        rig.library.updateDownload(.init(gallery: rig.first, status: .waiting, total: 1, error: "旧的网络错误"))
        rig.manager.pause(rig.first.id)
        let saved = try XCTUnwrap(rig.library.download(for: rig.first.ref))
        XCTAssertEqual(saved.status, .paused); XCTAssertNil(saved.error)
        XCTAssertFalse(saved.requiresRetry)
    }

    @MainActor func testPauseCheckpointStorageFailureStillReportsARealFailure() throws {
        let rig = BackgroundRig(enabled: true); defer { rig.clean() }
        XCTAssertTrue(rig.manager.enqueue(rig.first))
        let index = rig.library.directory.appendingPathComponent("library.json")
        try FileManager.default.removeItem(at: index)
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: true)
        rig.manager.pause(rig.first.id)
        XCTAssertNotNil(rig.library.error)
        XCTAssertEqual(rig.grant.endings.last, .failed)
    }

    @MainActor func testBackgroundQueueContinuesIntoNextGalleryAndReportsMonotonicProgress() async throws {
        OfflineTraffic.reset(delay: 100)
        let rig = BackgroundRig(enabled: true); defer { rig.clean() }
        XCTAssertTrue(rig.manager.enqueue(rig.first)); XCTAssertTrue(rig.manager.enqueue(rig.second))
        rig.manager.suspendForBackground()
        try await rig.wait { rig.manager.running == nil }
        XCTAssertEqual(rig.library.download(for: rig.first.ref)?.status, .complete)
        XCTAssertEqual(rig.library.download(for: rig.second.ref)?.status, .complete)
        XCTAssertEqual(rig.grant.begins, 1, "A queue should retain its grant between galleries")
        XCTAssertEqual(rig.grant.finishes, 1)
        XCTAssertEqual(rig.grant.endings, [.completed])
        XCTAssertEqual(rig.grant.progress, rig.grant.progress.sorted())
        XCTAssertEqual(rig.grant.progress.last, 2)
    }

    @MainActor func testDisabledBackgroundStopsAsWaitingAndResumesOnlyOnForeground() async throws {
        OfflineTraffic.reset(delay: 200)
        let rig = BackgroundRig(enabled: false); defer { rig.clean() }
        XCTAssertTrue(rig.manager.enqueue(rig.first))
        XCTAssertEqual(rig.grant.begins, 0); XCTAssertEqual(rig.grant.requests, 0)
        rig.manager.suspendForBackground()
        XCTAssertNil(rig.manager.running)
        XCTAssertEqual(rig.library.download(for: rig.first.ref)?.status, .waiting)
        XCTAssertTrue(rig.manager.enqueue(rig.second)); XCTAssertNil(rig.manager.running)
        rig.manager.resumeQueuedDownloads()
        try await rig.wait { rig.manager.running == nil }
        XCTAssertEqual(rig.library.download(for: rig.first.ref)?.status, .complete)
        XCTAssertEqual(rig.library.download(for: rig.second.ref)?.status, .complete)
        XCTAssertEqual(rig.grant.begins, 0)
    }

    @MainActor func testRevokingBackgroundAccessDoesNotPauseForegroundButOldExpiryCannotStopNewRun() async throws {
        OfflineTraffic.reset(delay: 200)
        let rig = BackgroundRig(enabled: true); defer { rig.clean() }
        XCTAssertTrue(rig.manager.enqueue(rig.first))
        let oldExpiry = rig.grant.expiration
        rig.defaults.set(false, forKey: DownloadLoadPolicy.backgroundKey)
        rig.manager.updateBackgroundDownloadPreference()
        XCTAssertEqual(rig.grant.endings.last, .foregroundOnly)
        XCTAssertEqual(rig.manager.running, rig.first.id)
        rig.manager.suspendForBackground()
        XCTAssertNil(rig.manager.running)
        rig.defaults.set(true, forKey: DownloadLoadPolicy.backgroundKey)
        rig.manager.resumeQueuedDownloads(); rig.manager.suspendForBackground()
        oldExpiry?()
        XCTAssertEqual(rig.manager.running, rig.first.id)
        try await rig.wait { rig.manager.running == nil }
        XCTAssertEqual(rig.library.download(for: rig.first.ref)?.status, .complete)
    }

    @MainActor func testBackgroundExpirationPersistsWaitingAndManualPauseDoesNotAutoResume() async throws {
        OfflineTraffic.reset(delay: 200)
        let rig = BackgroundRig(enabled: true); defer { rig.clean() }
        XCTAssertTrue(rig.manager.enqueue(rig.first)); rig.manager.suspendForBackground(); rig.grant.expire()
        XCTAssertEqual(rig.grant.endings, [.waiting])
        XCTAssertNil(rig.manager.running)
        XCTAssertEqual(rig.library.download(for: rig.first.ref)?.status, .waiting)
        rig.manager.resumeQueuedDownloads()
        try await rig.wait { rig.manager.running == nil }
        XCTAssertTrue(rig.manager.enqueue(rig.second)); rig.manager.pause(rig.second.id)
        rig.manager.resumeQueuedDownloads()
        XCTAssertNil(rig.manager.running)
        XCTAssertEqual(rig.library.download(for: rig.second.ref)?.status, .paused)
    }

    @MainActor func testSystemContinuedTaskStopInForegroundDoesNotImmediatelyRestartQueue() async throws {
        OfflineTraffic.reset(delay: 200)
        let rig = BackgroundRig(enabled: true); defer { rig.clean() }
        XCTAssertTrue(rig.manager.enqueue(rig.first)); XCTAssertTrue(rig.manager.enqueue(rig.second))
        rig.grant.expire()
        XCTAssertEqual(rig.grant.endings, [.waiting], "A system stop ends the grant once without reporting failure")
        XCTAssertNil(rig.manager.running)
        let requests = rig.grant.requests
        rig.manager.resumeQueuedDownloads()
        XCTAssertNil(rig.manager.running); XCTAssertEqual(rig.grant.requests, requests)
        XCTAssertEqual(rig.library.download(for: rig.first.ref)?.status, .waiting)
        rig.manager.suspendForBackground(); rig.manager.resumeQueuedDownloads()
        try await rig.wait { rig.manager.running == nil }
        XCTAssertEqual(rig.library.download(for: rig.second.ref)?.status, .complete)
    }

    @MainActor func testShortGrantExpiryCanRenewInForeground() async throws {
        OfflineTraffic.reset(delay: 100)
        let rig = BackgroundRig(enabled: true); defer { rig.clean() }
        XCTAssertTrue(rig.manager.enqueue(rig.first))
        rig.grant.canContinue = false; rig.grant.shortExpiration?()
        XCTAssertEqual(rig.manager.running, rig.first.id)
        XCTAssertEqual(rig.grant.begins, 2)
        try await rig.wait { rig.manager.running == nil }
    }

    @MainActor func testRestartRestoresDownloadingButPreservesManualPauseEvenWithBackgroundDisabled() async throws {
        OfflineTraffic.reset(delay: 0)
        let rig = BackgroundRig(enabled: false); defer { rig.clean() }
        rig.library.updateDownload(.init(gallery: rig.first, status: .downloading, total: 1))
        rig.library.updateDownload(.init(gallery: rig.second, status: .paused, total: 1))
        let restored = LibraryStore(qa: true, storageRoot: rig.root)
        XCTAssertEqual(restored.download(for: rig.first.ref)?.status, .waiting)
        XCTAssertEqual(restored.download(for: rig.second.ref)?.status, .paused)
        let manager = DownloadManager(session: rig.session, library: restored, repository: rig.repository, preferences: rig.defaults, backgroundWork: rig.grant)
        defer { manager.pauseAll() }
        manager.resumeQueuedDownloads()
        try await rig.wait { manager.running == nil }
        XCTAssertEqual(restored.download(for: rig.first.ref)?.status, .complete)
        XCTAssertEqual(restored.download(for: rig.second.ref)?.status, .paused)
        XCTAssertEqual(rig.grant.requests, 0)
    }

    @MainActor func testAutomaticResumeDoesNotStartAnotherAccountsQueuedDownload() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DownloadOwner-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = SiteSession(qa: true)
        let library = LibraryStore(qa: true, storageRoot: root)
        library.load(owner: "abcdef")
        XCTAssertNotEqual(library.owner, session.owner)
        let gallery = Gallery(ref: .init(site: .eh, gid: 42, token: "neutral"), title: "Neutral art book")
        library.updateDownload(.init(gallery: gallery, status: .waiting))
        XCTAssertEqual(library.download(for: gallery.ref)?.status, .waiting)
        let manager = DownloadManager(session: session, library: library)
        manager.resumeQueuedDownloads()
        XCTAssertNil(manager.running)
        XCTAssertEqual(library.download(for: gallery.ref)?.status, .waiting)
    }

    func testDetailDownloadStateAlignsOldAndNewReferencesThroughUpgrade() {
        let old = GalleryRef(site: .ex, gid: 70, token: "old")
        let newest = GalleryRef(site: .ex, gid: 72, token: "new")
        let original = DownloadRecord(gallery: Gallery(ref: old, title: "Earlier"), status: .complete)
        let generation = UUID()
        func state(_ ref: GalleryRef, _ records: [DownloadRecord], _ links: GalleryVersionLinks? = nil) -> GalleryDownloadState {
            .resolve(ref, records: records, links: links, owner: "guest", generation: generation)
        }
        XCTAssertEqual(state(old, []).title, "离线下载")
        XCTAssertEqual(state(old, [original]).title, "下载完成")
        let olderPage = GalleryVersionLinks(latest: newest, earlier: [])
        let latestPage = GalleryVersionLinks(latest: newest, earlier: [old])
        for (ref, links) in [(old, olderPage), (newest, latestPage)] {
            guard case .update(let update) = state(ref, [original], links) else { return XCTFail("Expected an upgrade from either version") }
            XCTAssertEqual(update, .init(old: old, target: newest, owner: "guest", generation: generation))
        }
        var upgrade = DownloadRecord(gallery: Gallery(ref: newest, title: "Latest"), status: .waiting, replaces: old)
        XCTAssertEqual(state(old, [original, upgrade]).title, "等待下载")
        XCTAssertEqual(state(newest, [original, upgrade]).progress, "等待中")
        upgrade.status = .downloading
        XCTAssertEqual(state(newest, [original, upgrade]).title, "正在下载")
        upgrade.status = .paused
        XCTAssertEqual(state(old, [original, upgrade]).title, "更新可用")
        upgrade.status = .complete
        upgrade.replaces = nil
        XCTAssertEqual(state(old, [upgrade], olderPage).title, "下载完成")
        XCTAssertEqual(state(newest, [upgrade]).title, "下载完成")
        let unrelated = GalleryRef(site: .ex, gid: old.gid, token: "other")
        XCTAssertEqual(state(newest, [original], .init(latest: newest, earlier: [unrelated])).title, "离线下载")
    }

    private final class VersionTraffic: URLProtocol, @unchecked Sendable {
        private static let lock = NSLock()
        private static var paths: [String] = []
        private static var rateLimited = false

        static func reset(rateLimited: Bool) {
            lock.withLock { paths = []; self.rateLimited = rateLimited }
        }

        static func imageRequests() -> [String] { lock.withLock { paths } }

        override class func canInit(with request: URLRequest) -> Bool {
            ["e-hentai.org", "api.e-hentai.org", "offline.fixture.hath.network"].contains(request.url?.host ?? "")
        }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let url = request.url!
            if url.host == "api.e-hentai.org" {
                let metadata = #"{"gmetadata":[{"gid":159,"token":"old","current_gid":"160","current_key":"new"}]}"#
                deliver(Data(metadata.utf8), type: "application/json")
            } else if url.host == "offline.fixture.hath.network" {
                let rateLimited = Self.lock.withLock { Self.paths.append(url.path); return Self.rateLimited }
                deliver(Images.png, type: "image/png", status: rateLimited ? 429 : 200)
            } else if url.path.hasPrefix("/s/") {
                let image = if url.path.hasSuffix("-2") {
                    "https://offline.fixture.hath.network/h/\(Insecure.SHA1.hash(data: Images.png).map { String(format: "%02x", $0) }.joined())-\(Images.png.count)-1-1-png/fixture/moved.png"
                } else {
                    "https://offline.fixture.hath.network/fresh.png"
                }
                deliver(Data("<div id='i3'><img id='img' src='\(image)'></div>".utf8), type: "text/html")
            } else {
                let detail = "<h1 id='gn'>Updated fixture</h1><table id='gdd'><tr><td class='gdt1'>Length:</td><td class='gdt2'>2 pages</td></tr></table><div id='gdt'><a href='/s/fixture/160-1'>Page 1</a><a href='/s/fixture/160-2'>Page 2</a></div>"
                deliver(Data(detail.utf8), type: "text/html")
            }
        }

        override func stopLoading() { }

        private func deliver(_ data: Data, type: String, status: Int = 200) {
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": type])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    @MainActor func testVersionUpdateReusesMovedPageAndDefersRetirementWhileReading() async throws {
        try await exerciseVersionUpdate(rateLimited: false)
    }

    @MainActor func testVersionUpdateKeepsOldCopyOnRateLimit() async throws {
        try await exerciseVersionUpdate(rateLimited: true)
    }

    @MainActor private func exerciseVersionUpdate(rateLimited: Bool) async throws {
        VersionTraffic.reset(rateLimited: rateLimited)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OfflineVersion-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [VersionTraffic.self]
        let repository = MediaRepository(root: root.appendingPathComponent("Browse"), configuration: config)
        let session = SiteSession(qa: true, configuration: config)
        let library = LibraryStore(qa: true, storageRoot: root)
        let old = Gallery(ref: .init(site: .eh, gid: 159, token: "old"), title: "Older fixture", pages: 1)
        let oldDirectory = library.offlineDirectory(old)
        try FileManager.default.createDirectory(at: oldDirectory, withIntermediateDirectories: true)
        try Images.png.write(to: oldDirectory.appendingPathComponent("page-1.media"))
        library.updateDownload(.init(gallery: old, status: .complete, completed: [1: "page-1.media"], total: 1))
        let current = try await session.currentGalleryVersion(old)
        let reference = try XCTUnwrap(current)
        XCTAssertEqual(reference, GalleryRef(site: .eh, gid: 160, token: "new"))
        let newer = Gallery(ref: reference, title: "New fixture")
        let reader = UUID()
        library.pinOfflineReader(old.ref, context: reader)
        let downloads = DownloadManager(session: session, library: library, repository: repository)
        defer { downloads.pauseAll() }
        XCTAssertTrue(downloads.enqueue(newer, replacing: old.ref))
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while downloads.running != nil && ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNil(downloads.running)
        XCTAssertEqual(VersionTraffic.imageRequests(), ["/fresh.png"])
        XCTAssertEqual(library.download(for: old.ref)?.status, .complete)
        let updated = try XCTUnwrap(library.download(for: reference))
        if rateLimited {
            XCTAssertEqual(updated.status, .failed)
            XCTAssertTrue(updated.error?.contains("429") == true)
            library.unpinOfflineReader(context: reader)
            XCTAssertTrue(FileManager.default.fileExists(atPath: oldDirectory.path))
            return
        }
        XCTAssertEqual(updated.status, .complete)
        XCTAssertEqual(updated.gallery.title, "Updated fixture")
        let pages = library.downloadedPages(updated)
        XCTAssertEqual(pages.map(\.index), [1, 2])
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(pages.last).url), Images.png)
        library.unpinOfflineReader(context: reader)
        XCTAssertNil(library.download(for: old.ref))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldDirectory.path))
        XCTAssertNil(library.download(for: reference)?.replaces)
        XCTAssertEqual(LibraryStore(qa: true, storageRoot: root).download(for: reference)?.status, .complete)
    }

    private final class OfflineTraffic: URLProtocol, @unchecked Sendable {
        private static let lock = NSLock()
        private static var active = Set<ObjectIdentifier>()
        private static var peak = 0
        private static var imageStarts: [TimeInterval] = []
        private static var delayMilliseconds = 950
        private static var failedPath: String?
        private static var failureStatus = 429
        private static var requestedPaths: [String] = []
        static let pageCount = 6

        static func reset(delay: Int, failing path: String? = nil, status: Int = 429) {
            lock.withLock {
                active.removeAll(); peak = 0; imageStarts.removeAll()
                delayMilliseconds = delay; failedPath = path; failureStatus = status; requestedPaths.removeAll()
            }
        }
        static func recover() { lock.withLock { failedPath = nil } }
        static func imageRequests() -> [String] { lock.withLock { requestedPaths } }
        static func sample() -> (peak: Int, imageStarts: [TimeInterval]) { lock.withLock { (peak, imageStarts) } }
        override class func canInit(with request: URLRequest) -> Bool {
            ["e-hentai.org", "offline.fixture.hath.network"].contains(request.url?.host ?? "")
        }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let url = request.url!
            let path = url.path
            if url.host == "offline.fixture.hath.network" {
                let (delay, status) = Self.lock.withLock {
                    Self.active.insert(ObjectIdentifier(self))
                    Self.peak = max(Self.peak, Self.active.count)
                    Self.imageStarts.append(ProcessInfo.processInfo.systemUptime)
                    Self.requestedPaths.append(path)
                    return (Self.delayMilliseconds, Self.failedPath == path ? Self.failureStatus : 200)
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(delay)) { [weak self] in
                    guard let self, self.endImage() else { return }
                    self.deliver(Images.png, type: "image/png", status: status)
                }
            } else if path.hasPrefix("/s/"), let page = path.split(separator: "/").last {
                let parts = page.split(separator: "-")
                let image = parts.first == "158" ? String(parts.last!) : "\(parts.first!)/\(parts.last!)"
                deliver(Data("<div id='i3'><img id='img' src='https://offline.fixture.hath.network/\(image).png'></div>".utf8), type: "text/html")
            } else {
                let gid = path.split(separator: "/").dropFirst().first ?? "158"
                let count = gid == "158" ? Self.pageCount : 1
                let links = (1...count).map { "<a href='/s/fixture/\(gid)-\($0)'>Page \($0)</a>" }.joined()
                let preview = "<h1 id='gn'>Transfer fixture</h1><table id='gdd'><tr><td class='gdt1'>Length:</td><td class='gdt2'>\(count) pages</td></tr></table><div id='gdt'>\(links)</div>"
                deliver(Data(preview.utf8), type: "text/html")
            }
        }

        override func stopLoading() { _ = endImage() }

        private func endImage() -> Bool {
            Self.lock.withLock { Self.active.remove(ObjectIdentifier(self)) != nil }
        }

        private func deliver(_ data: Data, type: String, status: Int = 200) {
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": type])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    @MainActor func testOfflineDownloadCompletesAllPagesWithMeasuredTraffic() async throws {
        try await verifyOfflineTraffic(concurrency: nil, delay: 950, expectedPeak: 2)
    }

    @MainActor func testOfflineDownloadRetriesFailedPageAfterRelaunchWithoutRedownloadingSavedPage() async throws {
        OfflineTraffic.reset(delay: 0, failing: "/2.png")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OfflineRetry-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineTraffic.self]
        let suite = "OfflineRetry-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(1, forKey: DownloadLoadPolicy.concurrencyKey)
        let knownTag = GalleryTag(namespace: "language", name: "english")
        let gallery = Gallery(ref: .init(site: .eh, gid: 158, token: "fixture"), title: "Transfer fixture",
                              pages: OfflineTraffic.pageCount, tags: [knownTag])

        func finish(_ manager: DownloadManager) async throws {
            let deadline = ProcessInfo.processInfo.systemUptime + 20
            while manager.running != nil && ProcessInfo.processInfo.systemUptime < deadline {
                try await Task.sleep(nanoseconds: 25_000_000)
            }
            XCTAssertNil(manager.running)
        }

        let original = LibraryStore(qa: true, storageRoot: root)
        let firstSession = SiteSession(qa: true, configuration: configuration)
        let first = DownloadManager(session: firstSession, library: original,
                                    repository: MediaRepository(root: root.appendingPathComponent("Browse"), configuration: configuration),
                                    preferences: defaults)
        defer { first.pauseAll() }
        XCTAssertTrue(first.enqueue(gallery))
        try await finish(first)

        let reopened = LibraryStore(qa: true, storageRoot: root)
        let saved = try XCTUnwrap(reopened.download(for: gallery.ref))
        XCTAssertEqual(saved.status, .failed)
        XCTAssertTrue(saved.error?.contains("429") == true)
        XCTAssertEqual(Set(saved.completed.keys), [1])
        XCTAssertEqual(OfflineTraffic.imageRequests(), ["/1.png", "/2.png"])
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(reopened.downloadedPages(saved).first).url), Images.png)

        OfflineTraffic.recover()
        let secondSession = SiteSession(qa: true, configuration: configuration)
        let second = DownloadManager(session: secondSession, library: reopened,
                                     repository: MediaRepository(root: root.appendingPathComponent("Browse"), configuration: configuration),
                                     preferences: defaults)
        defer { second.pauseAll() }
        second.resumeQueuedDownloads()
        XCTAssertNil(second.running, "A failed job waits for an explicit retry")
        XCTAssertTrue(second.enqueue(gallery))
        try await finish(second)

        let completed = try XCTUnwrap(LibraryStore(qa: true, storageRoot: root).download(for: gallery.ref))
        XCTAssertEqual(completed.status, .complete, completed.error ?? "")
        XCTAssertNil(completed.error)
        XCTAssertEqual(completed.gallery.tags, [knownTag])
        XCTAssertFalse(completed.gallery.tagsComplete, "A response without a tag list must not confirm the existing partial tags")
        XCTAssertEqual(OfflineTraffic.imageRequests(), ["/1.png", "/2.png"] + (2...OfflineTraffic.pageCount).map { "/\($0).png" })
        let files = reopened.downloadedPages(completed)
        XCTAssertEqual(files.map(\.index), Array(1...OfflineTraffic.pageCount))
        for file in files { XCTAssertEqual(try Data(contentsOf: file.url), Images.png) }
    }

    @MainActor func testMissingImageAdvancesQueueButRateLimitLeavesNextJobWaiting() async throws {
        for status in [404, 429] {
            OfflineTraffic.reset(delay: 0, failing: "/1.png", status: status)
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("DownloadQueue-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [OfflineTraffic.self]
            let library = LibraryStore(qa: true, storageRoot: root)
            let session = SiteSession(qa: true, configuration: configuration)
            let repository = MediaRepository(root: root.appendingPathComponent("Browse"), configuration: configuration)
            let suite = "DownloadQueue-" + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set(1, forKey: DownloadLoadPolicy.concurrencyKey)
            let grant = BackgroundGrant()
            let manager = DownloadManager(session: session, library: library, repository: repository, preferences: defaults, backgroundWork: grant)
            defer { manager.pauseAll() }
            let first = Gallery(ref: .init(site: .eh, gid: 158, token: "fixture"), title: "First", pages: OfflineTraffic.pageCount)
            let next = Gallery(ref: .init(site: .eh, gid: 159, token: "fixture"), title: "Next", pages: 1)
            XCTAssertTrue(manager.enqueue(first))
            XCTAssertTrue(manager.enqueue(next))
            let deadline = ProcessInfo.processInfo.systemUptime + 8
            while manager.running != nil && ProcessInfo.processInfo.systemUptime < deadline {
                try await Task.sleep(nanoseconds: 25_000_000)
            }
            XCTAssertNil(manager.running)
            XCTAssertEqual(grant.endings.last, .failed, "An earlier failed gallery must not become a completed queue after a later success")
            XCTAssertEqual(library.download(for: first.ref)?.status, .failed)
            XCTAssertEqual(library.download(for: next.ref)?.status, status == 404 ? .complete : .waiting)
            XCTAssertEqual(OfflineTraffic.imageRequests().contains("/159/1.png"), status == 404)
        }
    }

    @MainActor func testTorrentExportOwnsItsFileAndOldCompletionDoesNotRemoveNewExport() async throws {
        let info = Data("d6:lengthi4e4:name12:sample01.png12:piece lengthi16384e6:pieces20:".utf8)
            + Data(repeating: 0, count: 20) + Data("e".utf8)
        let hash = Insecure.SHA1.hash(data: info).map { String(format: "%02x", $0) }.joined()
        let url = try XCTUnwrap(URL(string: "https://ehtracker.org/get/1/\(hash).torrent"))
        let torrent = GalleryTorrent(title: "Fixture", downloadURL: url, infoHash: hash)
        let gallery = Gallery(ref: .init(site: .eh, gid: 42, token: "fixture"), title: "Fixture")
        let raw = Data("d8:announce12:private-test4:info".utf8) + info + Data("e".utf8)
        let tracker = "http://ehtracker.org/42/announce"
        let expected = Data("d8:announce\(tracker.utf8.count):\(tracker)4:info".utf8) + info + Data("e".utf8)
        let model = GalleryTorrentsModel(gallery: gallery, session: SiteSession(qa: true)) { _ in raw }

        func export() async throws {
            model.prepare(torrent)
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            while model.preparing != nil && ProcessInfo.processInfo.systemUptime < deadline {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            XCTAssertNil(model.error)
            let file = try XCTUnwrap(model.share?.file)
            XCTAssertEqual(file.lastPathComponent, hash + ".torrent")
            XCTAssertEqual(try Data(contentsOf: file), expected)
        }
        try await export()
        let firstID = try XCTUnwrap(model.share?.id)
        let firstFile = try XCTUnwrap(model.share?.file)
        model.finishSharing(firstID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstFile.deletingLastPathComponent().path))

        try await export()
        let secondFile = try XCTUnwrap(model.share?.file)
        model.finishSharing(firstID)
        XCTAssertEqual(model.share?.file, secondFile)
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondFile.path))
        model.cancel()
        XCTAssertNil(model.share)
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondFile.deletingLastPathComponent().path))
    }

    @MainActor func testThirtyTwoPageWindowCanOverlapMoreThanFourSlowImages() async throws {
        try await verifyOfflineTraffic(concurrency: 32, delay: 4_500, expectedPeak: 6)
    }

    @MainActor private func verifyOfflineTraffic(concurrency: Int?, delay: Int, expectedPeak: Int) async throws {
        OfflineTraffic.reset(delay: delay)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OfflineTraffic-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineTraffic.self]
        let repository = MediaRepository(root: root.appendingPathComponent("Browse"), configuration: configuration)
        let session = SiteSession(qa: true, configuration: configuration)
        let library = LibraryStore(qa: true, storageRoot: root)
        let suite = "OfflineTraffic-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        if let concurrency { defaults.set(concurrency, forKey: DownloadLoadPolicy.concurrencyKey) }
        let manager = DownloadManager(session: session, library: library, repository: repository, preferences: defaults)
        defer { manager.pauseAll() }
        let gallery = Gallery(ref: .init(site: .eh, gid: 158, token: "fixture"), title: "Transfer fixture", pages: OfflineTraffic.pageCount)

        let started = ProcessInfo.processInfo.systemUptime
        manager.enqueue(gallery)
        while manager.running != nil && ProcessInfo.processInfo.systemUptime - started < 20 {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        let record = try XCTUnwrap(library.download(for: gallery.ref))
        XCTAssertEqual(record.status, .complete, record.error ?? "")
        XCTAssertEqual(record.completed.count, OfflineTraffic.pageCount)
        let sample = OfflineTraffic.sample()
        XCTAssertEqual(sample.imageStarts.count, OfflineTraffic.pageCount)
        XCTAssertEqual(sample.peak, expectedPeak, "Downloads must use the configured page window while keeping site requests paced")
        // URLProtocol observes media delivery after HTML parsing and scheduling;
        // individual gaps include callback jitter. The gate's exact minimum is
        // covered separately by SiteRequestSchedulerV18Tests.
        if let first = sample.imageStarts.first, let last = sample.imageStarts.last {
            XCTAssertGreaterThanOrEqual(last - first, 0.70 * Double(OfflineTraffic.pageCount - 1),
                                        "Offline image transfer must retain the paced window")
        }
        for file in library.downloadedPages(record) { XCTAssertEqual(try Data(contentsOf: file.url), Images.png) }
        print("OFFLINE_TRAFFIC limit=\(DownloadLoadPolicy.configuredConcurrency(defaults: defaults)) pages=\(record.completed.count) peak=\(sample.peak) seconds=\(ProcessInfo.processInfo.systemUptime - started)")
    }

    @MainActor func testNormalReaderEntryUsesCompleteLocalCopyBeforeNetwork() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LibraryStore(qa: true, storageRoot: root)
        let session = SiteSession(qa: true)
        var gallery = Gallery(ref: .init(site: .eh, gid: 55, token: "sample"), title: "Offline fixture", pages: 1)
        gallery.tagsComplete = true
        let directory = library.offlineDirectory(gallery)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let page = directory.appendingPathComponent("page-1.media")
        try Images.png.write(to: page)
        library.updateDownload(.init(gallery: gallery, status: .complete, completed: [1: "page-1.media"], total: 1))
        let reader = ReaderModel(qa: false)
        await reader.load(gallery: gallery, offline: false, session: session, library: library)
        XCTAssertEqual(reader.pages.map(\.url), [page])
        XCTAssertNil(reader.next)
        XCTAssertNil(reader.error)
    }

    private final class Images: URLProtocol, @unchecked Sendable {
        private static let lock = NSLock()
        private static var hits: [String: Int] = [:]
        static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        static func reset() { lock.lock(); hits = [:]; lock.unlock() }
        static func count(_ path: String? = nil) -> Int {
            lock.lock(); defer { lock.unlock() }
            return path.map { hits[$0, default: 0] } ?? hits.values.reduce(0, +)
        }
        override class func canInit(with request: URLRequest) -> Bool { ["offline.fixture.hath.network", "e-hentai.org"].contains(request.url?.host ?? "") }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let url = request.url!
            Self.lock.lock(); Self.hits[url.path, default: 0] += 1; Self.lock.unlock()
            let isPage = url.path.hasPrefix("/s/")
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
                "Content-Type": isPage ? "text/html" : "image/png"
            ])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            let html = #"<div id="i3"><img id="img" src="https://offline.fixture.hath.network/image.png"></div>"#
            client?.urlProtocol(self, didLoad: isPage ? Data(html.utf8) : Self.png)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() { }
    }
    @MainActor func testReaderReopensCachedPageWithNoPageOrImageRequest() async throws {
        let (repo, root, config) = setup()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = SiteSession(qa: true, configuration: config)
        let galleryPage = GalleryPage(index: 1, url: page)
        let first = try await PageMediaLoader.readerFile(galleryPage, session: session, owner: session.owner,
                                                        request: MediaRequestDemand(), repository: repo, isCurrent: { true })
        XCTAssertEqual(Images.count(page.path), 1)
        XCTAssertEqual(Images.count(image.path), 1)

        let reopened = try await PageMediaLoader.readerFile(galleryPage, session: session, owner: session.owner,
                                                           request: MediaRequestDemand(), repository: repo, isCurrent: { true })
        XCTAssertEqual(first, reopened)
        XCTAssertEqual(Images.count(), 2, "Reopening must skip both network stages")

        let scope = session.pageReadScope
        let otherSession = PageReadScope(owner: scope.owner, generation: UUID(), preferences: scope.preferences)
        let otherPreferences = PageReadScope(owner: scope.owner, generation: scope.generation, preferences: UUID())
        let staleSessionHit = await repo.cachedPage(page, scope: otherSession)
        let stalePreferencesHit = await repo.cachedPage(page, scope: otherPreferences)
        XCTAssertNil(staleSessionHit)
        XCTAssertNil(stalePreferencesHit)

        try FileManager.default.removeItem(at: first)
        _ = try await PageMediaLoader.readerFile(galleryPage, session: session, owner: session.owner,
                                                request: MediaRequestDemand(), repository: repo, isCurrent: { true })
        XCTAssertEqual(Images.count(page.path), 2)
        XCTAssertEqual(Images.count(image.path), 2)
    }

    private let scopeA = PageReadScope(owner: "owner-a", generation: UUID(), preferences: UUID())
    private let scopeB = PageReadScope(owner: "owner-b", generation: UUID(), preferences: UUID())
    private let image = URL(string: "https://offline.fixture.hath.network/image.png")!
    private let page = URL(string: "https://e-hentai.org/s/fixture/55-1")!
    private func setup() -> (MediaRepository, URL, URLSessionConfiguration) {
        Images.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CacheDownload55-" + UUID().uuidString)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [Images.self]
        return (MediaRepository(root: root.appendingPathComponent("Browse"), configuration: config), root, config)
    }
    func testSeenPageCopiesCachedBytesWithoutASecondRequestAndSurvivesCacheClear() async throws {
        let (repo, root, _) = setup(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = try await repo.pageFile(for: image, page: page, scope: scopeA, request: MediaRequestDemand(priority: .foreground))
        let target = root.appendingPathComponent("Offline/page-1.media")
        let copied = try await repo.copyCachedPage(page, scope: scopeA, destination: target)
        XCTAssertTrue(copied); XCTAssertEqual(Images.count(), 1)
        XCTAssertNotEqual(cache, target); XCTAssertEqual(try Data(contentsOf: cache), try Data(contentsOf: target))
        try await repo.clear(owner: "owner-a")
        XCTAssertEqual(try Data(contentsOf: target), Images.png)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(target as CFURL, nil)); XCTAssertNotNil(CGImageSourceCreateImageAtIndex(source, 0, nil))
        print("DOWNLOAD55_SEEN_PAGE_NETWORK_REQUESTS=1;PROMOTION_EXTRA_REQUESTS=0;SURVIVES_CACHE_CLEAR=true")
    }
    func testExactImageCacheStillPromotesAfterRepositoryRestartWithoutPageHint() async throws {
        let (repo, root, config) = setup(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try await repo.file(for: image, owner: "owner-a")
        let restarted = MediaRepository(root: root.appendingPathComponent("Browse"), configuration: config)
        let target = root.appendingPathComponent("Offline/page-1.media")
        let hint = try await restarted.copyCachedPage(page, scope: scopeA, destination: target)
        XCTAssertFalse(hint); XCTAssertEqual(Images.count(), 1)
        _ = try await restarted.saveManual(url: image, owner: "owner-a", destination: target, allowNetwork: false)
        XCTAssertEqual(Images.count(), 1); XCTAssertEqual(try Data(contentsOf: target), Images.png)
    }
    func testExhaustedQuotaStillAllowsCacheCopiesButNeverAFreshImageRequest() async throws {
        let (repo, root, _) = setup(); defer { try? FileManager.default.removeItem(at: root) }
        do { _ = try await repo.saveManual(url: image, owner: "owner-a", destination: root.appendingPathComponent("Offline/page-1.media"), allowNetwork: false); XCTFail("Expected quota stop before image transfer") }
        catch { XCTAssertEqual(error as? ViewerError, .imageLimit) }
        XCTAssertEqual(Images.count(), 0)
    }
    func testOtherOwnersCannotPromoteThePageOrReuseTheImageFile() async throws {
        let (repo, root, _) = setup(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try await repo.pageFile(for: image, page: page, scope: scopeA, request: MediaRequestDemand(priority: .foreground))
        let target = root.appendingPathComponent("Offline/page-1.media")
        let copied = try await repo.copyCachedPage(page, scope: scopeB, destination: target)
        XCTAssertFalse(copied); XCTAssertEqual(Images.count(), 1)
        _ = try await repo.saveManual(url: image, owner: "owner-b", destination: target)
        XCTAssertEqual(Images.count(), 2)
    }
    func testMissingOrClearedCacheHintNeverStartsNetworkByItself() async throws {
        let (repo, root, _) = setup(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = try await repo.pageFile(for: image, page: page, scope: scopeA, request: MediaRequestDemand(priority: .foreground))
        try FileManager.default.removeItem(at: cache)
        let target = root.appendingPathComponent("Offline/page-1.media")
        let missing = try await repo.copyCachedPage(page, scope: scopeA, destination: target)
        XCTAssertFalse(missing)
        try await repo.clear(owner: "owner-a")
        let cleared = try await repo.copyCachedPage(page, scope: scopeA, destination: target)
        XCTAssertFalse(cleared); XCTAssertEqual(Images.count(), 1)
    }
    func testPaidEntryPointsAreRejectedBeforeAnyRequest() async throws {
        let (repo, root, _) = setup(); defer { try? FileManager.default.removeItem(at: root) }
        for path in ["archiver.php", "fullimg.php", "hathdl.php", "home.php", "FULLIMG.php/file.png"] {
            do { _ = try await repo.saveManual(url: URL(string: "https://e-hentai.org/" + path)!, owner: "owner-a", destination: root.appendingPathComponent("file.media")); XCTFail("Paid endpoint must not be requested") }
            catch { }
        }
        XCTAssertEqual(Images.count(), 0)
    }
    func testCorruptBrowseFileUsesNormalImageTransfer() async throws {
        let (repo, root, _) = setup(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = try await repo.file(for: image, owner: "owner-a")
        try Data([0, 1, 2]).write(to: cache)
        let target = root.appendingPathComponent("Offline/page-1.media")
        _ = try await repo.saveManual(url: image, owner: "owner-a", destination: target)
        XCTAssertEqual(Images.count(), 2); XCTAssertEqual(try Data(contentsOf: target), Images.png)
    }
    func testCopyStorageFailureDoesNotRedownloadOrRemoveTheBrowseFile() async throws {
        let (repo, root, _) = setup(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = try await repo.file(for: image, owner: "owner-a")
        let blocked = root.appendingPathComponent("blocked"); try Data([0]).write(to: blocked)
        do { _ = try await repo.saveManual(url: image, owner: "owner-a", destination: blocked.appendingPathComponent("file.media")); XCTFail("Expected local storage failure") }
        catch { }
        XCTAssertEqual(Images.count(), 1); XCTAssertEqual(try Data(contentsOf: cache), Images.png)
    }
}
