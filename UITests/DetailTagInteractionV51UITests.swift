import XCTest

final class DetailTagInteractionV51UITests: XCTestCase {
    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--qa", "--qa-tags-offline", "--qa-saved-search-management", "--qa-reset-reader-preferences"] + extra
        app.launch()
        XCTAssertTrue(app.buttons["discover.search-entry"].waitForExistence(timeout: 12))
        return app
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }

    private func openDetail(_ app: XCUIApplication) {
        let card = app.buttons["gallery.open.1"]
        XCTAssertTrue(card.waitForExistence(timeout: 6)); card.tap()
        XCTAssertTrue(app.navigationBars["画廊详情"].waitForExistence(timeout: 6))
    }

    private func select(_ id: String, in app: XCUIApplication) -> XCUIElement {
        let tag = app.buttons["detail.tag.\(id)"]
        XCTAssertTrue(tag.waitForExistence(timeout: 6))
        for _ in 0..<14 {
            if tag.isHittable && tag.frame.minY > 130 && tag.frame.maxY < app.frame.maxY - 100 { break }
            app.scrollViews["detail.scroll"].swipeUp()
        }
        XCTAssertTrue(tag.isHittable)
        let before = tag.frame
        tag.tap()
        XCTAssertEqual(tag.value as? String, "已选中")
        XCTAssertEqual(tag.frame.minY, before.minY, accuracy: 1, "Selecting must not push the detail content")
        XCTAssertTrue(app.buttons["detail.tags.search-menu"].isHittable)
        XCTAssertTrue(app.buttons["main.tab.library"].isHittable, "Tag selection retains the existing bottom tabs")
        return tag
    }

    private func startPreset(_ app: XCUIApplication, expectedText: String = "coast") {
        app.buttons["discover.saved-menu"].tap()
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "search-favorites.load."))
        XCTAssertEqual(rows.count, 3); rows.element(boundBy: 0).tap()
        XCTAssertEqual(app.textFields["compose.text"].value as? String, expectedText)
        app.buttons["compose.apply"].tap()
        XCTAssertTrue(app.buttons["discover.condition-summary"].waitForExistence(timeout: 6))
    }

    func testSelectionNewDraftCancelAndExplicitSubmitKeepTabsAndSingleLineInput() {
        let app = launch(); openDetail(app)
        _ = select("language:chinese", in: app)
        _ = select("artist:preview studio", in: app)
        XCTAssertTrue(app.navigationBars["已选 2 个"].exists)
        let menu = app.buttons["detail.tags.search-menu"]
        XCTAssertLessThan(menu.frame.maxY, app.frame.midY)
        capture(app, "detail51.selection.light")
        menu.tap()
        XCTAssertTrue(app.buttons["detail.tags.new-search"].exists)
        XCTAssertFalse(app.buttons["detail.tags.add-to-search"].exists, "An empty browsing lane is not a current search")
        app.buttons["detail.tags.new-search"].tap()
        XCTAssertTrue(app.navigationBars["新建搜索"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["compose.tag-source"].label.contains("已载入"))
        let input = app.textFields["compose.text"], height = input.frame.height
        let text = String(repeating: "landscape", count: 10)
        input.tap(); input.typeText(text)
        XCTAssertEqual(input.frame.height, height, accuracy: 1)
        input.typeText("\n")
        XCTAssertEqual(input.value as? String, text)
        XCTAssertTrue(app.navigationBars["新建搜索"].exists, "Return ends editing; it must not execute a search")
        app.buttons["compose.cancel"].tap()
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["已选 2 个"].exists)
        menu.tap(); app.buttons["detail.tags.new-search"].tap()
        XCTAssertEqual(app.textFields["compose.text"].value as? String, "关键词或标题")
        app.buttons["compose.apply"].tap()
        let result = app.buttons["discover.condition-summary"]
        XCTAssertTrue(result.waitForExistence(timeout: 6))
        XCTAssertTrue((result.value as? String)?.contains("language:chinese") == true)
        XCTAssertTrue((result.value as? String)?.contains("artist:preview studio") == true)
        XCTAssertFalse((result.value as? String)?.contains(text) == true)
        capture(app, "detail51.new-search.result")
    }

    func testAddingToCurrentSearchPreservesFiltersAndCancelLeavesOldResultsAndSavedPreset() {
        let app = launch(["--qa-multiline-search"])
        startPreset(app, expectedText: "coast field notes")
        let original = app.buttons["discover.condition-summary"].value as? String
        openDetail(app)
        _ = select("language:chinese", in: app); _ = select("artist:preview studio", in: app)
        app.buttons["detail.tags.search-menu"].tap()
        XCTAssertTrue(app.buttons["detail.tags.add-to-search"].exists)
        capture(app, "detail51.search-choices")
        app.buttons["detail.tags.add-to-search"].tap()
        XCTAssertTrue(app.navigationBars["编辑当前搜索"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["compose.text"].value as? String, "coast field notes")
        XCTAssertTrue(app.staticTexts["compose.tag-source"].label.contains("已加入当前搜索"))
        XCTAssertTrue((app.buttons["compose.filters"].value as? String)?.contains("≥3星") == true)
        capture(app, "detail51.merge-draft")
        app.buttons["compose.cancel"].tap()
        app.buttons["detail.tags.cancel"].tap(); app.buttons["BackButton"].tap()
        XCTAssertEqual(app.buttons["discover.condition-summary"].value as? String, original)
        openDetail(app)
        _ = select("language:chinese", in: app); _ = select("artist:preview studio", in: app)
        app.buttons["detail.tags.search-menu"].tap(); app.buttons["detail.tags.add-to-search"].tap()
        app.buttons["compose.apply"].tap()
        let result = app.buttons["discover.condition-summary"]
        XCTAssertTrue(result.waitForExistence(timeout: 6))
        let value = result.value as? String ?? ""
        XCTAssertTrue(value.contains("coast field notes")); XCTAssertTrue(value.contains("artist:preview studio")); XCTAssertTrue(value.contains("≥3星"))
        app.buttons["discover.saved-menu"].tap()
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "search-favorites.load."))
        XCTAssertEqual(rows.count, 3); rows.element(boundBy: 0).tap()
        XCTAssertFalse((app.buttons["compose.filters"].value as? String)?.contains("artist:preview studio") == true)
        XCTAssertEqual(app.textFields["compose.text"].value as? String, "coast field notes")
    }

    func testLibraryEntryAndDarkLargeTypeKeepCurrentExclusionVisible() {
        let app = launch(["--qa-detail-tag-conflict", "--qa-stored-bookmark-covers", "--qa-dark", "--qa-large-type"])
        startPreset(app)
        app.buttons["main.tab.library"].tap()
        if app.buttons["library.scope.menu"].exists { app.buttons["library.scope.menu"].tap() }
        app.buttons["library.scope.0"].tap()
        let stored = app.buttons["favorites.gallery.1"]
        XCTAssertTrue(stored.waitForExistence(timeout: 6)); stored.tap()
        _ = select("language:chinese", in: app)
        let menu = app.buttons["detail.tags.search-menu"]
        XCTAssertTrue(menu.isHittable); XCTAssertLessThan(menu.frame.maxY, app.frame.midY)
        capture(app, "detail51.selection.dark-large")
        menu.tap(); app.buttons["detail.tags.add-to-search"].tap()
        XCTAssertTrue(app.staticTexts["compose.tag-exclusions"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["compose.tag-exclusions"].label.contains("language:chinese"))
        XCTAssertTrue((app.buttons["compose.filters"].value as? String)?.contains("排除") == true)
        capture(app, "detail51.exclusion-draft.dark-large")
        app.buttons["compose.cancel"].tap()
        XCTAssertTrue(menu.waitForExistence(timeout: 5)); XCTAssertTrue(app.buttons["main.tab.library"].isHittable)
    }

    func testReaderDetailDraftSubmitsAfterBothSheetsClose() {
        let app = launch(["--qa-reader-transition"]); openDetail(app)
        app.buttons["在线阅读"].tap()
        let page = app.buttons["reader.page"]
        XCTAssertTrue(page.waitForExistence(timeout: 8))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleTap()
        XCTAssertTrue(app.navigationBars["画廊详情"].waitForExistence(timeout: 6))
        let detail = app.buttons["detail.tag.language:chinese"]
        for _ in 0..<8 { if detail.exists && detail.isHittable { break }; app.scrollViews["detail.scroll"].firstMatch.swipeUp() }
        XCTAssertTrue(detail.isHittable)
        detail.tap()
        app.buttons["detail.tags.search-menu"].tap(); app.buttons["detail.tags.new-search"].tap()
        XCTAssertTrue(app.navigationBars["新建搜索"].waitForExistence(timeout: 5))
        app.buttons["compose.apply"].tap()
        XCTAssertTrue(app.buttons["discover.condition-summary"].waitForExistence(timeout: 8))
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.buttons["reader.page"])
        waitForExpectations(timeout: 6)
        XCTAssertTrue(app.buttons["main.tab.discover"].isHittable)
    }
}
