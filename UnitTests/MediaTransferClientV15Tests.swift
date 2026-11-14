import XCTest
import Foundation
import ImageIO
import ExViewerCore
@testable import ExViewer

final class MediaTransferClientV15Tests: XCTestCase {
    private final class ControlledURLProtocol: URLProtocol, @unchecked Sendable {
        private static let lock = NSLock()
        private static var instances: [String: ControlledURLProtocol] = [:]

        private let instanceLock = NSLock()
        private var clientSnapshot: (any URLProtocolClient)?
        private var stopped = false
        private var delivered = false

        private static let png = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!

        override class func canInit(with request: URLRequest) -> Bool {
            request.url?.host == "media-transfer.fixture.hath.network"
        }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            instanceLock.lock()
            clientSnapshot = client
            instanceLock.unlock()

            guard let path = request.url?.path else { return }
            Self.lock.lock()
            Self.instances[path] = self
            Self.lock.unlock()

            // The cancellation case stays pending until URLSession cancels it.
            guard path != "/hold.png" else { return }
            deliver(path: path)
        }

        override func stopLoading() {
            instanceLock.lock()
            stopped = true
            instanceLock.unlock()
        }

        private func deliver(path: String) {
            instanceLock.lock()
            guard !delivered, !stopped,
                  let clientSnapshot, let url = request.url else {
                instanceLock.unlock()
                return
            }
            delivered = true
            instanceLock.unlock()

            let isHTML = path == "/html"
            let mime = isHTML ? "text/html" : "image/png"
            let body = isHTML ? Data("<html>not an image</html>".utf8) : Self.png
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": mime, "Content-Length": String(body.count)])!
            clientSnapshot.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            clientSnapshot.urlProtocol(self, didLoad: body)
            clientSnapshot.urlProtocolDidFinishLoading(self)
        }

        static func reset() {
            lock.lock(); instances.removeAll(); lock.unlock()
        }

