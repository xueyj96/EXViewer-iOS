import XCTest

final class UnifiedMenusUITests: XCTestCase {
    override func tearDown() { XCUIDevice.shared.orientation = .portrait; super.tearDown() }
    private func launch() -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--qa", "--qa-dark", "--qa-tags-offline", "--qa-library-sort", "--qa-reset-library-sort"]
        app.launch(); XCTAssertTrue(app.buttons["main.tab.account"].waitForExistence(timeout: 12)); return app
    }
    private func panel(_ app: XCUIApplication) -> XCUIElement { app.descendants(matching: .any)["app.menu.panel"].firstMatch }
    private func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
    func testSearchSelectorsShareStyledRowsAndWorkNearBottomAndInLandscape() {
        let app = launch()
        app.buttons["discover.lane.3"].tap()
        app.buttons["discover.search-entry"].tap()
        app.buttons["compose.filters"].tap()
        XCTAssertFalse(app.buttons["compose.site"].exists)
        let rating = app.buttons["compose.min-rating"]
        for _ in 0..<8 { if rating.isHittable { break }; app.swipeUp() }
        rating.tap()
        XCTAssertTrue(panel(app).waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["4 星"].firstMatch.isHittable)
        app.buttons["4 星"].firstMatch.tap()
        XCTAssertEqual(rating.value as? String, "4 星")
        XCUIDevice.shared.orientation = .landscapeLeft
        for _ in 0..<8 { if rating.isHittable { break }; app.swipeUp() }
        rating.tap()
        XCTAssertTrue(panel(app).waitForExistence(timeout: 5))
        capture("menus.search.rating.landscape")
        app.buttons["不限"].firstMatch.tap()
        XCTAssertEqual(rating.value as? String, "不限")
    }
    func testDetailLongPressUsesSharedMenuWithoutAlsoSelectingTheTag() {
        let app = launch()
        app.buttons["gallery.open.1"].tap()
        let tag = app.buttons["detail.tag.language:chinese"]
        for _ in 0..<8 { if tag.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(tag.isHittable)
        XCTAssertEqual(tag.value as? String, "未选中")
        tag.press(forDuration: 0.7)
        XCTAssertTrue(panel(app).waitForExistence(timeout: 5))
        let pin = app.buttons["加入常用标签"].firstMatch
        XCTAssertEqual(pin.frame.height, 36, accuracy: 1)
        capture("menus.detail.tag-long-press")
        pin.tap()
        XCTAssertTrue(panel(app).waitForNonExistence(timeout: 5))
        XCTAssertEqual(tag.value as? String, "未选中")
        tag.tap()
        XCTAssertEqual(tag.value as? String, "已选中")
        app.buttons["detail.tags.more"].tap()
        XCTAssertTrue(panel(app).waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["detail.tags.block"].isHittable)
        capture("menus.detail.tag-actions")
    }
    func testSavedTagLongPressIsAnActionMenuAndDoesNotEnterSelection() {
        let app = launch()
        app.buttons["main.tab.account"].tap()
        let entry = app.buttons["account.tags"]
        for _ in 0..<6 { if entry.isHittable { break }; app.swipeUp() }
        entry.tap()
        let saved = app.descendants(matching: .any)["tags.saved.language:english"].firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 5))
        saved.press(forDuration: 0.7)
        XCTAssertTrue(panel(app).waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["用于组合搜索"].isHittable)
        capture("menus.saved-tag.context")
        app.buttons["取消常用"].tap()
        XCTAssertTrue(saved.waitForNonExistence(timeout: 5))
        XCTAssertTrue(panel(app).waitForNonExistence(timeout: 5))
    }
    func testKeyboardNamespaceMenuDismissesAndReleasesPagingAcrossTabs() {
        let app = launch()
        app.buttons["main.tab.account"].tap()
        let tags = app.buttons["account.tags"]
        for _ in 0..<6 { if tags.isHittable { break }; app.swipeUp() }
        tags.tap()
        let input = app.textFields["tags.search"]
        XCTAssertTrue(input.waitForExistence(timeout: 5)); input.tap(); input.typeText("preview")
        app.buttons["tags.add.namespace"].tap()
        XCTAssertTrue(panel(app).waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        let artist = app.buttons["tags.add.namespace.artist"]
        XCTAssertTrue(artist.isHittable)
        capture("menus.namespace.keyboard-dismissed")
        artist.tap()
        XCTAssertTrue(panel(app).waitForNonExistence(timeout: 5))
        XCTAssertEqual(input.value as? String, "preview")
        app.buttons["tags.add.namespace"].tap()
        XCTAssertTrue(panel(app).waitForExistence(timeout: 5))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.8)).tap()
        XCTAssertTrue(panel(app).waitForNonExistence(timeout: 5))
        if !app.buttons["main.tab.library"].isSelected { app.buttons["main.tab.library"].tap() }
        app.buttons["main.tab.account"].tap()
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.995, dy: 0.55))
        start.press(forDuration: 0.08, thenDragTo: start.withOffset(CGVector(dx: -app.frame.width * 0.65, dy: 0)),
                    withVelocity: .slow, thenHoldForDuration: 0.2)
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: app.buttons["tags.scope.1"])
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 5), .completed)
    }

    func testDetailActionMenuNavigatesAndReturnsWithoutLeavingAnOpenMenu() {
        let app = launch()
        app.buttons["gallery.open.1"].tap()
        let more = app.buttons["detail.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 5)); more.tap()
        XCTAssertTrue(panel(app).waitForExistence(timeout: 5))
        app.buttons["detail.more.download"].tap()
        XCTAssertTrue(app.staticTexts["downloads.options.title"].waitForExistence(timeout: 8))
        XCTAssertFalse(panel(app).exists)
        app.buttons["downloads.options.close"].tap()
        XCTAssertTrue(more.waitForExistence(timeout: 5)); more.tap()
        XCTAssertTrue(panel(app).waitForExistence(timeout: 5))
        capture("menus.detail.more.after-return")
    }

    func testReaderDetailsMenuIsAboveItsModalAndReturnsToTheSamePage() {
        let app = launch()
        app.buttons["gallery.open.1"].tap(); app.buttons["detail.read"].tap()
        let page = app.buttons["reader.page"]
        XCTAssertTrue(page.waitForExistence(timeout: 8))
        let before = page.label
        app.buttons["reader.details.open"].tap()
        let details = app.descendants(matching: .any)["reader.details"].firstMatch
        XCTAssertTrue(details.waitForExistence(timeout: 8))
        // Fixed chrome is hosted outside the page content's AX container.
        let more = app.buttons.matching(identifier: "detail.more").allElementsBoundByIndex.first { $0.isHittable }
        XCTAssertNotNil(more); more?.tap()
        XCTAssertTrue(panel(app).waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["detail.more.download"].isHittable)
        capture("menus.reader.modal-detail")
        app.buttons["detail.more.download"].tap()
        XCTAssertTrue(app.buttons["downloads.options.close"].waitForExistence(timeout: 8))
        app.buttons["downloads.options.close"].tap()
        app.buttons["返回阅读"].tap()
        XCTAssertTrue(page.waitForExistence(timeout: 8))
        XCTAssertEqual(page.label, before)
    }

}
