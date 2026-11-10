import XCTest

final class LibrarySortingV28UITests: XCTestCase {
    private func openLibrary(seed: Bool = true, reset: Bool = true, extra: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--qa"] + (seed ? ["--qa-library-sort"] : []) + (reset ? ["--qa-reset-library-sort"] : []) + extra
        app.launch(); XCTAssertTrue(app.buttons["main.tab.library"].waitForExistence(timeout: 12)); app.buttons["main.tab.library"].tap()
        scope(app, 3)
        XCTAssertTrue(app.descendants(matching: .any)["library.sort.downloads"].firstMatch.waitForExistence(timeout: 5)); return app
    }
    private func scope(_ app: XCUIApplication, _ index: Int) {
        if app.buttons["library.scope.menu"].exists { app.buttons["library.scope.menu"].tap() }
        let option = app.buttons["library.scope.\(index)"]
        XCTAssertTrue(option.waitForExistence(timeout: 5)); option.tap()
    }
    private func openHistory(_ app: XCUIApplication) {
        app.buttons["main.tab.discover"].tap()
        let history = app.buttons["discover.lane.2"]
        XCTAssertTrue(history.waitForExistence(timeout: 5)); history.tap()
        XCTAssertTrue(app.textFields["reading-history.search-field"].waitForExistence(timeout: 5))
    }
    private func choose(_ app: XCUIApplication, section: String, title: String, up: Bool = true) {
        if section != "history" { scope(app, section == "downloads" ? 3 : 0) }
        let menu = app.descendants(matching: .any)[section == "history" ? "reading-history.sort" : "library.sort.\(section)"].firstMatch
        for _ in 0..<12 { if menu.exists && menu.isHittable { break }; if up { app.swipeUp() } else { app.swipeDown() } }
        XCTAssertTrue(menu.exists && menu.isHittable); menu.tap()
        let choice = app.buttons[title].firstMatch; XCTAssertTrue(choice.waitForExistence(timeout: 5)); choice.tap()
        XCTAssertEqual(menu.value as? String, title)
    }
    private func assertHistory(_ app: XCUIApplication, _ ids: [Int]) {
        let rows = ids.map { app.buttons["reading-history.item.\($0)"] }
        for row in rows { XCTAssertTrue(row.exists) }
        XCTAssertLessThan(rows[0].frame.minY, rows[1].frame.minY); XCTAssertLessThan(rows[1].frame.minY, rows[2].frame.minY)
    }
    func testHistorySortPersistsAcrossDetailReturnTabReturnAndRelaunch() {
        let app = openLibrary(extra: ["--qa-dark"]); openHistory(app); assertHistory(app, [7203, 7202, 7201])
        let header = app.descendants(matching: .any)["discover.header.floating"].firstMatch
        XCTAssertTrue(header.exists)
        XCTAssertTrue(app.buttons["discover.lane.2"].isSelected)
        let sort = app.buttons["reading-history.sort"]
        let period = app.buttons["reading-history.period"]
        let search = app.descendants(matching: .any)["reading-history.search"].firstMatch
        XCTAssertEqual(search.frame.width, 2 * period.frame.width + 4, accuracy: 1)
        XCTAssertEqual(sort.frame.width, period.frame.width, accuracy: 1)
        XCTAssertEqual(period.frame.minX - search.frame.maxX, 4, accuracy: 1)
        XCTAssertEqual(sort.frame.minX - period.frame.maxX, 4, accuracy: 1)
        let historyTab = app.buttons["discover.lane.2"]
        XCTAssertEqual(search.frame.midY, sort.frame.midY, accuracy: 1)
        XCTAssertEqual(search.frame.midY - historyTab.frame.midY, search.frame.height, accuracy: 1)
        XCTAssertFalse(app.buttons["discover.saved-menu"].exists)
        XCTAssertFalse(app.buttons["discover.search-entry"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["reading-history.summary"].firstMatch.exists)
        period.tap()
        app.buttons["reading-history.period.today"].tap()
        XCTAssertTrue(app.staticTexts["这段时间暂无阅读记录"].waitForExistence(timeout: 5))
        period.tap()
        app.buttons["reading-history.period.all"].tap()
        XCTAssertTrue(app.buttons["reading-history.item.7203"].waitForExistence(timeout: 5))
        let field = app.textFields["reading-history.search-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("beta")
        XCTAssertTrue(app.buttons["reading-history.item.7203"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["reading-history.item.7201"].exists)
        field.typeText("\n")
        app.buttons["reading-history.clear-search"].tap()
        XCTAssertTrue(app.buttons["reading-history.item.7203"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars["阅读历史"].exists)
        let historyShot = XCTAttachment(screenshot: app.screenshot())
        historyShot.name = "discover-history-floating-header"
        historyShot.lifetime = .keepAlways
        add(historyShot)
        choose(app, section: "history", title: "最早阅读"); assertHistory(app, [7201, 7202, 7203])
        choose(app, section: "history", title: "标题"); assertHistory(app, [7202, 7203, 7201])
        app.buttons["reading-history.item.7202"].tap()
        XCTAssertTrue(app.staticTexts["画廊详情"].waitForExistence(timeout: 5)); app.buttons["BackButton"].tap()
        XCTAssertEqual(app.descendants(matching: .any)["reading-history.sort"].firstMatch.value as? String, "标题")
        app.buttons["discover.lane.0"].tap()
        XCTAssertTrue(app.buttons["discover.lane.0"].isSelected)
        app.buttons["main.tab.library"].tap(); openHistory(app)
        XCTAssertEqual(app.descendants(matching: .any)["reading-history.sort"].firstMatch.value as? String, "标题")
        app.terminate()
        let relaunched = openLibrary(reset: false); openHistory(relaunched)
        XCTAssertEqual(relaunched.descendants(matching: .any)["reading-history.sort"].firstMatch.value as? String, "标题")
        assertHistory(relaunched, [7202, 7203, 7201])
    }
    func testDownloadAndBookmarkMenusAreIndependentAndUnreadItemsFollowReadItems() {
        let app = openLibrary()
        choose(app, section: "downloads", title: "最近阅读")
        let read = app.descendants(matching: .any)["library.download.item.7203"].firstMatch
        let unread = app.descendants(matching: .any)["library.download.item.7204"].firstMatch
        XCTAssertTrue(read.exists); XCTAssertTrue(unread.exists); XCTAssertLessThan(read.frame.minY, unread.frame.minY)
        choose(app, section: "bookmarks", title: "标题")
        let alpha = app.buttons["favorites.gallery.7202"]
        for _ in 0..<5 { if alpha.exists && alpha.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(alpha.exists)
        choose(app, section: "bookmarks", title: "最近阅读", up: false)
        let latest = app.buttons["favorites.gallery.7203"], next = app.buttons["favorites.gallery.7202"]
        XCTAssertTrue(latest.exists); XCTAssertTrue(next.exists); XCTAssertLessThan(latest.frame.minX, next.frame.minX)
        choose(app, section: "downloads", title: "标题", up: false)
        openHistory(app)
        XCTAssertEqual(app.descendants(matching: .any)["reading-history.sort"].firstMatch.value as? String, "最近阅读")
        app.terminate()
        let reopened = openLibrary(reset: false)
        choose(reopened, section: "downloads", title: "标题")
        choose(reopened, section: "bookmarks", title: "最近阅读")
    }
    func testEmptyLocalLibraryAndLargeTypeMenusKeepClearLabelsAndHitAreas() {
        let empty = openLibrary(seed: false)
        choose(empty, section: "downloads", title: "最近阅读")
        let scopeY = empty.buttons["library.scope.0"].frame.minY
        let actionsY = empty.buttons["library.sort.downloads"].frame.minY
        var shot: XCTAttachment
        for (index, action, name) in [(0, "library.sort.bookmarks", "read-later"), (1, "favorites.group-filter", "favorites"), (2, "reading-history.sort", "history"), (3, "library.sort.downloads", "downloads")] {
            scope(empty, index)
            let control = empty.buttons[action]
            XCTAssertTrue(control.waitForExistence(timeout: 5))
            XCTAssertEqual(empty.buttons["library.scope.0"].frame.minY, scopeY, accuracy: 1)
            XCTAssertEqual(control.frame.minY, actionsY, accuracy: 1)
            shot = XCTAttachment(screenshot: empty.screenshot()); shot.name = "library47.\(name).light"; shot.lifetime = .keepAlways; add(shot)
        }
        choose(empty, section: "bookmarks", title: "标题")
        openHistory(empty)
        XCTAssertTrue(empty.staticTexts["暂无阅读记录"].waitForExistence(timeout: 5))
        choose(empty, section: "history", title: "标题")
        empty.terminate()
        let large = openLibrary(extra: ["--qa-dark", "--qa-large-type"])
        choose(large, section: "downloads", title: "最近阅读")
        shot = XCTAttachment(screenshot: large.screenshot()); shot.name = "library47.downloads.dark-large"; shot.lifetime = .keepAlways; add(shot)
        openHistory(large)
        let menu = large.descendants(matching: .any)["reading-history.sort"].firstMatch
        XCTAssertGreaterThanOrEqual(menu.frame.width, 44); XCTAssertGreaterThanOrEqual(menu.frame.height, 44)
        choose(large, section: "history", title: "最早阅读")
        shot = XCTAttachment(screenshot: large.screenshot()); shot.name = "library47.history.dark-large"; shot.lifetime = .keepAlways; add(shot)
    }
    func testFavoriteSelectionHasExplicitExitAndPlainTapKeepsBrowsing() {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--qa", "--qa-library-large-selection"]; app.launch()
        XCTAssertTrue(app.buttons["main.tab.library"].waitForExistence(timeout: 12)); app.buttons["main.tab.library"].tap()
        let first = app.buttons["favorites.gallery.10000"]; XCTAssertTrue(first.waitForExistence(timeout: 8)); first.press(forDuration: 0.8)
        XCTAssertTrue(app.batchSelection("已选 1 项").waitForExistence(timeout: 5))
        app.buttons["favorites.select.10001"].tap(); XCTAssertTrue(app.batchSelection("已选 2 项").waitForExistence(timeout: 5))
        let exit = app.buttons["favorites.edit"]; XCTAssertEqual(exit.label, "退出多选"); exit.tap()
        XCTAssertTrue(first.waitForExistence(timeout: 5)); first.tap()
        XCTAssertTrue(app.staticTexts["画廊详情"].waitForExistence(timeout: 5)); app.buttons["BackButton"].tap()
        XCTAssertTrue(first.waitForExistence(timeout: 5)); first.press(forDuration: 0.8)
        XCTAssertTrue(app.batchSelection("已选 1 项").waitForExistence(timeout: 5))
        app.buttons["favorites.select.10000"].tap(); XCTAssertTrue(app.batchSelection("已选 0 项").waitForExistence(timeout: 5))
        exit.tap(); XCTAssertTrue(first.waitForExistence(timeout: 5))
    }
}
