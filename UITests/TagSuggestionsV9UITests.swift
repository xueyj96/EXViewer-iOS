import XCTest

final class TagSuggestionsV9UITests: XCTestCase {
    private func launch(_ arguments: [String] = [], accessibilityTextSize: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--qa", "--qa-reset-reader-preferences"] + arguments
        if accessibilityTextSize {
            app.launchArguments += ["--qa-large-type"]
        }
        app.launch()
        XCTAssertTrue(app.buttons["discover.search-entry"].waitForExistence(timeout: 12))
        return app
    }

    private func openTagEntry(_ app: XCUIApplication) -> XCUIElement {
        app.buttons["discover.search-entry"].tap()
        XCTAssertTrue(app.searchComposerTitle("搜索").waitForExistence(timeout: 5))
        app.buttons["compose.filters"].tap()
        let addTag = app.buttons["compose.add-tag"]
        for _ in 0..<5 { if addTag.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(addTag.isHittable)
        addTag.tap()
        XCTAssertTrue(app.staticTexts["添加标签"].waitForExistence(timeout: 5))
        return app.textFields["tag.name"]
    }

    func testDefaultAllFindsChineseNameOnlyInLocalDictionary() {
        let app = launch(["--qa-tags-offline"])
        let input = openTagEntry(app)
        XCTAssertEqual(app.buttons["tag.namespace-filter"].value as? String, "全部分类")
        input.tap(); input.typeText("英语")

        let candidate = app.buttons["tag.suggestion.language:english"]
        XCTAssertTrue(candidate.waitForExistence(timeout: 12))
        XCTAssertTrue((candidate.value as? String ?? "").contains("词库匹配，站点未验证"))
        XCTAssertFalse((candidate.value as? String ?? "").contains("E-Hentai 站点候选"))
        input.typeText("\n")
        let source = app.descendants(matching: .any)["tag.dictionary-disclosure"].firstMatch
        for _ in 0..<5 { if source.isHittable { break }; app.swipeUp() }
        XCTAssertEqual(source.frame.height, 36, accuracy: 1)
        XCTAssertEqual(source.value as? String, "已收起")
        source.tap()
        XCTAssertTrue(app.staticTexts["tag.dictionary-info"].label.contains("非全站标签目录"))
        XCTAssertTrue(app.staticTexts["tag.dictionary-info"].label.contains("v7.29356.1"))
        XCTAssertEqual(source.frame.height, 36, accuracy: 1)
        XCTAssertEqual(source.value as? String, "已展开")
    }

    func testLanguageQAFixtureSelectionAddsRuleWithExplicitFixtureStatus() {
        let app = launch(["--qa-tags-delayed"])
        let input = openTagEntry(app)
        app.selectTagNamespace("language")
        input.tap(); input.typeText("eng")

        let candidate = app.buttons["tag.suggestion.language:english"]
        XCTAssertTrue(candidate.waitForExistence(timeout: 12))
        expectation(for: NSPredicate { _, _ in (candidate.value as? String ?? "").contains("QA 样例") }, evaluatedWith: candidate)
        waitForExpectations(timeout: 8)
        candidate.tap()
        let pendingRow = app.descendants(matching: .any)["tag.pending.row.language:english"].firstMatch
        XCTAssertTrue(pendingRow.waitForExistence(timeout: 5))
        XCTAssertTrue((pendingRow.value as? String)?.contains("QA 样例，非真实站点匹配") == true)
        XCTAssertFalse(app.staticTexts["tag.pending.status.language:english"].exists)
        XCTAssertEqual(app.buttons["tag.confirm"].label, "完成")
        app.buttons["tag.confirm"].tap()

        XCTAssertTrue(app.staticTexts["language:english"].waitForExistence(timeout: 5))
        app.buttons["compose.apply"].tap()
        let summary = app.buttons["discover.search-entry"]
        XCTAssertTrue(summary.waitForExistence(timeout: 8))
        XCTAssertTrue((summary.value as? String)?.contains("language:english") == true)
    }

    func testAliasSuggestionShowsAndAddsTheCanonicalTag() {
        let app = launch(["--qa-tags-offline", "--qa-dark"])
        let input = openTagEntry(app)
        input.tap(); input.typeText("qa printmaker\n")

        let candidate = app.buttons["tag.suggestion.artist:qa stencil"]
        XCTAssertTrue(candidate.waitForExistence(timeout: 8))
        XCTAssertTrue(candidate.isEnabled)
        XCTAssertTrue(candidate.label.contains("别名 qa printmaker"))
        XCTAssertFalse(app.buttons["tag.suggestion.temp:qa printmaker"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "tag-suggestion-card-dark"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        candidate.tap()
        XCTAssertEqual(app.buttons["tag.confirm"].label, "完成")
        app.buttons["tag.confirm"].tap()

        XCTAssertTrue(app.staticTexts["artist:qa stencil"].waitForExistence(timeout: 5))
        app.buttons["compose.apply"].tap()
        let summary = app.buttons["discover.search-entry"]
        XCTAssertTrue(summary.waitForExistence(timeout: 8))
        XCTAssertTrue((summary.value as? String ?? "").contains("artist:qa stencil"))
    }

    func testUnknownFreeTextRequiresExplicitUnverifiedAction() {
        let app = launch(["--qa-tags-offline"])
        let input = openTagEntry(app)
        XCTAssertEqual(app.buttons["tag.namespace-filter"].value as? String, "全部分类")
        input.tap(); input.typeText("zz-no-real-tag\n")

        let add = app.buttons["tag.stage"]
        XCTAssertTrue(add.waitForExistence(timeout: 8))
        XCTAssertTrue(add.label.contains("未验证"))
        XCTAssertFalse(app.buttons["tag.confirm"].isEnabled)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "tag-manual-entry-card"
        screenshot.lifetime = .keepAlways
        self.add(screenshot)
        add.tap()
        let language = app.buttons["tag.stage.namespace.language"]
        XCTAssertTrue(language.waitForExistence(timeout: 5))
        language.tap()
        XCTAssertEqual(app.buttons["tag.confirm"].label, "完成")

        app.selectTagNamespace("language")
        input.tap(); input.typeText("zz-other-tag\n")
        XCTAssertTrue(add.waitForExistence(timeout: 8))
        XCTAssertTrue(add.label.contains("未验证 · 语言"))
        add.tap()
        XCTAssertEqual(app.buttons["tag.confirm"].label, "完成")
        app.buttons["tag.confirm"].tap()

        XCTAssertTrue(app.staticTexts["language:zz-no-real-tag"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["language:zz-other-tag"].exists)
        app.buttons["compose.apply"].tap()
        let summary = app.buttons["discover.search-entry"]
        XCTAssertTrue(summary.waitForExistence(timeout: 8))
        XCTAssertTrue((summary.value as? String ?? "").contains("language:zz-no-real-tag"))
    }

    func testDelayedOldSuggestionDoesNotReturnAfterInputChanges() {
        let app = launch(["--qa-tags-delayed"])
        let input = openTagEntry(app)
        app.selectTagNamespace("language")
        input.tap(); input.typeText("eng")
        let stale = app.buttons["tag.suggestion.language:english"]
        XCTAssertTrue(stale.waitForExistence(timeout: 5), "The local raw-name match should appear before the delayed QA response")
        input.tap(); input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 3)); input.typeText("zz-no-match")

        let disappeared = NSPredicate { _, _ in !stale.exists }
        expectation(for: disappeared, evaluatedWith: stale)
        waitForExpectations(timeout: 2)
        let add = app.buttons["tag.stage"]
        XCTAssertTrue(add.waitForExistence(timeout: 8))
        Thread.sleep(forTimeInterval: 1.7)
        XCTAssertFalse(stale.exists, "The delayed response for the old prefix must not repopulate the new input")
        XCTAssertTrue(add.label.contains("未验证 · 语言"))
    }

    func testLongChineseCandidateRemainsTouchableAtAccessibilityTextSize() {
        let app = launch(["--qa-tags-offline"], accessibilityTextSize: true)
        let input = openTagEntry(app)
        let classifier = app.buttons["tag.namespace-filter"]
        XCTAssertTrue(classifier.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(classifier.frame.minY, input.frame.maxY + 3)
        input.tap(); input.typeText("danshi koukousei de urekko light novel")
        input.typeText("\n")

        let candidates = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "tag.suggestion.parody:"))
        let candidate = candidates.firstMatch
        XCTAssertTrue(candidate.waitForExistence(timeout: 12))
        for _ in 0..<4 { if candidate.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(candidate.isHittable)
        XCTAssertGreaterThanOrEqual(candidate.frame.height, 44)
        XCTAssertTrue(candidate.label.contains("身为男高中生") || candidate.label.contains("男高中生兼当红"))
        let selectedID = String(candidate.identifier.dropFirst("tag.suggestion.".count))
        candidate.tap()
        let pendingRow = app.descendants(matching: .any)["tag.pending.row.\(selectedID)"].firstMatch
        for _ in 0..<8 { if pendingRow.exists && pendingRow.isHittable { break }; app.swipeDown() }
        XCTAssertTrue(pendingRow.exists && pendingRow.isHittable)
        XCTAssertTrue((pendingRow.value as? String)?.contains("本地词库") == true)
        XCTAssertTrue((pendingRow.value as? String)?.contains("站点未验证") == true)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "tags47.editor.accessibility"; shot.lifetime = .keepAlways; add(shot)
    }
}
