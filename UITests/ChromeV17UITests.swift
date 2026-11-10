import XCTest

final class ChromeV17UITests: XCTestCase {
    private func openSearchHistory(_ app: XCUIApplication) {
        let title = app.staticTexts["search-presets.title"]
        if title.exists, title.label == "搜索记录" { return }
        let close = app.buttons["search-presets.close"]
        if close.isHittable { close.tap() }
        let records = app.buttons["compose.records"]
        if !records.exists { app.buttons["discover.search-entry"].tap() }
        XCTAssertTrue(records.waitForExistence(timeout: 5))
        let headerY = app.descendants(matching: .any)["compose.header"].firstMatch.frame.minY
        records.tap()
        XCTAssertTrue(app.staticTexts["搜索记录"].waitForExistence(timeout: 5))
        let historyHeader = app.descendants(matching: .any)["search-presets.header"].firstMatch
        XCTAssertEqual(historyHeader.frame.minY, headerY, accuracy: 1)
        XCTAssertTrue(app.buttons["main.tab.discover"].isHittable)
    }

    private func openFavorites(_ app: XCUIApplication) {
        let title = app.staticTexts["常用组合"]
        if title.exists { return }
        let close = app.buttons["search-presets.close"]
        if close.isHittable { close.tap() }
        let cancel = app.buttons["compose.cancel"]
        if cancel.isHittable { cancel.tap() }
        let entry = app.buttons["discover.saved-menu"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5)); entry.tap()
        XCTAssertTrue(title.waitForExistence(timeout: 5))
    }
    private func collapseFilters(_ app: XCUIApplication) {
        setFiltersExpanded(false, in: app)
    }

    private func setFiltersExpanded(_ expanded: Bool, in app: XCUIApplication) {
        let filters = app.buttons["compose.filters"]
        let state = expanded ? "已展开" : "已收起"
        for _ in 0..<3 {
            if (filters.value as? String)?.hasPrefix(state) == true { return }
            for _ in 0..<8 { if filters.isHittable { break }; app.swipeDown() }
            XCTAssertTrue(filters.isHittable)
            filters.tap()
        }
        XCTAssertTrue((filters.value as? String)?.hasPrefix(state) == true)
    }
    private func feedback(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["compose.loaded-state"].firstMatch
    }

    private func nameFavorite(_ app: XCUIApplication, _ name: String) {
        let input = app.textFields["search.save.name"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        if let old = input.value as? String, old != input.placeholderValue {
            input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count))
        }
        input.typeText(name)
        app.buttons["search.save.confirm"].tap()
    }

    func testRecentSearchLoadsFullTagConditionsAndSavesAsCommon() {
        continueAfterFailure = false
        let app = launch()
        XCTAssertTrue(app.buttons["discover.search-entry"].waitForExistence(timeout: 12))
        submitHistorySearch(app, "coast language:english -other:city")
        app.buttons["discover.search-entry"].tap(); openSearchHistory(app)
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "search-history.load."))
        let row = rows.firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.label.contains("coast")); XCTAssertTrue(row.label.contains("language:english")); XCTAssertTrue(row.label.contains("排除"))
        XCTAssertEqual(row.label.components(separatedBy: "coast").count - 1, 1, "A record must show its condition summary only once")
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "search-history.save.")).firstMatch.tap()
        nameFavorite(app, "常用海岸")
        openFavorites(app)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "search-favorites.load.")).firstMatch.label.contains("常用海岸"))
        openSearchHistory(app); row.tap()
        XCTAssertTrue(app.searchComposerTitle("搜索").waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["compose.text"].value as? String, "coast")
        XCTAssertEqual(feedback(app).value as? String, "已载入")
        app.buttons["compose.apply"].tap()
        let summary = app.buttons["discover.search-entry"]
        XCTAssertTrue(summary.waitForExistence(timeout: 6))
        XCTAssertTrue((summary.value as? String ?? "").contains("排除 other:city"))
        app.buttons["discover.search-entry"].tap(); openSearchHistory(app)
        XCTAssertEqual(rows.count, 1, "Rerunning the same full conditions must update one record")
    }

    func testCancelDraftDoesNotCreateSearchHistory() {
        continueAfterFailure = false
        let app = launch()
        XCTAssertTrue(app.buttons["discover.search-entry"].waitForExistence(timeout: 12))
        app.buttons["discover.search-entry"].tap()
        let input = app.textFields["compose.text"]; XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap(); input.typeText("cancelled draft")
        app.buttons["compose.cancel"].tap()
        app.buttons["discover.search-entry"].tap(); openSearchHistory(app)
        XCTAssertTrue(app.staticTexts["search-history.empty"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "search-history.load.")).count, 0)
    }

    func testHistoryLoadShowsSourceAndModifiedDraftWithoutExecuting() {
        continueAfterFailure = false
        let app = launch()
        XCTAssertTrue(app.buttons["discover.search-entry"].waitForExistence(timeout: 12))
        submitHistorySearch(app, "coast language:english -other:city")
        submitHistorySearch(app, "mountain")
        let executed = app.buttons["discover.search-entry"]
        XCTAssertTrue(executed.waitForExistence(timeout: 5))
        let previousSearch = executed.value as? String
        XCTAssertTrue(previousSearch?.hasPrefix("mountain") == true)
        app.buttons["discover.search-entry"].tap(); openSearchHistory(app)
        let history = XCTAttachment(screenshot: app.screenshot())
        history.name = "search-history-full-page"; history.lifetime = .keepAlways; add(history)
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "search-history.load."))
        let coast = rows.matching(NSPredicate(format: "label CONTAINS %@", "coast")).firstMatch
        coast.tap()
        if !app.searchComposerTitle("搜索").waitForExistence(timeout: 3) {
            let failure = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            failure.name = "search-history-return-failure"; failure.lifetime = .keepAlways; add(failure)
        }
        let state = feedback(app)
        XCTAssertTrue(state.waitForExistence(timeout: 5)); XCTAssertTrue(state.isHittable)
        XCTAssertTrue(state.label.contains("从最近搜索载入")); XCTAssertEqual(state.value as? String, "已载入")
        XCTAssertFalse(app.staticTexts["compose.loaded-title"].exists, "The source must not repeat its title and description in a large panel")
        let input = app.textFields["compose.text"]
        XCTAssertEqual(input.value as? String, "coast")
        let filters = app.buttons["compose.filters"]
        XCTAssertTrue((filters.value as? String)?.contains("包含 language:english") == true)
        XCTAssertTrue((filters.value as? String)?.contains("排除 other:city") == true)
        input.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap(); input.typeText(" revised")
        XCTAssertEqual(state.value as? String, "已修改")
        XCTAssertTrue(app.searchComposerTitle("搜索").exists)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "build25.main.loaded-and-modified"; shot.lifetime = .keepAlways; add(shot)
        openSearchHistory(app); XCTAssertEqual(coast.value as? String, "已修改")
        app.buttons["search-presets.close"].tap()
        app.buttons["compose.cancel"].tap()
        XCTAssertTrue(executed.waitForExistence(timeout: 5))
        XCTAssertEqual(executed.value as? String, previousSearch, "Cancelling must retain the prior executed search")
        app.buttons["discover.search-entry"].tap()
        XCTAssertEqual(app.textFields["compose.text"].value as? String, "mountain")
    }

    func testHistoryKeepsAQuotedKeywordLiteralAfterReopeningFilters() {
        continueAfterFailure = false
        let app = launch()
        XCTAssertTrue(app.buttons["discover.search-entry"].waitForExistence(timeout: 12))
        authorComposer(app, text: #"title:"language:chinese""#)
        app.buttons["compose.apply"].tap()
        let entry = app.buttons["discover.search-entry"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        let first = entry.value as? String
        XCTAssertTrue(first?.contains("language:chinese") == true)
        XCTAssertFalse(first?.contains("包含 language:chinese") == true)

        entry.tap()
        openSearchHistory(app)
        XCTAssertTrue(app.staticTexts["点选记录载入条件，返回后再执行搜索。"].exists)
        let records = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "search-history.load."))
        XCTAssertTrue(records.firstMatch.waitForExistence(timeout: 5))
        records.firstMatch.tap()
        let status = feedback(app)
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertEqual(status.value as? String, "已载入")
        setFiltersExpanded(true, in: app)
        XCTAssertEqual(app.textFields["compose.text"].value as? String, "language:chinese")
        app.buttons["compose.apply"].tap()
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        XCTAssertEqual(entry.value as? String, first)
    }

    func testFavoriteLoadStaysDistinctFromHistoryAndKeepsOriginalUntilSaved() {
        continueAfterFailure = false
        let app = launch()
        XCTAssertTrue(app.buttons["discover.search-entry"].waitForExistence(timeout: 12))
        submitHistorySearch(app, "coast language:english -other:city")
        app.buttons["discover.search-entry"].tap(); app.buttons["compose.save-favorite"].tap()
        nameFavorite(app, "海岸收藏"); openFavorites(app)
        let common = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "search-favorites.load.")).firstMatch
        XCTAssertTrue(common.label.contains("海岸收藏")); common.tap()
        XCTAssertTrue(feedback(app).waitForExistence(timeout: 5))
        XCTAssertTrue(feedback(app).label.contains("从常用组合载入")); XCTAssertEqual(feedback(app).value as? String, "已载入")
        let input = app.textFields["compose.text"]
        input.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap(); input.typeText(" changed")
        XCTAssertEqual(feedback(app).value as? String, "已修改")
        app.buttons["compose.cancel"].tap()
        app.buttons["discover.search-entry"].tap(); openFavorites(app); common.tap()
        XCTAssertEqual(input.value as? String, "coast", "Editing must not overwrite the stored combination")
        XCTAssertEqual(feedback(app).value as? String, "已载入")
        openSearchHistory(app)
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "search-history.load.")).firstMatch.tap()
        XCTAssertTrue(feedback(app).label.contains("从最近搜索载入"))
        let records = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "search-history.load."))
        openSearchHistory(app)
        XCTAssertEqual(records.firstMatch.value as? String, "已载入")
        openFavorites(app); XCTAssertNotEqual(common.value as? String, "已载入")
        openSearchHistory(app)
        XCTAssertNotEqual(records.firstMatch.value as? String, "已载入")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "build25.records.source-distinction"; shot.lifetime = .keepAlways; add(shot)
    }

    func testAllFavoriteCombinationsRemainReachableFromRecordsPage() {
        continueAfterFailure = false
        let app = launch()
        XCTAssertTrue(app.buttons["discover.search-entry"].waitForExistence(timeout: 12))
        app.buttons["discover.search-entry"].tap()
        let input = app.textFields["compose.text"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        for index in 1...4 {
            if index > 1 { app.buttons["compose.clear"].tap() }
            input.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
            if let old = input.value as? String, old != input.placeholderValue {
                input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count))
            }
            input.typeText("preset\(index)"); app.buttons["compose.save-favorite"].tap(); nameFavorite(app, "组合\(index)")
        }
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "compose.favorite.")).count, 0, "The main page must not expand saved combinations")
        openFavorites(app)
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "search-favorites.load."))
        XCTAssertEqual(rows.count, 4)
        rows.matching(NSPredicate(format: "label CONTAINS %@", "组合4")).firstMatch.tap()
        XCTAssertTrue(feedback(app).waitForExistence(timeout: 5)); XCTAssertTrue(feedback(app).isHittable)
        XCTAssertTrue(feedback(app).label.contains("从常用组合载入")); XCTAssertEqual(input.value as? String, "preset4")
    }

    func testSaveCurrentDraftAsCommonWithoutExecutingAndClearOnlyHistory() {
        continueAfterFailure = false
        let app = launch()
        XCTAssertTrue(app.buttons["discover.search-entry"].waitForExistence(timeout: 12))
        app.buttons["discover.search-entry"].tap()
        let input = app.textFields["compose.text"]; XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap(); input.typeText("forest language:english")
        app.buttons["compose.save-favorite"].tap(); nameFavorite(app, "常用森林")
        openSearchHistory(app); XCTAssertTrue(app.staticTexts["search-history.empty"].waitForExistence(timeout: 5))
        app.buttons["search-presets.close"].tap(); app.buttons["compose.apply"].tap()
        app.buttons["discover.search-entry"].tap(); openSearchHistory(app)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "search-history.load.")).firstMatch.waitForExistence(timeout: 5))
        app.buttons["search-history.clear"].tap(); app.buttons["清空搜索记录"].tap()
        XCTAssertTrue(app.staticTexts["search-history.empty"].waitForExistence(timeout: 5))
        openFavorites(app)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "search-favorites.load.")).firstMatch.label.contains("常用森林"))
        XCTAssertFalse(app.buttons["search-history.clear"].exists, "Clear history must not become a clear-favorites action")
    }

    func testFilterPageKeepsDraftAndEditsInlineTagsWithoutExecuting() {
        continueAfterFailure = false
        let app = launch(["--qa-tags-offline"])
        XCTAssertTrue(app.buttons["discover.search-entry"].waitForExistence(timeout: 12))
        app.buttons["discover.search-entry"].tap()
        let input = app.textFields["compose.text"]; XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap(); input.typeText("coast language:english -other:city")
        app.buttons["compose.filters"].tap()
        XCTAssertTrue(app.searchComposerTitle("搜索").waitForExistence(timeout: 5))
        XCTAssertTrue(input.exists, "Filters expand below the original search field")
        XCTAssertTrue(app.buttons["compose.apply"].isHittable, "The same search action applies the draft")
        let remove = app.buttons["移除 other:city"]
        for _ in 0..<4 { if remove.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(remove.isHittable); remove.tap()
        let artist = app.textFields["compose.artist"]
        for _ in 0..<4 { if artist.isHittable { break }; app.swipeDown() }
        artist.tap(); artist.typeText("sample")
        collapseFilters(app)
        XCTAssertEqual(input.value as? String, "coast", "Inline tags must move into editable filter rules")
        let filters = app.buttons["compose.filters"]
        XCTAssertTrue((filters.value as? String)?.contains("作者 sample") == true)
        XCTAssertTrue((filters.value as? String)?.contains("language:english") == true)
        XCTAssertFalse((filters.value as? String)?.contains("other:city") == true)
        filters.tap(); XCTAssertEqual(artist.value as? String, "sample")
        let minimum = app.textFields["compose.min-pages"]
        for _ in 0..<7 { if minimum.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(minimum.isHittable)
        let maximum = app.textFields["compose.max-pages"]
        for _ in 0..<3 { if maximum.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(maximum.isHittable)
        let blank = XCTAttachment(screenshot: app.screenshot()); blank.name = "build26.page-range.blank"; blank.lifetime = .keepAlways; add(blank)
        minimum.tap(); minimum.typeText("040")
        for _ in 0..<3 { if maximum.isHittable { break }; app.swipeUp() }
        maximum.tap(); maximum.typeText("45")
        let warning = app.staticTexts["compose.page-range-warning"]
        XCTAssertTrue(warning.exists)
        maximum.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 2) + "100")
        XCTAssertFalse(warning.exists)
        let filled = XCTAttachment(screenshot: app.screenshot()); filled.name = "build26.page-range.filled"; filled.lifetime = .keepAlways; add(filled)
        collapseFilters(app)
        setFiltersExpanded(true, in: app)
        for _ in 0..<7 { if maximum.isHittable { break }; app.swipeUp() }
        XCTAssertEqual(minimum.value as? String, "040", "Draft page text must retain its leading zero until submission")
        XCTAssertEqual(maximum.value as? String, "100")
        collapseFilters(app)
        XCTAssertTrue((filters.value as? String)?.contains("40–100 页") == true)
        app.buttons["compose.apply"].tap()
        let result = app.buttons["discover.search-entry"]
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        let executed = result.value as? String ?? ""
        XCTAssertTrue(executed.contains("coast"))
        XCTAssertTrue(executed.contains("作者 sample"))
        XCTAssertTrue(executed.contains("40–100 页"))
        XCTAssertFalse(executed.contains("other:city"), "Removed inline tags must not reappear during search")
        app.buttons["discover.search-entry"].tap(); filters.tap()
        for _ in 0..<7 { if minimum.isHittable { break }; app.swipeUp() }
        XCTAssertEqual(minimum.value as? String, "40"); XCTAssertEqual(maximum.value as? String, "100")
        app.buttons["compose.cancel"].tap()
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        XCTAssertEqual(result.value as? String, executed)
    }

    func testCompactSearchPagesInDarkLargeType() {
        continueAfterFailure = false
        let app = launch(["--qa-dark", "--qa-large-type", "--qa-tags-offline"])
        XCTAssertTrue(app.buttons["discover.search-entry"].waitForExistence(timeout: 12))
        submitHistorySearch(app, "coast language:english -other:city")
        app.buttons["discover.search-entry"].tap(); openSearchHistory(app)
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "search-history.load.")).firstMatch.tap()
        XCTAssertTrue(feedback(app).waitForExistence(timeout: 5)); XCTAssertTrue(feedback(app).isHittable)
        XCTAssertTrue(app.buttons["compose.filters"].isHittable); XCTAssertTrue(app.buttons["compose.records"].isHittable)
        print("SEARCH25_TYPE fieldHeight=\(app.textFields["compose.text"].frame.height)")
        XCTAssertFalse(app.textFields["compose.artist"].exists)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "search-history.load.")).count, 0)
        let main = XCTAttachment(screenshot: app.screenshot()); main.name = "build25.main.dark-large"; main.lifetime = .keepAlways; add(main)
        app.buttons["compose.filters"].tap()
        XCTAssertTrue(app.searchComposerTitle("搜索").waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["compose.cancel"].isHittable)
        let filters = XCTAttachment(screenshot: app.screenshot()); filters.name = "build25.filters.dark-large"; filters.lifetime = .keepAlways; add(filters)
        collapseFilters(app); openSearchHistory(app)
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "search-history.load.")).firstMatch
        XCTAssertTrue(row.isHittable)
        let records = XCTAttachment(screenshot: app.screenshot()); records.name = "build25.records.dark-large"; records.lifetime = .keepAlways; add(records)
    }

    private func submitHistorySearch(_ app: XCUIApplication, _ text: String) {
        app.buttons["discover.search-entry"].tap()
        let input = app.textFields["compose.text"]
        XCTAssertTrue(input.waitForExistence(timeout: 6))
        input.tap()
        if let old = input.value as? String, !old.isEmpty, old != input.placeholderValue {
            // Short keyword edits start with the caret at the end when tapping
            // the empty portion of the field; remove the previous draft first.
            input.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
            input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count))
        }
        input.typeText(text)
        app.buttons["compose.apply"].tap()
    }

    private func historySwipe(_ app: XCUIApplication, right: Bool) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: right ? 0.2 : 0.8, dy: 0.62))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: right ? 0.8 : 0.2, dy: 0.62))
        start.press(forDuration: 0.04, thenDragTo: end, withVelocity: .default, thenHoldForDuration: 0.08)
    }

    func testBrowseSwipeBackForwardAndNewSearchBranch() {
        continueAfterFailure = false
        let app = launch()
        XCTAssertTrue(app.buttons["discover.search-entry"].waitForExistence(timeout: 12))
        submitHistorySearch(app, "coast")
        XCTAssertTrue(app.staticTexts["已执行：EX · coast"].waitForExistence(timeout: 6))
        submitHistorySearch(app, "mountain")
        XCTAssertTrue(app.staticTexts["已执行：EX · mountain"].waitForExistence(timeout: 6))
        historySwipe(app, right: true)
        XCTAssertTrue(app.staticTexts["已执行：EX · coast"].waitForExistence(timeout: 6))
        historySwipe(app, right: false)
        XCTAssertTrue(app.staticTexts["已执行：EX · mountain"].waitForExistence(timeout: 6))
        historySwipe(app, right: true)
        XCTAssertTrue(app.staticTexts["已执行：EX · coast"].waitForExistence(timeout: 6))
        submitHistorySearch(app, "forest")
        XCTAssertTrue(app.staticTexts["已执行：EX · forest"].waitForExistence(timeout: 6))
        historySwipe(app, right: false)
        XCTAssertTrue(app.staticTexts["已执行：EX · forest"].exists)
    }

    func testBrowseSwipeLeavesVerticalScrollAndHeaderChipsUsable() {
        continueAfterFailure = false
        let app = launch(["--qa-feed-paging"])
        XCTAssertTrue(app.buttons["discover.search-entry"].waitForExistence(timeout: 12))
        submitHistorySearch(app, "language:english other:landscape ~artist:sample")
        let summary = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "已执行：")).firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 6))
        let original = summary.label
        let chips = app.scrollViews["discover.rule-chips"]
        XCTAssertTrue(chips.waitForExistence(timeout: 4))
        chips.swipeRight()
        XCTAssertEqual(summary.label, original)
        app.swipeUp()
        XCTAssertEqual(summary.label, original)
        let card = app.buttons["gallery.open.205"]
        for _ in 0..<8 { if card.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(card.isHittable, "Vertical feed scrolling must remain available")
        card.tap()
        XCTAssertTrue(app.descendants(matching: .any)["detail.actions"].firstMatch.waitForExistence(timeout: 6))
    }

    func testMinimumRatingSearchKeepsExactThresholdAndExcludesLowerDecimalRatings() {
        continueAfterFailure = false
        let app = launch(["--qa-rating-filter", "--qa-tags-offline"])
        XCTAssertTrue(app.buttons["discover.search-entry"].waitForExistence(timeout: 12))
        XCTAssertTrue(app.buttons["gallery.open.1"].exists)
        app.buttons["discover.search-entry"].tap(); app.buttons["compose.filters"].tap()
        let picker = app.buttons["compose.min-rating"]
        for _ in 0..<7 { if picker.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(picker.isHittable); picker.tap()
        let three = app.buttons["3 星"]; XCTAssertTrue(three.waitForExistence(timeout: 5)); three.tap()
        app.buttons["compose.apply"].tap()
        XCTAssertTrue(app.buttons["gallery.open.3"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["gallery.open.4"].exists)
        XCTAssertFalse(app.buttons["gallery.open.1"].exists, "2.8 must be excluded")
        XCTAssertFalse(app.buttons["gallery.open.2"].exists, "2.9 must be excluded")
    }

    func testDetailLinksUseCompactRowsInLightAndDark() {
        continueAfterFailure = false
        for arguments in [["--qa-detail-actions"], ["--qa-detail-actions", "--qa-dark", "--qa-large-type"]] {
            let app = launch(arguments)
            let card = app.buttons["gallery.open.1"]
            XCTAssertTrue(card.waitForExistence(timeout: 12)); card.tap()
            let site = app.buttons["detail.site-page"], archive = app.buttons["detail.download"]
            let tabs = app.descendants(matching: .any)["main.tabs.compact"].firstMatch
            for _ in 0..<5 {
                if archive.exists && archive.frame.maxY < tabs.frame.minY - 8 { break }
                app.swipeUp()
            }
            XCTAssertTrue(site.exists); XCTAssertTrue(archive.exists)
            XCTAssertLessThan(archive.frame.maxY, tabs.frame.minY - 8, "Both rows must be scrollable fully above the floating tabs")
            XCTAssertEqual(site.label, "站点原页"); XCTAssertEqual(archive.label, "本地下载")
            XCTAssertEqual(site.frame.minX, archive.frame.minX, accuracy: 1)
            XCTAssertEqual(site.frame.width, archive.frame.width, accuracy: 1)
            XCTAssertGreaterThanOrEqual(site.frame.height, 44); XCTAssertGreaterThanOrEqual(archive.frame.height, 44)
            let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = arguments.count == 1 ? "build27.detail-links.light" : "build27.detail-links.dark-large"
            shot.lifetime = .keepAlways; add(shot); app.terminate()
        }
    }

    private func launch(_ arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--qa"] + arguments
        app.launch()
        return app
    }

    private func openAccount(_ app: XCUIApplication) -> XCUIElement {
        let tab = app.buttons["main.tab.account"]
        XCTAssertTrue(tab.waitForExistence(timeout: 12))
        tab.tap()
        return app.descendants(matching: .any)["account.browser-site"].firstMatch
    }

    func testRootTitlesAreRemovedAndSearchStillSubmits() {
        let app = launch()
        let search = app.buttons["discover.search-entry"]
        XCTAssertTrue(search.waitForExistence(timeout: 12))
        XCTAssertEqual(app.navigationBars.count, 0, "The discovery root should not retain an empty title bar")

        search.tap()
        let input = app.textFields["compose.text"]
        XCTAssertTrue(input.waitForExistence(timeout: 6))
        input.tap()
        input.typeText("coast")
        app.buttons["compose.apply"].tap()
        XCTAssertTrue(app.staticTexts["已执行：EX · coast"].waitForExistence(timeout: 8))
        XCTAssertEqual(app.navigationBars.count, 0)

        app.buttons["main.tab.library"].tap()
        XCTAssertEqual(app.navigationBars.count, 0, "The library root should not retain an empty title bar")
        app.buttons["main.tab.account"].tap()
        XCTAssertEqual(app.navigationBars.count, 0, "The account root should not retain an empty title bar")
    }

    func testSitePreferencePersistsAndUpdatesDiscoverySearch() {
        let app = launch()
        let sitePicker = openAccount(app)
        XCTAssertTrue(sitePicker.waitForExistence(timeout: 6))
        XCTAssertTrue(app.staticTexts["默认浏览站点"].exists)
        let eh = sitePicker.buttons["EH"]
        XCTAssertTrue(eh.waitForExistence(timeout: 4))
        eh.tap()
        XCTAssertTrue(eh.isSelected)

        app.terminate()
        let reopened = launch(["--qa-keep-site-preference"])
        let search = reopened.buttons["discover.search-entry"]
        XCTAssertTrue(search.waitForExistence(timeout: 12))
        search.tap()
        let input = reopened.textFields["compose.text"]
        XCTAssertTrue(input.waitForExistence(timeout: 6))
        XCTAssertTrue((reopened.buttons["compose.filters"].value as? String)?.contains("EH") == true)
        input.tap()
        input.typeText("persisted")
        reopened.buttons["compose.apply"].tap()
        expectation(for: NSPredicate(format: "value CONTAINS %@", "persisted"), evaluatedWith: search)
        waitForExpectations(timeout: 8)
    }

    func testBottomBarLeavesFinalFeedItemReachable() {
        let app = launch(["--qa-feed-paging"])
        let bar = app.descendants(matching: .any)["main.tabs.compact"].firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 12))
        let last = app.staticTexts["浏览样例 · 12"]
        for _ in 0..<12 {
            if last.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(last.waitForExistence(timeout: 6))
        XCTAssertTrue(last.isHittable, "The last feed item should scroll above the compact bar")
        XCTAssertLessThanOrEqual(last.frame.maxY, bar.frame.minY + 1)
    }

    func testFloatingDiscoveryHeaderStaysUsableWhenFeedScrolls() {
        continueAfterFailure = false
        let app = launch(["--qa-feed-paging"])
        let header = app.descendants(matching: .any)["discover.header.floating"].firstMatch
        let search = app.buttons["discover.search-entry"]
        let first = app.buttons["gallery.open.1"]
        XCTAssertTrue(header.waitForExistence(timeout: 12))
        XCTAssertTrue(first.waitForExistence(timeout: 8))
        XCTAssertGreaterThanOrEqual(first.frame.minY, header.frame.maxY - 1, "The initial row must start below the floating controls")
        let headerY = header.frame.minY
        let firstY = first.frame.minY

        app.swipeUp()
        XCTAssertEqual(header.frame.minY, headerY, accuracy: 1)
        if first.exists {
            XCTAssertLessThan(first.frame.minY, firstY - 40, "The feed should move independently of the header")
        }
        let scrolled = XCTAttachment(screenshot: app.screenshot())
        scrolled.name = "build17.discovery.floating-scrolled"
        scrolled.lifetime = .keepAlways
        add(scrolled)
        XCTAssertTrue(search.isHittable)

        let popular = app.buttons["热门"]
        XCTAssertTrue(popular.isHittable)
        popular.tap()
        XCTAssertTrue(popular.isSelected)
        search.tap()
        XCTAssertTrue(app.textFields["compose.text"].waitForExistence(timeout: 6))
    }

    func testFloatingFavoritesAndLocalScopeStayUsableWhenFeedScrolls() {
        continueAfterFailure = false
        let app = launch(["--qa-library-large-selection"])
        app.buttons["main.tab.library"].tap()
        let header = app.descendants(matching: .any)["favorites.header.floating"].firstMatch
        let scope = app.segmentedControls["library.scope"]
        let first = app.buttons["favorites.gallery.10000"]
        XCTAssertTrue(header.waitForExistence(timeout: 12))
        XCTAssertTrue(first.waitForExistence(timeout: 8))
        XCTAssertGreaterThanOrEqual(first.frame.minY, header.frame.maxY - 1)
        let headerY = header.frame.minY
        app.swipeUp()
        XCTAssertEqual(header.frame.minY, headerY, accuracy: 1)
        XCTAssertTrue(scope.buttons["本机内容"].isHittable)
        let scrolled = XCTAttachment(screenshot: app.screenshot())
        scrolled.name = "build17.favorites.floating-scrolled"
        scrolled.lifetime = .keepAlways
        add(scrolled)

        scope.buttons["本机内容"].tap()
        let localHeader = app.descendants(matching: .any)["library.header.floating"].firstMatch
        XCTAssertTrue(localHeader.waitForExistence(timeout: 6))
        let localY = localHeader.frame.minY
        app.swipeUp()
        XCTAssertEqual(localHeader.frame.minY, localY, accuracy: 1)
        XCTAssertTrue(scope.buttons["站点收藏"].isHittable)
        scope.buttons["站点收藏"].tap()
        XCTAssertTrue(header.waitForExistence(timeout: 6))
    }

    func testReturningToScrolledFeedRestoresCardBelowFloatingHeader() {
        continueAfterFailure = false
        let app = launch(["--qa-feed-paging"])
        let header = app.descendants(matching: .any)["discover.header.floating"].firstMatch
        let card = app.buttons["gallery.open.205"]
        XCTAssertTrue(header.waitForExistence(timeout: 12))
        for _ in 0..<5 {
            if card.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(card.isHittable)
        for _ in 0..<5 {
            let distance = card.frame.minY - (header.frame.maxY + 1)
            if abs(distance) < 2 { break }
            let delta = max(-250, min(250, distance))
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -delta)),
                        withVelocity: .slow, thenHoldForDuration: 0.4)
        }
        XCTAssertEqual(card.frame.minY, header.frame.maxY + 1, accuracy: 16, "Set up a user-visible card near the top before leaving the feed; the final restoration assertion remains strict")

        app.buttons["discover.search-entry"].tap()
        let input = app.textFields["compose.text"]
        XCTAssertTrue(input.waitForExistence(timeout: 6))
        input.tap(); input.typeText("return position")
        app.buttons["compose.apply"].tap()
        XCTAssertTrue(app.buttons["discover.back"].waitForExistence(timeout: 6))
        historySwipe(app, right: true)

        let restored = NSPredicate { _, _ in
            guard card.exists, card.isHittable else { return false }
            return card.frame.minY >= header.frame.maxY - 1 && card.frame.minY <= header.frame.maxY + 30
        }
        expectation(for: restored, evaluatedWith: card)
        waitForExpectations(timeout: 8)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "build17.discovery.restored-below-header"
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func authorSearchApp(_ extra: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--qa", "--qa-tags-offline"] + extra
        app.launch()
        XCTAssertTrue(app.buttons["discover.search-entry"].waitForExistence(timeout: 12))
        return app
    }

    func testFilterIconOpensFiltersDirectlyAndOnlySearchCommitsTheDraft() {
        let app = authorSearchApp()
        app.buttons["discover.filters"].tap()
        XCTAssertTrue(app.searchComposerTitle("搜索").waitForExistence(timeout: 5))
        let artist = app.textFields["compose.artist"]
        artist.tap(); artist.typeText("Draft Author")
        XCTAssertTrue(app.staticTexts["作者"].exists)
        XCTAssertTrue(app.buttons["compose.apply"].isHittable)
        collapseFilters(app)
        XCTAssertTrue(app.searchComposerTitle("搜索").waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["compose.filters"].label.contains("Draft Author"))
        app.buttons["compose.cancel"].tap()
        XCTAssertFalse(app.buttons["discover.condition-summary"].exists)
        app.buttons["discover.filters"].tap()
        XCTAssertTrue(artist.waitForExistence(timeout: 5))
        XCTAssertEqual(artist.value as? String, artist.placeholderValue)
        artist.tap(); artist.typeText("Applied Author")
        let uploader = app.textFields["compose.uploader"]
        for _ in 0..<6 { if uploader.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(uploader.isHittable)
        uploader.tap(); uploader.typeText("sample-uploader")
        XCTAssertTrue(app.staticTexts["上传者"].exists)
        XCTAssertEqual(uploader.value as? String, "sample-uploader")
        app.buttons["compose.apply"].tap()
        assertAuthorResult(app, author: "Applied Author", without: "Draft Author")
    }

    func testMalformedInputDoesNotOpenFiltersAndCorrectingInputClearsOldError() {
        let app = authorSearchApp()
        authorComposer(app, text: #"artist:""#)
        app.buttons["compose.filters"].tap()
        XCTAssertTrue(app.staticTexts["compose.error"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.searchComposerTitle("搜索").exists)
        let field = app.textFields["compose.text"]
        XCTAssertEqual(field.value as? String, #"artist:""#)
        app.buttons["compose.records"].tap()
        XCTAssertTrue(app.staticTexts["搜索记录"].waitForExistence(timeout: 5))
        app.buttons["search-presets.close"].tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, #"artist:""#, "Backing out of history must keep the unfinished token")
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.9)).tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 8)); field.typeText("language:english")
        XCTAssertFalse(app.staticTexts["compose.error"].exists)
        app.buttons["compose.filters"].tap()
        XCTAssertTrue(app.searchComposerTitle("搜索").waitForExistence(timeout: 5))
        let mode = app.descendants(matching: .any)["compose.rule.match.language:english"].firstMatch
        XCTAssertTrue(mode.isHittable); mode.tap()
        let exclude = app.buttons.matching(NSPredicate(format: "label == %@", "排除")).allElementsBoundByIndex.last(where: { $0.isHittable })
        XCTAssertNotNil(exclude); exclude?.tap()
        XCTAssertEqual(mode.value as? String, "排除")
        app.buttons["compose.apply"].tap()
        let applied = app.buttons["discover.condition-summary"]
        XCTAssertTrue(applied.waitForExistence(timeout: 7))
        XCTAssertTrue((applied.value as? String)?.contains("排除 language:english") == true)
    }

    func testFilterValidationIsVisibleAndFixingTheFieldKeepsTheOtherConditions() {
        let app = authorSearchApp()
        authorComposer(app, text: "one two three four five")
        app.buttons["compose.filters"].tap()
        let artist = app.textFields["compose.artist"]
        XCTAssertTrue(artist.waitForExistence(timeout: 5)); artist.tap(); artist.typeText("Limit Author")
        app.buttons["compose.apply"].tap()
        let error = app.staticTexts["compose.error"]
        let beforeCheck = XCTAttachment(screenshot: app.screenshot()); beforeCheck.name = "filter-error.before-visibility-check"; beforeCheck.lifetime = .keepAlways; add(beforeCheck)
        let hierarchy = XCTAttachment(string: app.debugDescription); hierarchy.name = "filter-error.accessibility"; hierarchy.lifetime = .keepAlways; add(hierarchy)
        XCTAssertTrue(error.waitForExistence(timeout: 5)); XCTAssertTrue(error.isHittable)
        XCTAssertTrue(error.label.contains("6"))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "search-interaction.visible-filter-error"; shot.lifetime = .keepAlways; add(shot)
        artist.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        artist.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "Limit Author".count))
        XCTAssertFalse(error.exists)
        app.buttons["compose.apply"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS %@", "已执行：", "one two three four five")).firstMatch.waitForExistence(timeout: 7))
    }

    func testClearingDraftDoesNotChangeResultsOrDeleteSearchHistoryUntilSearch() {
        let app = authorSearchApp()
        authorComposer(app, text: "coast language:english"); app.buttons["compose.apply"].tap()
        let active = app.buttons["discover.search-entry"]
        let summary = app.buttons["discover.condition-summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 6))
        let applied = try? XCTUnwrap(active.value as? String)
        XCTAssertTrue(applied?.contains("coast") == true)
        authorComposer(app, text: "coast")
        app.buttons["compose.clear"].tap()
        XCTAssertTrue(app.staticTexts["compose.cleared-state"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["compose.text"].value as? String, app.textFields["compose.text"].placeholderValue)
        app.buttons["compose.cancel"].tap()
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        XCTAssertEqual(active.value as? String, applied)
        authorComposer(app, text: "coast"); app.buttons["compose.clear"].tap(); app.buttons["compose.apply"].tap()
        XCTAssertTrue(summary.waitForNonExistence(timeout: 5))
        XCTAssertFalse((active.value as? String)?.contains("coast") == true)
        authorComposer(app, text: ""); app.buttons["compose.records"].tap()
        let record = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "search-history.load.")).firstMatch
        XCTAssertTrue(record.waitForExistence(timeout: 5)); XCTAssertTrue(record.label.contains("coast"))
    }

    func testFavoriteEntryPointsLoadDraftsAndEditedSearchDoesNotClaimTheOriginalPreset() {
        let app = authorSearchApp()
        authorComposer(app, text: "coast"); app.buttons["compose.apply"].tap()
        app.buttons["discover.search-entry"].tap(); app.buttons["compose.save-favorite"].tap()
        nameFavorite(app, "Coast preset"); app.buttons["compose.cancel"].tap()
        authorComposer(app, text: "mountain"); app.buttons["compose.apply"].tap()
        app.buttons["discover.saved-menu"].tap()
        let shortcut = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "search-favorites.load.")).firstMatch
        XCTAssertTrue(shortcut.waitForExistence(timeout: 5)); shortcut.tap()
        XCTAssertTrue(app.searchComposerTitle("搜索").waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["compose.text"].value as? String, "coast")
        XCTAssertEqual(feedback(app).value as? String, "已载入")
        openSearchHistory(app)
        let latest = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "search-history.load.")).firstMatch
        XCTAssertTrue(latest.label.contains("mountain"), "Loading a preset must not execute or reorder search history")
        app.buttons["search-presets.close"].tap(); app.buttons["compose.cancel"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS %@", "已执行：", "mountain")).firstMatch.waitForExistence(timeout: 5))

        app.buttons["discover.saved-menu"].tap()
        XCTAssertTrue(app.staticTexts["常用组合"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["search-history.clear"].exists)
        let preset = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "search-favorites.load.")).firstMatch
        XCTAssertTrue(preset.waitForExistence(timeout: 5)); preset.tap()
        XCTAssertTrue(app.searchComposerTitle("搜索").waitForExistence(timeout: 7))
        XCTAssertEqual(app.textFields["compose.text"].value as? String, "coast")
        XCTAssertEqual(feedback(app).value as? String, "已载入")
        let text = app.textFields["compose.text"]; text.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.9)).tap(); text.typeText(" changed")
        app.buttons["compose.apply"].tap()
        app.buttons["discover.search-entry"].tap()
        app.buttons["compose.save-favorite"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["search.save.header"].firstMatch.waitForExistence(timeout: 5), "Edited criteria must not silently target the original preset for replacement")
    }

    func testHistoryLivesInDiscoverAndKeepsTheFeedAndAuthorNavigation() {
        let app = authorSearchApp(["--qa-library-sort", "--qa-reset-library-sort"])
        XCTAssertEqual(app.buttons["main.tab.library"].label, "资料库")
        XCTAssertEqual(app.buttons["main.tab.account"].label, "我的")
        authorComposer(app, text: "coast"); app.buttons["compose.apply"].tap()
        app.buttons["discover.lane.2"].tap()
        XCTAssertTrue(app.textFields["reading-history.search-field"].waitForExistence(timeout: 5))
        let row = app.buttons["reading-history.item.7203"]
        XCTAssertTrue(row.waitForExistence(timeout: 5)); row.tap()
        XCTAssertTrue(app.staticTexts["画廊详情"].waitForExistence(timeout: 5)); app.buttons["BackButton"].tap()
        app.buttons["discover.lane.0"].tap()
        let search = app.buttons["discover.search-entry"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        XCTAssertTrue((search.value as? String)?.contains("coast") == true)
        app.buttons["main.tab.library"].tap()
        app.buttons["library.scope.2"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        app.buttons["main.tab.discover"].tap()
        app.buttons["discover.lane.2"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5)); row.tap()
        let author = app.buttons["detail.tag.artist:preview studio"]
        for _ in 0..<6 { if author.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(author.isHittable); author.tap()
        app.buttons["detail.tags.search-menu"].tap()
        app.buttons["detail.tags.new-search"].tap()
        app.buttons["compose.apply"].tap()
        assertAuthorResult(app, author: "preview studio", without: "coast")
        XCTAssertFalse(app.staticTexts["阅读历史"].exists)
    }

    private func authorComposer(_ app: XCUIApplication, text: String) {
        app.buttons["discover.search-entry"].tap()
        let field = app.textFields["compose.text"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.9)).tap()
        if let old = field.value as? String, old != field.placeholderValue, !old.isEmpty {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count))
        }
        if !text.isEmpty { field.typeText(text) }
    }

    private func assertAuthorResult(_ app: XCUIApplication, author: String, without previous: String? = nil) {
        let result = app.buttons["discover.condition-summary"]
        let authorIsApplied = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", author), object: result)
        XCTAssertEqual(XCTWaiter.wait(for: [authorIsApplied], timeout: 7), .completed)
        if let previous { XCTAssertFalse((result.value as? String ?? "").contains(previous)) }
        XCTAssertFalse(app.searchComposerTitle("搜索").exists)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "author-search." + author; shot.lifetime = .keepAlways; add(shot)
    }

    func testAuthorDetailStartsFreshSearchWithoutFivePreviousConditions() {
        let app = authorSearchApp()
        authorComposer(app, text: "one two three four five")
        app.buttons["compose.apply"].tap()
        let gallery = app.staticTexts["海岸线 · 插画与速写"].firstMatch
        XCTAssertTrue(gallery.waitForExistence(timeout: 7)); gallery.tap()
        let author = app.buttons["preview studio"]
        for _ in 0..<6 { if author.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(author.isHittable); author.tap()
        assertAuthorResult(app, author: "preview studio", without: "one")
        authorComposer(app, text: "")
        XCTAssertEqual(app.textFields["compose.text"].value as? String, app.textFields["compose.text"].placeholderValue)
        app.buttons["compose.filters"].tap()
        XCTAssertEqual(app.textFields["compose.artist"].value as? String, "preview studio")
        XCTAssertFalse(app.buttons["移除 artist:preview studio"].exists)
    }

    func testAuthorFilterReplacesInlineAuthorAndReportsOnlyActualOverLimit() {
        let app = authorSearchApp()
        authorComposer(app, text: #"one two three four artist:"Previous Author""#)
        app.buttons["compose.filters"].tap()
        let artist = app.textFields["compose.artist"]
        XCTAssertTrue(artist.waitForExistence(timeout: 5)); artist.tap()
        artist.typeText("New "); artist.typeText("Author")
        XCTAssertFalse(app.buttons["移除 artist:Previous Author"].exists)
        app.buttons["compose.apply"].tap()
        assertAuthorResult(app, author: "New Author", without: "Previous Author")

        authorComposer(app, text: "one two three four five")
        app.buttons["compose.apply"].tap()
        let failure = app.staticTexts["compose.error"]
        XCTAssertTrue(failure.waitForExistence(timeout: 5))
        XCTAssertTrue(failure.label.contains("6")); XCTAssertTrue(failure.label.contains("包含"))
        XCTAssertFalse(failure.label.contains("10"))
        XCTAssertTrue(app.searchComposerTitle("搜索").exists)
        XCTAssertEqual(app.textFields["compose.text"].value as? String, "one two three four five")
    }

    func testAuthorTextReplacesPreviousFilterAndKeepsMultiwordNameAsOneTerm() {
        let app = authorSearchApp()
        authorComposer(app, text: "")
        app.buttons["compose.filters"].tap()
        let artist = app.textFields["compose.artist"]
        XCTAssertTrue(artist.waitForExistence(timeout: 5)); artist.tap(); artist.typeText("Previous Author")
        app.buttons["compose.apply"].tap()
        assertAuthorResult(app, author: "Previous Author")
        let name = "Sample Artist With Six Separate Name Words"
        authorComposer(app, text: "one two three four ArTiSt:\"\(name)\"")
        app.buttons["compose.apply"].tap()
        assertAuthorResult(app, author: name, without: "Previous Author")
        authorComposer(app, text: "one two three four")
        app.buttons["compose.filters"].tap()
        XCTAssertEqual(app.textFields["compose.artist"].value as? String, app.textFields["compose.artist"].placeholderValue)
        XCTAssertTrue(app.buttons["移除 artist:\(name)"].exists)
    }
}
