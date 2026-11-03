import XCTest

final class CompactHeadersV42UITests: XCTestCase {
    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--qa", "--qa-tags-offline", "--qa-saved-search-management", "--qa-search-sort"] + extra
        app.launch()
        XCTAssertTrue(app.buttons["discover.saved-menu"].waitForExistence(timeout: 12))
        return app
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }

    private func loadFirstPreset(_ app: XCUIApplication) {
        app.buttons["discover.saved-menu"].tap()
        XCTAssertTrue(app.navigationBars["记录与常用"].waitForExistence(timeout: 5))
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "search-favorites.load."))
        XCTAssertEqual(rows.count, 3); rows.element(boundBy: 0).tap()
        XCTAssertEqual(app.descendants(matching: .any)["compose.loaded-state"].firstMatch.value as? String, "已载入")
    }

    private func assertActiveHeader(_ app: XCUIApplication, large: Bool) {
        let header = app.descendants(matching: .any)["discover.header.floating"].firstMatch
        let summary = app.buttons["discover.condition-summary"]
        let common = app.buttons["discover.saved-menu"]
        XCTAssertTrue(summary.waitForExistence(timeout: 5)); XCTAssertTrue(common.isHittable)
        capture(app, large ? "compact42.search.large-before-bounds" : "compact42.search.before-bounds")
        XCTAssertLessThanOrEqual(header.frame.height, large ? 190 : 100)
        XCTAssertEqual(summary.frame.minX, app.frame.minX + 20, accuracy: 1)
        XCTAssertEqual(summary.frame.midY, common.frame.midY, accuracy: 1)
        XCTAssertGreaterThanOrEqual(summary.frame.height, 44)
        XCTAssertGreaterThanOrEqual(common.frame.width, 44)
        XCTAssertLessThanOrEqual(common.frame.maxX, app.frame.maxX - 19)
        XCTAssertFalse(app.buttons["discover.sort-order"].exists)
        XCTAssertLessThanOrEqual(summary.frame.maxX, common.frame.minX)
        XCTAssertTrue((summary.value as? String)?.contains("language:chinese") == true, "Full criteria stay available to accessibility")
        XCTAssertFalse(app.scrollViews["discover.rule-chips"].exists)
        XCTAssertFalse(app.scrollViews["discover.saved-shortcuts"].exists)
    }

    func testTwoRowHeaderKeepsAlignmentAndLoadingConditionsRequiresSearch() {
        let app = launch()
        let header = app.descendants(matching: .any)["discover.header.floating"].firstMatch
        let initialHeight = header.frame.height
        loadFirstPreset(app); app.buttons["compose.cancel"].tap()
        XCTAssertFalse(app.buttons["discover.condition-summary"].exists)
        XCTAssertFalse(app.buttons["discover.back"].exists)
        loadFirstPreset(app); app.buttons["compose.apply"].tap()
        assertActiveHeader(app, large: false)
        XCTAssertEqual(header.frame.height, initialHeight, accuracy: 4)
        let card = app.buttons["gallery.open.2"]
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        XCTAssertEqual(card.frame.minX, app.buttons["discover.condition-summary"].frame.minX, accuracy: 1)
        XCTAssertGreaterThanOrEqual(card.frame.minY, header.frame.maxY)
        capture(app, "compact42.search.light")
        app.buttons["discover.condition-summary"].tap()
        XCTAssertTrue(app.navigationBars["筛选条件"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["compose.sort-order"].exists)
    }

    func testLargeTypeUsesAnotherRowWithoutShrinkingOrOverlappingActions() {
        let app = launch(["--qa-dark", "--qa-large-type"])
        loadFirstPreset(app); app.buttons["compose.apply"].tap()
        assertActiveHeader(app, large: true)
        capture(app, "compact42.search.dark-large-portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        expectation(for: NSPredicate { _, _ in app.frame.width > app.frame.height }, evaluatedWith: app)
        waitForExpectations(timeout: 6)
        let summary = app.buttons["discover.condition-summary"], common = app.buttons["discover.saved-menu"]
        XCTAssertTrue(summary.isHittable && common.isHittable)
        XCTAssertLessThanOrEqual(common.frame.maxX, app.frame.maxX)
        capture(app, "compact42.search.dark-large-landscape")
    }

    func testLibraryToolbarAlignsWithCoversAndOffersExplicitMultiSelection() {
        let app = launch(["--qa-stored-bookmark-covers"])
        app.buttons["main.tab.library"].tap()
        let local = app.descendants(matching: .any)["library.header.floating"].firstMatch
        let choose = app.buttons["read-later.select"], sort = app.buttons["library.sort.bookmarks"]
        XCTAssertTrue(choose.waitForExistence(timeout: 5)); XCTAssertTrue(sort.isHittable)
        XCTAssertEqual(choose.frame.midY, sort.frame.midY, accuracy: 1)
        XCTAssertLessThan(local.frame.height, 100)
        capture(app, "compact42.library.read-later")
        choose.tap()
        XCTAssertTrue(app.buttons["read-later.exit"].waitForExistence(timeout: 5))
        app.buttons["read-later.exit"].tap()
        if app.buttons["library.scope.menu"].exists { app.buttons["library.scope.menu"].tap() }
        app.buttons["library.scope.1"].tap()
        let group = app.buttons["favorites.group-filter"], select = app.buttons["favorites.select"]
        XCTAssertTrue(group.waitForExistence(timeout: 5)); XCTAssertTrue(select.isHittable && select.isEnabled)
        XCTAssertEqual(group.frame.minX, app.frame.minX + 20, accuracy: 1)
        XCTAssertEqual(group.frame.midY, select.frame.midY, accuracy: 1)
        XCTAssertLessThanOrEqual(group.frame.maxX, select.frame.minX)
        XCTAssertLessThan(app.descendants(matching: .any)["favorites.header.floating"].firstMatch.frame.height, 100)
        capture(app, "compact42.library.site-favorites")
        select.tap()
        let count = app.staticTexts["favorites.selection-count"]
        XCTAssertEqual(count.label, "已选 0 项")
        let card = app.buttons["favorites.select.1"]
        XCTAssertTrue(card.waitForExistence(timeout: 5)); card.tap()
        XCTAssertEqual(count.label, "已选 1 项")
        XCTAssertTrue(app.buttons["favorites.remove"].isEnabled)
        app.buttons["favorites.edit"].tap()
        XCTAssertEqual(group.value as? String, "全部分组")
    }

    func testBrowsingControlsStayFloatingAndReturnToTheSelectedLane() {
        let app = launch(["--qa-feed-paging"])
        let header = app.descendants(matching: .any)["discover.header.floating"].firstMatch
        let top = header.frame.minY
        app.swipeUp()
        capture(app, "compact42.browse.scrolled")
        XCTAssertEqual(header.frame.minY, top, accuracy: 1)
        let popular = app.buttons["热门"]
        let tree = XCTAttachment(string: app.debugDescription); tree.name = "compact42.browse.hierarchy"; tree.lifetime = .keepAlways; add(tree)
        XCTAssertTrue(popular.waitForExistence(timeout: 3)); popular.tap()
        XCTAssertTrue(popular.isSelected)
        app.buttons["discover.search-entry"].tap()
        let text = app.textFields["compose.text"]
        XCTAssertTrue(text.waitForExistence(timeout: 5)); text.tap(); text.typeText("coast")
        app.buttons["compose.apply"].tap()
        XCTAssertTrue(app.buttons["discover.back"].waitForExistence(timeout: 5))
        app.buttons["discover.back"].tap()
        XCTAssertTrue(popular.waitForExistence(timeout: 5)); XCTAssertTrue(popular.isSelected)
        XCTAssertTrue(app.buttons["discover.saved-menu"].isHittable)
    }

    func testDetailTagChipsRetainTheirSearchAction() {
        let app = launch()
        app.buttons["gallery.open.1"].tap()
        let tag = app.buttons["detail.tag.language:chinese"]
        XCTAssertTrue(tag.waitForExistence(timeout: 5))
        for _ in 0..<6 { if tag.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(tag.isHittable)
        capture(app, "controls43.detail-tags")
        tag.tap()
        XCTAssertTrue(app.buttons["detail.tags.search-menu"].waitForExistence(timeout: 5))
        XCTAssertEqual(tag.value as? String, "已选中")
        app.buttons["detail.tags.search-menu"].tap()
        app.buttons["detail.tags.new-search"].tap()
        XCTAssertTrue(app.navigationBars["新建搜索"].waitForExistence(timeout: 5))
        app.buttons["compose.apply"].tap()
        let summary = app.buttons["discover.condition-summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        XCTAssertTrue((summary.value as? String)?.contains("language:chinese") == true)
    }
}
