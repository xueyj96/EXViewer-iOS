import XCTest
import ImageIO
import ExViewerCore
@testable import ExViewer

final class CachedDownloadV55Tests: XCTestCase {
    private final class Images: URLProtocol, @unchecked Sendable {
        private static let lock = NSLock()
        private static var hits = 0
        static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        static func reset() { lock.lock(); hits = 0; lock.unlock() }
        static func count() -> Int { lock.lock(); defer { lock.unlock() }; return hits }
        override class func canInit(with request: URLRequest) -> Bool { ["offline.fixture.hath.network", "e-hentai.org"].contains(request.url?.host ?? "") }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Self.lock.lock(); Self.hits += 1; Self.lock.unlock()
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "image/png"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.png); client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() { }
    }
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
        let cache = try await repo.pageFile(for: image, page: page, owner: "owner-a", request: MediaRequestDemand(priority: .foreground))
        let target = root.appendingPathComponent("Offline/page-1.media")
        let copied = try await repo.copyCachedPage(page, owner: "owner-a", destination: target)
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
        let hint = try await restarted.copyCachedPage(page, owner: "owner-a", destination: target)
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
        _ = try await repo.pageFile(for: image, page: page, owner: "owner-a", request: MediaRequestDemand(priority: .foreground))
        let target = root.appendingPathComponent("Offline/page-1.media")
        let copied = try await repo.copyCachedPage(page, owner: "owner-b", destination: target)
        XCTAssertFalse(copied); XCTAssertEqual(Images.count(), 1)
        _ = try await repo.saveManual(url: image, owner: "owner-b", destination: target)
        XCTAssertEqual(Images.count(), 2)
    }
    func testMissingOrClearedCacheHintNeverStartsNetworkByItself() async throws {
        let (repo, root, _) = setup(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = try await repo.pageFile(for: image, page: page, owner: "owner-a", request: MediaRequestDemand(priority: .foreground))
        try FileManager.default.removeItem(at: cache)
        let target = root.appendingPathComponent("Offline/page-1.media")
        let missing = try await repo.copyCachedPage(page, owner: "owner-a", destination: target)
        XCTAssertFalse(missing)
        try await repo.clear(owner: "owner-a")
        let cleared = try await repo.copyCachedPage(page, owner: "owner-a", destination: target)
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
