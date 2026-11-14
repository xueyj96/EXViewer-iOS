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
        XCTAssertTrue(app.staticTexts["画廊详情"].waitForExistence(timeout: 6))
    }

    private func select(_ id: String, in app: XCUIApplication, mainTabs: Bool = true) -> XCUIElement {
        let tags = app.buttons.matching(identifier: "detail.tag.\(id)")
        XCTAssertTrue(tags.firstMatch.waitForExistence(timeout: 6))
        for _ in 0..<14 {
            let candidate = visible(tags)
            if candidate.isHittable && candidate.frame.minY > 130 && candidate.frame.maxY < app.frame.maxY - 100 { break }
            app.swipeUp()
        }
        let tag = visible(tags)
        XCTAssertTrue(tag.isHittable)
        let before = tag.frame
        tag.tap()
        XCTAssertEqual(tag.value as? String, "已选中")
        XCTAssertEqual(tag.frame.minY, before.minY, accuracy: 1, "Selecting must not push the detail content")
        XCTAssertTrue(visible(app.buttons.matching(identifier: "detail.tags.search-menu")).isHittable)
        if mainTabs {
            XCTAssertTrue(app.buttons["main.tab.library"].isHittable, "Tag selection retains the existing bottom tabs")
        }
        return tag
    }

    private func visible(_ query: XCUIElementQuery) -> XCUIElement {
        query.allElementsBoundByIndex.first { $0.isHittable && $0.isEnabled } ?? query.firstMatch
    }

    private func startPreset(_ app: XCUIApplication, expectedText: String = "coast") {
        app.buttons["discover.saved-menu"].tap()
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "search-favorites.load."))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(rows.count, 3); rows.element(boundBy: 0).tap()
        XCTAssertEqual(app.textFields["compose.text"].value as? String, expectedText)
        app.buttons["compose.apply"].tap()
        XCTAssertTrue(app.buttons["discover.search-entry"].waitForExistence(timeout: 6))
    }

    func testSelectionNewDraftCancelAndExplicitSubmitKeepTabsAndSingleLineInput() {
        let app = launch()
        let discoverHeader = app.descendants(matching: .any)["discover.header.floating"].firstMatch
        XCTAssertTrue(discoverHeader.waitForExistence(timeout: 6))
        let top = discoverHeader.frame.minY
        openDetail(app)
        let detailHeader = app.descendants(matching: .any)["detail.header.floating"].firstMatch
        XCTAssertEqual(detailHeader.frame.minY - top, 3, accuracy: 2)
        XCTAssertEqual(detailHeader.buttons.matching(identifier: "BackButton").count, 1)
        _ = select("language:chinese", in: app)
        _ = select("artist:preview studio", in: app)
        XCTAssertTrue(app.staticTexts["已选 2 个"].exists)
        let menu = app.buttons["detail.tags.search-menu"]
        XCTAssertLessThan(menu.frame.maxY, app.frame.midY)
        capture(app, "detail51.selection.light")
        menu.tap()
        XCTAssertTrue(app.buttons["detail.tags.new-search"].exists)
        XCTAssertFalse(app.buttons["detail.tags.add-to-search"].exists, "An empty browsing lane is not a current search")
        app.buttons["detail.tags.new-search"].tap()
        XCTAssertTrue(app.searchComposerTitle("新建搜索").waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["compose.tag-source"].exists)
        XCTAssertFalse(app.staticTexts["compose.tag-original"].exists)
        let input = app.textFields["compose.text"]
        let fieldCard = app.descendants(matching: .any)["compose.keyword-card"].firstMatch
        XCTAssertTrue(fieldCard.exists)
        let height = fieldCard.frame.height
        let text = String(repeating: "landscape", count: 10)
        input.tap(); input.typeText(text)
        XCTAssertEqual(fieldCard.frame.height, height, accuracy: 1)
        XCTAssertLessThanOrEqual(input.frame.height, height)
        input.typeText("\n")
        XCTAssertEqual(input.value as? String, text)
        XCTAssertTrue(app.searchComposerTitle("新建搜索").exists, "Return ends editing; it must not execute a search")
        app.buttons["compose.cancel"].tap()
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["已选 2 个"].exists)
        menu.tap(); app.buttons["detail.tags.new-search"].tap()
        let reopenedInput = app.textFields["compose.text"]
        XCTAssertEqual(reopenedInput.value as? String, reopenedInput.placeholderValue)
        app.buttons["compose.apply"].tap()
        let resultsBar = app.descendants(matching: .any)["discover.header.floating"].firstMatch
        XCTAssertTrue(resultsBar.waitForExistence(timeout: 6))
        XCTAssertEqual(resultsBar.frame.width, app.frame.width - 40, accuracy: 1, "Standalone results use the shared side insets")
        let result = app.buttons["discover.search-entry"]
        XCTAssertTrue(result.waitForExistence(timeout: 6))
        XCTAssertTrue((result.value as? String)?.contains("language:chinese") == true)
        XCTAssertTrue((result.value as? String)?.contains("artist:preview studio") == true)
        XCTAssertFalse((result.value as? String)?.contains(text) == true)
        capture(app, "detail51.new-search.result")

        let searchEntry = app.buttons["discover.search-entry"]
        let original = searchEntry.value as? String
        searchEntry.tap()
        let condition = app.textFields["compose.text"]
        XCTAssertTrue(condition.waitForExistence(timeout: 5))
        condition.tap(); condition.typeText("coast")
        XCTAssertEqual(app.buttons["compose.apply"].label, "更新结果")
        app.buttons["compose.apply"].tap()
        XCTAssertTrue(app.buttons["search.results.close"].waitForExistence(timeout: 5))
        XCTAssertTrue((searchEntry.value as? String)?.contains("coast") == true)
        app.buttons["discover.back"].tap()
        XCTAssertEqual(searchEntry.value as? String, original)

        openDetail(app)
        _ = select("other:full color", in: app, mainTabs: false)
        visible(app.buttons.matching(identifier: "detail.tags.search-menu")).tap()
        app.buttons["detail.tags.add-to-search"].tap()
        XCTAssertTrue(app.searchComposerTitle("编辑当前搜索").waitForExistence(timeout: 5))
        app.buttons["compose.apply"].tap()
        let returnsToResults = app.buttons["search.results.close"].waitForExistence(timeout: 6)
        if !returnsToResults { capture(app, "detail-search-update-return-failure") }
        XCTAssertTrue(returnsToResults)
        XCTAssertTrue((result.value as? String)?.contains("other:full color") == true)
        app.buttons["search.results.close"].tap()
        XCTAssertTrue(app.staticTexts["已选 2 个"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["detail.tag.language:chinese"].value as? String, "已选中")
        XCTAssertEqual(app.buttons["detail.tag.artist:preview studio"].value as? String, "已选中")
        app.buttons["detail.tags.cancel"].tap()
        app.buttons["BackButton"].tap()
        XCTAssertTrue(app.buttons["discover.search-entry"].waitForExistence(timeout: 5))
        XCTAssertFalse(result.exists, "Standalone searches must not replace Discover's browsing lane")
    }

    func testAddingToCurrentSearchPreservesFiltersAndCancelLeavesOldResultsAndSavedPreset() {
        let app = launch(["--qa-multiline-search"])
        startPreset(app, expectedText: "coast field notes")
        let original = app.buttons["discover.search-entry"].value as? String
        openDetail(app)
        _ = select("language:chinese", in: app); _ = select("artist:preview studio", in: app)
        app.buttons["detail.tags.search-menu"].tap()
        XCTAssertTrue(app.buttons["detail.tags.add-to-search"].exists)
        capture(app, "detail51.search-choices")
        app.buttons["detail.tags.add-to-search"].tap()
        XCTAssertTrue(app.searchComposerTitle("编辑当前搜索").waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["compose.text"].value as? String, "coast field notes")
        XCTAssertFalse(app.staticTexts["compose.tag-source"].exists)
        XCTAssertFalse(app.staticTexts["compose.tag-original"].exists)
        XCTAssertTrue((app.buttons["compose.filters"].value as? String)?.contains("≥3星") == true)
        capture(app, "detail51.merge-draft")
        app.buttons["compose.cancel"].tap()
        app.buttons["detail.tags.cancel"].tap(); app.buttons["BackButton"].tap()
        XCTAssertEqual(app.buttons["discover.search-entry"].value as? String, original)
        openDetail(app)
        _ = select("language:chinese", in: app); _ = select("artist:preview studio", in: app)
        app.buttons["detail.tags.search-menu"].tap(); app.buttons["detail.tags.add-to-search"].tap()
        app.buttons["compose.apply"].tap()
        let result = app.buttons["discover.search-entry"]
        XCTAssertTrue(result.waitForExistence(timeout: 6))
        let search = app.buttons["discover.search-entry"]
        XCTAssertTrue((search.value as? String)?.contains("coast field notes") == true)
        let filters = result.value as? String ?? ""
        XCTAssertTrue(filters.contains("artist:preview studio"))
        XCTAssertTrue(filters.contains("≥3星"))
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
        menu.tap()
        XCTAssertTrue(app.buttons["detail.tags.add-to-search"].label.contains("加入发现页搜索"))
        app.buttons["detail.tags.add-to-search"].tap()
        XCTAssertTrue(app.searchComposerTitle("编辑发现页搜索").waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["compose.tag-exclusions"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["compose.tag-exclusions"].label.contains("language:chinese"))
        XCTAssertTrue((app.buttons["compose.filters"].value as? String)?.contains("排除") == true)
        capture(app, "detail51.exclusion-draft.dark-large")
        app.buttons["compose.cancel"].tap()
        XCTAssertTrue(menu.waitForExistence(timeout: 5)); XCTAssertTrue(app.buttons["main.tab.library"].isHittable)

        menu.tap(); app.buttons["detail.tags.new-search"].tap()
        app.buttons["compose.apply"].tap()
        XCTAssertTrue(app.buttons["search.results.close"].waitForExistence(timeout: 5))
        app.buttons["search.results.close"].tap()
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["main.tab.library"].isSelected)
        XCTAssertEqual(app.buttons["detail.tag.language:chinese"].value as? String, "已选中")

        _ = select("artist:preview studio", in: app)
        menu.tap(); app.buttons["detail.tags.add-to-search"].tap()
        app.buttons["compose.apply"].tap()
        XCTAssertTrue(app.buttons["discover.search-entry"].waitForExistence(timeout: 6))
        XCTAssertTrue(app.buttons["main.tab.discover"].isSelected)
        XCTAssertTrue((app.buttons["discover.search-entry"].value as? String)?.contains("artist:preview studio") == true)
        app.buttons["main.tab.library"].tap()
        XCTAssertTrue(app.staticTexts["已选 2 个"].waitForExistence(timeout: 6))
        app.buttons["detail.tags.cancel"].tap()
        app.buttons["BackButton"].tap()
        XCTAssertTrue(stored.waitForExistence(timeout: 5))
    }

    func testReaderSearchCanReturnToReadingOrUpdateItsSourceResults() {
        let app = launch(["--qa-reader-transition"])
        startPreset(app); openDetail(app)
        app.buttons["在线阅读"].tap()
        let page = app.buttons["reader.page"]
        XCTAssertTrue(page.waitForExistence(timeout: 8))
        let readerPage = page.label
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleTap()
        XCTAssertTrue(app.buttons["返回阅读"].waitForExistence(timeout: 6))
        _ = select("language:chinese", in: app, mainTabs: false)
        app.buttons["detail.tags.search-menu"].tap(); app.buttons["detail.tags.new-search"].tap()
        XCTAssertTrue(app.searchComposerTitle("新建搜索").waitForExistence(timeout: 5))
        app.buttons["compose.apply"].tap()
        XCTAssertTrue(app.buttons["search.results.close"].waitForExistence(timeout: 6))
        app.buttons["search.results.close"].tap()
        XCTAssertTrue(app.staticTexts["已选 1 个"].waitForExistence(timeout: 5))
        XCTAssertEqual(visible(app.buttons.matching(identifier: "detail.tag.language:chinese")).value as? String, "已选中")
        app.buttons["返回阅读"].tap()
        XCTAssertTrue(page.waitForExistence(timeout: 5))
        XCTAssertEqual(page.label, readerPage)

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleTap()
        XCTAssertTrue(app.staticTexts["画廊详情"].waitForExistence(timeout: 6))
        _ = select("language:chinese", in: app, mainTabs: false)
        app.buttons["detail.tags.search-menu"].tap(); app.buttons["detail.tags.add-to-search"].tap()
        app.buttons["compose.apply"].tap()
        XCTAssertTrue(app.buttons["discover.search-entry"].waitForExistence(timeout: 8))
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.buttons["reader.page"])
        waitForExpectations(timeout: 6)
        XCTAssertTrue(app.buttons["main.tab.discover"].isHittable)
        XCTAssertTrue((app.buttons["discover.search-entry"].value as? String)?.contains("language:chinese") == true)
    }

    func testNewSearchReturnsToTheSameFavoriteGroupAndScrolledCard() {
        let app = launch(["--qa-library-large-selection"])
        app.buttons["main.tab.library"].tap()
        if app.buttons["library.scope.menu"].exists { app.buttons["library.scope.menu"].tap() }
        app.buttons["library.scope.1"].tap()
        let group = app.buttons["favorites.group-filter"]
        XCTAssertTrue(group.waitForExistence(timeout: 6))
        group.tap()
        app.buttons["常用"].firstMatch.tap()
        XCTAssertEqual(group.value as? String, "常用")
        let card = app.buttons["favorites.gallery.10008"]
        for _ in 0..<6 {
            if card.exists && card.isHittable && card.frame.midY > 200 && card.frame.midY < app.frame.maxY - 100 { break }
            app.swipeUp()
        }
        XCTAssertTrue(card.isHittable)
        let position = card.frame.midY
        card.tap()
        XCTAssertTrue(app.staticTexts["画廊详情"].waitForExistence(timeout: 6))
        _ = select("language:chinese", in: app)
        app.buttons["detail.tags.search-menu"].tap()
        app.buttons["detail.tags.new-search"].tap()
        app.buttons["compose.apply"].tap()
        XCTAssertTrue(app.buttons["search.results.close"].waitForExistence(timeout: 6))
        app.buttons["search.results.close"].tap()
        XCTAssertTrue(app.staticTexts["已选 1 个"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["main.tab.library"].isSelected)
        app.buttons["detail.tags.cancel"].tap()
        app.buttons["BackButton"].tap()
        XCTAssertTrue(group.waitForExistence(timeout: 5))
        XCTAssertEqual(group.value as? String, "常用")
        XCTAssertTrue(card.isHittable)
        XCTAssertEqual(card.frame.midY, position, accuracy: 2)
        card.press(forDuration: 0.7)
        XCTAssertTrue(app.batchSelection("已选 1 项").waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["detail.tags.search-menu"].exists)
    }
    func testNestedSearchHistoryLatestAndCloseRemainInTheSameFlow() {
        let app = launch(); openDetail(app)
        _ = select("language:chinese", in: app)
        visible(app.buttons.matching(identifier: "detail.tags.search-menu")).tap()
        app.buttons["detail.tags.new-search"].tap()
        XCTAssertTrue(app.buttons["compose.apply"].waitForExistence(timeout: 5))
        app.buttons["compose.apply"].tap()
        let entry = app.buttons["discover.search-entry"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        for index in 0...2 { XCTAssertFalse(app.buttons["discover.lane.\(index)"].isSelected) }
        app.buttons["discover.lane.2"].tap()
        let history = app.textFields["reading-history.search-field"]
        XCTAssertTrue(history.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["search.results.close"].isHittable)
        app.buttons["discover.lane.0"].tap()
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["discover.lane.0"].isSelected)
        app.buttons["discover.lane.2"].tap()
        XCTAssertTrue(history.waitForExistence(timeout: 5))
        app.buttons["search.results.close"].tap()
        XCTAssertTrue(app.buttons["detail.read"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["search.results.close"].exists)
    }

}
