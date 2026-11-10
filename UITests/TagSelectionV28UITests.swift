import XCTest

final class TagSelectionV28UITests: XCTestCase {
    func testTagManagementDoesNotOfferSearchMatchingModes() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--qa", "--qa-tags-offline"]
        app.launch()
        XCTAssertTrue(app.buttons["main.tab.account"].waitForExistence(timeout: 10))
        app.buttons["main.tab.account"].tap()
        let settings = app.buttons["account.tags"]
        for _ in 0..<4 { if settings.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(settings.isHittable)
        settings.tap()
        app.buttons["tags.add"].tap()
        let input = app.textFields["tag.name"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["main.tab.account"].isHittable)
        XCTAssertFalse(app.buttons["tag.match.0"].exists)
        input.tap()
        input.typeText("英语\n")
        tapCandidate(app)
        XCTAssertFalse(app.buttons["tag.pending.match.language:english"].exists)
        XCTAssertTrue(app.buttons["tag.pending.remove.language:english"].exists)
        app.buttons["tag.confirm"].tap()
        XCTAssertTrue(app.buttons["tags.add"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["english"].exists)
        let filter = app.textFields["tags.search"]
        XCTAssertTrue(filter.isHittable)
        let searchCard = app.descendants(matching: .any)["tags.search-card"].firstMatch
        XCTAssertTrue(searchCard.exists)
        XCTAssertEqual(searchCard.frame.height, 36, accuracy: 1)
        XCTAssertEqual(searchCard.frame.midY, filter.frame.midY, accuracy: 1)
        XCTAssertEqual(app.buttons["tags.scope.0"].frame.minY - searchCard.frame.maxY, 4, accuracy: 1)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "tags-management.separate-search"; shot.lifetime = .keepAlways; add(shot)
        filter.tap(); filter.typeText("zzzz")
        XCTAssertFalse(app.staticTexts["english"].exists)
        filter.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 4))
        XCTAssertTrue(app.staticTexts["english"].exists)
        let blocked = app.buttons["tags.scope.1"]
        let common = app.buttons["tags.scope.0"]
        XCTAssertEqual(common.frame.height, 36, accuracy: 1)
        XCTAssertEqual(blocked.frame.height, common.frame.height, accuracy: 1)
        XCTAssertEqual(common.frame.midY, blocked.frame.midY, accuracy: 1)
        blocked.tap()
        XCTAssertTrue(blocked.isSelected)
        XCTAssertFalse(app.staticTexts["english"].exists)
        common.tap()
        XCTAssertTrue(common.isSelected)
        XCTAssertTrue(app.staticTexts["english"].exists)
        XCTAssertTrue(app.buttons["main.tab.account"].isHittable)

