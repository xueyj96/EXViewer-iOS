import XCTest

final class LibraryFavoritesV37UITests: XCTestCase {
    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }
    private func launch(_ args: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(); app.launchArguments = ["--qa", "--qa-reset-reader-preferences"] + args
        app.launch(); XCTAssertTrue(app.buttons["main.tab.library"].waitForExistence(timeout: 12)); return app
    }
    private func detail(_ app: XCUIApplication) {
        let card = app.buttons["gallery.open.1"]; XCTAssertTrue(card.waitForExistence(timeout: 8)); card.tap()
        XCTAssertTrue(app.buttons["detail.site-favorite"].waitForExistence(timeout: 8))
    }
    private func reveal(_ app: XCUIApplication, _ element: XCUIElement) {
        for _ in 0..<6 { if element.exists && element.isHittable { return }; app.swipeUp() }
        XCTAssertTrue(element.exists && element.isHittable)
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
    private func scope(_ title: String, index: Int, app: XCUIApplication) {
        if app.buttons["library.scope.menu"].exists {
            app.buttons["library.scope.menu"].tap(); app.buttons["library.scope.\(index)"].tap()
        } else if app.buttons["library.scope.\(index)"].exists { app.buttons["library.scope.\(index)"].tap() }
        else { app.segmentedControls["library.scope"].buttons[title].tap() }
    }
    private func openGroupFilter(_ extra: [String] = []) -> XCUIApplication {
        let app = launch(["--qa-tags-offline"] + extra)
        app.buttons["main.tab.library"].tap()
        scope("站点收藏", index: 1, app: app)
        XCTAssertTrue(app.buttons["favorites.group-filter"].waitForExistence(timeout: 8))
        return app
    }
    private func chooseGroup(_ name: String, app: XCUIApplication) {
        let filter = app.buttons["favorites.group-filter"]
        filter.tap()
        let choice = app.buttons[name].firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 4)); choice.tap()
        expectation(for: NSPredicate(format: "value == %@", name), evaluatedWith: filter)
        waitForExpectations(timeout: 4)
    }
    private func assertGroupFilterBounds(_ app: XCUIApplication) {
        let filter = app.buttons["favorites.group-filter"]
        XCTAssertTrue(filter.exists && filter.isHittable)
        XCTAssertGreaterThanOrEqual(filter.frame.height + 0.000_001, 44)
        XCTAssertGreaterThanOrEqual(filter.frame.width + 0.000_001, 44)
        XCTAssertGreaterThanOrEqual(filter.frame.minX, app.frame.minX + 8)
        XCTAssertLessThanOrEqual(filter.frame.maxX, app.frame.maxX - 8)
        XCTAssertEqual(filter.label, "收藏分组")
    }
    private func rotateGroupLayout(_ orientation: UIDeviceOrientation, app: XCUIApplication) {
        XCUIDevice.shared.orientation = orientation
        var previous = CGRect.null
        var stableSince = ProcessInfo.processInfo.systemUptime
        expectation(for: NSPredicate { _, _ in
            let frame = app.buttons["favorites.group-filter"].frame
            let isLandscape = app.frame.width > app.frame.height
            guard isLandscape == orientation.isLandscape, frame != .zero else { return false }
            let now = ProcessInfo.processInfo.systemUptime
            if frame != previous { previous = frame; stableSince = now; return false }
            return now - stableSince >= 0.7
        }, evaluatedWith: app)
        waitForExpectations(timeout: 6)
    }
    func testGroupFilterOffersAllGroupsAndKeepsCompactLightLayoutInBothOrientations() {
        let app = openGroupFilter()
        let filter = app.buttons["favorites.group-filter"]
        XCTAssertEqual(filter.value as? String, "全部分组")
        filter.tap()
        for name in ["全部分组", "常用", "稍后阅读"] + (3...10).map({ "分组 \($0)" }) {
            XCTAssertTrue(app.buttons[name].firstMatch.exists, name)
        }
        app.buttons["常用"].firstMatch.tap()
        XCTAssertEqual(filter.value as? String, "常用")
        for name in ["稍后阅读", "分组 10", "全部分组"] { chooseGroup(name, app: app) }
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            rotateGroupLayout(orientation, app: app)
            assertGroupFilterBounds(app)
            XCTAssertLessThan(filter.frame.width, app.frame.width * 0.6)
            capture(app, orientation == .portrait ? "favorite-group41.light-portrait" : "favorite-group41.light-landscape")
        }
    }
    func testLongGroupNameRetainsFullAccessibilityValueInDarkLargeTypeAndBothOrientations() {
        let name = "特别长的收藏分组名称用于核对截断后的完整辅助功能内容（第二册）"
        let app = openGroupFilter(["--qa-favorite-sync-list", "--qa-favorite-group=" + name, "--qa-dark", "--qa-large-type"])
        chooseGroup(name, app: app)
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            rotateGroupLayout(orientation, app: app)
            assertGroupFilterBounds(app)
            XCTAssertEqual(app.buttons["favorites.group-filter"].value as? String, name)
            capture(app, orientation == .portrait ? "favorite-group41.dark-large-portrait" : "favorite-group41.dark-large-landscape")
        }
        chooseGroup("全部分组", app: app)
    }
    func testGroupFilterSelectionSurvivesEnteringAndExitingMultiSelection() {
        let app = openGroupFilter()
        chooseGroup("稍后阅读", app: app)
        let card = app.buttons["favorites.gallery.1"]
        XCTAssertTrue(card.waitForExistence(timeout: 5)); card.press(forDuration: 0.8)
        XCTAssertTrue(app.batchSelection("已选 1 项").waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["favorites.group-filter"].exists)
        app.buttons["favorites.edit"].tap()
        let filter = app.buttons["favorites.group-filter"]
        XCTAssertTrue(filter.waitForExistence(timeout: 5))
        XCTAssertEqual(filter.value as? String, "稍后阅读")
        assertGroupFilterBounds(app)
    }
    func testFavoriteSortFitsTheExistingHeaderAndRemembersTheChoice() {
        let app = openGroupFilter(["--qa-reset-library-sort", "--qa-dark"])
        chooseGroup("稍后阅读", app: app)
        let sort = app.buttons["favorites.sort"]
        let group = app.buttons["favorites.group-filter"]
        let select = app.buttons["favorites.select"]
        XCTAssertEqual(sort.value as? String, "跟随站点")
        XCTAssertTrue(sort.isHittable)
        XCTAssertGreaterThanOrEqual(sort.frame.height, 44)
        XCTAssertLessThanOrEqual(group.frame.maxX, sort.frame.minX)
        XCTAssertLessThanOrEqual(sort.frame.maxX, select.frame.minX)
        XCTAssertEqual(sort.frame.midY, group.frame.midY, accuracy: 1)
        let sortFrame = sort.frame
        sort.tap()
        let option = app.buttons["favorites.sort.favorited"]
        XCTAssertTrue(option.waitForExistence(timeout: 5))
        XCTAssertTrue(option.isHittable)
        let selected = app.buttons["favorites.sort.siteDefault"]
        XCTAssertTrue(selected.isSelected)
        XCTAssertGreaterThanOrEqual(selected.frame.minY, sortFrame.maxY)
        XCTAssertGreaterThanOrEqual(option.frame.height, 44)
        XCTAssertTrue(app.buttons["favorites.sort.posted"].isHittable)
        capture(app, "favorites-sort.flat-dark")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)).tap()
        XCTAssertTrue(sort.waitForExistence(timeout: 5))
        XCTAssertFalse(option.exists)
        sort.tap()
        XCTAssertTrue(option.waitForExistence(timeout: 5)); option.tap()
        expectation(for: NSPredicate(format: "value == %@", "收藏时间"), evaluatedWith: sort)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(group.value as? String, "稍后阅读")
        app.terminate()
        let reopened = openGroupFilter()
        XCTAssertEqual(reopened.buttons["favorites.sort"].value as? String, "收藏时间")
    }
    func testLoadingGroupIsCenteredInPortraitAndLandscapeWithoutChangingFormRowAlignment() {
        let app = launch(["--qa-favorite-loading"]); detail(app); app.buttons["detail.site-favorite"].tap()
        let loading = app.descendants(matching: .any)["favorite.editor.loading"].firstMatch
        XCTAssertTrue(loading.waitForExistence(timeout: 5))
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            let spinner = app.descendants(matching: .any)["favorite.editor.loading-spinner"].firstMatch
            let label = app.staticTexts["favorite.editor.loading-label"]
            XCTAssertTrue(label.waitForExistence(timeout: 3))
            XCTAssertEqual(spinner.frame.midX, label.frame.midX, accuracy: 1)
            XCTAssertEqual(label.frame.midX, app.frame.midX, accuracy: 2)
            XCTAssertEqual(spinner.frame.union(label.frame).midY, loading.frame.midY, accuracy: 2)
            capture(app, orientation == .portrait ? "library37.loading-portrait" : "library37.loading-landscape")
        }
        app.buttons["favorite.editor.cancel"].tap()
        XCTAssertTrue(app.buttons["detail.site-favorite"].exists)
    }
    func testDiscoverSelectionReadLaterAndBulkRemovalKeepHistoryDownloadsAndSiteStateSeparate() {
        let app = launch()
        let discover = app.buttons["gallery.open.1"]
        XCTAssertTrue(discover.waitForExistence(timeout: 5)); discover.press(forDuration: 0.8)
        let add = app.buttons["discover.add-read-later"]; XCTAssertTrue(add.waitForExistence(timeout: 3)); add.tap()
        XCTAssertTrue(app.staticTexts["discover.feedback"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.buttons["discover.select.1"].value as? String, "已选中")
        app.buttons["discover.exit"].tap()
        app.buttons["main.tab.library"].tap()
        let card = app.buttons["favorites.gallery.1"]; XCTAssertTrue(card.waitForExistence(timeout: 5))
        capture(app, "library37.read-later")
        card.press(forDuration: 0.8)
        XCTAssertTrue(app.buttons["read-later.remove"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.buttons["read-later.favorite"].isEnabled)
        XCTAssertTrue(app.buttons["read-later.download"].isEnabled)
        XCTAssertFalse(app.buttons["read-later.add-read-later"].exists)
        XCTAssertFalse(app.buttons["main.tab.library"].exists)
        app.buttons["read-later.select-all"].tap()
        XCTAssertFalse(app.buttons["read-later.remove"].isEnabled)
        app.buttons["read-later.select-all"].tap(); app.buttons["read-later.remove"].tap()
        app.buttons["移出所选作品"].tap()
        XCTAssertTrue(app.staticTexts["read-later.empty"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.buttons["main.tab.library"].exists)
        scope("阅读历史", index: 2, app: app); XCTAssertTrue(app.staticTexts["暂无阅读记录"].waitForExistence(timeout: 4))
        scope("下载", index: 3, app: app); XCTAssertTrue(app.descendants(matching: .any)["library.downloads"].firstMatch.waitForExistence(timeout: 4))
        scope("站点收藏", index: 1, app: app)
        XCTAssertTrue(app.buttons["favorites.group-filter"].waitForExistence(timeout: 4))
    }

    func testDiscoverBatchQueuesFavoritesAndDownloadsAndKeepsSelection() {
        let app = launch(["--qa-download-actions"])
        let first = app.buttons["gallery.open.1"]
        XCTAssertTrue(first.waitForExistence(timeout: 5)); first.press(forDuration: 0.8)
        let second = app.buttons["discover.select.2"]
        XCTAssertTrue(second.waitForExistence(timeout: 5)); second.tap()
        XCTAssertTrue(app.batchSelection("已选 2 项", source: "discover").exists)
        app.buttons["discover.favorite"].tap()
        let group = app.buttons["favorites.add-to.1"]
        XCTAssertTrue(group.waitForExistence(timeout: 5)); group.tap()
        app.buttons["favorites.confirm-add"].tap()
        let feedback = app.staticTexts["discover.feedback"]
        XCTAssertTrue(feedback.waitForExistence(timeout: 5))
        XCTAssertTrue(feedback.label.contains("已加入收藏同步队列 2 项"))
        XCTAssertTrue(app.batchSelection("已选 2 项", source: "discover").exists)
        app.buttons["discover.download"].tap()
        XCTAssertTrue(feedback.label.contains("已加入下载队列 2 项"))
        app.buttons["discover.exit"].tap()
        app.buttons["main.tab.library"].tap()
        scope("下载", index: 3, app: app)
        for id in [1, 2] {
            XCTAssertTrue(app.buttons["library.download.item.\(id)"].waitForExistence(timeout: 4))
        }
    }

    func testReadingHistoryLongPressShowsOnlyTheThreeBatchActions() {
        let app = launch(["--qa-library-sort", "--qa-reset-library-sort", "--qa-library-long-history"])
        let discoverHeader = app.descendants(matching: .any)["discover.header.floating"].firstMatch
        let headerFrame = discoverHeader.frame
        app.buttons["discover.lane.2"].tap()
        XCTAssertTrue(app.textFields["reading-history.search-field"].waitForExistence(timeout: 5))
        XCTAssertEqual(discoverHeader.frame, headerFrame)
        let mainTab = app.buttons["main.tab.discover"]
        XCTAssertTrue(mainTab.isHittable)
        let bottomFrame = mainTab.frame
        let bottomBarFrame = app.descendants(matching: .any)["main.tabs.compact"].firstMatch.frame
        capture(app, "reading-history-inline")
        let item = app.buttons["reading-history.item.7304"]
        let list = app.descendants(matching: .any)["reading-history"].firstMatch
        for _ in 0..<7 {
            if item.isHittable { break }
            list.swipeUp()
        }
        XCTAssertTrue(item.isHittable); item.press(forDuration: 0.8)
        XCTAssertTrue(app.buttons["reading-history.select.7304"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["reading-history.select.7304"].value as? String, "已选中")
        let actionBar = app.descendants(matching: .any)["reading-history.actions"].firstMatch
        XCTAssertEqual(actionBar.frame, bottomBarFrame)
        for action in ["add-read-later", "favorite", "download"] {
            XCTAssertTrue(app.buttons["reading-history.\(action)"].isEnabled)
        }
        XCTAssertFalse(app.buttons["reading-history.remove"].exists)
        app.buttons["reading-history.exit"].tap()
        XCTAssertTrue(item.waitForExistence(timeout: 4))
        item.tap()
        XCTAssertTrue(app.staticTexts["画廊详情"].waitForExistence(timeout: 5))
        XCTAssertTrue(mainTab.isHittable)
        XCTAssertEqual(mainTab.frame, bottomFrame)
        app.buttons["BackButton"].tap()
        app.buttons["discover.lane.0"].tap()
        XCTAssertTrue(app.buttons["main.tab.discover"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["main.tab.discover"].isHittable)
    }
    func testLegacyCollectionAndFourScopesWorkWithLargeTypeLandscape() {
        let app = launch(["--qa-stored-bookmark-covers", "--qa-dark", "--qa-large-type"])
        app.buttons["main.tab.library"].tap()
        XCTAssertTrue(app.buttons["favorites.gallery.1"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["favorites.gallery.2"].exists)
        capture(app, "library37.legacy-large-portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        scope("阅读历史", index: 2, app: app)
        XCTAssertTrue(app.buttons["reading-history.item.1"].waitForExistence(timeout: 5))
        capture(app, "library37.history-large-landscape")
        scope("下载", index: 3, app: app)
        scope("稍后再读", index: 0, app: app)
        XCTAssertTrue(app.buttons["favorites.gallery.1"].waitForExistence(timeout: 5))
    }
    private func readerFavorite(in app: XCUIApplication) -> XCUIElement {
        ReaderSettingsUIHelpers.open(in: app)
        let button = app.buttons["reader.settings.site-favorite"]
        XCTAssertTrue(button.isHittable)
        return button
    }

    func testReaderStarUsesSiteFavoritesWhileReadLaterRemainsIndependent() {
        let app = launch(); detail(app)
        app.buttons["detail.more"].tap(); app.buttons["detail.local-bookmark"].tap()
        app.buttons["在线阅读"].tap()
        let star = readerFavorite(in: app)
        XCTAssertEqual(app.buttons["reader.settings.read-later"].label, "移出稍后再读")
        expectation(for: NSPredicate(format: "value == %@", "未收藏"), evaluatedWith: star); waitForExpectations(timeout: 5)
        star.tap(); XCTAssertTrue(app.buttons["favorite.editor.group.5"].waitForExistence(timeout: 5))
        app.buttons["favorite.editor.group.5"].tap(); app.buttons["favorite.editor.save"].tap()
        _ = readerFavorite(in: app)
        expectation(for: NSPredicate(format: "value CONTAINS %@", "已收藏"), evaluatedWith: star); waitForExpectations(timeout: 6)
        capture(app, "library37.reader-site-star")
        ReaderSettingsUIHelpers.close(in: app)
        app.buttons["reader.close"].tap()
        let detailFavorite = app.buttons["detail.site-favorite"]
        expectation(for: NSPredicate(format: "label CONTAINS %@", "长篇"), evaluatedWith: detailFavorite); waitForExpectations(timeout: 5)
        capture(app, "library37.detail-reflects-reader-favorite")
        (app.buttons["继续阅读"].exists ? app.buttons["继续阅读"] : app.buttons["在线阅读"]).tap()
        _ = readerFavorite(in: app)
        star.tap(); let remove = app.buttons["favorite.editor.remove"]; reveal(app, remove); remove.tap()
        app.buttons["favorite.editor.confirm-remove"].firstMatch.tap()
        _ = readerFavorite(in: app)
        expectation(for: NSPredicate(format: "value == %@", "未收藏"), evaluatedWith: star); waitForExpectations(timeout: 6)
        ReaderSettingsUIHelpers.close(in: app)
        app.buttons["reader.close"].tap()
        expectation(for: NSPredicate(format: "label CONTAINS %@", "添加收藏"), evaluatedWith: detailFavorite); waitForExpectations(timeout: 5)
    }
    func testDetailCancelFavoriteHasExplicitConfirmationAndVerifiedUnfavoritedResult() {
        let app = launch(["--qa-favorite-existing"]); detail(app)
        let button = app.buttons["detail.site-favorite"]
        expectation(for: NSPredicate(format: "label CONTAINS %@", "收藏完成"), evaluatedWith: button); waitForExpectations(timeout: 5)
        let originalFrame = button.frame
        XCTAssertFalse(app.buttons["detail.cancel-favorite"].exists)
        button.tap()
        let cancel = app.buttons["favorite.editor.remove"]; XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["favorite.editor.edit"].isHittable)
        let status = app.descendants(matching: .any)["favorite.editor.status"].firstMatch
        XCTAssertTrue(status.exists)
        XCTAssertTrue(status.label.contains("已读") || (status.value as? String)?.contains("已读") == true)
        cancel.tap()
        let confirm = app.buttons["favorite.editor.confirm-remove"]; XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        capture(app, "library37.detail-remove-confirmation"); confirm.tap()
        expectation(for: NSPredicate(format: "label CONTAINS %@", "添加收藏"), evaluatedWith: button); waitForExpectations(timeout: 6)
        XCTAssertEqual(button.frame.midX, originalFrame.midX, accuracy: 1)
        XCTAssertEqual(button.frame.midY, originalFrame.midY, accuracy: 1)
    }
    func testUnauthenticatedReaderCannotAppearFavoritedOrSubmit() {
        let app = launch(["--qa-favorite-unauthenticated"]); detail(app); app.buttons["在线阅读"].tap()
        let star = readerFavorite(in: app)
        XCTAssertEqual(star.value as? String, "状态待核实"); star.tap()
        XCTAssertTrue(app.staticTexts["favorite.editor.error"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["favorite.editor.save"].isEnabled)
        XCTAssertFalse(app.buttons["favorite.editor.remove"].exists)
    }
    func testReadingAndLocalStateBindingDoNotReadFavoriteFormUntilExplicitAction() {
        let app = launch(["--qa-favorite-counters"]); detail(app); app.buttons["在线阅读"].tap()
        let star = readerFavorite(in: app)
        XCTAssertTrue((star.value as? String)?.contains("reads=0;posts=0") == true)
        ReaderSettingsUIHelpers.close(in: app)
        let slider = app.sliders["reader.progress"]
        slider.adjust(toNormalizedSliderPosition: 0.9)
        slider.adjust(toNormalizedSliderPosition: 0.1)
        _ = readerFavorite(in: app)
        XCTAssertTrue((star.value as? String)?.contains("reads=0;posts=0") == true)
        capture(app, "favorite38.reading-zero-form-requests")
        star.tap(); XCTAssertTrue(app.buttons["favorite.editor.group.0"].waitForExistence(timeout: 5))
        app.buttons["favorite.editor.cancel"].tap()
        _ = readerFavorite(in: app)
        XCTAssertTrue((star.value as? String)?.contains("reads=1;posts=0") == true)
        ReaderSettingsUIHelpers.close(in: app)
        slider.adjust(toNormalizedSliderPosition: 0.8)
        _ = readerFavorite(in: app)
        XCTAssertTrue((star.value as? String)?.contains("reads=1;posts=0") == true)
        star.tap()
        let refresh = app.buttons["favorite.editor.reload"]; reveal(app, refresh); refresh.tap()
        app.buttons["favorite.editor.cancel"].tap()
        _ = readerFavorite(in: app)
        expectation(for: NSPredicate(format: "value CONTAINS %@", "reads=2;posts=0"), evaluatedWith: star)
        waitForExpectations(timeout: 5)
        capture(app, "favorite38.only-manual-refresh-reads")
    }
}
