import XCTest

final class SearchContractV43UITests: XCTestCase {
    private func favoriteRows(_ app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "search-favorites.load."))
    }
    private func openFavorites(_ app: XCUIApplication) {
        app.buttons["discover.search-entry"].tap()
        app.buttons["compose.records"].tap()
        app.segmentedControls["compose.records-tabs"].buttons["常用组合"].tap()
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
    func testFavoritesTapLoadsWhileLongPressEditsOriginalAndKeepsFilters() {
        let app = launch(["--qa-saved-search-management"])
        openFavorites(app)
        let initial = favoriteRows(app).element(boundBy: 0)
        let id = initial.identifier
        initial.tap()
        XCTAssertTrue(app.navigationBars["组合搜索"].waitForExistence(timeout: 4))
        XCTAssertEqual(app.textFields["compose.text"].value as? String, "coast")
        XCTAssertFalse(app.textFields["saved-editor.name"].exists)
        app.buttons["compose.cancel"].tap()
        XCTAssertFalse(app.buttons["discover.back"].exists, "Loading must not execute the query")

        openFavorites(app)
        favoriteRows(app).element(boundBy: 0).press(forDuration: 0.8)
        XCTAssertTrue(app.textFields["saved-editor.name"].waitForExistence(timeout: 4))
        XCTAssertEqual(app.textFields["saved-editor.name"].value as? String, "中文画集")
        replace(app.textFields["saved-editor.name"], with: "Updated collection")
        replace(app.textFields["compose.text"], with: "updated")
        app.buttons["saved-editor.save"].tap()
        XCTAssertTrue(app.navigationBars["记录与常用"].waitForExistence(timeout: 4), "Long press must not also load the preset")
        XCTAssertEqual(favoriteRows(app).count, 3)
        let updated = favoriteRows(app).element(boundBy: 0)
        XCTAssertEqual(updated.identifier, id)
        XCTAssertTrue(updated.label.contains("Updated collection")); XCTAssertTrue(updated.label.contains("updated"))
        XCTAssertTrue(updated.label.contains("language:chinese"))
        XCTAssertTrue(updated.label.contains("≥3星"))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "saved-search42.updated-original"; shot.lifetime = .keepAlways; add(shot)
        app.navigationBars["记录与常用"].buttons["BackButton"].tap(); app.buttons["compose.cancel"].tap()
        app.buttons["discover.saved-menu"].tap()
        let saved = favoriteRows(app).element(boundBy: 0)
        XCTAssertTrue(saved.waitForExistence(timeout: 4)); saved.press(forDuration: 0.8)
        XCTAssertTrue(app.textFields["saved-editor.name"].waitForExistence(timeout: 4))
        XCTAssertEqual(app.textFields["compose.text"].value as? String, "updated")
        XCTAssertTrue((app.buttons["compose.filters"].value as? String)?.contains("≥3星") == true)
        replace(app.textFields["saved-editor.name"], with: "Discarded")
        app.buttons["saved-editor.cancel"].tap()
        XCTAssertTrue(saved.waitForExistence(timeout: 4)); XCTAssertTrue(saved.label.contains("Updated collection"))
        app.navigationBars["记录与常用"].buttons["BackButton"].tap(); app.buttons["compose.cancel"].tap()
        XCTAssertFalse(app.buttons["discover.back"].exists)
    }
    func testFavoritesCanDragTheirOrderAndCommonEntryRetainsIt() {
        let app = launch(["--qa-saved-search-management"])
        openFavorites(app)
        let rows = favoriteRows(app)
        XCTAssertTrue(rows.element(boundBy: 0).label.contains("中文画集"))
        app.buttons["search-favorites.reorder"].tap()
        let first = app.cells.containing(.button, identifier: rows.element(boundBy: 0).identifier).firstMatch
        let last = app.cells.containing(.button, identifier: rows.element(boundBy: 2).identifier).firstMatch
        XCTAssertTrue(first.exists); XCTAssertTrue(last.exists)
        let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: first.frame.maxX - 20, dy: first.frame.midY))
        let end = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: last.frame.maxX - 20, dy: last.frame.maxY - 5))
        start.press(forDuration: 0.4, thenDragTo: end)
        expectation(for: NSPredicate(format: "label CONTAINS %@", "短篇优先"), evaluatedWith: rows.element(boundBy: 0))
        waitForExpectations(timeout: 5)
        XCTAssertTrue(rows.element(boundBy: 2).label.contains("中文画集"))
        app.buttons["search-favorites.reorder"].tap()
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "saved-search42.reordered"; shot.lifetime = .keepAlways; add(shot)
        app.navigationBars["记录与常用"].buttons["BackButton"].tap(); app.buttons["compose.cancel"].tap()
        app.buttons["discover.saved-menu"].tap()
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

    private func chooseMinimumRating(_ app: XCUIApplication, _ title: String) {
        app.buttons["compose.filters"].tap()
        let picker = app.buttons["compose.min-rating"]
        XCTAssertTrue(app.navigationBars["筛选条件"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["compose.sort-order"].exists)
        for _ in 0..<8 { if picker.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(picker.isHittable); picker.tap()
        let choice = app.buttons[title].firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 3)); choice.tap()
        app.navigationBars["筛选条件"].buttons["BackButton"].tap()
    }

    func testMinimumRatingFiltersWithoutReorderingTheServerResults() {
        let app = launch(); startDraft(app)
        chooseMinimumRating(app, "3 星")
        app.buttons["compose.apply"].tap()
        let summary = app.buttons["discover.condition-summary"]
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
        replace(app.textFields["compose.text"], with: "notes")
        XCTAssertEqual(app.descendants(matching: .any)["compose.loaded-state"].firstMatch.value as? String, "已修改")
        app.buttons["compose.cancel"].tap()
        XCTAssertTrue((app.buttons["discover.condition-summary"].value as? String)?.contains("coast") == true)
        app.buttons["discover.search-entry"].tap(); app.buttons["compose.records"].tap()
        app.segmentedControls["compose.records-tabs"].buttons["常用组合"].tap()
        let common = favoriteRows(app).firstMatch
        XCTAssertTrue(common.waitForExistence(timeout: 5)); XCTAssertTrue(common.label.contains("coast")); common.tap()
        let loaded = app.descendants(matching: .any)["compose.loaded-state"].firstMatch
        XCTAssertTrue(loaded.waitForExistence(timeout: 5)); XCTAssertEqual(loaded.value as? String, "已载入")
        replace(app.textFields["compose.text"], with: "notes"); app.buttons["compose.apply"].tap()
        XCTAssertTrue((app.buttons["discover.condition-summary"].value as? String)?.contains("notes") == true)
        app.buttons["discover.search-entry"].tap(); app.buttons["compose.records"].tap()
        app.segmentedControls["compose.records-tabs"].buttons["最近搜索"].tap()
        let history = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "search-history.load."))
        XCTAssertEqual(history.count, 2)
        XCTAssertTrue(history.element(boundBy: 0).label.contains("notes"))
        XCTAssertTrue(history.element(boundBy: 1).label.contains("coast"))
        history.element(boundBy: 1).tap()
        XCTAssertEqual(app.textFields["compose.text"].value as? String, "coast")
        app.buttons["compose.cancel"].tap()
        XCTAssertTrue((app.buttons["discover.condition-summary"].value as? String)?.contains("notes") == true)
    }

    func testRealRatingFilterRemainsReachableInDarkLargeType() {
        let app = launch(["--qa-dark", "--qa-large-type"]); startDraft(app)
        chooseMinimumRating(app, "3 星")
        XCTAssertTrue((app.buttons["compose.filters"].value as? String)?.contains("≥3星") == true)
        XCTAssertFalse(app.buttons["compose.sort-order"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "search43.filters.dark-large"; shot.lifetime = .keepAlways; add(shot)
    }
}