        let longName = "an unusually long local tag name with a distinctive ending for layout checks"
        app.buttons["tags.add"].tap()
        app.selectTagNamespace("other")
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        input.typeText(longName + "\n")
        let manualTag = app.buttons["tag.stage"]
        XCTAssertTrue(manualTag.waitForExistence(timeout: 5))
        for _ in 0..<3 { if manualTag.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(manualTag.isHittable)
        manualTag.tap()
        app.buttons["tag.confirm"].tap()
        let longTag = app.staticTexts[longName]
        XCTAssertTrue(longTag.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(longTag.frame.height, app.staticTexts["english"].frame.height)
    }

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
        app.selectTagNamespace("language")
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
        XCTAssertTrue(app.searchComposerTitle("搜索").waitForExistence(timeout: 5))
        app.buttons["compose.add-tag"].tap()
        let remove = app.buttons["tag.pending.remove.language:english"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        let row = app.descendants(matching: .any)["tag.pending.row.language:english"].firstMatch
        XCTAssertTrue(row.exists)
        XCTAssertEqual(row.frame.height, 36, accuracy: 1)
        XCTAssertEqual(remove.frame.height, row.frame.height, accuracy: 1)
        XCTAssertGreaterThanOrEqual(remove.frame.width, 43.99)
        XCTAssertFalse(app.staticTexts["tag.pending.status.language:english"].exists)
        XCTAssertTrue((row.value as? String)?.contains("已在本次搜索条件中") == true)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "tags47.editor.light"; shot.lifetime = .keepAlways; add(shot)
        let rowShot = XCTAttachment(screenshot: row.screenshot()); rowShot.name = "tags47.selected-row.light"; rowShot.lifetime = .keepAlways; add(rowShot)
        XCTAssertEqual(app.buttons["tag.confirm"].label, "完成")
        remove.tap()
        XCTAssertEqual(app.buttons["tag.confirm"].label, "完成")
        XCTAssertTrue(app.buttons["tag.confirm"].isEnabled)
        app.buttons["tag.confirm"].tap()
        XCTAssertTrue(app.searchComposerTitle("搜索").waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["移除 language:english"].exists)
        app.buttons["compose.filters"].tap()
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
        XCTAssertTrue(shortcut.waitForExistence(timeout: 5))
        XCTAssertFalse(shortcut.isEnabled)
        XCTAssertEqual(shortcut.frame.minY - common.frame.maxY, 4, accuracy: 1)
        XCTAssertEqual(common.frame.minX - add.frame.maxX, 4, accuracy: 1)
        XCTAssertEqual(shortcut.frame.minX, add.frame.minX, accuracy: 1)
        XCTAssertEqual(shortcut.frame.maxX, common.frame.maxX, accuracy: 1)
        XCTAssertEqual(common.value as? String, "已展开")
        let expandedShot = XCTAttachment(screenshot: app.screenshot())
        expandedShot.name = "search-common-tags-expanded"
        expandedShot.lifetime = .keepAlways
        self.add(expandedShot)
        common.tap()
        XCTAssertTrue(shortcut.waitForNonExistence(timeout: 5))
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
        XCTAssertFalse(shortcut.isEnabled)
        XCTAssertEqual(app.descendants(matching: .any)["compose.rule.match.language:english"].firstMatch.value as? String, "包含")
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == %@", "language:english")).count, 1)
    }

    func testRepeatedCandidateToggleAndExplicitRemovalImmediatelyUpdateCount() {
        let app = openTags()
        let candidate = app.buttons["tag.suggestion.language:english"], done = app.buttons["tag.confirm"]
        for _ in 0..<3 {
            tapCandidate(app); XCTAssertTrue(candidate.isSelected); XCTAssertEqual(done.label, "完成")
            tapCandidate(app); XCTAssertFalse(candidate.isSelected); XCTAssertEqual(done.label, "完成")
            XCTAssertFalse(done.isEnabled); XCTAssertFalse(app.buttons["tag.pending.remove.language:english"].exists)
        }
        tapCandidate(app)
        let remove = app.buttons["tag.pending.remove.language:english"]
        for _ in 0..<5 { if remove.isHittable { break }; app.swipeDown() }
        XCTAssertTrue(remove.isHittable); remove.tap()
        XCTAssertFalse(candidate.isSelected); XCTAssertEqual(done.label, "完成")
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
        XCTAssertTrue(app.searchComposerTitle("搜索").waitForExistence(timeout: 5)); app.buttons["compose.filters"].tap()
        XCTAssertTrue((app.buttons["compose.filters"].value as? String)?.contains("排除 language:english") == true)
        XCTAssertEqual(app.textFields["compose.text"].value as? String, "coast")
        XCTAssertFalse(app.buttons["discover.condition-summary"].exists)
        app.buttons["compose.apply"].tap()
        let result = app.buttons["discover.condition-summary"]
        XCTAssertTrue(result.waitForExistence(timeout: 6))
        XCTAssertTrue((result.value as? String)?.contains("排除 language:english") == true)
        app.buttons["discover.search-entry"].tap(); app.buttons["compose.records"].tap()
        XCTAssertTrue(app.staticTexts["搜索记录"].exists)
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "search-history.load.")).firstMatch
        XCTAssertTrue(row.label.contains("排除 language:english"))
    }
    func testCancelDiscardsPendingTagsAndKeepsParentConditions() {
        let app = openTags(); tapCandidate(app)
        app.buttons["tag.cancel"].tap()
        XCTAssertTrue(app.searchComposerTitle("搜索").waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["移除 language:english"].exists)
        app.buttons["compose.filters"].tap()
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
        XCTAssertTrue(favorite.isSelected); XCTAssertEqual(app.buttons["tag.confirm"].label, "完成")
        tapCandidate(app)
        XCTAssertFalse(favorite.isSelected); XCTAssertEqual(app.buttons["tag.confirm"].label, "完成")
        for _ in 0..<8 { if favorite.isHittable { break }; app.swipeUp() }
        favorite.tap(); favorite.tap()
        XCTAssertFalse(favorite.isSelected); XCTAssertEqual(app.buttons["tag.confirm"].label, "完成")
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
