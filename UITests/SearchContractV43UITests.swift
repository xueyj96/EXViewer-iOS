import XCTest

final class SearchContractV43UITests: XCTestCase {
    private func favoriteRows(_ app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "search-favorites.load."))
    }
    private func openFavorites(_ app: XCUIApplication) {
        let common = app.buttons["discover.saved-menu"]
        XCTAssertTrue(common.waitForExistence(timeout: 5)); common.tap()
        XCTAssertTrue(favoriteRows(app).firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(favoriteRows(app).count, 3)
    }
    private func replace(_ field: XCUIElement, with text: String) {
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        if let current = field.value as? String, current != field.placeholderValue {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        field.typeText(text)
        XCTAssertEqual(field.value as? String, text)
    }
    func testSavedEditorNameInputAndActionsShareCompactLayout() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--qa", "--qa-search-sort", "--qa-tags-offline", "--qa-saved-search-management"]
        app.launch()
        let searchLane = app.buttons["discover.lane.3"]
        XCTAssertTrue(searchLane.waitForExistence(timeout: 12)); searchLane.tap()
        openFavorites(app)
        favoriteRows(app).firstMatch.press(forDuration: 0.8)
        let name = app.textFields["saved-editor.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        let clear = app.buttons["compose.clear"]
        let delete = app.buttons["saved-editor.delete"]
        XCTAssertTrue(delete.exists)
        XCTAssertEqual(clear.frame.midY, delete.frame.midY, accuracy: 1)
        XCTAssertEqual(clear.frame.width, delete.frame.width, accuracy: 1)
        XCTAssertEqual(clear.frame.height, delete.frame.height, accuracy: 1)
        XCTAssertGreaterThan(name.frame.width, app.frame.width * 0.5)
        XCTAssertGreaterThan(name.frame.minX, app.textFields["saved-editor.text"].frame.minX)
        replace(name, with: "Updated collection")
        app.buttons["saved-editor.save"].tap()
        XCTAssertTrue(favoriteRows(app).firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(favoriteRows(app).firstMatch.label.contains("Updated collection"))
        favoriteRows(app).firstMatch.press(forDuration: 0.8)
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertEqual(name.value as? String, "Updated collection")
        app.buttons["saved-editor.cancel"].tap()
    }

    func testFavoritesTapLoadsWhileLongPressEditsOriginalAndKeepsFilters() {
        let app = launch(["--qa-saved-search-management"])
        let filterShortcut = app.buttons["discover.filters"]
        XCTAssertTrue(filterShortcut.waitForExistence(timeout: 5)); filterShortcut.tap()
        let filters = app.buttons["compose.filters"]
        XCTAssertTrue(filters.waitForExistence(timeout: 5))
        XCTAssertTrue((filters.value as? String)?.hasPrefix("已展开") == true)
        app.buttons["compose.cancel"].tap()
        XCTAssertTrue(app.buttons["compose.cancel"].waitForNonExistence(timeout: 5))

        openFavorites(app)
        let initial = favoriteRows(app).element(boundBy: 0)
        let id = initial.identifier
        // XCTest includes the list row’s 4 pt bottom inset around the 52 pt card.
        XCTAssertEqual(initial.frame.height, 56, accuracy: 1)
        initial.tap()
        XCTAssertTrue(app.searchComposerTitle("搜索").waitForExistence(timeout: 4))
        XCTAssertEqual(app.textFields["compose.text"].value as? String, "coast")
        XCTAssertTrue((filters.value as? String)?.hasPrefix("已展开") == true)
        let favoriteAction = app.buttons["compose.save-favorite"]
        let firstFilter = app.buttons["compose.add-tag"]
        XCTAssertTrue(firstFilter.exists)
        XCTAssertLessThan(favoriteAction.frame.maxY, filters.frame.midY)
        XCTAssertLessThan(filters.frame.maxY, firstFilter.frame.midY)
        filters.tap()
        let filterPreview = app.staticTexts["compose.filters.preview"]
        let filterLimits = app.staticTexts["compose.filters.limits"]
        XCTAssertTrue(filterPreview.waitForExistence(timeout: 5))
        XCTAssertFalse(filterPreview.label.contains("coast"))
        XCTAssertEqual(filterLimits.label, "≥3 星")
        XCTAssertTrue((app.buttons["compose.filters"].value as? String)?.contains("language:chinese") == true)
        XCTAssertFalse(app.textFields["saved-editor.name"].exists)
        app.buttons["compose.cancel"].tap()
        XCTAssertTrue(app.buttons["compose.cancel"].waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.buttons["discover.back"].exists, "Loading must not execute the query")

        openFavorites(app)
        favoriteRows(app).element(boundBy: 0).press(forDuration: 0.8)
        XCTAssertTrue(app.textFields["saved-editor.name"].waitForExistence(timeout: 4))
        XCTAssertEqual(app.textFields["saved-editor.name"].value as? String, "中文画集")
        replace(app.textFields["saved-editor.name"], with: "Updated collection")
        replace(app.textFields["saved-editor.text"], with: "updated")
        app.buttons["saved-editor.save"].tap()
        XCTAssertTrue(app.staticTexts["常用组合"].waitForExistence(timeout: 4), "Long press must not also load the preset")
        XCTAssertEqual(favoriteRows(app).count, 3)
        let updated = favoriteRows(app).element(boundBy: 0)
        XCTAssertEqual(updated.identifier, id)
        XCTAssertTrue(updated.label.contains("Updated collection")); XCTAssertTrue(updated.label.contains("updated"))
        XCTAssertTrue(updated.label.contains("language:chinese"))
        XCTAssertTrue(updated.label.contains("≥3星"))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "saved-search42.updated-original"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["search-presets.close"].tap()
        XCTAssertTrue(app.buttons["search-presets.close"].waitForNonExistence(timeout: 5))
        openFavorites(app)
        let saved = favoriteRows(app).element(boundBy: 0)
        XCTAssertTrue(saved.waitForExistence(timeout: 4)); saved.press(forDuration: 0.8)
        XCTAssertTrue(app.textFields["saved-editor.name"].waitForExistence(timeout: 4))
        XCTAssertEqual(app.textFields["saved-editor.text"].value as? String, "updated")
        XCTAssertTrue((app.buttons["compose.filters"].value as? String)?.contains("≥3星") == true)
        replace(app.textFields["saved-editor.name"], with: "Discarded")
        app.buttons["saved-editor.cancel"].tap()
        XCTAssertTrue(saved.waitForExistence(timeout: 4)); XCTAssertTrue(saved.label.contains("Updated collection"))
        app.buttons["search-presets.close"].tap()
        XCTAssertFalse(app.buttons["discover.back"].exists)
    }
    func testFavoritesCanDragTheirOrderAndCommonEntryRetainsIt() {
        let app = launch(["--qa-saved-search-management"])
        openFavorites(app)
        let rows = favoriteRows(app)
        XCTAssertTrue(rows.element(boundBy: 0).label.contains("中文画集"))
        let reorder = app.buttons["search-favorites.reorder"]
        XCTAssertEqual(reorder.label, "编辑顺序")
        XCTAssertEqual(reorder.frame.width, app.buttons["search-presets.close"].frame.width, accuracy: 1)
        reorder.tap()
        XCTAssertEqual(reorder.label, "完成")
        let first = rows.element(boundBy: 0)
        let last = rows.element(boundBy: 2)
        XCTAssertTrue(first.exists); XCTAssertTrue(last.exists)
        let handleInset = CGVector(dx: -28, dy: 0)
        let start = first.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5)).withOffset(handleInset)
        let end = last.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.9)).withOffset(handleInset)
        start.press(forDuration: 0.5, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.35)
        XCTAssertTrue(rows.element(boundBy: 0).label.contains("短篇优先"))
        XCTAssertTrue(rows.element(boundBy: 2).label.contains("中文画集"))
        app.buttons["search-favorites.reorder"].tap()
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "saved-search42.reordered"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["search-presets.close"].tap()
        XCTAssertTrue(app.buttons["search-presets.close"].waitForNonExistence(timeout: 5))
        openFavorites(app)
        let reopened = favoriteRows(app)
        XCTAssertEqual(reopened.count, 3)
        XCTAssertTrue(reopened.element(boundBy: 0).label.contains("短篇优先"))
        XCTAssertTrue(reopened.element(boundBy: 2).label.contains("中文画集"))
    }
    private func launch(_ extra: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--qa", "--qa-search-sort", "--qa-tags-offline"] + extra
        app.launch()
        XCTAssertTrue(app.buttons["discover.search-entry"].waitForExistence(timeout: 12))
        return app
    }

    private func startDraft(_ app: XCUIApplication) {
        app.buttons["discover.search-entry"].tap()
        let input = app.textFields["compose.text"]
        XCTAssertTrue(input.waitForExistence(timeout: 5)); input.tap(); input.typeText("coast")
    }

    func testSearchHistoryStaysBesideTheInputWithRecentSearches() {
        let app = launch(["--qa-dark"])
        let discoverHeader = app.descendants(matching: .any)["discover.header.floating"].firstMatch
        let discoverTop = discoverHeader.frame.minY
        startDraft(app)
        app.buttons["compose.apply"].tap()
        XCTAssertTrue(app.buttons["discover.search-entry"].waitForExistence(timeout: 6))

        app.buttons["discover.search-entry"].tap()
        app.buttons["compose.clear"].tap()
        let recent = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "search-history.recent.")).firstMatch
        XCTAssertTrue(recent.waitForExistence(timeout: 5))
        let history = app.buttons["compose.records"]
        XCTAssertTrue(history.isHittable)
        XCTAssertEqual(history.frame.midY, app.textFields["compose.text"].frame.midY, accuracy: 4)
        let header = app.descendants(matching: .any)["compose.header"].firstMatch
        let filter = app.buttons["compose.filters"]
        let save = app.buttons["compose.save-favorite"]
        let apply = app.buttons["compose.apply"]
        XCTAssertEqual(apply.label, "更新结果")
        XCTAssertEqual(apply.frame.width, app.buttons["compose.cancel"].frame.width, accuracy: 1)
        XCTAssertEqual(header.frame.minY - discoverTop, 3, accuracy: 2)
        // Touch targets touch; each visible card is inset 4 pt vertically.
        XCTAssertEqual(save.frame.minY - filter.frame.maxY, 0, accuracy: 1)
        XCTAssertFalse(save.isEnabled)
        XCTAssertFalse(header.buttons["compose.save-favorite"].exists)
        XCTAssertFalse(app.buttons["compose.saved-list"].exists)
        XCTAssertEqual(filter.frame.height, 44, accuracy: 1)
        XCTAssertEqual(save.frame.height, 44, accuracy: 1)
        for card in [filter, save, recent] {
            XCTAssertEqual(card.frame.minX, header.frame.minX, accuracy: 1)
            XCTAssertEqual(card.frame.maxX, header.frame.maxX, accuracy: 1)
        }
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "search-audit-dark-cards"; shot.lifetime = .keepAlways; add(shot)
        history.tap()
        XCTAssertTrue(app.staticTexts["搜索记录"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "search-history.load.")).firstMatch.label.contains("coast"))
    }

    private func chooseMinimumRating(_ app: XCUIApplication, _ title: String) {
        app.buttons["compose.filters"].tap()
        let picker = app.buttons["compose.min-rating"]
        XCTAssertTrue(app.searchComposerTitle("搜索").waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["compose.sort-order"].exists)
        for _ in 0..<8 { if picker.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(picker.isHittable); picker.tap()
        let choice = app.buttons[title].firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 3)); choice.tap()
        let filters = app.buttons["compose.filters"]
        for _ in 0..<8 { if filters.isHittable { break }; app.swipeDown() }
        XCTAssertTrue(filters.isHittable)
    }

    func testMinimumRatingFiltersWithoutReorderingTheServerResults() {
        let app = launch(); startDraft(app)
        chooseMinimumRating(app, "3 星")
        app.buttons["compose.apply"].tap()
        let summary = app.buttons["discover.search-entry"]
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        XCTAssertTrue((summary.value as? String)?.contains("≥3星") == true)
        XCTAssertFalse(app.buttons["discover.sort-order"].exists)
        let first = app.buttons["gallery.open.2"], second = app.buttons["gallery.open.3"]
        XCTAssertTrue(first.waitForExistence(timeout: 5)); XCTAssertTrue(second.exists)
        XCTAssertFalse(app.buttons["gallery.open.1"].exists)
        XCTAssertLessThan(first.frame.minX, second.frame.minX)
        XCTAssertLessThan(first.frame.minY, app.buttons["gallery.open.4"].frame.minY)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "search43.server-order.minimum-rating"; shot.lifetime = .keepAlways; add(shot)
    }

    func testSavedConditionsAndHistoryCanBeLoadedEditedAndCancelled() {
        let app = launch(); startDraft(app)
        app.buttons["compose.apply"].tap()
        app.buttons["discover.search-entry"].tap(); app.buttons["compose.save-favorite"].tap()
        XCTAssertTrue(app.textFields["search.save.name"].waitForExistence(timeout: 5))
        app.buttons["search.save.confirm"].tap()
        XCTAssertEqual(app.buttons["compose.save-favorite"].value as? String, "已保存")
        XCTAssertFalse(app.descendants(matching: .any)["compose.loaded-state"].firstMatch.exists)
        replace(app.textFields["compose.text"], with: "notes")
        XCTAssertFalse(app.descendants(matching: .any)["compose.loaded-state"].firstMatch.exists)
        app.buttons["compose.cancel"].tap()
        XCTAssertTrue((app.buttons["discover.search-entry"].value as? String)?.contains("coast") == true)
        app.buttons["discover.saved-menu"].tap()
        let common = favoriteRows(app).firstMatch
        XCTAssertTrue(common.waitForExistence(timeout: 5)); XCTAssertTrue(common.label.contains("coast")); common.tap()
        let keyword = app.textFields["compose.text"]
        XCTAssertTrue(keyword.waitForExistence(timeout: 5))
        XCTAssertEqual(keyword.value as? String, "coast")
        XCTAssertFalse(app.descendants(matching: .any)["compose.loaded-state"].firstMatch.exists)
        replace(app.textFields["compose.text"], with: "notes"); app.buttons["compose.apply"].tap()
        XCTAssertTrue((app.buttons["discover.search-entry"].value as? String)?.contains("notes") == true)
        app.buttons["discover.search-entry"].tap(); app.buttons["compose.records"].tap()
        let history = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "search-history.load."))
        XCTAssertEqual(history.count, 2)
        XCTAssertTrue(history.element(boundBy: 0).label.contains("notes"))
        XCTAssertTrue(history.element(boundBy: 1).label.contains("coast"))
        history.element(boundBy: 1).tap()
        XCTAssertEqual(app.textFields["compose.text"].value as? String, "coast")
        app.buttons["compose.cancel"].tap()
        XCTAssertTrue((app.buttons["discover.search-entry"].value as? String)?.contains("notes") == true)
    }

    func testSavedSearchIsReadOnlyOutsideFavoritesAndDeletionKeepsSearchHistory() {
        let app = launch(); startDraft(app)
        app.buttons["compose.apply"].tap()
        app.buttons["discover.search-entry"].tap()
        let bookmark = app.buttons["compose.save-favorite"]
        XCTAssertEqual(bookmark.value as? String, "未保存")
        bookmark.tap()
        let confirm = app.buttons["search.save.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5)); confirm.tap()
        expectation(for: NSPredicate(format: "value == %@", "已保存"), evaluatedWith: bookmark)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(bookmark.label, "已存常用")
        XCTAssertFalse(bookmark.isEnabled)

        app.buttons["compose.records"].tap()
        let historyAction = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "search-history.save.")).firstMatch
        XCTAssertTrue(historyAction.waitForExistence(timeout: 5))
        XCTAssertEqual(historyAction.label, "已存常用")
        XCTAssertFalse(historyAction.isEnabled)
        app.buttons["search-presets.close"].tap()
        app.buttons["compose.cancel"].tap()

        app.buttons["discover.saved-menu"].tap()
        let row = favoriteRows(app).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.press(forDuration: 0.8)
        let delete = app.buttons["saved-editor.delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5)); delete.tap()
        let confirmDelete = app.sheets["删除这个常用组合？"].buttons["saved-editor.confirm-delete"].firstMatch
        XCTAssertTrue(confirmDelete.waitForExistence(timeout: 5)); confirmDelete.tap()
        XCTAssertTrue(app.staticTexts["search-favorites.empty"].waitForExistence(timeout: 5))
        app.buttons["search-presets.close"].tap()

        app.buttons["discover.search-entry"].tap()
        XCTAssertTrue(bookmark.waitForExistence(timeout: 5))
        XCTAssertEqual(bookmark.label, "加入常用搜索组合")
        XCTAssertTrue(bookmark.isEnabled)
        app.buttons["compose.records"].tap()
        let history = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "search-history.load.")).firstMatch
        XCTAssertTrue(history.waitForExistence(timeout: 5))
        XCTAssertTrue(history.label.contains("coast"))
        XCTAssertTrue(historyAction.isEnabled)
    }

    func testRealRatingFilterRemainsReachableInDarkLargeType() {
        let app = launch(["--qa-dark", "--qa-large-type"]); startDraft(app)
        chooseMinimumRating(app, "3 星")
        XCTAssertTrue((app.buttons["compose.filters"].value as? String)?.contains("≥3星") == true)
        XCTAssertFalse(app.buttons["compose.sort-order"].exists)
        XCTAssertFalse(app.buttons["compose.site"].exists, "Search inherits the browsing site instead of offering a second site selector")
        let filters = app.buttons["compose.filters"]
        XCTAssertTrue((filters.value as? String)?.contains("EX") == true)
        XCTAssertTrue((filters.value as? String)?.contains("≥3星") == true)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "search43.filters.dark-large"; shot.lifetime = .keepAlways; add(shot)
    }
}