        static func started(_ paths: Set<String>) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return paths.allSatisfy { instances[$0] != nil }
        }
        static func completeHeldImage() {
            lock.lock(); let instance = instances["/hold.png"]; lock.unlock()
            instance?.deliver(path: "/image.png")
        }
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    private func makeClient() -> MediaTransferClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ControlledURLProtocol.self]
        return MediaTransferClient(configuration: configuration)
    }

    private func fixture(_ path: String) -> URL {
        URL(string: "https://media-transfer.fixture.hath.network\(path)")!
    }

    @MainActor func test138VisibleNoResponseUsesExistingSingleRetryAndSucceeds() async throws {
        ControlledURLProtocol.reset()
        let client = makeClient()
        var attempts = 0, resolutions = 0
        let file = try await PageMediaLoader.file(resolvePage: {
            resolutions += 1
            return try EHParser.image("<img id='img' src='\(self.fixture("/image.png").absoluteString)'>", base: URL(string: "https://e-hentai.org/s/fixture/1-1")!)
        }, loadMedia: { _ in
            attempts += 1
            return try await FileTransfer(limit: 64_000_000, client: client, firstResponseTimeout: 0.08)
                .fetch(self.fixture(attempts == 1 ? "/hold.png" : "/image.png"), request: MediaRequestDemand())
        }, isCurrent: { true })
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(attempts, 2); XCTAssertEqual(resolutions, 2)
        XCTAssertNotNil(CGImageSourceCreateWithURL(file as CFURL, nil))
    }
    @MainActor func test138RepeatedNoResponseStopsAfterOneRetryAndCanBeRetriedManually() async throws {
        ControlledURLProtocol.reset()
        let client = makeClient()
        var attempts = 0
        do {
            _ = try await PageMediaLoader.file(resolvePage: {
                try EHParser.image("<img id='img' src='\(self.fixture("/hold.png").absoluteString)'>", base: URL(string: "https://e-hentai.org/s/fixture/1-1")!)
            }, loadMedia: { image in
                attempts += 1
                return try await FileTransfer(limit: 64_000_000, client: client, firstResponseTimeout: 0.08).fetch(image, request: MediaRequestDemand())
            }, isCurrent: { true })
            XCTFail("Two stalled attempts must terminate")
        } catch { XCTAssertEqual(error as? RequestFailure, .transport(.media, URLError.timedOut.rawValue)) }
        XCTAssertEqual(attempts, 2)
        let file = try await FileTransfer(limit: 64_000_000, client: client).fetch(fixture("/image.png"), request: MediaRequestDemand())
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertNotNil(CGImageSourceCreateWithURL(file as CFURL, nil))
    }

    func test138ReceivedHeadersDisarmVisibleDeadlineWhileBodyIsSlow() async throws {
        ControlledURLProtocol.reset()
        let client = makeClient()
        let demand = MediaRequestDemand()
        let transfer = FileTransfer(limit: 64_000_000, client: client, firstResponseTimeout: 0.3)
        let task = Task {
            try await transfer.fetch(fixture("/hold.png"), request: demand)
        }
        defer { task.cancel() }
        let started = await waitUntil { ControlledURLProtocol.started(["/hold.png"]) }
        XCTAssertTrue(started)
        // URLProtocol buffers this response until completion on this Simulator.
        // Deliver the header delegate event explicitly, then let the controlled
        // transport supply its real body after the header budget has elapsed.
        let response = HTTPURLResponse(url: fixture("/hold.png"), statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "image/png"])!
        let callbackTask = URLSession.shared.dataTask(with: fixture("/hold.png"))
        defer { callbackTask.cancel() }
        transfer.urlSession(URLSession.shared, dataTask: callbackTask, didReceive: response) { XCTAssertEqual($0, .allow) }
        XCTAssertEqual(demand.progress.phase, .transferring)
        try await Task.sleep(for: .milliseconds(500))
        ControlledURLProtocol.completeHeldImage()
        let file = try await task.value
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertNotNil(CGImageSourceCreateWithURL(file as CFURL, nil))
    }

    func test138DownloadKeepsOriginalWaitAndPrefetchPromotionBoundsExistingWait() async throws {
        for priority in [MediaRequestPriority.download, .prefetch] {
            ControlledURLProtocol.reset()
            let demand = MediaRequestDemand(priority: priority)
            let client = makeClient()
            let task = Task {
                try await FileTransfer(limit: 64_000_000, client: client, firstResponseTimeout: 0.08)
                    .fetch(fixture("/hold.png"), request: demand)
            }
            defer { task.cancel() }
            let started = await waitUntil { ControlledURLProtocol.started(["/hold.png"]) }
            XCTAssertTrue(started)
            try await Task.sleep(for: .milliseconds(180))
            if priority == .prefetch {
                demand.setPriority(.foreground)
                do { _ = try await task.value; XCTFail("Promoted stalled preload must time out") }
                catch { XCTAssertEqual(error as? RequestFailure, .transport(.media, URLError.timedOut.rawValue)) }
            } else {
                task.cancel()
                do { _ = try await task.value; XCTFail("Download must wait until explicit cancellation") }
                catch { XCTAssertTrue(error is CancellationError) }
            }
        }
    }

    func testCancellingOneTaskDoesNotCancelAnotherTaskOnSharedClient() async throws {
        ControlledURLProtocol.reset()
        let client = makeClient()
        let heldTransfer = FileTransfer(limit: 64_000_000, client: client)
        let imageTransfer = FileTransfer(limit: 64_000_000, client: client)
        let held = Task { try await heldTransfer.fetch(fixture("/hold.png")) }
        let image = Task { try await imageTransfer.fetch(fixture("/image.png")) }
        defer { held.cancel(); image.cancel() }

        let bothStarted = await waitUntil { ControlledURLProtocol.started(["/hold.png", "/image.png"]) }
        XCTAssertTrue(bothStarted, "Both independent tasks should reach the controlled URLProtocol")
        held.cancel()
        do {
            _ = try await held.value
            XCTFail("The held task should be cancelled")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        let imageFile = try await image.value
        defer { try? FileManager.default.removeItem(at: imageFile) }
        let source = CGImageSourceCreateWithURL(imageFile as CFURL, nil)
        XCTAssertNotNil(source)
        XCTAssertGreaterThan(source.map(CGImageSourceGetCount) ?? 0, 0)
    }

    func testNonImageResponseFailsOnlyItsOwnTask() async throws {
        ControlledURLProtocol.reset()
        let client = makeClient()
        let htmlTransfer = FileTransfer(limit: 64_000_000, client: client)
        let imageTransfer = FileTransfer(limit: 64_000_000, client: client)
        let html = Task { try await htmlTransfer.fetch(fixture("/html")) }
        let image = Task { try await imageTransfer.fetch(fixture("/image.png")) }
        defer { html.cancel(); image.cancel() }

        let bothStarted = await waitUntil { ControlledURLProtocol.started(["/html", "/image.png"]) }
        XCTAssertTrue(bothStarted, "Both independent tasks should reach the controlled URLProtocol")
        do {
            _ = try await html.value
            XCTFail("The HTML response must fail image MIME validation")
        } catch {
            XCTAssertEqual(error as? RequestFailure, .nonImage)
        }

        let imageFile = try await image.value
        defer { try? FileManager.default.removeItem(at: imageFile) }
        let source = CGImageSourceCreateWithURL(imageFile as CFURL, nil)
        XCTAssertNotNil(source)
        XCTAssertGreaterThan(source.map(CGImageSourceGetCount) ?? 0, 0)
    }
}
