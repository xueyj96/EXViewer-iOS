import XCTest
@testable import ExViewerCore

final class PageAuthenticationTests: XCTestCase {
    private let reference = GalleryRef(site: .ex, gid: 42, token: "neutral")

    func testGalleryUserContentDoesNotBecomeAnAuthenticationError() throws {
        let html = """
        <html><head><title>Sad Panda sketchbook - ExHentai</title></head><body>
        <h1 id="gn">Sad Panda sketchbook</h1><div id="gdn">sadpanda</div>
        <div id="taglist"><table><tr><td class="tc">artist:</td><td><div class="gt"><a>sad panda</a></div></td></tr></table></div>
        <div id="gdt"><a href="/s/neutral/42-1">Page 1</a></div>
        <div id="cdiv"><div class="c3">sadpanda</div><div class="c6">This page requires you to log on. That is the message I used to get.</div></div>
        </body></html>
        """
        let detail = try EHParser.detail(html, reference: reference)
        XCTAssertEqual(detail.gallery.title, "Sad Panda sketchbook")
        XCTAssertEqual(detail.gallery.uploader, "sadpanda")
        XCTAssertEqual(detail.pages.map(\.index), [1])
        XCTAssertEqual(detail.gallery.tags.first?.id, "artist:sad panda")
    }

    func testListTitlesAndSearchFieldDoNotBecomeAuthenticationErrors() throws {
        let html = """
        <form><input name="f_search" value="sadpanda"></form>
        <div class="itg"><table><tr><td><a href="/g/42/neutral/"><div class="glink">Sad Panda sketches</div></a></td></tr></table></div>
        """
        XCTAssertEqual(try EHParser.list(html, base: GallerySite.ex.baseURL).items.count, 1)
        let empty = "<form><input name='f_search' value='sad panda'></form><p>No hits found</p>"
        XCTAssertTrue(try EHParser.list(empty, base: GallerySite.ex.baseURL).items.isEmpty)
    }

    func testImagePageUserContentAndImageFilenameDoNotRequireLogin() throws {
        let html = """
        <div id="i3"><img id="img" alt="Sad Panda" src="https://ehgt.org/sadpanda.jpg"></div>
        <div id="cdiv"><p>This page requires you to log on.</p><span>sadpanda</span></div>
        """
        let result = try EHParser.image(html, base: GallerySite.ex.baseURL)
        XCTAssertEqual(result.url.lastPathComponent, "sadpanda.jpg")
    }

    func testPageTitleAloneCannotOverrideReadableGalleryContent() throws {
        let html = "<title>Sad Panda</title><h1 id='gn'>Neutral art book</h1><div id='gdt'><a href='/s/neutral/42-1'>Page 1</a></div>"
        XCTAssertEqual(try EHParser.detail(html, reference: reference).pages.count, 1)
    }

    func testFavoriteNotesAndCategoryNamesAreNotLoginErrors() throws {
        let html = """
        <form method="post"><textarea name="favnote">This page requires you to log on.</textarea>
        <div class="nosel"><div><input type="radio" name="favcat" value="0">This page requires you to log on.</div></div>
        <button>Save</button></form>
        <div class="fp"><a>sadpanda</a><a>This page requires you to log on.</a></div>
        """
        XCTAssertNoThrow(try EHParser.check(html))
    }

    func testLoginNoticeOutsideUserContentStillRequiresAuthentication() {
        let html = "<div id='cdiv'>sadpanda</div><textarea name='favnote'>Notes</textarea><p>This page requires you to log on.</p>"
        XCTAssertThrowsError(try EHParser.check(html)) { XCTAssertEqual($0 as? ViewerError, .authentication) }
    }

    func testRealLoginMessagesStillRequireAuthentication() {
        for html in [
            "This page requires you to log on.",
            "<html><body><nav>E-Hentai</nav><p>This page requires you to <b>log on</b>. Please log in.</p></body></html>"
        ] {
            XCTAssertThrowsError(try EHParser.check(html)) { XCTAssertEqual($0 as? ViewerError, .authentication) }
        }
    }

    func testStandaloneLegacyPandaDenialStillRequiresAuthentication() {
        for html in [
            "<html><head><title>Sad Panda</title></head><body></body></html>",
            "<p>sadpanda</p>",
            "<img src='https://ehgt.org/sadpanda.gif'>"
        ] {
            XCTAssertThrowsError(try EHParser.check(html)) { XCTAssertEqual($0 as? ViewerError, .authentication) }
        }
    }

    func testOtherDenialsKeepTheirExistingClassification() {
        let cases: [(String, ViewerError)] = [
            ("<title>Just a moment...</title><script src='/cdn-cgi/challenge-platform/cf-chl-test'></script>", .challenge),
            ("<p>You have exceeded your image viewing limits.</p>", .imageLimit),
            ("<img src='https://ehgt.org/g/509.gif'>", .imageLimit),
            ("<p>Your IP address has been temporarily banned.</p>", .restricted)
        ]
        for (html, error) in cases {
            XCTAssertThrowsError(try EHParser.check(html)) { XCTAssertEqual($0 as? ViewerError, error) }
        }
    }

    func testUnrecognizedResponseIsNotRelabeledAsARequiredLogin() {
        let html = "<p>Unrecognized response mentioning sadpanda in diagnostic text.</p>"
        XCTAssertThrowsError(try EHParser.detail(html, reference: reference)) {
            XCTAssertEqual($0 as? ViewerError, .layoutChanged)
        }
    }
}
