import XCTest

final class TagSuggestionsV12UITests: XCTestCase {
    private func openComposer() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--qa", "--qa-reset-reader-preferences", "--qa-tags-offline"]
        app.launch()
        XCTAssertTrue(app.buttons["discover.search-entry"].waitForExistence(timeout: 12))
        app.buttons["discover.search-entry"].tap()
        XCTAssertTrue(app.searchComposerTitle("搜索").waitForExistence(timeout: 5))
        app.buttons["compose.filters"].tap()
        XCTAssertTrue(app.searchComposerTitle("搜索").waitForExistence(timeout: 5))
        let add = app.buttons["compose.add-tag"]
        for _ in 0..<5 { if add.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(add.isHittable)
        add.tap()
        XCTAssertTrue(app.staticTexts["添加标签"].waitForExistence(timeout: 5))
        app.selectTagNamespace("parody")
        return app
    }


    private func typePrefix(_ app: XCUIApplication) {
        let input = app.textFields["tag.name"]
        input.tap()
        input.typeText("pre")
        input.typeText("\n")
    }

    private func tapCandidate(_ app: XCUIApplication, id: String) {
        let candidate = app.buttons["tag.suggestion.\(id)"]
        // Form virtualizes off-screen rows; a broad prefix has up to20 results.
        // Exercise scrolling to the actual candidate rather than waiting for an
        // off-screen accessibility node that has not been materialized yet.
        for _ in 0..<8 {
            if candidate.exists && candidate.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(candidate.exists && candidate.isHittable, "Expected reachable dictionary candidate \(id)")
        XCTAssertTrue((candidate.value as? String ?? "").contains("词库匹配，站点未验证"))
        candidate.tap()
        XCTAssertTrue((candidate.value as? String ?? "").contains("已加入待添加"))
        XCTAssertTrue(app.staticTexts["添加标签"].exists)
    }

    func testSamePrefixCanSelectTwoCandidatesThenCompleteToComposerDraft() {
        let app = openComposer()
        typePrefix(app)
        tapCandidate(app, id: "parody:pretty cure")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "tag-suggestion-cards-light"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        let mode = app.buttons["tag.match.1"]
        for _ in 0..<8 { if mode.exists && mode.isHittable { break }; app.swipeDown() }
        XCTAssertTrue(mode.isHittable)
        XCTAssertEqual(app.textFields["tag.name"].value as? String, "pre", "Candidate selection must retain the original prefix")
        mode.tap()
        tapCandidate(app, id: "parody:pretty rhythm")
        XCTAssertEqual(app.buttons["tag.confirm"].label, "完成")

        app.buttons["tag.confirm"].tap()
        XCTAssertTrue(app.searchComposerTitle("搜索").waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["parody:pretty cure"].exists)
        XCTAssertTrue(app.staticTexts["parody:pretty rhythm"].exists)
        XCTAssertTrue(app.staticTexts["包含"].exists)
        XCTAssertTrue(app.staticTexts["任一"].exists)
        // Deliberately leave the composer open: tag selection edits only its draft.
    }

    func testCancelAfterSamePrefixMultiSelectLeavesComposerDraftEmpty() {
        let app = openComposer()
        typePrefix(app)
        tapCandidate(app, id: "parody:pretty cure")
        tapCandidate(app, id: "parody:pretty rhythm")
        app.buttons["tag.cancel"].tap()

        XCTAssertTrue(app.searchComposerTitle("搜索").waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["parody:pretty cure"].exists)
        XCTAssertFalse(app.staticTexts["parody:pretty rhythm"].exists)
        app.buttons["BackButton"].tap()
        app.buttons["compose.cancel"].tap()
    }

    func testMixedCaseInteriorFragmentAddsOriginalTagToComposer() {
        let app = openComposer()
        let input = app.textFields["tag.name"]
        input.tap()
        input.typeText("eTtY cU\n")
        tapCandidate(app, id: "parody:pretty cure")
        XCTAssertEqual(input.value as? String, "eTtY cU")
        XCTAssertEqual(app.buttons["tag.confirm"].label, "完成")
        app.buttons["tag.confirm"].tap()
        XCTAssertTrue(app.searchComposerTitle("搜索").waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["parody:pretty cure"].exists)
    }
}
