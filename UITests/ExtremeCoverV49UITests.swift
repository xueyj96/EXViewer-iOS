import XCTest

final class ExtremeCoverV49UITests: XCTestCase {
    private func launch() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--qa", "--qa-extreme-covers", "--qa-library-large-selection", "--qa-stored-bookmark-covers"]
        app.launch()
        XCTAssertTrue(app.buttons["gallery.open.1"].waitForExistence(timeout: 12))
        return app
    }

    private func assertBoundedColumns(_ app: XCUIApplication, first: String, second: String, selecting: Bool = false) {
        let left = app.buttons[first], right = app.buttons[second]
        XCTAssertTrue(left.waitForExistence(timeout: 8))
        XCTAssertTrue(right.waitForExistence(timeout: 8))
        XCTAssertLessThan(left.frame.midX, app.frame.midX)
        XCTAssertGreaterThan(right.frame.midX, app.frame.midX)
        // A selected cell exposes its outlined hit region to accessibility;
        // an unselected cell exposes the image/text region inside its padding.
        // Check equal card bounds before selection, and containment in both modes.
        if !selecting { XCTAssertEqual(left.frame.width, right.frame.width, accuracy: 1) }
        for card in [left, right] {
            XCTAssertGreaterThan(card.frame.width, 100)
            XCTAssertLessThanOrEqual(card.frame.height, card.frame.width * 2 + 85)
            XCTAssertGreaterThanOrEqual(card.frame.minX, 19)
            XCTAssertLessThanOrEqual(card.frame.maxX, app.frame.maxX - 19)
        }
    }

    func testDiscoverExtremeCoversRemainBoundedAndBothColumnsStayVisible() {
        let app = launch()
        let strip = app.buttons["gallery.open.1"]
        // Wait for the actual wide cover to replace the unknown-ratio layout.
        let wide = app.buttons["gallery.open.2"]
        expectation(for: NSPredicate { _, _ in wide.frame.height < wide.frame.width + 80 }, evaluatedWith: wide)
        waitForExpectations(timeout: 12)
        assertBoundedColumns(app, first: "gallery.open.1", second: "gallery.open.2")
        XCTAssertTrue(strip.isHittable && wide.isHittable)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "covers49.discover"; shot.lifetime = .keepAlways; add(shot)
        app.swipeUp(); app.swipeDown()
        assertBoundedColumns(app, first: "gallery.open.1", second: "gallery.open.2")
    }

    func testLibraryUsesTheSameBoundedCoverGeometryDuringSelection() {
        let app = launch()
        app.buttons["main.tab.library"].tap()
        if app.buttons["library.scope.menu"].exists { app.buttons["library.scope.menu"].tap() }
        app.buttons["library.scope.1"].tap()
        assertBoundedColumns(app, first: "favorites.gallery.10000", second: "favorites.gallery.10001")
        app.buttons["favorites.gallery.10000"].press(forDuration: 0.8)
        XCTAssertTrue(app.buttons["favorites.select.10000"].waitForExistence(timeout: 6))
        XCTAssertEqual(app.buttons["favorites.select.10000"].value as? String, "已选中")
        assertBoundedColumns(app, first: "favorites.select.10000", second: "favorites.select.10001", selecting: true)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "covers49.library-selection"; shot.lifetime = .keepAlways; add(shot)
    }
}
