import XCTest

final class FavoriteSyncV53UITests: XCTestCase {
    private func detail(_ flags: [String]) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--qa", "--qa-favorite-counters"] + flags; app.launch()
        XCTAssertTrue(app.buttons["gallery.open.1"].waitForExistence(timeout: 12)); app.buttons["gallery.open.1"].tap()
        XCTAssertTrue(app.buttons["detail.site-favorite"].waitForExistence(timeout: 6)); return app
    }
    private func open(_ app: XCUIApplication) {
        app.buttons["detail.site-favorite"].tap()
        XCTAssertTrue(app.buttons["favorite.editor.group.0"].waitForExistence(timeout: 6))
    }
    func testSlowSubmissionDismissesImmediatelyAndReadingRemainsAvailable() {
        let app = detail(["--qa-favorite-save-delay"]); open(app)
        app.buttons["favorite.editor.group.1"].tap(); app.buttons["favorite.editor.save"].tap()
        XCTAssertTrue(app.buttons["detail.site-favorite"].waitForExistence(timeout: 1.2))
        XCTAssertEqual(app.buttons["detail.site-favorite"].label, "站点收藏，待阅读")
        XCTAssertFalse((app.buttons["detail.site-favorite"].value as? String ?? "").isEmpty)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "favorite53.immediate-local-state"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["在线阅读"].tap()
        XCTAssertTrue(app.buttons["reader.page"].waitForExistence(timeout: 6))
    }
    func testUnknownResultHasCheckActionAndNeverRequiresResubmitting() {
        let app = detail(["--qa-favorite-unknown"]); open(app)
        app.buttons["favorite.editor.group.3"].tap(); app.buttons["favorite.editor.save"].tap()
        let status = app.buttons["detail.site-favorite"]
        XCTAssertTrue(status.waitForExistence(timeout: 6))
        expectation(for: NSPredicate(format: "value == %@", "结果待确认"), evaluatedWith: status)
        waitForExpectations(timeout: 6)
        status.tap()
        let check = app.buttons["favorite.sync.check"]; XCTAssertTrue(check.waitForExistence(timeout: 6))
        let save = app.buttons["favorite.editor.save"]
        XCTAssertFalse(save.exists && save.isEnabled)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "favorite53.check-uncertain-result"; shot.lifetime = .keepAlways; add(shot)
        check.tap()
        XCTAssertTrue(app.buttons["detail.site-favorite"].waitForExistence(timeout: 6))
        XCTAssertTrue(app.buttons["detail.site-favorite"].label.contains("画集"))
    }
}
