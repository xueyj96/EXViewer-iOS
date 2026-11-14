import XCTest

final class Chrome130UITests: XCTestCase {
    override func tearDown() { XCUIDevice.shared.orientation = .portrait; super.tearDown() }

    private func launch() -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--qa", "--qa-tags-offline", "--qa-reader-many", "--qa-reader-transition", "--qa-reset-reader-preferences"]
        app.launch()
        XCTAssertTrue(app.buttons["discover.search-entry"].waitForExistence(timeout: 10))
        return app
    }
    private func header(_ app: XCUIApplication, _ id: String = "discover.header.floating") -> XCUIElement {
        app.descendants(matching: .any)["chrome.surface.geometry"].firstMatch
    }
    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }

    func testBrowseSingleRowHistoryExpansionAndSharedShellKeepTheirAnchors() {
        let app = launch(), h = header(app)
        let single = h.frame, bottom = app.buttons["main.tab.discover"].frame
        XCTAssertEqual(app.buttons["discover.search-entry"].label, "搜索")
        XCTAssertFalse(app.buttons["discover.filters"].exists)
        app.buttons["discover.lane.1"].tap()
        expectation(for: NSPredicate(format: "selected == true"), evaluatedWith: app.buttons["discover.lane.1"])
        waitForExpectations(timeout: 5)
        XCTAssertEqual(h.frame, single)
        expectation(for: NSPredicate(format: "value CONTAINS %@", "selection=1;target=-1"), evaluatedWith: app.staticTexts["discover.lane.paging"])
        waitForExpectations(timeout: 5)
        app.buttons["discover.lane.2"].tap()
        XCTAssertTrue(app.textFields["reading-history.search-field"].waitForExistence(timeout: 5))
        XCTAssertEqual(h.frame.minX, single.minX, accuracy: 1)
        XCTAssertEqual(h.frame.minY, single.minY, accuracy: 1)
        XCTAssertEqual(h.frame.width, single.width, accuracy: 1)
        XCTAssertEqual(h.frame.height - single.height, 38, accuracy: 2)
        XCTAssertEqual(app.buttons["main.tab.discover"].frame, bottom)
        shot("chrome130.history-expanded")
        app.buttons["discover.lane.0"].tap()
        XCTAssertTrue(app.textFields["reading-history.search-field"].waitForNonExistence(timeout: 5))
        XCTAssertEqual(h.frame, single)
        app.buttons["main.tab.library"].tap()
        XCTAssertTrue(app.buttons["library.scope.0"].waitForExistence(timeout: 5))
        app.buttons["main.tab.account"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["account.header"].firstMatch.waitForExistence(timeout: 5))
        let account = header(app)
        XCTAssertTrue(account.waitForExistence(timeout: 5))
        XCTAssertEqual(account.frame, single)
        XCTAssertEqual(app.buttons["main.tab.discover"].frame, bottom)
        app.buttons["account.login-management"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["account.login-page.header"].firstMatch.waitForExistence(timeout: 5))
        let child = header(app)
        XCTAssertTrue(child.waitForExistence(timeout: 5))
        XCTAssertEqual(child.frame, single)
        XCTAssertEqual(app.buttons["main.tab.discover"].frame, bottom)
        shot("chrome130.single-to-single")
    }

    func testStandaloneSearchKeepsDraftAndReturnsToTheOriginalPopularLane() {
        let app = launch()
        app.buttons["discover.lane.1"].tap()
        let sourceFrame = header(app).frame, bottom = app.buttons["main.tab.discover"].frame
        app.buttons["discover.search-entry"].tap()
        let field = app.textFields["compose.text"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText("coast")
        let edge = app.coordinate(withNormalizedOffset: .init(dx: 0.995, dy: 0.55))
        edge.press(forDuration: 0.08, thenDragTo: edge.withOffset(.init(dx: -app.frame.width * 0.65, dy: 0)), withVelocity: .slow, thenHoldForDuration: 0.2)
        app.buttons["compose.records"].tap()
        XCTAssertTrue(app.buttons["search-presets.close"].waitForExistence(timeout: 5))
        app.buttons["search-presets.close"].tap()
        XCTAssertEqual(field.value as? String, "coast")
        app.buttons["compose.apply"].tap()
        let entry = app.buttons["discover.search-entry"]
        expectation(for: NSPredicate(format: "value CONTAINS %@", "coast"), evaluatedWith: entry)
        waitForExpectations(timeout: 5)
        XCTAssertFalse(app.buttons["discover.lane.0"].exists)
        XCTAssertTrue(app.buttons["discover.filters"].exists)
        XCTAssertEqual(app.buttons["main.tab.discover"].frame, bottom)
        XCTAssertEqual(header(app).frame.minY, sourceFrame.minY, accuracy: 1)
        XCTAssertEqual(header(app).frame.height, sourceFrame.height, accuracy: 1)
        shot("chrome130.independent-search-results")
        app.buttons["discover.filters"].tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap(); field.typeText("line")
        app.buttons["compose.apply"].tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 5))
        expectation(for: NSPredicate(format: "value CONTAINS %@", "coastline"), evaluatedWith: entry)
        waitForExpectations(timeout: 5)
        app.buttons["search.results.close"].tap()
        expectation(for: NSPredicate(format: "value CONTAINS %@", "coast"), evaluatedWith: entry)
        waitForExpectations(timeout: 5)
        XCTAssertFalse(app.buttons["discover.lane.1"].exists)
        app.buttons["search.results.close"].tap()
        XCTAssertTrue(app.buttons["discover.lane.1"].waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "selected == true"), evaluatedWith: app.buttons["discover.lane.1"])
        waitForExpectations(timeout: 5)
        XCTAssertEqual(app.buttons["discover.search-entry"].label, "搜索")
        XCTAssertEqual(header(app).frame, sourceFrame)
    }

    func testReaderDetailTagSearchHasOneFullPageChromeAndReturnsToReader() {
        let app = launch()
        app.buttons["gallery.open.1"].tap(); app.buttons["detail.read"].tap()
        let page = app.buttons["reader.page"]
        XCTAssertTrue(page.waitForExistence(timeout: 8)); let original = page.label
        app.buttons["reader.details.open"].tap()
        XCTAssertEqual(app.buttons.matching(identifier: "detail.tag.language:chinese").count, 1)
        let tag = app.buttons["detail.tag.language:chinese"]
        XCTAssertTrue(tag.waitForExistence(timeout: 5))
        for _ in 0..<5 { if tag.isHittable { break }; app.swipeUp() }
        tag.tap()
        app.buttons["detail.tags.search-menu"].tap()
        app.buttons["detail.tags.new-search"].tap()
        XCTAssertTrue(app.buttons["compose.apply"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["main.tab.library"].isHittable)
        app.buttons["compose.apply"].tap()
        let result = app.buttons["discover.search-entry"]
        expectation(for: NSPredicate(format: "value CONTAINS %@", "language:chinese"), evaluatedWith: result)
        waitForExpectations(timeout: 5)
        XCTAssertFalse(app.buttons["discover.lane.0"].exists)
        XCTAssertTrue(app.buttons["main.tab.library"].isHittable)
        XCTAssertLessThan(header(app).frame.minY, app.frame.height * 0.2)
        app.buttons["search.results.close"].tap()
        XCTAssertTrue(app.buttons["detail.read"].waitForExistence(timeout: 5))
        app.buttons["detail.read"].tap()
        XCTAssertTrue(page.waitForExistence(timeout: 5)); XCTAssertEqual(page.label, original)
    }
}
