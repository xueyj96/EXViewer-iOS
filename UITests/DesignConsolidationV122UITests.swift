import XCTest

final class DesignConsolidationV122UITests: XCTestCase {
    override func tearDown() { XCUIDevice.shared.orientation = .portrait; super.tearDown() }
    private func launch(_ flags: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--qa", "--qa-dark", "--qa-reset-favorite-groups", "--qa-reset-library-sort", "--qa-tags-offline"] + flags
        app.launch(); XCTAssertTrue(app.buttons["main.tab.account"].waitForExistence(timeout: 10))
        return app
    }
    private func rotate(_ app: XCUIApplication, _ orientation: UIDeviceOrientation) {
        XCUIDevice.shared.orientation = orientation
        var previous: CGRect?
        let stable = NSPredicate { _, _ in
            let frame = app.frame
            guard (frame.width > frame.height) == orientation.isLandscape else { return false }
            defer { previous = frame }; return previous == frame
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: stable, object: app)], timeout: 8), .completed)
    }
    private func capture(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }
    private func reveal(_ element: XCUIElement, in app: XCUIApplication, limit: Int = 8) {
        for _ in 0..<limit { if element.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(element.isHittable)
    }
    func testDefaultFavoriteCaptionDoesNotOpenMenuAndOnlyValueChangesDefault() {
        let app = launch()
        app.buttons["main.tab.account"].tap()
        reveal(app.buttons["account.favorite-settings"], in: app)
        app.buttons["account.favorite-settings"].tap()
        let menu = app.buttons["favorite.settings.default"]
        XCTAssertTrue(menu.waitForExistence(timeout: 8))
        let loaded = NSPredicate(format: "enabled == true")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: loaded, object: app.buttons["favorite.settings.group.1"])], timeout: 8), .completed)
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            rotate(app, orientation)
            let caption = app.staticTexts["favorite.settings.default.title"]
            caption.tap()
            XCTAssertFalse(app.buttons["favorite.settings.default.group.1"].exists)
            XCTAssertEqual(menu.frame.height, 36, accuracy: 1)
            menu.tap()
            let option = app.buttons["favorite.settings.default.group.1"]
            XCTAssertTrue(option.waitForExistence(timeout: 5))
            XCTAssertTrue(option.isEnabled)
            capture("consolidation.favorite-menu.open")
            option.tap()
            let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "待阅读"), object: menu)
            XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed)
            capture("consolidation.favorite-menu.\(orientation.isLandscape ? "landscape" : "portrait")")
        }
    }
    func testSearchMenusHaveUnscaledCompactValuesAndKeepDraftSelections() {
        let app = launch()
        app.buttons["discover.lane.3"].tap()
        app.buttons["discover.search-entry"].tap()
        app.buttons["compose.filters"].tap()
        XCTAssertFalse(app.buttons["compose.site"].exists)
        let rating = app.buttons["compose.min-rating"]
        reveal(rating, in: app); rating.tap(); app.buttons["4 星"].firstMatch.tap()
        XCTAssertEqual(rating.value as? String, "4 星")
        XCTAssertEqual(rating.frame.height, 36, accuracy: 1)
        capture("consolidation.search-rating")
        app.buttons["compose.filters"].tap(); app.buttons["compose.filters"].tap()
        reveal(rating, in: app)
        XCTAssertEqual(rating.value as? String, "4 星")
        rating.tap(); app.buttons["不限"].firstMatch.tap()
        XCTAssertEqual(rating.value as? String, "不限")
    }
    func testTagsKeepIndependentExpandedTargetsIncludingMultilineAndShortNames() {
        let app = launch(["--qa-consolidation-tags"])
        app.buttons["gallery.open.1"].tap()
        let artist = app.buttons["detail.tag.artist:a"]
        XCTAssertTrue(artist.waitForExistence(timeout: 8))
        XCTAssertEqual(artist.frame.height, 30, accuracy: 1)
        XCTAssertGreaterThanOrEqual(artist.frame.width, 44)
        // The first/last two points lie outside the visible face but inside its target.
        artist.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: artist.frame.width / 2, dy: 1)).tap()
        XCTAssertEqual(artist.value as? String, "已选中")
        artist.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: artist.frame.width / 2, dy: artist.frame.height - 1)).tap()
        XCTAssertEqual(artist.value as? String, "未选中")
        let long = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "detail.tag.character:")).firstMatch
        XCTAssertGreaterThan(long.frame.height, 30)
        capture("consolidation.tags.multiline.portrait")
        let a = app.buttons["detail.tag.other:a"], b = app.buttons["detail.tag.other:b"]
        reveal(a, in: app)
        XCTAssertEqual(a.frame.height, 30, accuracy: 1)
        XCTAssertEqual(b.frame.minX - a.frame.maxX, 4, accuracy: 1)
        a.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: a.frame.width / 2, dy: 1)).tap()
        XCTAssertEqual(a.value as? String, "已选中"); XCTAssertEqual(b.value as? String, "未选中")
        rotate(app, .landscapeLeft)
        capture("consolidation.tags.landscape")
    }
    func testDownloadsAndTorrentUseTheCurrentStackWhileSlowVersionCheckFinishes() {
        let app = launch(["--qa-offline-layout", "--qa-download-version", "--qa-version-slow", "--qa-download-actions"])
        app.buttons["gallery.open.1"].tap()
        let options = app.buttons["detail.download"]
        reveal(options, in: app); options.tap()
        XCTAssertTrue(app.staticTexts["downloads.options.title"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["main.tab.library"].isHittable)
        XCTAssertTrue(app.buttons["downloads.update"].waitForExistence(timeout: 25), "Cancelling a parent page must not leave a shared version check idle")
        rotate(app, .landscapeLeft)
        app.buttons["downloads.torrents"].tap()
        XCTAssertTrue(app.staticTexts["torrent.title"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["main.tab.library"].isHittable)
        capture("consolidation.downloads.torrent.landscape")
        app.buttons["BackButton"].tap()
        app.buttons["downloads.options.close"].tap()
        XCTAssertTrue(app.buttons["detail.more"].waitForExistence(timeout: 8))
    }
    func testLocalListTailsHaveOneContentGapAboveTheFixedBottomBar() {
        let app = launch(["--qa-ui-tail-rows"])
        app.buttons["main.tab.library"].tap()
        for scope in [0, 2, 3] {
            app.buttons["library.scope.\(scope)"].tap()
            let scroll = scope == 2 ? app.scrollViews["reading-history"] : app.scrollViews["library.local"]
            for _ in 0..<10 { scroll.swipeUp() }
            let id = scope == 0 ? "favorites.gallery.8001" : scope == 2 ? "reading-history.item.8001" : "library.download.item.8012"
            let last = app.descendants(matching: .any)[id].firstMatch
            capture("consolidation.tail.scope\(scope)")
            let bottom = app.descendants(matching: .any)["main.tabs.compact"].firstMatch
            XCTAssertEqual(scroll.frame.maxY, bottom.frame.minY, accuracy: 2)
            if scope != 0 {
                XCTAssertTrue(last.exists)
                XCTAssertEqual(bottom.frame.minY - last.frame.maxY, 12, accuracy: 2)
            }
            // Nested lazy grid omits its last rendered cell from the AX tree.
            // Scope 0 retains a screenshot for visible tail review; do not
            // substitute the last hittable cell for its actual final item.

        }
    }
    func testReaderDetailTorrentShareReturnsToTheSamePageWithoutMainTabs() {
        let app = launch(["--qa-reader-many", "--qa-reader-transition", "--qa-reset-reader-preferences", "--qa-detail-actions", "--qa-download-actions"])
        app.buttons["gallery.open.1"].tap()
        app.buttons["detail.read"].tap()
        let page = app.buttons["reader.page"]
        XCTAssertTrue(page.waitForExistence(timeout: 8))
        ReaderSettingsUIHelpers.setMode("单页模式", in: app)
        for index in 2...3 {
            app.coordinate(withNormalizedOffset: .init(dx: 0.82, dy: 0.64)).tap()
            let advanced = NSPredicate { _, _ in page.label == "\(index) / 12" }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: advanced, object: page)], timeout: 8), .completed)
        }
        let originalPage = page.label
        app.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5)).doubleTap()
        XCTAssertTrue(app.buttons["返回阅读"].waitForExistence(timeout: 8))
        let readerDetails = app.descendants(matching: .any)["reader.details"].firstMatch
        let options = readerDetails.buttons["detail.download"]
        let tree = XCTAttachment(string: app.debugDescription); tree.name = "reader-detail-tree"; tree.lifetime = .keepAlways; add(tree)
        capture("consolidation.reader.detail")
        XCTAssertTrue(options.waitForExistence(timeout: 8))
        XCTAssertTrue(options.isEnabled)
        options.tap()
        XCTAssertTrue(app.buttons["downloads.torrents"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["main.tab.library"].isHittable)
        rotate(app, .landscapeLeft)
        app.buttons["downloads.torrents"].tap()
        let export = app.buttons["torrent.export"]
        XCTAssertTrue(export.waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["main.tab.library"].isHittable)
        capture("consolidation.reader.torrent.landscape")
        export.tap()
        let share = app.otherElements["ActivityListView"]
        XCTAssertTrue(share.waitForExistence(timeout: 8))
        app.buttons["header.closeButton"].tap()
        XCTAssertTrue(share.waitForNonExistence(timeout: 8))
        XCTAssertTrue(export.isHittable)
        app.buttons["BackButton"].tap()
        app.buttons["downloads.options.close"].tap()
        rotate(app, .portrait)
        reveal(app.buttons["返回阅读"], in: app)
        app.buttons["返回阅读"].tap()
        XCTAssertTrue(page.waitForExistence(timeout: 8))
        XCTAssertEqual(page.label, originalPage)
        XCTAssertFalse(app.buttons["main.tab.library"].isHittable)
    }

    func testManagementKeepsTheSameBottomSlotAndLandscapeViewport() {
        let app = launch(["--qa-ui-tail-rows"])
        app.buttons["main.tab.library"].tap()
        app.buttons["library.scope.3"].tap()
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            rotate(app, orientation)
            let bottom = app.descendants(matching: .any)["main.tabs.compact"].firstMatch
            let original = bottom.frame
            app.buttons["downloads.select"].tap()
            let actions = app.descendants(matching: .any)["downloads.actions"].firstMatch
            XCTAssertTrue(actions.waitForExistence(timeout: 5))
            XCTAssertEqual(actions.frame.minX, original.minX, accuracy: 1)
            XCTAssertEqual(actions.frame.minY, original.minY, accuracy: 1)
            XCTAssertEqual(actions.frame.width, original.width, accuracy: 1)
            XCTAssertEqual(actions.frame.height, original.height, accuracy: 1)
            XCTAssertEqual(app.scrollViews["library.local"].frame.maxY, actions.frame.minY, accuracy: 2)
            app.buttons["downloads.select-all"].tap()
            XCTAssertTrue(app.buttons["downloads.remove"].isEnabled)
            capture("consolidation.management.\(orientation.isLandscape ? "landscape" : "portrait")")
            app.buttons["downloads.exit"].tap()
            XCTAssertTrue(app.buttons["main.tab.library"].isHittable)
        }
    }

    func testPopulatedFavoriteSyncAndSponsorshipScreenshots() {
        let app = launch(["--qa-favorite-unknown", "--qa-sponsorship-preview"])
        app.buttons["gallery.open.1"].tap()
        let favorite = app.buttons["detail.site-favorite"]
        XCTAssertTrue(favorite.waitForExistence(timeout: 8)); favorite.tap()
        let uncertain = NSPredicate(format: "value == %@", "结果待确认")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: uncertain, object: favorite)], timeout: 8), .completed)
        app.buttons["main.tab.account"].tap()
        reveal(app.buttons["account.favorite-sync"], in: app)
        app.buttons["account.favorite-sync"].tap()
        XCTAssertTrue(app.buttons["favorite.sync.check"].waitForExistence(timeout: 8))
        capture("preview.favorite-sync.populated")
        app.buttons["BackButton"].tap()
        reveal(app.buttons["account.sponsorship"], in: app)
        app.buttons["account.sponsorship"].tap()
        XCTAssertTrue(app.staticTexts["测试权益项目"].waitForExistence(timeout: 8))
        capture("preview.sponsorship.populated")
    }

    func testTagsCanBeAddedInlineAndLocalFilterIsPreserved() {
        let app = launch()
        app.buttons["main.tab.account"].tap()
        reveal(app.buttons["account.tags"], in: app); app.buttons["account.tags"].tap()
        let input = app.textFields["tags.search"]
        let card = app.descendants(matching: .any)["tags.search-card"].firstMatch
        let action = app.buttons["tags.add"]
        XCTAssertTrue(input.waitForExistence(timeout: 8))
        XCTAssertEqual(card.frame.height, 44, accuracy: 1)
        XCTAssertFalse(action.isEnabled)
        input.tap(); input.typeText("英语\n")
        let english = app.buttons["tag.suggestion.language:english"]
        XCTAssertTrue(english.waitForExistence(timeout: 8)); english.tap()
        XCTAssertEqual(english.value as? String, "已选中")
        app.buttons["tags.add.namespace"].tap(); app.buttons["tags.add.namespace.artist"].tap()
        XCTAssertFalse(action.isEnabled)
        app.buttons["tags.add.namespace"].tap(); app.buttons["tags.add.namespace.all"].tap()
        XCTAssertTrue(english.waitForExistence(timeout: 8)); english.tap()
        XCTAssertEqual(action.label, "添加所选标签"); action.tap()
        XCTAssertEqual(english.value as? String, "已添加")
        XCTAssertEqual(card.frame.height, 44, accuracy: 1)
        let resultsCard = app.descendants(matching: .any)["tags.results"].firstMatch
        XCTAssertGreaterThan(resultsCard.frame.minY, card.frame.maxY)
        let savedEnglish = app.descendants(matching: .any)["tags.saved.language:english"].firstMatch
        XCTAssertTrue(savedEnglish.exists)
        app.buttons["tags.search.clear"].tap()
        input.tap(); input.typeText("preview\n")
        let otherCandidate = app.buttons["tag.suggestion.artist:preview"]
        XCTAssertTrue(otherCandidate.waitForExistence(timeout: 8)); otherCandidate.tap()
        XCTAssertEqual(otherCandidate.value as? String, "已选中")
        savedEnglish.tap()
        XCTAssertEqual(otherCandidate.value as? String, "未选中")
        XCTAssertEqual(action.label, "移除所选标签")
        otherCandidate.tap()
        XCTAssertEqual(savedEnglish.value as? String, "未选中")
        XCTAssertEqual(action.label, "添加所选标签")
        capture("inline.tags.mutual-selection")
        app.buttons["tags.search.clear"].tap()
        XCTAssertFalse(otherCandidate.exists)
        XCTAssertEqual(card.frame.height, 44, accuracy: 1)
        XCTAssertFalse(action.isEnabled)
        XCTAssertTrue(savedEnglish.exists)
        savedEnglish.tap(); action.tap()
        XCTAssertFalse(savedEnglish.exists)
        app.buttons["tags.scope.1"].tap()
        let scopeSettled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: app.buttons["tags.scope.1"])
        XCTAssertEqual(XCTWaiter.wait(for: [scopeSettled], timeout: 5), .completed)
        input.tap(); input.typeText("英语\n")
        XCTAssertTrue(english.waitForExistence(timeout: 8)); english.tap(); action.tap()
        XCTAssertTrue(savedEnglish.exists)
        app.buttons["tags.search.clear"].tap()
        capture("inline.tags.saved-blocked")
        XCTAssertFalse(app.buttons["tag.confirm"].exists)
        XCTAssertTrue(app.buttons["main.tab.account"].isHittable)
    }

}
