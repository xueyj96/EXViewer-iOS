import XCTest

final class FeedStatusV122UITests: XCTestCase {
    override func tearDown() { XCUIDevice.shared.orientation = .portrait; super.tearDown() }

    private func launch(_ flags: [String]) -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--qa", "--qa-dark", "--qa-feed-cache", "--qa-feed-cache-run", UUID().uuidString] + flags
        app.launch()
        XCTAssertTrue(app.buttons["main.tab.library"].waitForExistence(timeout: 10))
        return app
    }

    private func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }

    private func rotate(_ app: XCUIApplication, orientation: UIDeviceOrientation = .landscapeLeft) {
        XCUIDevice.shared.orientation = orientation
        var previous: CGRect?
        let settled = NSPredicate { _, _ in
            let frame = app.frame
            guard (frame.width > frame.height) == orientation.isLandscape else { return false }
            defer { previous = frame }
            return frame == previous
        }
        expectation(for: settled, evaluatedWith: app); waitForExpectations(timeout: 8)
    }

    private func assertBetweenBars(_ element: XCUIElement, app: XCUIApplication) {
        XCTAssertTrue(element.waitForExistence(timeout: 8))
        XCTAssertGreaterThan(element.frame.minY, app.frame.minY + 80)
        let bottom = app.descendants(matching: .any)["main.tabs.compact"].firstMatch
        XCTAssertLessThan(element.frame.maxY, bottom.frame.minY)
    }

    func testEmptyWorkListsUsePlainCenteredTextAcrossLibraryScopes() {
        let app = launch(["--qa-feed-cache-empty"])
        app.buttons["main.tab.library"].tap()
        for scope in [0, 1, 2, 3] {
            app.buttons["library.scope.\(scope)"].tap()
            let empty = app.staticTexts["无作品"].firstMatch
            assertBetweenBars(empty, app: app)
            XCTAssertEqual(empty.frame.midX, app.frame.midX, accuracy: 1)
            XCTAssertGreaterThan(empty.frame.midY, app.frame.height * 0.4)
            XCTAssertLessThan(empty.frame.midY, app.frame.height * 0.7)
            capture("empty.scope.\(scope).portrait")
        }
        rotate(app)
        assertBetweenBars(app.staticTexts["无作品"].firstMatch, app: app)
        capture("empty.downloads.landscape")
    }

    func testColdLoadingAndRequestFailureStayInsideContentArea() {
        var app = launch(["--qa-feed-cache-slow"])
        let spinner = app.activityIndicators.matching(NSPredicate(format: "label == %@", "正在载入")).firstMatch
        assertBetweenBars(spinner, app: app)
        XCTAssertLessThanOrEqual(spinner.frame.height, 24)
        XCTAssertFalse(app.staticTexts["无作品"].exists)
        capture("request.loading.portrait")
        app.terminate()
        app = launch(["--qa-feed-cache-failure"])
        let retry = app.buttons["重试"].firstMatch
        XCTAssertTrue(retry.waitForExistence(timeout: 18))
        assertBetweenBars(retry, app: app)
        XCTAssertFalse(app.staticTexts["无作品"].exists)
        capture("request.failure.portrait")
        rotate(app)
        assertBetweenBars(retry, app: app)
        capture("request.failure.landscape")
    }

    func testExpiredLoginShowsAuthenticationFailureWithoutPretendingTheListIsEmpty() {
        let app = launch(["--qa-feed-cache-login-expired"])
        let message = app.staticTexts["会话需要重新验证，请在官方网页完成登录。"]
        assertBetweenBars(message, app: app)
        XCTAssertTrue(app.buttons["重试"].firstMatch.isHittable)
        XCTAssertFalse(app.staticTexts["无作品"].exists)
        capture("login.expired.portrait")
    }

    private func assertLoginIsFullPage(_ app: XCUIApplication) {
        let header = app.descendants(matching: .any)["official-web.header"].firstMatch
        let bottom = app.descendants(matching: .any)["main.tabs.compact"].firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 8))
        XCTAssertTrue(bottom.exists)
        XCTAssertTrue(app.buttons["main.tab.account"].isHittable)
        XCTAssertEqual(header.frame.height, 44, accuracy: 1)
        XCTAssertEqual(header.frame.minX, bottom.frame.minX, accuracy: 1)
        XCTAssertEqual(header.frame.width, bottom.frame.width, accuracy: 1)
        let web = app.webViews.firstMatch
        XCTAssertGreaterThanOrEqual(web.frame.minY, header.frame.maxY)
        XCTAssertEqual(web.frame.maxY, bottom.frame.minY, accuracy: 1)
        XCTAssertTrue(app.buttons["official-web.close"].isHittable)
        let complete = app.buttons["完成登录"]
        XCTAssertTrue(complete.isHittable)
        XCTAssertLessThanOrEqual(complete.frame.maxY, bottom.frame.minY - 4)
        XCTAssertEqual(complete.frame.width, app.buttons["official-web.close"].frame.width, accuracy: 1)
        XCTAssertEqual(complete.frame.midY, app.buttons["official-web.close"].frame.midY, accuracy: 1)
    }

    func testBothLoginEntrancesOpenTheSameOfficialWebContainer() {
        let app = launch(["--qa-feed-cache-empty", "--qa-favorites-login-required"])
        app.buttons["main.tab.library"].tap()
        app.buttons["library.scope.1"].tap()
        app.buttons["打开官方登录页"].tap()
        let close = app.buttons["official-web.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["forums.e-hentai.org"].exists)
        XCTAssertTrue(app.staticTexts["子页面兼容检查通过"].waitForExistence(timeout: 12))
        assertLoginIsFullPage(app)
        capture("login.full-page.from-favorites.portrait")
        rotate(app)
        assertLoginIsFullPage(app)
        capture("login.full-page.from-favorites.landscape")
        rotate(app, orientation: .portrait)
        let field = app.webViews.textFields["网页测试输入"]
        field.tap(); field.typeText("draft-check")
        app.buttons["main.tab.account"].tap()
        app.buttons["main.tab.library"].tap()
        XCTAssertTrue(close.waitForExistence(timeout: 8))
        XCTAssertEqual(field.value as? String, "draft-check", "Switching tabs must preserve the entered web form")
        close.tap()
        XCTAssertTrue(app.buttons["打开官方登录页"].waitForExistence(timeout: 8))
        app.buttons["main.tab.account"].tap()
        app.buttons["account.login-management"].tap()
        XCTAssertTrue(app.buttons["account.login-page.action"].waitForExistence(timeout: 8))
        app.buttons["account.login-page.action"].tap()
        XCTAssertTrue(close.waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["forums.e-hentai.org"].exists)
        XCTAssertTrue(app.staticTexts["子页面兼容检查通过"].waitForExistence(timeout: 12))
        assertLoginIsFullPage(app)
        capture("login.full-page.from-settings.portrait")
        rotate(app)
        assertLoginIsFullPage(app)
        capture("login.full-page.from-settings.landscape")
        rotate(app, orientation: .portrait)
        close.tap()
        XCTAssertTrue(app.buttons["account.login-page.action"].waitForExistence(timeout: 8))
    }

    func testLoginRequiredHasReachableActionAndIsNotAnEmptyList() {
        let app = launch(["--qa-feed-cache-empty", "--qa-favorites-login-required"])
        app.buttons["main.tab.library"].tap()
        app.buttons["library.scope.1"].tap()
        let login = app.buttons["打开官方登录页"]
        assertBetweenBars(login, app: app)
        XCTAssertTrue(login.isHittable)
        XCTAssertFalse(app.staticTexts["无作品"].exists)
        capture("login.required.portrait")
        rotate(app)
        assertBetweenBars(login, app: app)
        XCTAssertTrue(login.isHittable)
        capture("login.required.landscape")
    }
}
