import XCTest
import ImageIO
import ExViewerCore
@testable import ExViewer

@MainActor final class ReaderPreloadV54Tests: XCTestCase {
    private final class FixtureProtocol: URLProtocol, @unchecked Sendable {
        private static let lock = NSLock()
        private static var counts: [String: Int] = [:]
        private static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        override class func canInit(with request: URLRequest) -> Bool {
            ["e-hentai.org", "preload.fixture.hath.network"].contains(request.url?.host ?? "")
        }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        static func reset() { lock.lock(); counts = [:]; lock.unlock() }
        static func count(_ key: String) -> Int { lock.lock(); defer { lock.unlock() }; return counts[key] ?? 0 }
        override func startLoading() {
            guard let url = request.url else { return }
            let key = (url.host ?? "") + url.path
            Self.lock.lock(); Self.counts[key, default: 0] += 1; Self.lock.unlock()
            if url.host == "preload.fixture.hath.network", url.path == "/page-2.png" {
                client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)); return
            }
            let data: Data
            let contentType: String
            if url.host == "e-hentai.org" {
                let index = url.lastPathComponent
                data = Data("<html><body><img id='img' src='https://preload.fixture.hath.network/page-\(index).png'></body></html>".utf8)
                contentType = "text/html; charset=utf-8"
            } else { data = Self.png; contentType = "image/png" }
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": contentType])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() { }
    }

    func testRealPageParserTransferAndDiskCacheKeepHealthyFutureImagesAfterOneImageFails() async throws {
        FixtureProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureProtocol.self]
        let session = SiteSession(qa: true, configuration: configuration, searchInterval: 0, pageConcurrencyLimit: { 2 })
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ReaderPreload54-\(UUID().uuidString)", isDirectory: true)
        let repository = MediaRepository(root: root, configuration: configuration)
        let store = ReaderMediaStore()
        defer { store.reset(); try? FileManager.default.removeItem(at: root) }
        let scope = ReaderMediaScope(galleryID: "eh:54", owner: "preload-fixture", generation: session.generation, context: UUID())
        let pages = (1...7).map { GalleryPage(index: $0, url: URL(string: "https://e-hentai.org/s/preload/\($0)")!) }
        let update: (Int) -> Void = { current in
            store.update(scope: scope, pages: pages, current: current, prefetchCount: 6, downloadConcurrency: 4,
                         demandLoader: { page, demand in
                try await PageMediaLoader.file(resolvePage: {
                    try EHParser.image(await session.html(page.url, recoverConnection: false, request: demand), base: page.url)
                }, loadMedia: { try await repository.file(for: $0, owner: scope.owner, request: demand) }, isCurrent: { true })
            }, isCurrent: { true })
        }
        update(1)
        let ready = Set([1, 3, 4, 5, 6, 7])
        for _ in 0..<400 {
            if Set(store.files.keys).isSuperset(of: ready), store.failures[2] != nil { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(store.currentPage, 1)
        XCTAssertFalse(store.prefetchPaused)
        XCTAssertTrue(Set(store.files.keys).isSuperset(of: ready), "The real parser/transport pipeline must cache healthy future images while still on page 1")
        XCTAssertNotNil(store.failures[2])
        XCTAssertEqual(FixtureProtocol.count("preload.fixture.hath.network/page-2.png"), 2, "The existing two-attempt budget is retained; no automatic third retry")
        for index in ready {
            let file = try XCTUnwrap(store.files[index])
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(file as CFURL, nil))
            XCTAssertNotNil(CGImageSourceCreateImageAtIndex(source, 0, nil), "The cached fixture must fully decode")
        }
        let file3 = try XCTUnwrap(store.files[3])
        let pageReads = FixtureProtocol.count("e-hentai.org/s/preload/3")
        let imageReads = FixtureProtocol.count("preload.fixture.hath.network/page-3.png")
        update(3)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(store.files[3], file3)
        XCTAssertEqual(FixtureProtocol.count("e-hentai.org/s/preload/3"), pageReads)
        XCTAssertEqual(FixtureProtocol.count("preload.fixture.hath.network/page-3.png"), imageReads)
        let cached = try await repository.file(for: URL(string: "https://preload.fixture.hath.network/page-3.png")!, owner: scope.owner)
        XCTAssertEqual(cached, file3)
        XCTAssertEqual(FixtureProtocol.count("preload.fixture.hath.network/page-3.png"), imageReads, "A separate foreground repository lookup must also hit the completed disk file")
        print("READER54_REAL_PIPELINE_FUTURE_READY_AT_PAGE1=5;FAILED_IMAGE_ATTEMPTS=2;PAGE3_FOREGROUND_EXTRA_READS=0;DECODED_FILES=6")
    }
}
