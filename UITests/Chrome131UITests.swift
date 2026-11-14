import XCTest

final class Chrome131UITests: XCTestCase {
    override func tearDown() { XCUIDevice.shared.orientation = .portrait; super.tearDown() }
    private func launch() -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--qa", "--qa-tags-offline", "--qa-sponsorship-preview"]
        app.launch()
        XCTAssertTrue(app.buttons["discover.lane.3"].waitForExistence(timeout: 10))
        return app
    }
    private func selected(_ app: XCUIApplication, _ id: String) {
        expectation(for: NSPredicate(format: "selected == true"), evaluatedWith: app.buttons[id])
        waitForExpectations(timeout: 5)
    }
    private func screenshot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }
    func testFourEqualChannelsSearchStartsBlankAndRestoresItsOwnResults() {
        let app = launch()
        let lanes = (0..<4).map { app.buttons["discover.lane.\($0)"] }
        for lane in lanes { XCTAssertEqual(lane.frame.width, lanes[0].frame.width, accuracy: 1) }
        XCTAssertFalse(app.buttons["discover.search-entry"].exists)
        let frame = app.descendants(matching: .any)["chrome.surface.geometry"].firstMatch.frame
        let bottom = app.buttons["main.tab.discover"].frame
        lanes[3].tap(); selected(app, "discover.lane.3")
        XCTAssertTrue(app.buttons["discover.search-entry"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["gallery.open.1"].exists)
        XCTAssertTrue(app.buttons["discover.saved-menu"].exists)
        let searchFrame = app.descendants(matching: .any)["chrome.surface.geometry"].firstMatch.frame
        XCTAssertEqual(searchFrame.minY, frame.minY, accuracy: 1)
        XCTAssertEqual(searchFrame.height - frame.height, 38, accuracy: 1)
        XCTAssertEqual(app.buttons["main.tab.discover"].frame, bottom)
        screenshot("chrome131.blank-search")
        app.buttons["discover.search-entry"].tap()
        let field = app.textFields["compose.text"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText("coast")
        app.buttons["compose.apply"].tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 5))
        selected(app, "discover.lane.3")
        expectation(for: NSPredicate(format: "value CONTAINS %@", "coast"), evaluatedWith: app.buttons["discover.search-entry"])
        waitForExpectations(timeout: 5)
        XCTAssertTrue(app.buttons["gallery.open.1"].waitForExistence(timeout: 5))
        app.buttons["discover.lane.0"].tap(); selected(app, "discover.lane.0")
        XCTAssertTrue(app.buttons["discover.search-entry"].waitForNonExistence(timeout: 5))
        app.buttons["discover.lane.3"].tap(); selected(app, "discover.lane.3")
        expectation(for: NSPredicate(format: "value CONTAINS %@", "coast"), evaluatedWith: app.buttons["discover.search-entry"])
        waitForExpectations(timeout: 5)
        screenshot("chrome131.search-results")
        app.buttons["discover.lane.2"].tap()
        XCTAssertTrue(app.textFields["reading-history.search-field"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["discover.lane.3"].frame.width, app.buttons["discover.lane.0"].frame.width, accuracy: 1)
    }
    func testSearchHistoryHasTwoFramedButtonsAndLoadsBackIntoDraft() {
        let app = launch()
        app.buttons["discover.lane.3"].tap()
        app.buttons["discover.search-entry"].tap()
        let field = app.textFields["compose.text"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText("coast")
        app.buttons["compose.apply"].tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 5))
        app.buttons["discover.search-entry"].tap()
        app.buttons["compose.records"].tap()
        let load = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "search-history.load.")).firstMatch
        let save = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "search-history.save.")).firstMatch
        XCTAssertTrue(load.waitForExistence(timeout: 5)); XCTAssertTrue(save.exists)
        XCTAssertEqual(load.frame.width, 34, accuracy: 1); XCTAssertEqual(load.frame.height, 44, accuracy: 1)
        XCTAssertEqual(save.frame.width, load.frame.width, accuracy: 1)
        XCTAssertEqual(save.frame.minY, load.frame.minY, accuracy: 1)
        XCTAssertGreaterThanOrEqual(save.frame.minX - load.frame.maxX, 4)
        screenshot("chrome131.history-buttons")
        load.tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5)); XCTAssertEqual(field.value as? String, "coast")
    }
    func testDetailTagsStillOpenIndependentSearchAndReturnToDetail() {
        let app = launch()
        app.buttons["gallery.open.1"].tap()
        let tag = app.buttons["detail.tag.language:chinese"]
        XCTAssertTrue(tag.waitForExistence(timeout: 5)); tag.tap()
        let actions = app.buttons["detail.tags.search-menu"]
        XCTAssertFalse(app.buttons["detail.tags.more"].exists)
        XCTAssertEqual(actions.frame.width, app.buttons["detail.tags.cancel"].frame.width, accuracy: 1)
        actions.tap(); app.buttons["detail.tags.new-search"].tap()
        XCTAssertFalse(app.buttons["compose.apply"].exists)
        XCTAssertTrue(app.buttons["discover.filters"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["discover.lane.0"].exists)
        XCTAssertTrue(app.buttons["main.tab.library"].isHittable)
        app.buttons["search.results.close"].tap()
        XCTAssertTrue(app.buttons["detail.read"].waitForExistence(timeout: 5))
    }

    func testSponsorshipUsesStandardTextCardsInPortraitAndLandscape() {
        let app = launch()
        app.buttons["main.tab.account"].tap(); app.buttons["account.sponsorship"].tap()
        XCTAssertTrue(app.staticTexts["赞助状态"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["测试赞助状态"].exists)
        XCTAssertTrue(app.staticTexts["付款信息"].exists)
        XCTAssertTrue(app.buttons["main.tab.discover"].exists)
        screenshot("chrome131.sponsorship")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.staticTexts["赞助状态"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["测试赞助状态"].exists)
        screenshot("chrome131.sponsorship-landscape")
    }
}
