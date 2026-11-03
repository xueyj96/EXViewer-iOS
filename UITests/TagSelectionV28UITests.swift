import XCTest

final class TagSelectionV28UITests: XCTestCase {
    private func openTags(_ extra: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--qa", "--qa-tags-offline", "--qa-library-sort"] + extra
        app.launch()
        XCTAssertTrue(app.buttons["discover.search-entry"].waitForExistence(timeout: 12)); app.buttons["discover.search-entry"].tap()
        let text = app.textFields["compose.text"]; XCTAssertTrue(text.waitForExistence(timeout: 5)); text.tap(); text.typeText("coast")
        app.buttons["compose.filters"].tap()
        let add = app.buttons["compose.add-tag"]
        for _ in 0..<5 { if add.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(add.isHittable); add.tap()
        let language = app.buttons["tag.namespace.language"]
        XCTAssertTrue(language.waitForExistence(timeout: 5)); language.tap()
        let name = app.textFields["tag.name"]; XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText("eng\n")
        XCTAssertTrue(app.buttons["tag.suggestion.language:english"].waitForExistence(timeout: 8))
        return app
    }
    private func tapCandidate(_ app: XCUIApplication) {
        let button = app.buttons["tag.suggestion.language:english"]
        for _ in 0..<5 { if button.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(button.isHittable); button.tap()
    }
    func testTagEditorReopensExistingSelectionAndCanCommitRemovingEverything() {
        let app = openTags(); tapCandidate(app); app.buttons["tag.confirm"].tap()
        XCTAssertTrue(app.navigationBars["筛选条件"].waitForExistence(timeout: 5))
        app.buttons["compose.add-tag"].tap()
        let remove = app.buttons["tag.pending.remove.language:english"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        let row = app.descendants(matching: .any)["tag.pending.row.language:english"].firstMatch
        XCTAssertTrue(row.exists)
        XCTAssertLessThanOrEqual(row.frame.height, 44.5)
        XCTAssertGreaterThanOrEqual(remove.frame.height, 44)
        XCTAssertFalse(app.staticTexts["tag.pending.status.language:english"].exists)
        XCTAssertTrue((row.value as? String)?.contains("已在本次搜索条件中") == true)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "tags47.editor.light"; shot.lifetime = .keepAlways; add(shot)
        let rowShot = XCTAttachment(screenshot: row.screenshot()); rowShot.name = "tags47.selected-row.light"; rowShot.lifetime = .keepAlways; add(rowShot)
        XCTAssertEqual(app.buttons["tag.confirm"].label, "完成，1 个标签")
        remove.tap()
        XCTAssertEqual(app.buttons["tag.confirm"].label, "完成，0 个标签")
        XCTAssertTrue(app.buttons["tag.confirm"].isEnabled)
        app.buttons["tag.confirm"].tap()
        XCTAssertTrue(app.navigationBars["筛选条件"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["移除 language:english"].exists)
        app.buttons["BackButton"].tap()
        XCTAssertEqual(app.textFields["compose.text"].value as? String, "coast")
    }

    func testCommonTagsStaySeparateAndCancelKeepsExistingSelection() {
        let app = openTags(); tapCandidate(app); app.buttons["tag.confirm"].tap()
        let add = app.buttons["compose.add-tag"], common = app.buttons["compose.common-tags"]
        XCTAssertTrue(common.waitForExistence(timeout: 5))
        XCTAssertEqual(add.label, "添加标签")
        XCTAssertEqual(common.label, "常用标签")
        XCTAssertEqual(add.frame.midY, common.frame.midY, accuracy: 1)
        let entryShot = XCTAttachment(screenshot: app.screenshot()); entryShot.name = "tags48.entry-labels.light"; entryShot.lifetime = .keepAlways; self.add(entryShot)
        XCTAssertFalse(app.buttons["compose.new-tag-match.0"].exists)
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == %@", "language:english")).count, 1)
        common.tap()
        let shortcut = app.buttons["compose.favorite-tag.language:english"]
        XCTAssertTrue(shortcut.waitForExistence(timeout: 5)); XCTAssertFalse(shortcut.isEnabled)
        app.navigationBars["筛选条件"].staticTexts["筛选条件"].tap()
        app.buttons["compose.add-tag"].tap()
        XCTAssertTrue(app.buttons["tag.match.2"].waitForExistence(timeout: 5))
        app.buttons["tag.match.2"].tap()
        XCTAssertTrue(app.buttons["tag.match.2"].isSelected)
        let existing = app.descendants(matching: .any)["tag.pending.match.language:english"].firstMatch
        XCTAssertEqual(existing.value as? String, "包含", "Changing the new-tag default must not rewrite an existing tag")
        app.buttons["tag.pending.remove.language:english"].tap()
        app.buttons["tag.cancel"].tap()
        XCTAssertTrue(app.buttons["移除 language:english"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.descendants(matching: .any)["compose.rule.match.language:english"].firstMatch.value as? String, "包含")
        app.buttons["compose.rule.remove.language:english"].tap()
        common.tap()
        XCTAssertTrue(shortcut.isEnabled); shortcut.tap()
        XCTAssertEqual(app.descendants(matching: .any)["compose.rule.match.language:english"].firstMatch.value as? String, "包含")
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == %@", "language:english")).count, 1)
    }

    func testRepeatedCandidateToggleAndExplicitRemovalImmediatelyUpdateCount() {
        let app = openTags()
        let candidate = app.buttons["tag.suggestion.language:english"], done = app.buttons["tag.confirm"]
        for _ in 0..<3 {
            tapCandidate(app); XCTAssertTrue(candidate.isSelected); XCTAssertEqual(done.label, "完成，1 个标签")
            tapCandidate(app); XCTAssertFalse(candidate.isSelected); XCTAssertEqual(done.label, "完成，0 个标签")
            XCTAssertFalse(done.isEnabled); XCTAssertFalse(app.buttons["tag.pending.remove.language:english"].exists)
        }
        tapCandidate(app)
        let remove = app.buttons["tag.pending.remove.language:english"]
        for _ in 0..<5 { if remove.isHittable { break }; app.swipeDown() }
        XCTAssertTrue(remove.isHittable); remove.tap()
        XCTAssertFalse(candidate.isSelected); XCTAssertEqual(done.label, "完成，0 个标签")
        XCTAssertEqual(app.textFields["tag.name"].value as? String, "eng")
    }
    func testMatchMenuEditsDraftAndSearchRunsOnlyAfterExplicitSearch() {
        let app = openTags(); tapCandidate(app)
        let mode = app.descendants(matching: .any)["tag.pending.match.language:english"].firstMatch
        for _ in 0..<5 { if mode.isHittable { break }; app.swipeDown() }
        XCTAssertTrue(mode.isHittable); mode.tap()
        XCTAssertTrue(app.buttons["排除"].firstMatch.waitForExistence(timeout: 5))
        let exclude = app.buttons.matching(NSPredicate(format: "label == %@", "排除")).allElementsBoundByIndex.last(where: { $0.isHittable })
        XCTAssertNotNil(exclude); exclude?.tap()
        XCTAssertEqual(mode.value as? String, "排除")
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "build28.tags.selected-mode"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["tag.confirm"].tap()
        XCTAssertTrue(app.navigationBars["筛选条件"].waitForExistence(timeout: 5)); app.buttons["BackButton"].tap()
        XCTAssertTrue((app.buttons["compose.filters"].value as? String)?.contains("排除 language:english") == true)
        XCTAssertEqual(app.textFields["compose.text"].value as? String, "coast")
        XCTAssertFalse(app.buttons["discover.condition-summary"].exists)
        app.buttons["compose.apply"].tap()
        let result = app.buttons["discover.condition-summary"]
        XCTAssertTrue(result.waitForExistence(timeout: 6))
        XCTAssertTrue((result.value as? String)?.contains("排除 language:english") == true)
        app.buttons["discover.search-entry"].tap(); app.buttons["compose.records"].tap()
        XCTAssertTrue(app.segmentedControls["compose.records-tabs"].buttons["最近搜索"].exists)
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "search-history.load.")).firstMatch
        XCTAssertTrue(row.label.contains("排除 language:english"))
    }
    func testCancelDiscardsPendingTagsAndKeepsParentConditions() {
        let app = openTags(); tapCandidate(app)
        app.buttons["tag.cancel"].tap()
        XCTAssertTrue(app.navigationBars["筛选条件"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["移除 language:english"].exists)
        app.buttons["BackButton"].tap()
        XCTAssertEqual(app.textFields["compose.text"].value as? String, "coast")
        XCTAssertFalse((app.buttons["compose.filters"].value as? String ?? "").contains("language:english"))
        app.buttons["compose.cancel"].tap()
        app.buttons["discover.search-entry"].tap(); app.buttons["compose.records"].tap()
        XCTAssertTrue(app.staticTexts["search-history.empty"].waitForExistence(timeout: 5))
    }
    func testFavoriteAliasAndCandidateShareTheSameReversibleSelection() {
        let app = openTags()
        let favorite = app.buttons["tag.favorite.language:english"]
        for _ in 0..<8 { if favorite.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(favorite.isHittable); favorite.tap()
        XCTAssertTrue(favorite.isSelected); XCTAssertEqual(app.buttons["tag.confirm"].label, "完成，1 个标签")
        tapCandidate(app)
        XCTAssertFalse(favorite.isSelected); XCTAssertEqual(app.buttons["tag.confirm"].label, "完成，0 个标签")
        for _ in 0..<8 { if favorite.isHittable { break }; app.swipeUp() }
        favorite.tap(); favorite.tap()
        XCTAssertFalse(favorite.isSelected); XCTAssertEqual(app.buttons["tag.confirm"].label, "完成，0 个标签")
    }

    func testParentRuleMenusAndRemovalOnlyChangeTheChosenCondition() {
        for extra in [[], ["--qa-dark", "--qa-large-type"]] {
            let app = openTags(extra)
            tapCandidate(app); app.buttons["tag.confirm"].tap()
            app.buttons["compose.add-tag"].tap()
            let input = app.textFields["tag.name"]
            XCTAssertTrue(input.waitForExistence(timeout: 5)); input.tap(); input.typeText("full color\n")
            let color = app.buttons["tag.suggestion.other:full color"]
            XCTAssertTrue(color.waitForExistence(timeout: 8))
            for _ in 0..<5 { if color.isHittable { break }; app.swipeUp() }
            XCTAssertTrue(color.isHittable); color.tap(); app.buttons["tag.confirm"].tap()
            let language = app.buttons["compose.rule.match.language:english"]
            let colorMode = app.buttons["compose.rule.match.other:full color"]
            for _ in 0..<5 { if language.isHittable && colorMode.isHittable { break }; app.swipeUp() }
            XCTAssertTrue(language.isHittable && colorMode.isHittable)
            XCTAssertEqual(language.value as? String, "包含")
            XCTAssertEqual(colorMode.value as? String, "包含")
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = extra.isEmpty ? "tags46.parent.light" : "tags46.parent.dark-large"
            shot.lifetime = .keepAlways; add(shot)
            colorMode.tap()
            let exclude = app.buttons.matching(NSPredicate(format: "label == %@", "排除")).allElementsBoundByIndex.last(where: { $0.isHittable })
            XCTAssertNotNil(exclude); exclude?.tap()
            XCTAssertEqual(colorMode.value as? String, "排除")
            XCTAssertEqual(language.value as? String, "包含")
            XCTAssertFalse(app.buttons["compose.new-tag-match.0"].exists)
            app.buttons["compose.rule.remove.other:full color"].tap()
            XCTAssertFalse(colorMode.exists)
            XCTAssertEqual(language.value as? String, "包含")
            app.terminate()
        }
    }
}
