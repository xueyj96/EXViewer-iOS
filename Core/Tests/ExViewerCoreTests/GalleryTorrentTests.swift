import XCTest
import CryptoKit
@testable import ExViewerCore

final class GalleryTorrentTests: XCTestCase {
    private let fixtureHash = String(repeating: "a", count: 40)
    private let base = URL(string: "https://exhentai.org/gallerytorrents.php?gid=55&t=fixture")!
    private var info: Data { Data("d6:lengthi4e4:name12:sample01.png12:piece lengthi16384e6:pieces20:".utf8) + Data(repeating: 0, count: 20) + Data("e".utf8) }
    private func string(_ text: String) -> Data { Data("\(text.utf8.count):\(text)".utf8) }
    private func digest(_ data: Data) -> String { Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func row(_ name: String = "Neutral gallery", hash: String? = nil) -> String {
        "<form><table><tr><td>Posted: 2026-11-05 12:30 Size: 1.2 GiB Seeds: 1,234 Peers: 2</td></tr><tr><td><a href='http://ehtracker.org/get/12/\(hash ?? self.fixtureHash).torrent?p=fixture-personalized#ignored'>\(name)</a></td></tr></table></form>"
    }
    func testListingUsesNativeMetadataAndStripsPersonalizedURLParameters() throws {
        let items = try GalleryTorrentParser.parse(row(), base: base)
        XCTAssertEqual(items.count, 1); XCTAssertEqual(items[0].seeds, 1234); XCTAssertEqual(items[0].peers, 2)
        XCTAssertEqual(items[0].size, "1.2 GiB"); XCTAssertEqual(items[0].downloadURL.scheme, "https")
        XCTAssertNil(URLComponents(url: items[0].downloadURL, resolvingAgainstBaseURL: false)?.query)
        XCTAssertFalse(items[0].magnet(galleryID: 55).contains("fixture-personalized"))
        XCTAssertTrue(items[0].magnet(galleryID: 55).contains("urn:btih:" + fixtureHash))
    }
    func testEmptyListIsDistinctFromUnexpectedOrAuthenticationResponse() throws {
        XCTAssertTrue(try GalleryTorrentParser.parse("<body><p>No torrents found for this gallery.</p></body>", base: base).isEmpty)
        XCTAssertThrowsError(try GalleryTorrentParser.parse("<html><body>Unexpected response</body></html>", base: base))
        XCTAssertThrowsError(try GalleryTorrentParser.parse("This page requires you to log on", base: base)) { XCTAssertEqual($0 as? ViewerError, .authentication) }
        XCTAssertThrowsError(try GalleryTorrentParser.parse("Just a moment...", base: base)) { XCTAssertEqual($0 as? ViewerError, .challenge) }
    }
    func testTorrentNamesContainingLoginWordsDoNotBecomeAuthenticationErrors() throws {
        XCTAssertEqual(try GalleryTorrentParser.parse(row("This page requires you to log on"), base: base).count, 1)
        XCTAssertThrowsError(try GalleryTorrentParser.parse("<p>This page requires you to log on</p>" + row(), base: base)) { XCTAssertEqual($0 as? ViewerError, .authentication) }
    }
    func testDuplicateTorrentsAreDeduplicatedAndUntrustedLinksRejected() throws {
        XCTAssertEqual(try GalleryTorrentParser.parse(row() + row(), base: base).count, 1)
        for url in ["https://ehtracker.org.evil.invalid/get/12/\(fixtureHash).torrent", "https://e-hentai.org/archiver.php", "file:///get/12/\(fixtureHash).torrent", "https://ehtracker.org:8443/get/12/\(fixtureHash).torrent"] {
            XCTAssertNil(GalleryTorrentParser.publicDownloadURL(URL(string: url)!))
        }
    }
    func testGalleryListRequestKeepsGallerySiteAndEncodesParameters() throws {
        let ref = GalleryRef(site: .ex, gid: 55, token: "fixture")
        let url = try GalleryTorrentParser.listURL(ref)
        XCTAssertEqual(url.host, "exhentai.org"); XCTAssertEqual(url.path, "/gallerytorrents.php")
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name), ["gid", "t"])
    }
    func testPublicExportPreservesInfoHashAndRemovesPrivateOuterMetadata() throws {
        let raw = Data("d8:announce".utf8) + string("https://tracker.invalid/fixture-personalized") + Data("4:info".utf8) + info + Data("8:url-list".utf8) + string("https://webseed.invalid/fixture-only") + Data("e".utf8)
        let result = try PublicTorrentFile.sanitize(raw, expectedHash: digest(info), galleryID: 55)
        XCTAssertNotNil(result.range(of: info))
        XCTAssertNil(result.range(of: Data("fixture-personalized".utf8))); XCTAssertNil(result.range(of: Data("webseed.invalid".utf8)))
        XCTAssertNotNil(result.range(of: Data("http://ehtracker.org/55/announce".utf8)))
        XCTAssertEqual(try PublicTorrentFile.sanitize(result, expectedHash: digest(info), galleryID: 55), result)
    }
    func testWrongHashMalformedDuplicateAndOversizedFilesAreRejected() {
        let valid = Data("d4:info".utf8) + info + Data("e".utf8)
        for raw in [valid, Data("<html>not a torrent</html>".utf8), Data("d4:info".utf8) + info,
                    Data("d4:info".utf8) + info + Data("4:info".utf8) + info + Data("e".utf8), Data(repeating: 0, count: PublicTorrentFile.maximumBytes + 1)] {
            XCTAssertThrowsError(try PublicTorrentFile.sanitize(raw, expectedHash: fixtureHash, galleryID: 55))
        }
    }
    func testExcessivelyNestedTorrentIsRejected() {
        let data = Data(("d4:info" + String(repeating: "l", count: 40) + "0:" + String(repeating: "e", count: 41)).utf8)
        XCTAssertThrowsError(try PublicTorrentFile.sanitize(data, expectedHash: digest(data), galleryID: 55))
    }
}
