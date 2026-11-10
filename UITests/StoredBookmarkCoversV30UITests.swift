import XCTest

final class StoredBookmarkCoversV30UITests: XCTestCase {
    func testPersistedBookmarksRestoreCoversAfterReopenAndSort() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--qa", "--qa-stored-bookmark-covers", "--qa-reset-library-sort"]
        app.launch()
        XCTAssertTrue(app.buttons["main.tab.library"].waitForExistence(timeout: 12))
        app.buttons["main.tab.library"].tap()
        XCTAssertTrue(app.buttons["library.scope.0"].waitForExistence(timeout: 5))
        app.buttons["read-later.select"].tap()
        for id in [1, 2, 3] {
            let cover = app.buttons["favorites.select.\(id)"]
            for _ in 0..<4 { if cover.exists && cover.isHittable { break }; app.swipeUp() }
            XCTAssertTrue(cover.waitForExistence(timeout: 5))
            assertLoadedCover(id, in: app)
            XCTAssertGreaterThan(cover.frame.width, 60); XCTAssertGreaterThan(cover.frame.height, 60)
        }
        app.buttons["read-later.exit"].tap()
        let menu = app.descendants(matching: .any)["library.sort.bookmarks"].firstMatch
        for _ in 0..<4 { if menu.isHittable { break }; app.swipeDown() }
        menu.tap(); app.buttons["标题"].firstMatch.tap()
        app.buttons["read-later.select"].tap()
        assertLoadedCover(1, in: app)
        app.buttons["read-later.exit"].tap()
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "stored-bookmarks.restored-covers"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["main.tab.discover"].tap(); app.buttons["discover.lane.2"].tap()
        XCTAssertTrue(app.textFields["reading-history.search-field"].waitForExistence(timeout: 5))
        let historyShot = XCTAttachment(screenshot: app.screenshot()); historyShot.name = "stored-history.restored-cover"; historyShot.lifetime = .keepAlways; add(historyShot)
    }

    private func assertLoadedCover(_ id: Int, in app: XCUIApplication) {
        let cover = app.buttons["favorites.select.\(id)"]
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "封面已载入"), object: cover)
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 8), .completed)
    }

    func testUnavailableStoredCoverShowsRetryWithoutBlockingBookmarkBrowsing() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--qa", "--qa-stored-bookmark-covers", "--qa-stored-cover-missing"]
        app.launch(); XCTAssertTrue(app.buttons["main.tab.library"].waitForExistence(timeout: 12))
        app.buttons["main.tab.library"].tap()
        XCTAssertTrue(app.buttons["library.scope.0"].waitForExistence(timeout: 5))
        let cover = app.buttons["favorites.gallery.1"]
        XCTAssertTrue(cover.waitForExistence(timeout: 5))
        let retry = app.buttons["重新载入封面"].firstMatch
        XCTAssertTrue(retry.waitForExistence(timeout: 8)); retry.tap()
        XCTAssertTrue(app.buttons["library.scope.0"].isSelected)
        let link = app.buttons["favorites.gallery.1"]
        link.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.88)).tap()
        XCTAssertTrue(app.staticTexts["画廊详情"].waitForExistence(timeout: 5))
    }
}
