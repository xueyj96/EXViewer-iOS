import XCTest

final class FavoriteSettingsUITests: XCTestCase {
    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }
    private func appWithDefaultReadingGroup() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--qa", "--qa-reset-favorite-groups"]
        app.launch()
        XCTAssertTrue(app.buttons["main.tab.account"].waitForExistence(timeout: 10)); app.buttons["main.tab.account"].tap()
        let settings = app.buttons["account.favorite-settings"]
        for _ in 0..<5 { if settings.isHittable { break }; app.swipeUp() }
        settings.tap()
        let group = app.buttons["favorite.settings.group.1"]
        XCTAssertTrue(group.waitForExistence(timeout: 8))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: group)
        waitForExpectations(timeout: 8)
        app.buttons["favorite.settings.default"].tap(); app.buttons["待阅读"].firstMatch.tap()
        app.buttons["BackButton"].tap(); app.buttons["main.tab.discover"].tap()
        XCTAssertTrue(app.buttons["gallery.open.1"].waitForExistence(timeout: 8))
        return app
    }
    func testReaderUsesSameDefaultWithoutOpeningGroupPickerAndDetailReflectsIt() {
        let app = appWithDefaultReadingGroup()
        app.buttons["gallery.open.1"].tap(); app.buttons["detail.read"].tap()
        ReaderSettingsUIHelpers.open(in: app)
        let favorite = app.buttons["reader.settings.site-favorite"]
        XCTAssertTrue(favorite.waitForExistence(timeout: 8)); favorite.tap()
        XCTAssertFalse(app.buttons["favorite.editor.save"].exists)
        expectation(for: NSPredicate(format: "value CONTAINS %@", "待阅读"), evaluatedWith: favorite)
        waitForExpectations(timeout: 8)
        favorite.tap()
        let cancel = app.buttons["favorite.editor.cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 8)); XCTAssertTrue(cancel.isHittable)
        cancel.tap()
        XCTAssertTrue(app.buttons["reader.close"].waitForExistence(timeout: 8)); app.buttons["reader.close"].tap()
        expectation(for: NSPredicate(format: "label CONTAINS %@", "待阅读"), evaluatedWith: app.buttons["detail.site-favorite"])
        waitForExpectations(timeout: 8)
    }
    func testDiscoverBatchUsesConfiguredDefaultWithoutPicker() {
        let app = appWithDefaultReadingGroup()
        app.buttons["gallery.open.1"].press(forDuration: 0.8)
        let favorite = app.buttons["discover.favorite"]
        XCTAssertTrue(favorite.waitForExistence(timeout: 5)); favorite.tap()
        XCTAssertFalse(app.buttons["favorite.batch.confirm"].exists)
        XCTAssertTrue(app.staticTexts["discover.feedback"].waitForExistence(timeout: 5))
        app.buttons["discover.exit"].tap(); app.buttons["gallery.open.1"].tap()
        expectation(for: NSPredicate(format: "label CONTAINS %@", "待阅读"), evaluatedWith: app.buttons["detail.site-favorite"])
        waitForExpectations(timeout: 8)
    }
    func testBackgroundToggleRetainsValueAcrossLaunchAndFitsLandscape() {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--qa"]
        app.launch(); LoadingSettingsUIHelpers.open(in: app)
        let toggle = app.switches["account.download.background"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 8))
        if toggle.value as? String == "1" {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
        }
        expectation(for: NSPredicate(format: "value == %@", "0"), evaluatedWith: toggle)
        waitForExpectations(timeout: 5)
        XCUIDevice.shared.orientation = .landscapeLeft
        for _ in 0..<4 { if toggle.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(toggle.isHittable)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "background-toggle.landscape"; shot.lifetime = .keepAlways; add(shot)
        XCUIDevice.shared.orientation = .portrait
        app.terminate(); app.launch(); LoadingSettingsUIHelpers.open(in: app)
        XCTAssertEqual(toggle.value as? String, "0")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
        expectation(for: NSPredicate(format: "value == %@", "1"), evaluatedWith: toggle)
        waitForExpectations(timeout: 5)
    }
    func testDefaultRenameAndDirectFavoriteUseFullPageManagement() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--qa", "--qa-reset-favorite-groups"]
        app.launch()
        XCTAssertTrue(app.buttons["main.tab.account"].waitForExistence(timeout: 10))
        app.buttons["main.tab.account"].tap()
        let settings = app.buttons["account.favorite-settings"]
        for _ in 0..<5 { if settings.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(settings.isHittable); settings.tap()
        let group = app.buttons["favorite.settings.group.1"]
        XCTAssertTrue(group.waitForExistence(timeout: 8))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: group)
        waitForExpectations(timeout: 8)
        group.tap()
        let field = app.textFields["favorite.settings.name"]
        let opened = field.waitForExistence(timeout: 5)
        let tree = XCTAttachment(string: app.debugDescription); tree.name = "inline.rename.tree"; tree.lifetime = .keepAlways; add(tree)
        let editorShot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); editorShot.name = "inline.rename.editor"; editorShot.lifetime = .keepAlways; add(editorShot)
        XCTAssertTrue(opened); field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 20) + "Draft")
        XCTAssertFalse(app.buttons["favorite.settings.group.2"].isEnabled)
        app.buttons["favorite.settings.cancel"].tap()
        XCTAssertTrue(group.label.contains("待阅读"))
        group.tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 20) + "Reading")
        app.buttons["favorite.settings.save"].tap()
        XCTAssertTrue(group.waitForExistence(timeout: 6))
        XCTAssertTrue(group.label.contains("Reading"))
        app.buttons["favorite.settings.default"].tap()
        app.buttons["Reading"].firstMatch.tap()
        app.buttons["BackButton"].tap()
        app.buttons["main.tab.discover"].tap()
        let card = app.buttons["gallery.open.1"]
        XCTAssertTrue(card.waitForExistence(timeout: 8)); card.tap()
        let favorite = app.buttons["detail.site-favorite"]
        XCTAssertTrue(favorite.waitForExistence(timeout: 8)); favorite.tap()
        XCTAssertFalse(app.buttons["favorite.editor.save"].exists)
        expectation(for: NSPredicate(format: "label CONTAINS %@", "Reading"), evaluatedWith: favorite)
        waitForExpectations(timeout: 8)
        favorite.tap()
        XCTAssertTrue(app.descendants(matching: .any)["favorite.editor.status"].firstMatch.waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["main.tab.discover"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "favorite.full-page-management"; shot.lifetime = .keepAlways; add(shot)
    }
}
