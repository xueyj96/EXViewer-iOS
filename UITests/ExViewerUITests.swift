import XCTest
import UIKit

final class ExViewerUITests: XCTestCase {
    private func launch(_ screen: String = "browse", extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication(); app.launchArguments = ["--qa", "--qa-reset-reader-preferences", "--screen", screen] + extraArguments; app.launch(); return app
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func field(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.textFields[id].exists ? app.textFields[id] : app.textViews[id]
    }
    private func openComposer(_ app: XCUIApplication) -> XCUIElement {
        let entry = app.buttons["discover.search-entry"]
        XCTAssertTrue(entry.waitForExistence(timeout: 12)); entry.tap()
        XCTAssertTrue(app.searchComposerTitle("搜索").waitForExistence(timeout: 5))
        return field(app, "compose.text")
    }
    private func submit(_ app: XCUIApplication, text: String) {
        let input = openComposer(app); input.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        if let current = input.value as? String, current != input.placeholderValue, !current.isEmpty {
            input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        input.typeText(text); app.buttons["compose.apply"].tap()
        XCTAssertTrue(app.buttons["discover.search-entry"].waitForExistence(timeout: 6))
        XCTAssertFalse(app.searchComposerTitle("搜索").exists)
    }
    private func readThroughDetails(_ app: XCUIApplication) {
        let title = app.staticTexts["海岸线 · 插画与速写"]
        XCTAssertTrue(title.waitForExistence(timeout: 12)); title.tap()
        app.buttons["在线阅读"].tap()
        XCTAssertTrue(app.buttons["reader.page"].waitForExistence(timeout: 12))
    }
    func testGalleryNavigationAndTags() {
        let app = launch()
        let title = app.staticTexts["海岸线 · 插画与速写"]
        XCTAssertTrue(title.waitForExistence(timeout: 15)); capture(app, "Native gallery list")
        title.tap()
        XCTAssertTrue(app.staticTexts["画廊详情"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["full color"].exists)
        capture(app, "Gallery details and real tag layout")
    }
    func testDiscoveryCombinesBrowsingAndTagSearch() {
        let app = launch()
        XCTAssertTrue(app.buttons["discover.search-entry"].waitForExistence(timeout: 15))
        let compactTabs = app.descendants(matching: .any)["main.tabs.compact"].firstMatch
        XCTAssertTrue(compactTabs.waitForExistence(timeout: 15))
        XCTAssertEqual(compactTabs.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "main.tab.")).count, 3)
        app.segmentedControls.buttons["热门"].tap()
        app.staticTexts["海岸线 · 插画与速写"].tap()
        app.buttons["full color"].tap()
        XCTAssertTrue(app.buttons["包含 · other:full color  ×"].waitForExistence(timeout: 6))
        XCTAssertFalse(app.staticTexts["画廊详情"].exists)
        app.buttons["discover.back"].tap()
        XCTAssertTrue(app.segmentedControls.buttons["热门"].isSelected)
        capture(app, "Detail tag replaces discovery and returns to previous feed")
    }

    func testAnimationMovesWithoutChangingPageNumber() {
        let app = launch(); readThroughDetails(app)
        let image = app.otherElements["media.animated"].firstMatch
        XCTAssertTrue(image.waitForExistence(timeout: 12))
        let initial = image.value as? String
        let moved = NSPredicate { _, _ in (image.value as? String) != initial }
        expectation(for: moved, evaluatedWith: image); waitForExpectations(timeout: 4)
        XCTAssertEqual(app.buttons["reader.page"].label, "1 / 3")
        ReaderSettingsUIHelpers.setDirection("topToBottom", in: app)
        app.swipeUp()
        let changed = NSPredicate { _, _ in app.buttons["reader.page"].label != "1 / 3" }
        expectation(for: changed, evaluatedWith: app.buttons["reader.page"]); waitForExpectations(timeout: 6)
        capture(app, "Animated file is one page through real reading entry")
    }

    func testSaveAndReuseSearchCombination() {
        continueAfterFailure = false
        let app = launch()
        let input = openComposer(app)
        input.tap(); input.typeText("Landscape")
        let saveAction = app.buttons["compose.save-favorite"]
        let saveName = app.textFields["search.save.name"]
        let confirm = app.buttons["search.save.confirm"]
        let common = app.buttons["discover.saved-menu"]
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "search-favorites.load."))

