import XCTest

final class ReaderSettingsFullPageUITests: XCTestCase {
    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }

    func testSettingsFullPageBackFavoriteRoundTripAndRotation() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--qa", "--qa-reset-favorite-groups"]
        app.launch()

        XCTAssertTrue(app.buttons["main.tab.account"].waitForExistence(timeout: 10))
        app.buttons["main.tab.account"].tap()
        let favoriteSettings = app.buttons["account.favorite-settings"]
        for _ in 0..<5 where !favoriteSettings.isHittable { app.swipeUp() }
        XCTAssertTrue(favoriteSettings.isHittable)
        favoriteSettings.tap()
        let group = app.buttons["favorite.settings.group.1"]
        XCTAssertTrue(group.waitForExistence(timeout: 8))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: group)
        waitForExpectations(timeout: 8)
        app.buttons["favorite.settings.default"].tap()
        app.buttons["待阅读"].firstMatch.tap()
        app.buttons["BackButton"].tap()
        app.buttons["main.tab.discover"].tap()

        let gallery = app.buttons["gallery.open.1"]
        XCTAssertTrue(gallery.waitForExistence(timeout: 8))
        gallery.tap()
        let read = app.buttons["detail.read"]
        XCTAssertTrue(read.waitForExistence(timeout: 8))
        read.tap()
        let page = app.buttons["reader.page"]
        XCTAssertTrue(page.waitForExistence(timeout: 12))
        let originalPage = page.label

        app.buttons["reader.settings"].tap()
        let header = app.descendants(matching: .any)["reader.settings-page.header"].firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["reader.settings.back"].isHittable)
        XCTAssertLessThan(header.frame.minY, app.frame.height * 0.2, "Settings header should be at the page top, not in a lower sheet")
        XCTAssertFalse(page.exists, "The underlying reader should be hidden from accessibility while settings is open")
        XCTAssertTrue(app.buttons["main.tab.discover"].exists, "The fixed main tab bar remains hosted by the settings page")

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["reader.settings.back"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["reader.settings.direction.leftToRight"].exists)
        XCUIDevice.shared.orientation = .portrait

        let favorite = app.buttons["reader.settings.site-favorite"]
        XCTAssertTrue(favorite.waitForExistence(timeout: 5))
        favorite.tap()
        expectation(for: NSPredicate(format: "value CONTAINS %@", "待阅读"), evaluatedWith: favorite)
        waitForExpectations(timeout: 8)
        favorite.tap()
        expectation(for: NSPredicate(format: "label == %@", "添加收藏"), evaluatedWith: favorite)
        waitForExpectations(timeout: 8)
        XCTAssertFalse(app.buttons["favorite.editor.cancel"].exists)
        XCTAssertTrue(app.buttons["reader.settings.back"].isHittable)

        app.buttons["reader.settings.back"].tap()
        XCTAssertTrue(page.waitForExistence(timeout: 8))
        XCTAssertEqual(page.label, originalPage, "Returning from settings must keep the reader and its current page mounted")
    }
}
