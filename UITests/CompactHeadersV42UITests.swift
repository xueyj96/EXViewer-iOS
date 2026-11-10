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
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }

    private func assertContentWidth(_ app: XCUIApplication, header: XCUIElement, leading: XCUIElement, trailing: XCUIElement) {
        XCTAssertTrue(leading.waitForExistence(timeout: 5)); XCTAssertTrue(trailing.exists)
        XCTAssertEqual(header.frame.minX, app.frame.minX + 20, accuracy: 1)
        XCTAssertEqual(header.frame.maxX, app.frame.maxX - 20, accuracy: 1)
        XCTAssertEqual(header.frame.minX, leading.frame.minX, accuracy: 1)
        XCTAssertEqual(header.frame.maxX, trailing.frame.maxX, accuracy: 1)
    }

    private func loadFirstPreset(_ app: XCUIApplication) {
        app.buttons["discover.saved-menu"].tap()
        XCTAssertTrue(app.staticTexts["常用组合"].waitForExistence(timeout: 5))
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
        XCTAssertEqual(summary.frame.minX, header.frame.minX + 4, accuracy: 1)
        XCTAssertEqual(summary.frame.midY, common.frame.midY, accuracy: 1)
        XCTAssertGreaterThanOrEqual(summary.frame.height, 44)
        XCTAssertGreaterThanOrEqual(common.frame.width, 44)
        XCTAssertEqual(common.frame.maxX, header.frame.maxX - 4, accuracy: 1)
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
        assertContentWidth(app, header: header, leading: app.buttons["gallery.open.1"], trailing: app.buttons["gallery.open.2"])
        capture(app, "feed-alignment.discover")
        loadFirstPreset(app); app.buttons["compose.cancel"].tap()
        XCTAssertFalse(app.buttons["discover.condition-summary"].exists)
        XCTAssertFalse(app.buttons["discover.back"].exists)
        loadFirstPreset(app); app.buttons["compose.apply"].tap()
        assertActiveHeader(app, large: false)
        XCTAssertEqual(header.frame.height, initialHeight, accuracy: 4)
        let card = app.buttons["gallery.open.2"]
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        XCTAssertEqual(card.frame.minX, header.frame.minX, accuracy: 1)
        XCTAssertGreaterThanOrEqual(card.frame.minY, header.frame.maxY)
        capture(app, "compact42.search.light")
        app.buttons["discover.condition-summary"].tap()
        XCTAssertTrue(app.searchComposerTitle("搜索").waitForExistence(timeout: 5))
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
        // App geometry changes before the rendered rotation completes. Wait for a landscape capture too.
        expectation(for: NSPredicate { _, _ in
            let size = XCUIScreen.main.screenshot().image.size
            return size.width > size.height
        }, evaluatedWith: app)
        waitForExpectations(timeout: 6)
        let summary = app.buttons["discover.condition-summary"], common = app.buttons["discover.saved-menu"]
        XCTAssertTrue(summary.isHittable && common.isHittable)
        XCTAssertLessThanOrEqual(common.frame.maxX, app.frame.maxX)
        capture(app, "compact42.search.dark-large-landscape")
    }

    func testComposerFilterKeepsOneRowWithFiveConditions() {
        let app = launch()
        loadFirstPreset(app)
        app.buttons["compose.filters"].tap()
        let phrase = app.switches["匹配完整短语"]
        for _ in 0..<6 { if phrase.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(phrase.isHittable)
        XCTAssertEqual(phrase.value as? String, "0")
        // SwiftUI exposes the entire labelled row as the switch; target the visible switch thumb.
        phrase.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(phrase.value as? String, "1")
        app.buttons["compose.apply"].tap()
        let badge = app.buttons["discover.filters"]
        XCTAssertTrue(badge.waitForExistence(timeout: 5))
        XCTAssertTrue((badge.value as? String ?? "").contains("5 项筛选条件"))
        capture(app, "summary62.five-conditions.preview")
        app.buttons["discover.condition-summary"].tap()
        let filter = app.buttons["compose.filters"]
        XCTAssertTrue(filter.waitForExistence(timeout: 5))
        filter.tap()
        let title = app.staticTexts["compose.filters.title"]
        let count = app.staticTexts["compose.filters.count"]
        let common = app.buttons["compose.save-favorite"]
        XCTAssertTrue(filter.isHittable && count.exists && common.isHittable)
        XCTAssertTrue(count.label.contains("5 项条件"))
        XCTAssertEqual(title.frame.midY, count.frame.midY, accuracy: 1)
        XCTAssertFalse(app.staticTexts["compose.current-summary"].exists)
        XCTAssertEqual(filter.frame.height, 44, accuracy: 1)
        capture(app, "composer.single-row.light.collapsed")
        filter.tap()
        XCTAssertTrue((filter.value as? String ?? "").contains("已展开"))
        XCTAssertEqual(filter.frame.height, 44, accuracy: 1)
        for condition in ["仅标题", "完整短语", "language:chinese", "≥3星", "排除分类"] {
            XCTAssertTrue((filter.value as? String ?? "").contains(condition))
        }
        capture(app, "summary62.composer.light.expanded")
        app.buttons["compose.cancel"].tap()
        XCTAssertTrue((badge.value as? String ?? "").contains("5 项筛选条件"))
    }

    func testComposerFilterKeepsOneRowInDarkLargeType() {
        let app = launch(["--qa-dark", "--qa-large-type"])
        loadFirstPreset(app)
        let title = app.staticTexts["compose.filters.title"]
        let count = app.staticTexts["compose.filters.count"]
        let common = app.buttons["compose.save-favorite"]
        for _ in 0..<4 { if common.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(title.exists && count.exists && common.isHittable)
        XCTAssertEqual(title.frame.midY, count.frame.midY, accuracy: 1)
        XCTAssertLessThanOrEqual(title.frame.maxX, count.frame.minX)
        XCTAssertTrue(common.label.contains("常用"))
        XCTAssertGreaterThanOrEqual(common.frame.height, 44)
        // Form exposes the full cell hit area; visible label alignment is checked in the retained screenshots.
        capture(app, "summary62.composer.dark.large")
    }

    func testLibraryToolbarAlignsWithCoversAndOffersExplicitMultiSelection() throws {
        let app = launch(["--qa-stored-bookmark-covers", "--qa-library-sort", "--qa-reset-library-sort"])
        let discover = app.descendants(matching: .any)["discover.header.floating"].firstMatch
        let discoverFirstRow = app.buttons["discover.search-entry"]
        let discoverSecondRow = app.buttons["discover.saved-menu"]
        let discoverCard = app.buttons["gallery.open.1"]
        XCTAssertTrue(discoverCard.waitForExistence(timeout: 6))
        let discoverFrame = discover.frame
        // The accessibility frame includes the hit targets that extend beyond the drawn panel.
        let panelOverhang: CGFloat = 4
        let firstTab = app.buttons["main.tab.discover"].frame
        let lastTab = app.buttons["main.tab.account"].frame
        XCTAssertEqual(firstTab.height, 44, accuracy: 0.75)
        XCTAssertEqual(firstTab.minX - discoverFrame.minX, 4, accuracy: 0.75)
        XCTAssertEqual(discoverFrame.maxX - lastTab.maxX, 4, accuracy: 0.75)
        let historyShortcut = app.buttons["discover.history"]
        XCTAssertEqual(historyShortcut.frame.minX, discoverSecondRow.frame.minX, accuracy: 0.75)
        XCTAssertEqual(historyShortcut.frame.width, discoverSecondRow.frame.width, accuracy: 0.75)
        let discoverFirstRowFrame = discoverFirstRow.frame
        let discoverSecondRowFrame = discoverSecondRow.frame
        let lane = app.descendants(matching: .any)["discover.lane"].firstMatch
        let latest = app.buttons["discover.lane.0"], popular = app.buttons["discover.lane.1"]
        XCTAssertEqual(latest.frame.width, popular.frame.width, accuracy: 0.75)
        XCTAssertEqual(discoverSecondRowFrame.minX - lane.frame.maxX, 4, accuracy: 1)
        XCTAssertEqual(lane.frame.width, 3 * discoverSecondRowFrame.width + 8, accuracy: 1)
        let discoverGap = discoverCard.frame.minY - discoverFrame.maxY + panelOverhang
        XCTAssertEqual(app.buttons["gallery.open.2"].frame.minX - discoverCard.frame.maxX, discoverGap, accuracy: 0.75)
        capture(app, "feed-alignment.discover")
        app.buttons["main.tab.library"].tap()
        let local = app.descendants(matching: .any)["library.header.floating"].firstMatch
        let choose = app.buttons["read-later.select"], sort = app.buttons["library.sort.bookmarks"]
        XCTAssertTrue(choose.waitForExistence(timeout: 5)); XCTAssertTrue(sort.isHittable)
        XCTAssertEqual(choose.frame.midY, sort.frame.midY, accuracy: 1)
        XCTAssertEqual(local.frame.height, 88, accuracy: 0.75)
        assertContentWidth(app, header: local, leading: app.buttons["favorites.gallery.7201"], trailing: app.buttons["favorites.gallery.7204"])
        let libraryHeaderFrame = local.frame
        let readLater = app.buttons["favorites.gallery.7201"]
        let topGap = readLater.frame.minY - libraryHeaderFrame.maxY + panelOverhang
        XCTAssertEqual(topGap, 8, accuracy: 0.75)
        XCTAssertEqual(discoverGap, topGap, accuracy: 0.75)
        XCTAssertEqual(app.buttons["favorites.gallery.7204"].frame.minX - readLater.frame.maxX, topGap, accuracy: 0.75)
        let otherCards = [7202, 7203, 7204].map { app.buttons["favorites.gallery.\($0)"].frame }
        let nextInColumn = try XCTUnwrap(otherCards
            .filter { abs($0.minX - readLater.frame.minX) < 1 && $0.minY > readLater.frame.minY }
            .min { $0.minY < $1.minY })
        XCTAssertEqual(nextInColumn.minY - readLater.frame.maxY, topGap, accuracy: 0.75)
        XCTAssertEqual(libraryHeaderFrame.minX, discoverFrame.minX, accuracy: 0.75)
        XCTAssertEqual(libraryHeaderFrame.minY, discoverFrame.minY, accuracy: 0.75)
        XCTAssertEqual(libraryHeaderFrame.width, discoverFrame.width, accuracy: 0.75)
        XCTAssertEqual(libraryHeaderFrame.height, discoverFrame.height, accuracy: 0.75)
        let libraryFirstRow = app.buttons["library.scope.0"]
        XCTAssertEqual(libraryFirstRow.frame.midY, discoverFirstRowFrame.midY, accuracy: 0.75)
        XCTAssertEqual(libraryFirstRow.frame.height, discoverFirstRowFrame.height, accuracy: 0.75)
        XCTAssertEqual(choose.frame.midY, discoverSecondRowFrame.midY, accuracy: 0.75)
        XCTAssertEqual(choose.frame.height, discoverSecondRowFrame.height, accuracy: 0.75)
        XCTAssertEqual(choose.frame.maxX, discoverSecondRowFrame.maxX, accuracy: 0.75)
        let localCount = app.descendants(matching: .any)["library.count.bookmarks"].firstMatch
        XCTAssertEqual(localCount.label, "已保存 4 个作品")
        let countFrame = localCount.frame
        XCTAssertEqual(sort.frame.minX - countFrame.maxX, 4, accuracy: 1)
        XCTAssertEqual(choose.frame.minX - sort.frame.maxX, 4, accuracy: 1)
        XCTAssertEqual(sort.frame.width, choose.frame.width, accuracy: 1)
        XCTAssertEqual(countFrame.width, 2 * choose.frame.width + 4, accuracy: 1)
        let sortColumnWidth = sort.frame.width
        capture(app, "compact42.library.read-later")
        choose.tap()
        XCTAssertTrue(app.buttons["read-later.exit"].waitForExistence(timeout: 5))
        app.buttons["read-later.exit"].tap()
        if app.buttons["library.scope.menu"].exists { app.buttons["library.scope.menu"].tap() }
        app.buttons["library.scope.1"].tap()
        let group = app.buttons["favorites.group-filter"], select = app.buttons["favorites.select"]
        XCTAssertTrue(group.waitForExistence(timeout: 5)); XCTAssertTrue(select.isHittable && select.isEnabled)
        let favorites = app.descendants(matching: .any)["favorites.header.floating"].firstMatch
        assertContentWidth(app, header: favorites, leading: app.buttons["favorites.gallery.1"], trailing: app.buttons["favorites.gallery.2"])
        XCTAssertEqual(favorites.frame.height, libraryHeaderFrame.height, accuracy: 1)
        XCTAssertEqual(app.buttons["favorites.gallery.1"].frame.minY - favorites.frame.maxY + panelOverhang,
                       topGap, accuracy: 0.75)
        XCTAssertEqual(app.buttons["favorites.gallery.2"].frame.minX - app.buttons["favorites.gallery.1"].frame.maxX,
                       topGap, accuracy: 0.75)
        XCTAssertEqual(group.frame.minX, favorites.frame.minX + 4, accuracy: 1)
        XCTAssertEqual(select.frame.maxX, favorites.frame.maxX - 4, accuracy: 1)
        XCTAssertEqual(group.frame.midY, select.frame.midY, accuracy: 1)
        XCTAssertEqual(select.frame.height, app.buttons["library.scope.1"].frame.height, accuracy: 1)
        XCTAssertGreaterThanOrEqual(select.frame.height + 0.01, 44)
        let favoriteSort = app.buttons["favorites.sort"]
        XCTAssertEqual(favoriteSort.frame.minX - group.frame.maxX, 4, accuracy: 1)
        XCTAssertEqual(select.frame.minX - favoriteSort.frame.maxX, 4, accuracy: 1)
        XCTAssertEqual(select.frame.width, discoverSecondRowFrame.width, accuracy: 1)
        XCTAssertEqual(favoriteSort.frame.width, select.frame.width, accuracy: 1)
        XCTAssertEqual(group.frame.width, 2 * select.frame.width + 4, accuracy: 1)
        for (control, column) in [(favoriteSort, 2), (select, 3)] {
            let tab = app.buttons["library.scope.\(column)"]
            XCTAssertEqual(control.frame.midX, tab.frame.midX, accuracy: 1)
        }
        XCTAssertLessThanOrEqual(group.frame.maxX, select.frame.minX)
        XCTAssertLessThan(app.descendants(matching: .any)["favorites.header.floating"].firstMatch.frame.height, 100)
        capture(app, "compact42.library.site-favorites")
        select.tap()
        let count = app.staticTexts["favorites.selection-count"]
        XCTAssertEqual(count.label, "已选 0 项")
        let card = app.buttons["favorites.select.1"]
        XCTAssertTrue(card.waitForExistence(timeout: 5)); card.tap()
        XCTAssertEqual(count.label, "已选 1 项")
        XCTAssertTrue(app.buttons["favorites.manage"].isEnabled)
        app.buttons["favorites.edit"].tap()
        XCTAssertEqual(group.value as? String, "全部分组")
        app.buttons["library.scope.2"].tap()
        let history = app.descendants(matching: .any)["reading-history.header.floating"].firstMatch
        let historyRow = app.buttons["reading-history.item.7203"]
        assertContentWidth(app, header: history, leading: historyRow, trailing: historyRow)
        XCTAssertEqual(history.frame.height, libraryHeaderFrame.height, accuracy: 1)
        XCTAssertEqual(history.frame.minY, libraryHeaderFrame.minY, accuracy: 1)
        XCTAssertEqual(historyRow.frame.minY - history.frame.maxY + panelOverhang, topGap, accuracy: 0.75)
        let historySort = app.buttons["reading-history.sort"]
        let historyCount = app.descendants(matching: .any)["reading-history.count"].firstMatch
        XCTAssertEqual(historyCount.label, "3 条阅读记录")
        XCTAssertTrue((historyCount.value as? String)?.hasPrefix("最近阅读 ") == true)
        XCTAssertEqual(historyCount.frame.height, historySort.frame.height, accuracy: 1)
        XCTAssertEqual(historySort.frame.width, sortColumnWidth, accuracy: 1)
        XCTAssertEqual(historySort.frame.minX - historyCount.frame.maxX, 4, accuracy: 1)
        capture(app, "feed-alignment.history")

        app.buttons["library.scope.3"].tap()
        let download = app.buttons["library.download.item.7204"]
        assertContentWidth(app, header: local, leading: download, trailing: download)
        XCTAssertEqual(local.frame.height, libraryHeaderFrame.height, accuracy: 1)
        XCTAssertEqual(local.frame.minY, libraryHeaderFrame.minY, accuracy: 1)
        XCTAssertEqual(download.frame.minY - local.frame.maxY + panelOverhang, topGap, accuracy: 0.75)
        let help = app.buttons["downloads.help"], downloadSort = app.buttons["library.sort.downloads"]
        let downloadCount = app.descendants(matching: .any)["library.count.downloads"].firstMatch
        XCTAssertEqual(app.buttons["library.scope.3"].label, "离线下载")
        XCTAssertEqual(downloadSort.frame.minX - downloadCount.frame.maxX, 4, accuracy: 1)
        XCTAssertEqual(help.frame.minX - downloadSort.frame.maxX, 4, accuracy: 1)
        XCTAssertEqual(downloadCount.label, "4 项 · 0 项已下载")
        XCTAssertEqual(downloadSort.frame.width, sortColumnWidth, accuracy: 1)
        XCTAssertEqual(help.frame.width, sortColumnWidth, accuracy: 1)
        XCTAssertEqual(downloadCount.frame.width, 2 * sortColumnWidth + 4, accuracy: 1)
        capture(app, "feed-alignment.downloads")
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
        let selectedTitle = app.staticTexts["detail.title"]
        XCTAssertEqual(selectedTitle.frame.minX - app.buttons["detail.tags.cancel"].frame.maxX, 4, accuracy: 1)
        XCTAssertEqual(app.buttons["detail.tags.more"].frame.minX - selectedTitle.frame.maxX, 4, accuracy: 1)
        for id in ["detail.tags.cancel", "detail.tags.more", "detail.tags.search-menu"] {
            XCTAssertEqual(app.buttons[id].frame.width, 44, accuracy: 1)
            XCTAssertEqual(app.buttons[id].frame.midY, selectedTitle.frame.midY, accuracy: 1)
        }
        capture(app, "detail-framed-title")
        XCTAssertEqual(tag.value as? String, "已选中")
        app.buttons["detail.tags.search-menu"].tap()
        app.buttons["detail.tags.new-search"].tap()
        XCTAssertTrue(app.searchComposerTitle("新建搜索").waitForExistence(timeout: 5))
        app.buttons["compose.apply"].tap()
        let summary = app.buttons["discover.condition-summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        XCTAssertTrue((summary.value as? String)?.contains("language:chinese") == true)
    }
}