        saveAction.tap()
        XCTAssertTrue(saveName.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(saveName.waitForNonExistence(timeout: 5))
        XCTAssertEqual(saveAction.value as? String, "已保存")
        app.buttons["compose.cancel"].tap()
        common.tap()
        let original = rows.matching(NSPredicate(format: "label CONTAINS %@", "Landscape")).firstMatch
        XCTAssertTrue(original.waitForExistence(timeout: 5))
        let originalID = original.identifier
        original.tap()
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertEqual(input.value as? String, "Landscape")
        XCTAssertFalse(app.descendants(matching: .any)["compose.loaded-state"].firstMatch.exists)

        input.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        input.typeText(" edited")
        XCTAssertEqual(saveAction.label, "存为常用")
        saveAction.tap()
        XCTAssertTrue(app.staticTexts["保存搜索组合"].waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(saveName.waitForNonExistence(timeout: 5))
        app.buttons["compose.cancel"].tap()
        common.tap()
        XCTAssertTrue(app.buttons[originalID].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons[originalID].label.contains("edited"))
        XCTAssertTrue(rows.matching(NSPredicate(format: "label CONTAINS %@", "Landscape edited")).firstMatch.exists)
    }

    func testTagBlockAndUndoAffectsNativeList() {
        let app = launch()
        let title = app.staticTexts["海岸线 · 插画与速写"]
        XCTAssertTrue(title.waitForExistence(timeout: 15)); title.tap()
        app.buttons["在线阅读"].tap()
        XCTAssertTrue(app.otherElements["media.animated"].firstMatch.waitForExistence(timeout: 10))
        app.buttons["关闭"].tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["main.tab.library"].tap()
        app.segmentedControls["library.scope"].buttons["本机内容"].tap()
        XCTAssertTrue(app.staticTexts["海岸线 · 插画与速写"].waitForExistence(timeout: 5))
        app.buttons["main.tab.account"].tap()
        let tagSettings = app.buttons["account.tags"]
        XCTAssertTrue(tagSettings.waitForExistence(timeout: 5)); tagSettings.tap()
        let scope = app.buttons["tags.scope.1"]
        XCTAssertTrue(scope.waitForExistence(timeout: 15)); scope.tap()
        app.buttons["tags.add"].tap()
        let tag = app.textFields["tag.name"]
        XCTAssertTrue(tag.waitForExistence(timeout: 5)); tag.tap(); tag.typeText("full color")
        // The composer now starts in all namespaces. Choose the real local
        // dictionary candidate instead of relying on the old implicit "other".
        let candidate = app.buttons["tag.suggestion.other:full color"]
        XCTAssertTrue(candidate.waitForExistence(timeout: 8)); candidate.tap()
        app.buttons["tag.confirm"].tap()
        app.buttons["main.tab.discover"].tap()
        let hidden = app.staticTexts["当前结果已被本机标签屏蔽。可到账号的「标签与屏蔽」调整。"]
        XCTAssertTrue(hidden.waitForExistence(timeout: 5))
        app.buttons["main.tab.library"].tap()
        app.segmentedControls["library.scope"].buttons["本机内容"].tap()
        XCTAssertFalse(app.staticTexts["海岸线 · 插画与速写"].exists)
        app.buttons["main.tab.account"].tap()
        app.buttons["撤销"].tap()
        app.buttons["main.tab.discover"].tap()
        XCTAssertTrue(app.staticTexts["海岸线 · 插画与速写"].waitForExistence(timeout: 5))
    }
    func testAccountSeparatesSessionAndEXVerification() {
        let app = launch("account", extraArguments: ["--qa-account-status-preview"])
        XCTAssertTrue(app.buttons["account.login-management"].waitForExistence(timeout: 15))
        let accountTitle = app.staticTexts["站点账号"]
        let login = app.buttons["登录"]
        XCTAssertTrue(accountTitle.exists && login.exists)
        XCTAssertEqual(accountTitle.frame.midY, login.frame.midY, accuracy: 1)
        capture(app, "Compact account and separate site states")
        app.buttons["account.login-management"].tap()
        XCTAssertTrue(app.buttons["重新登录"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["验证当前会话"].exists)
        XCTAssertFalse(app.buttons["account.ex-web"].exists)
        let eh = app.staticTexts["E-Hentai"]
        let ex = app.staticTexts["ExHentai"]
        let failed = app.staticTexts["连接失败"]
        let available = app.staticTexts["EX 画廊可访问"]
        for item in [eh, ex, failed, available] { XCTAssertTrue(item.exists) }
        XCTAssertEqual(eh.frame.minX, ex.frame.minX, accuracy: 1)
        XCTAssertEqual(failed.frame.maxX, available.frame.maxX, accuracy: 1)
        XCTAssertEqual(eh.frame.midY, failed.frame.midY, accuracy: 1)
        XCTAssertEqual(ex.frame.midY, available.frame.midY, accuracy: 1)
        capture(app, "Login management and independent EX verification")

        app.buttons["BackButton"].tap()
        let quota = app.buttons["account.quota"]
        for _ in 0..<4 { if quota.isHittable { break }; app.swipeUp() }
        quota.tap()
        XCTAssertTrue(app.staticTexts["计量方式"].waitForExistence(timeout: 5))
        capture(app, "IP quota with external settings button")
        XCTAssertTrue(app.staticTexts["暂不可读"].exists)
        let settings = app.descendants(matching: .any)["account.quota.settings"].firstMatch
        XCTAssertTrue(settings.exists)
        // A List row's accessibility frame also includes its four-point bottom gap.
        XCTAssertEqual(settings.frame.height, 40, accuracy: 1)
        let quotaRows = ["计量方式", "用量 / 上限", "重置费用"].map { app.staticTexts[$0] }
        for (upper, lower) in zip(quotaRows, quotaRows.dropFirst()) {
            XCTAssertEqual(lower.frame.midY - upper.frame.midY, 36, accuracy: 1)
        }
        XCTAssertEqual(settings.frame.midY - quotaRows[2].frame.midY, 42, accuracy: 2)

        app.buttons["BackButton"].tap()
        let storage = app.buttons["account.storage"]
        for _ in 0..<4 { if storage.isHittable { break }; app.swipeUp() }
        storage.tap()
        let cacheLimit = app.staticTexts["浏览缓存上限"]
        for _ in 0..<4 { if cacheLimit.isHittable { break }; app.swipeUp() }
        let clearCache = app.buttons["清理浏览缓存"]
        XCTAssertTrue(cacheLimit.exists && clearCache.isHittable)
        XCTAssertFalse(app.staticTexts["按设备可用空间保存"].exists)
        capture(app, "Storage counters and aligned clear cache action")
    }
    func testSiteFavoritesAndManualStoragePolicy() {
        let app = launch()
        app.buttons["main.tab.library"].tap()
        XCTAssertTrue(app.segmentedControls["library.scope"].buttons["站点收藏"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["海岸线 · 插画与速写"].exists)
        app.segmentedControls["library.scope"].buttons["本机内容"].tap()
        XCTAssertTrue(app.staticTexts["按设备可用空间保存，切到后台会暂停；下载内容不参与浏览缓存清理。"].waitForExistence(timeout: 5))
        capture(app, "Durable manual downloads outside browse cache")
    }
    func testWebViewSrcdocAndJavaScriptCompatibility() {
        let app = launch("web-compat")
        XCTAssertTrue(app.staticTexts["子页面兼容检查通过"].waitForExistence(timeout: 15))
        capture(app, "Local srcdoc frame and JavaScript compatibility")
    }
    func testFavoritesMultiSelectRequiresExplicitConfirmation() {
        let app = launch()
        app.buttons["main.tab.library"].tap()
        app.buttons["library.scope.1"].tap()
        let first = app.buttons["favorites.gallery.1"]
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        first.press(forDuration: 0.8)
        XCTAssertTrue(app.batchSelection("已选 1 项").waitForExistence(timeout: 5))
        app.buttons["favorites.select.2"].tap()
        XCTAssertTrue(app.batchSelection("已选 2 项").exists)
        app.buttons["favorites.manage"].tap()
        app.buttons["favorites.remove"].tap()
        XCTAssertTrue(app.buttons["移除所选收藏"].waitForExistence(timeout: 5))
        app.buttons["取消"].tap()
        XCTAssertTrue(app.batchSelection("已选 2 项").exists)
        app.buttons["favorites.move"].tap()
        let group = app.buttons["favorites.move-to.0"]
        XCTAssertTrue(group.waitForExistence(timeout: 5)); group.tap()
        app.buttons["favorites.confirm-move"].tap()
        XCTAssertTrue(app.staticTexts["测试模式仅检查多选交互，未修改站点收藏。"].waitForExistence(timeout: 5))
        capture(app, "Favorites selection and explicit batch confirmation")
    }
    func testFeedLoadsNextBatchWhenScrollingDown() {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--qa", "--qa-feed-paging", "--qa-reset-reader-preferences"]; app.launch()
        XCTAssertTrue(app.buttons["discover.search-entry"].waitForExistence(timeout: 12))
        // Different feeds intentionally reuse the same fixture title. Bind to
        // each active feed's gallery control instead of a cached hidden label.
        func continueByScrolling(_ next: XCUIElement) {
            XCTAssertFalse(next.exists, "The app must not traverse unseen pages before scrolling")
            for _ in 0..<6 { if next.isHittable { break }; app.swipeUp() }
            XCTAssertTrue(next.waitForExistence(timeout: 5))
            XCTAssertTrue(next.isHittable)
        }
        continueByScrolling(app.scrollViews["discover.feed"].buttons["gallery.open.101"])
        capture(app, "Discovery appends after actual downward browsing")
        submit(app, text: "Neutral query")
        let searchEntry = app.buttons["discover.search-entry"]
        let applied = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "Neutral query"),
                                                  object: searchEntry)
        XCTAssertEqual(XCTWaiter.wait(for: [applied], timeout: 5), .completed)
        let firstSearchResult = app.scrollViews["discover.feed"].buttons["gallery.open.1"]
        expectation(for: NSPredicate { _, _ in firstSearchResult.isHittable }, evaluatedWith: nil)
        waitForExpectations(timeout: 5)
        continueByScrolling(app.scrollViews["discover.feed"].buttons["gallery.open.101"])
        capture(app, "Search results append in the same feed")
        app.buttons["main.tab.library"].tap()
        app.buttons["library.scope.1"].tap()
        XCTAssertTrue(app.buttons["favorites.gallery.1"].waitForExistence(timeout: 10))
        continueByScrolling(app.buttons["favorites.gallery.101"])
        capture(app, "Favorites append after actual downward browsing")
    }
    func testInlineTagsBecomeSearchConditions() {
        let app = launch()
        submit(app, text: "title:Autumn language:chinese -other:city")
        XCTAssertTrue(app.buttons["包含 · language:chinese  ×"].exists)
        XCTAssertTrue(app.buttons["排除 · other:city  ×"].exists)
        let input = openComposer(app)
        XCTAssertEqual(input.value as? String, "Autumn")
        XCTAssertEqual(app.switches["仅搜标题"].value as? String, "1")
        app.buttons["compose.cancel"].tap()
        capture(app, "Inline syntax remains compatible in combination input")
    }

    func testQuotaAndSponsorshipUseNativePages() {
        assertAccountSubpages(orientation: .portrait)
    }

    func testAccountSubpagesAlignInLandscape() {
        assertAccountSubpages(orientation: .landscapeLeft)
    }

    private func assertAccountSubpages(orientation: UIDeviceOrientation) {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = orientation
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = launch("account")
        let accountHeader = app.descendants(matching: .any)["account.header"].firstMatch
        XCTAssertTrue(accountHeader.waitForExistence(timeout: 6))
        let settled = NSPredicate { _, _ in (app.frame.width > app.frame.height) == orientation.isLandscape }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: settled, object: nil)], timeout: 6), .completed)
        let accountFrame = accountHeader.frame
        for page in ["login-management": "login-page", "tags": "tags-page", "favorite-sync": "favorite-sync-page",
                     "storage": "storage-page", "quota": "quota-page", "sponsorship": "sponsorship-page"]
            .sorted(by: { $0.key < $1.key }) {
            let link = app.buttons["account.\(page.key)"]
            let lowerEdge = app.buttons["main.tab.account"].frame.minY
            for _ in 0..<8 {
                if link.isHittable && link.frame.midY > accountHeader.frame.maxY + 4 &&
                    link.frame.midY < lowerEdge - 4 { break }
                if link.frame.midY < accountHeader.frame.maxY { app.swipeDown(velocity: .slow) }
                else { app.swipeUp(velocity: .slow) }
            }
            XCTAssertTrue(link.isHittable)
            XCTAssertGreaterThan(link.frame.midY, accountHeader.frame.maxY)
            XCTAssertLessThan(link.frame.midY, lowerEdge)
            if orientation.isLandscape && page.key == "tags" {
                capture(app, "account-landscape-tags-before")
                link.coordinate(withNormalizedOffset: CGVector(dx: 0.18, dy: 0.5)).tap()
            } else {
                link.tap()
            }
            let header = app.descendants(matching: .any)["account.\(page.value).header"].firstMatch
            let title = app.staticTexts["account.\(page.value).title"]
            let opened = title.waitForExistence(timeout: 5)
            if !opened { capture(app, "account-\(page.key)-route-failure") }
            XCTAssertTrue(opened)
            XCTAssertEqual(header.frame.minX, accountFrame.minX, accuracy: 1)
            XCTAssertEqual(header.frame.maxX, accountFrame.maxX, accuracy: 1)
            XCTAssertEqual(title.frame.midX, header.frame.midX, accuracy: 1)
            let back = header.buttons["BackButton"]
            let action = header.buttons[page.key == "tags" ? "tags.add" : "account.\(page.value).action"]
            XCTAssertTrue(action.exists)
            XCTAssertEqual(action.frame.midY, back.frame.midY, accuracy: 1)
            XCTAssertEqual(action.frame.width, back.frame.width, accuracy: 1)
            XCTAssertEqual(action.frame.minX - title.frame.maxX, 4, accuracy: 1)
            XCTAssertEqual(title.frame.minX - back.frame.maxX, 4, accuracy: 1)
            if page.key == "storage", orientation.isLandscape {
                let prefetch = app.sliders["account.loading.prefetch"]
                let imageConcurrency = app.sliders["account.loading.concurrency"]
                let siteConcurrency = app.sliders["account.loading.site-concurrency"]
                let download = app.sliders["account.loading.download-concurrency"]
                let bottomBarTop = app.buttons["main.tab.account"].frame.minY
                for slider in [prefetch, imageConcurrency, siteConcurrency, download] {
                    XCTAssertTrue(slider.isHittable)
                    XCTAssertGreaterThanOrEqual(slider.frame.height, 44)
                    XCTAssertLessThanOrEqual(slider.frame.maxY, bottomBarTop)
                }
                XCTAssertEqual(prefetch.frame.midY, imageConcurrency.frame.midY, accuracy: 1)
                XCTAssertEqual(siteConcurrency.frame.midY, download.frame.midY, accuracy: 1)
            }
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "account-\(orientation.isLandscape ? "landscape" : "portrait")-\(page.key)"
            shot.lifetime = .keepAlways
            add(shot)
            header.buttons["BackButton"].tap()
            XCTAssertTrue(accountHeader.waitForExistence(timeout: 5))
        }
        let quota = app.buttons["account.quota"]
        for _ in 0..<4 { if quota.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(app.staticTexts["尚未取得当前额度"].exists)
        capture(app, "Account quota and sponsorship rows")
        quota.tap()
        XCTAssertTrue(app.staticTexts["看图额度"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.webViews.count, 0)
        app.buttons["BackButton"].tap()
        let sponsorship = app.buttons["account.sponsorship"]
        for _ in 0..<4 { if sponsorship.isHittable { break }; app.swipeUp() }
        sponsorship.tap()
        XCTAssertTrue(app.staticTexts["赞助与权益"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.webViews.count, 0)
        capture(app, "Native account quota and sponsorship pages")
    }
    func testLandscapeCoverUsesItsOwnAspectRatio() {
        let app = launch()
        let portrait = app.descendants(matching: .any)["gallery.cover.1"].firstMatch
        let landscape = app.descendants(matching: .any)["gallery.cover.2"].firstMatch
        XCTAssertTrue(portrait.waitForExistence(timeout: 10)); XCTAssertTrue(landscape.exists)
        let differentHeights = NSPredicate { _, _ in portrait.frame.height > landscape.frame.height * 1.5 }
        expectation(for: differentHeights, evaluatedWith: portrait); waitForExpectations(timeout: 5)
        capture(app, "Landscape and portrait covers retain natural aspect ratios")
    }
    func testComposerCancellationAndCompactCategoryGrid() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--qa", "--qa-search-sort", "--qa-tags-offline"]
        app.launch()
        XCTAssertFalse(app.staticTexts["保存的组合会显示在这里"].exists)
        let input = openComposer(app); input.tap(); input.typeText("Cancelled draft")
        app.buttons["compose.filters"].tap()
        let first = app.buttons["compose.category.2"], second = app.buttons["compose.category.4"]
        let all = app.buttons["compose.categories.select-all"], invert = app.buttons["compose.categories.invert"]
        for _ in 0..<5 { if first.isHittable && invert.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(first.isHittable); XCTAssertTrue(second.isHittable)
        XCTAssertLessThan(abs(first.frame.minY - second.frame.minY), 4)
        XCTAssertGreaterThan(abs(first.frame.minX - second.frame.minX), 30)
        XCTAssertEqual(first.frame.width, second.frame.width, accuracy: 1)
        XCTAssertEqual(first.frame.height, 36, accuracy: 1)
        XCTAssertEqual(all.frame.height, 36, accuracy: 1)
        XCTAssertEqual(invert.frame.height, 36, accuracy: 1)
        XCTAssertEqual(first.frame.minY - all.frame.maxY, 4, accuracy: 1)
        XCTAssertEqual(invert.frame.minX - all.frame.maxX, second.frame.minX - first.frame.maxX, accuracy: 1)
        XCTAssertFalse(all.isEnabled)
        first.tap(); second.tap()
        XCTAssertEqual(first.value as? String, "未选择"); XCTAssertEqual(second.value as? String, "未选择")
        invert.tap()
        XCTAssertEqual(first.value as? String, "已选择"); XCTAssertEqual(second.value as? String, "已选择")
        XCTAssertEqual(app.buttons["compose.category.8"].value as? String, "未选择")
        if first.frame.minY > app.frame.height * 0.5 { app.swipeUp() }
        capture(app, "Category filters aligned with select all and invert")
        invert.tap()
        XCTAssertEqual(first.value as? String, "未选择"); XCTAssertEqual(second.value as? String, "未选择")
        all.tap()
        XCTAssertFalse(all.isEnabled)
        invert.tap()
        XCTAssertTrue(app.staticTexts["compose.categories.empty"].exists)
        XCTAssertFalse(app.buttons["compose.apply"].isEnabled)
        invert.tap()
        XCTAssertFalse(all.isEnabled)
        XCTAssertTrue(app.buttons["compose.apply"].isEnabled)
        first.tap()
        app.buttons["compose.cancel"].tap()
        XCTAssertFalse(app.buttons["discover.back"].exists)
        let reopened = openComposer(app)
        XCTAssertFalse((reopened.value as? String ?? "").contains("Cancelled draft"))
        app.buttons["compose.filters"].tap()
        for _ in 0..<5 { if first.isHittable { break }; app.swipeUp() }
        XCTAssertEqual(first.value as? String, "已选择")
        first.tap(); second.tap(); invert.tap()
        app.buttons["compose.apply"].tap()
        XCTAssertTrue(app.buttons["discover.search-entry"].waitForExistence(timeout: 5))
        _ = openComposer(app); app.buttons["compose.filters"].tap()
        for _ in 0..<5 { if first.isHittable { break }; app.swipeUp() }
        XCTAssertEqual(first.value as? String, "已选择"); XCTAssertEqual(second.value as? String, "已选择")
        XCTAssertEqual(app.buttons["compose.category.8"].value as? String, "未选择")
    }
    func testCategoryControlsAndLabelsAdaptToDarkLargeType() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--qa", "--qa-search-sort", "--qa-tags-offline", "--qa-dark", "--qa-large-type"]
        app.launch()
        _ = openComposer(app); app.buttons["compose.filters"].tap()
        let first = app.buttons["compose.category.2"], second = app.buttons["compose.category.4"]
        let invert = app.buttons["compose.categories.invert"], all = app.buttons["compose.categories.select-all"]
        for _ in 0..<8 { if first.isHittable && invert.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(first.isHittable); XCTAssertTrue(invert.isHittable); XCTAssertTrue(all.exists)
        XCTAssertEqual(first.frame.minX, second.frame.minX, accuracy: 1)
        XCTAssertGreaterThan(second.frame.minY, first.frame.minY)
        XCTAssertGreaterThanOrEqual(first.frame.height, 36)
        XCTAssertGreaterThanOrEqual(invert.frame.height, 36)
        XCTAssertEqual(first.label, "Doujinshi"); XCTAssertEqual(second.label, "Manga")
        first.tap(); invert.tap()
        XCTAssertEqual(first.value as? String, "已选择"); XCTAssertEqual(second.value as? String, "未选择")
        capture(app, "Category filters in dark mode with accessibility text size")
    }
    func testMultipleSearchesReturnToPagedBrowsingAndScrollAnchor() {
        let app = XCUIApplication(); app.launchArguments = ["--qa", "--qa-feed-paging", "--qa-reset-reader-preferences"]; app.launch()
        XCTAssertTrue(app.buttons["discover.search-entry"].waitForExistence(timeout: 12))
        let secondBatch = app.staticTexts["第二批 · 山间笔记"]
        for _ in 0..<6 { if secondBatch.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(secondBatch.isHittable)
        capture(app, "Paged browsing anchor before new conditions")
        submit(app, text: "First query")
        submit(app, text: "Second query")
        app.buttons["discover.back"].tap()
        let restored = openComposer(app)
        XCTAssertEqual(restored.value as? String, "First query")
        app.buttons["compose.cancel"].tap()
        app.buttons["discover.back"].tap()
        let anchorRestored = NSPredicate { _, _ in secondBatch.isHittable }
        expectation(for: anchorRestored, evaluatedWith: secondBatch); waitForExpectations(timeout: 6)
        XCTAssertFalse(app.buttons["discover.back"].exists)
        capture(app, "Multi-level return restores paged browsing anchor")
    }
    func testCardsUseNaturalTitleHeightAndOmitMissingMetadata() {
        let app = XCUIApplication(); app.launchArguments = ["--qa", "--qa-layout-cases", "--qa-reset-reader-preferences"]; app.launch()
        let short = app.descendants(matching: .any)["gallery.title.1"].firstMatch
        let long = app.descendants(matching: .any)["gallery.title.2"].firstMatch
        let metadata = app.descendants(matching: .any)["gallery.metadata.1"].firstMatch
        XCTAssertTrue(short.waitForExistence(timeout: 12)); XCTAssertTrue(long.exists); XCTAssertTrue(metadata.exists)
        XCTAssertLessThan(short.frame.height, long.frame.height)
        XCTAssertLessThanOrEqual(metadata.frame.minY - short.frame.maxY, 14)
        for _ in 0..<4 { if app.staticTexts["缺少元数据"].isHittable { break }; app.swipeUp() }
        XCTAssertFalse(app.descendants(matching: .any)["gallery.metadata.3"].firstMatch.exists)
        capture(app, "Short and long title spacing with missing metadata")
    }
    func testGalleryDetailUsesOneCompactActionRow() {
        let app = launch()
        let title = app.staticTexts["海岸线 · 插画与速写"]
        XCTAssertTrue(title.waitForExistence(timeout: 12)); title.tap()
        let read = app.buttons["在线阅读"], favorite = app.buttons["detail.site-favorite"], more = app.buttons["detail.more"]
        XCTAssertTrue(read.waitForExistence(timeout: 8))
        XCTAssertLessThan(abs(read.frame.midY - favorite.frame.midY), 6)
        XCTAssertLessThan(abs(read.frame.midY - more.frame.midY), 6)
        XCTAssertGreaterThanOrEqual(favorite.frame.height, 44)
        XCTAssertGreaterThanOrEqual(more.frame.height, 44)
        XCTAssertTrue(app.staticTexts["作者 · preview studio"].exists)
        XCTAssertTrue(app.staticTexts["上传者 · Preview Studio"].exists)
        capture(app, "Compact detail actions and readable gallery metadata")
    }

}
