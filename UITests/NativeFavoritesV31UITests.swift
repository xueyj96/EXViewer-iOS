import XCTest

final class NativeFavoritesV31UITests: XCTestCase {
    private func detail(_ extra: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--qa"] + extra; app.launch()
        let card = app.buttons["gallery.open.1"]; XCTAssertTrue(card.waitForExistence(timeout: 12)); card.tap()
        XCTAssertTrue(app.buttons["detail.site-favorite"].waitForExistence(timeout: 8)); return app
    }
    private func openExistingEditor(_ app: XCUIApplication) {
        app.buttons["detail.site-favorite"].tap()
        let picker = app.descendants(matching: .any)["favorite.editor.group-picker"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 8))
        XCTAssertEqual(app.webViews.count, 0, "Routine favorite editing must use native controls")
    }
    private func openEditorFromManager(_ app: XCUIApplication) {
        XCTAssertTrue(app.descendants(matching: .any)["favorite.editor.group-picker"].firstMatch.waitForExistence(timeout: 8))
    }
    private func openGroupMenu(_ app: XCUIApplication) {
        app.descendants(matching: .any)["favorite.editor.group-picker"].firstMatch.tap()
        XCTAssertTrue(group(0, app: app).waitForExistence(timeout: 8))
    }
    private func group(_ index: Int, app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["favorite.editor.group.\(index)"].firstMatch
    }
    private func editorCount(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["favorite.editor.qa-counts"].firstMatch
    }
    private func waitForFavoriteLabel(_ app: XCUIApplication, containing text: String) {
        expectation(for: NSPredicate(format: "label CONTAINS %@", text), evaluatedWith: app.buttons["detail.site-favorite"])
        waitForExpectations(timeout: 8)
    }
    private func reveal(_ app: XCUIApplication, _ element: XCUIElement) {
        for _ in 0..<8 { if element.exists && element.isHittable { return }; app.swipeUp() }
        XCTAssertTrue(element.exists && element.isHittable)
    }
    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
    func testQuickAddUsesDefaultWithoutPickerAndLocalBookmarkRemainsIndependent() {
        let app = detail(["--qa-reset-favorite-groups", "--qa-favorite-save-delay"])
        let favorite = app.buttons["detail.site-favorite"]
        favorite.tap()
        XCTAssertTrue(favorite.waitForExistence(timeout: 5))
        XCTAssertFalse(group(0, app: app).exists, "Quick add must not open the picker")
        favorite.tap()
        XCTAssertTrue(app.descendants(matching: .any)["favorite.editor.group-picker"].firstMatch.waitForExistence(timeout: 5), "A pending favorite must open its full page editor")
        // The queue may already be confirmed by the time the manager finishes loading.
        app.buttons["favorite.editor.cancel"].tap()
        app.buttons["detail.more"].tap()
        let local = app.buttons["detail.local-bookmark"]; XCTAssertTrue(local.waitForExistence(timeout: 3)); local.tap()
        app.buttons["detail.more"].tap(); XCTAssertTrue(app.buttons["移出稍后再读"].waitForExistence(timeout: 3)); app.buttons["移出稍后再读"].tap()
        XCTAssertFalse(favorite.label.contains("添加收藏"), "The default favorite should remain queued or confirmed")
        screenshot(app, "native-favorite.quick-add-independent-local-bookmark")
    }
    func testNativeAddMoveAndConfirmedRemovalUpdateDetailState() {
        let app = detail(["--qa-favorite-existing"]); openExistingEditor(app)
        XCTAssertFalse(app.descendants(matching: .any)["favorite.editor.note"].firstMatch.exists, "Favorite editor should not expose a note field")
        openGroupMenu(app)
        group(1, app: app).tap()
        app.buttons["favorite.editor.save"].tap()
        XCTAssertTrue(app.buttons["detail.site-favorite"].waitForExistence(timeout: 6))
        waitForFavoriteLabel(app, containing: "待阅读")
        openExistingEditor(app)
        openGroupMenu(app)
        XCTAssertTrue(group(1, app: app).exists)
        let destination = group(2, app: app)
        for _ in 0..<8 { if destination.isHittable { break }; app.swipeDown() }
        XCTAssertTrue(destination.isHittable); destination.tap(); app.buttons["favorite.editor.save"].tap()
        XCTAssertTrue(app.buttons["detail.site-favorite"].waitForExistence(timeout: 6))
        waitForFavoriteLabel(app, containing: "已读"); screenshot(app, "native-favorite.saved-detail")
        app.buttons["detail.site-favorite"].tap()
        let remove = app.buttons["favorite.editor.remove"]; XCTAssertTrue(remove.waitForExistence(timeout: 5)); remove.tap()
        let confirm = app.alerts.buttons["favorite.editor.confirm-remove"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 4)); confirm.tap()
        XCTAssertTrue(app.buttons["detail.site-favorite"].waitForExistence(timeout: 6))
        waitForFavoriteLabel(app, containing: "添加收藏")
    }
    func testUnknownQuickAddCanBeCheckedFromReopenedManager() {
        let app = detail(["--qa-favorite-unknown", "--qa-reset-favorite-groups"])
        let favorite = app.buttons["detail.site-favorite"]
        favorite.tap()
        expectation(for: NSPredicate(format: "value CONTAINS %@", "结果待确认"), evaluatedWith: favorite)
        waitForExpectations(timeout: 8)
        favorite.tap()
        let check = app.descendants(matching: .any)["favorite.sync.check"].firstMatch
        XCTAssertTrue(check.waitForExistence(timeout: 6))
        XCTAssertTrue(app.descendants(matching: .any)["favorite.sync.status"].firstMatch.waitForExistence(timeout: 5))
        screenshot(app, "native-favorite.unknown-reopened-manager")
        check.tap()
        expectation(for: NSPredicate(format: "label CONTAINS %@", "默认"), evaluatedWith: favorite)
        waitForExpectations(timeout: 8)
    }
    func testLostPostResponseQuickAddIsReadBackAsConfirmed() {
        let app = detail(["--qa-favorite-post-lost", "--qa-reset-favorite-groups"])
        let favorite = app.buttons["detail.site-favorite"]
        favorite.tap()
        expectation(for: NSPredicate(format: "label CONTAINS %@", "默认"), evaluatedWith: favorite)
        waitForExpectations(timeout: 10)
    }
    func testFailedQuickAddCanBeRetriedFromReopenedManager() {
        let app = detail(["--qa-favorite-unapplied", "--qa-reset-favorite-groups"])
        let favorite = app.buttons["detail.site-favorite"]
        favorite.tap()
        XCTAssertTrue(favorite.waitForExistence(timeout: 6))
        favorite.tap()
        let retry = app.buttons["favorite.sync.retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 6))
        XCTAssertFalse(app.buttons["favorite.editor.save"].isEnabled)
    }
    func testExistingGroupHasCompactRowAndHeaderCancelRemainsReachableWithLargeType() {
        let app = detail(["--qa-favorite-existing", "--qa-dark", "--qa-large-type"]); openExistingEditor(app)
        let picker = app.descendants(matching: .any)["favorite.editor.group-picker"].firstMatch
        XCTAssertTrue(picker.exists); XCTAssertGreaterThanOrEqual(picker.frame.height, 36)
        openGroupMenu(app)
        group(2, app: app).tap()
        XCTAssertFalse(app.buttons["favorite.editor.save"].isEnabled)
        screenshot(app, "native-favorite.dark-large-groups")
        XCTAssertFalse(app.descendants(matching: .any)["favorite.editor.note"].firstMatch.exists)
        let cancel = app.buttons["favorite.editor.cancel"]
        XCTAssertTrue(cancel.isHittable); cancel.tap()
        XCTAssertTrue(app.buttons["detail.site-favorite"].waitForExistence(timeout: 6))
        waitForFavoriteLabel(app, containing: "已读")
    }
    func testInitialReadFailureOffersNativeReload() {
        let app = detail(["--qa-favorite-existing", "--qa-favorite-read-failure"]); app.buttons["detail.site-favorite"].tap()
        let reload = app.buttons["favorite.editor.refresh"]; XCTAssertTrue(reload.waitForExistence(timeout: 6)); reload.tap()
        let picker = app.descendants(matching: .any)["favorite.editor.group-picker"].firstMatch; XCTAssertTrue(picker.waitForExistence(timeout: 6)); openGroupMenu(app)
        XCTAssertTrue(group(0, app: app).waitForExistence(timeout: 6)); XCTAssertEqual(app.webViews.count, 0)
    }
    func testFavoriteListRefreshesAfterEditingFromAnotherTabAndFromItsOwnDetail() {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--qa", "--qa-favorite-sync-list"]; app.launch()
        XCTAssertTrue(app.buttons["main.tab.library"].waitForExistence(timeout: 12)); app.buttons["main.tab.library"].tap()
        app.buttons["library.scope.1"].tap()
        let empty = app.staticTexts["当前分组没有收藏结果。"]
        XCTAssertTrue(empty.waitForExistence(timeout: 6))
        app.buttons["main.tab.discover"].tap(); app.buttons["gallery.open.1"].tap()
        XCTAssertTrue(app.buttons["detail.site-favorite"].waitForExistence(timeout: 6))
        let favorite = app.buttons["detail.site-favorite"]
        favorite.tap()
        XCTAssertTrue(favorite.waitForExistence(timeout: 6))
        favorite.tap()
        openEditorFromManager(app)
        openGroupMenu(app)
        group(1, app: app).tap(); app.buttons["favorite.editor.save"].tap()
        XCTAssertTrue(app.buttons["detail.site-favorite"].waitForExistence(timeout: 6)); app.buttons["main.tab.library"].tap()
        let item = app.buttons["favorites.gallery.1"]; XCTAssertTrue(item.waitForExistence(timeout: 6)); item.tap()
        app.buttons["detail.site-favorite"].tap()
        let remove = app.buttons["favorite.editor.remove"]; XCTAssertTrue(remove.waitForExistence(timeout: 5)); remove.tap()
        let confirm = app.alerts.buttons["favorite.editor.confirm-remove"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 4)); confirm.tap()
        XCTAssertTrue(app.buttons["detail.site-favorite"].waitForExistence(timeout: 6)); app.buttons["BackButton"].tap()
        XCTAssertTrue(empty.waitForExistence(timeout: 6)); XCTAssertFalse(app.buttons["favorites.gallery.1"].exists)
    }
}
