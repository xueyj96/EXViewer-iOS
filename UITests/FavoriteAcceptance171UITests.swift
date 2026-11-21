import XCTest

final class FavoriteAcceptance171UITests: XCTestCase {
    private func detail(_ flags: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--qa", "--qa-reset-favorite-groups"] + flags
        app.launch()
        let gallery = app.buttons["gallery.open.1"]
        XCTAssertTrue(gallery.waitForExistence(timeout: 12)); gallery.tap()
        XCTAssertTrue(app.buttons["detail.site-favorite"].waitForExistence(timeout: 6))
        return app
    }

    func testConfirmedDirectAddAndRemoveRetainAccessibleActionAfterAsyncAcceptance() {
        let app = detail(), favorite = app.buttons["detail.site-favorite"]
        favorite.tap()
        expectation(for: NSPredicate(format: "label BEGINSWITH %@ AND value == %@", "取消收藏", ""), evaluatedWith: favorite)
        waitForExpectations(timeout: 6)
        XCTAssertTrue(favorite.isEnabled && favorite.isHittable)
        favorite.tap()
        expectation(for: NSPredicate(format: "label == %@ AND value == %@", "添加收藏", ""), evaluatedWith: favorite)
        waitForExpectations(timeout: 6)
        XCTAssertTrue(app.buttons["detail.read"].isHittable)
    }

    func testBackgroundFailureHasToastAndRetainsPendingIntent() {
        let app = detail(["--qa-favorite-unapplied"])
        let favorite = app.buttons["detail.site-favorite"]
        favorite.tap()
        expectation(for: NSPredicate(format: "value == %@", "同步失败"), evaluatedWith: favorite)
        waitForExpectations(timeout: 6)
        XCTAssertTrue(app.descendants(matching: .any)["detail.favorite-error"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(favorite.isHittable)
    }
}
