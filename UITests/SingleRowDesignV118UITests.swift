import XCTest

private enum FeedChromeMetrics { static let rowHeight: CGFloat = 44 }

final class SingleRowDesignV118UITests: XCTestCase {
    override func tearDown() { XCUIDevice.shared.orientation = .portrait; super.tearDown() }
    private func launch(_ flags: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(); app.launchArguments = ["--qa", "--qa-reset-favorite-groups", "--qa-tags-offline"] + flags
        app.launch(); XCTAssertTrue(app.buttons["main.tab.account"].waitForExistence(timeout: 10))
        return app
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
    private func rotate(_ orientation: UIDeviceOrientation, in app: XCUIApplication) {
        XCUIDevice.shared.orientation = orientation
        var previous: CGRect?
        let settled = NSPredicate { _, _ in
            let frame = app.frame
            guard (frame.width > frame.height) == orientation.isLandscape else { previous = nil; return false }
            defer { previous = frame }
            return previous == frame
        }
        expectation(for: settled, evaluatedWith: app)
        waitForExpectations(timeout: 8)
    }
    private func assertBars(_ app: XCUIApplication, header id: String, back: XCUIElement) {
        let header = app.descendants(matching: .any)[id].firstMatch
        let bottom = app.descendants(matching: .any)["main.tabs.compact"].firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 6)); XCTAssertTrue(bottom.exists)
        // The bottom accessibility container includes its outer layout insets;
        // the header identifier also includes its standard 44 pt hit area.
        XCTAssertEqual(header.frame.height, FeedChromeMetrics.rowHeight, accuracy: 1)
        XCTAssertLessThanOrEqual(bottom.frame.height, 50)
        XCTAssertGreaterThanOrEqual(header.frame.minX, bottom.frame.minX - 1)
        XCTAssertLessThanOrEqual(header.frame.maxX, bottom.frame.maxX + 1)
        XCTAssertEqual(back.frame.width, 34, accuracy: 0.75)
        XCTAssertEqual(back.frame.height, 44, accuracy: 0.75)
        XCTAssertTrue(back.isHittable)
    }
    func testAccountPagesShareSingleRowBarAndSquareActionsInBothOrientations() {
        let app = launch(["--qa-account-status-preview"])
        app.buttons["main.tab.account"].tap()
        let pages = [("login-management", "login-page"), ("tags", "tags-page"), ("favorite-settings", "favorite.settings"),
                     ("favorite-sync", "favorite-sync-page"), ("storage", "storage-page"), ("quota", "quota-page"), ("sponsorship", "sponsorship-page")]
        for (route, page) in pages {
            let entry = app.buttons["account.\(route)"]
            for _ in 0..<8 { if entry.isHittable { break }; app.swipeUp() }
            if !entry.isHittable { app.swipeDown(); app.swipeDown() }
            XCTAssertTrue(entry.isHittable); entry.tap()
            let header = page == "favorite.settings" ? "favorite.settings.header" : "account.\(page).header"
            for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
                rotate(orientation, in: app)
                let back = app.buttons["BackButton"]
                assertBars(app, header: header, back: back)
                capture(app, "single-row.\(route).\(orientation.isLandscape ? "landscape" : "portrait")")
            }
            rotate(.portrait, in: app)
            app.buttons["BackButton"].tap()
            XCTAssertTrue(app.descendants(matching: .any)["account.title"].firstMatch.waitForExistence(timeout: 6))
        }
    }
    func testFavoriteManagementIsOnePageWithoutNotesAndRemovalNeedsOnlyOneAlert() {
        let app = launch(["--qa-favorite-existing", "--qa-dark"])
        app.buttons["gallery.open.1"].tap(); app.buttons["detail.site-favorite"].tap()
        let picker = app.buttons["favorite.editor.group-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["favorite.editor.edit"].exists)
        XCTAssertFalse(app.textFields["favorite.editor.note"].exists)
        let groupTitle = app.staticTexts["favorite.editor.group-title"]
        XCTAssertTrue(groupTitle.exists)
        XCTAssertLessThan(groupTitle.frame.maxX, picker.frame.minX)
        groupTitle.tap()
        XCTAssertFalse(app.descendants(matching: .any)["favorite.editor.group.0"].firstMatch.exists,
                       "The readonly group title must not open the menu")
        picker.tap()
        let currentGroup = app.descendants(matching: .any)["favorite.editor.group.2"].firstMatch
        XCTAssertTrue(currentGroup.waitForExistence(timeout: 5)); currentGroup.tap()
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            rotate(orientation, in: app)
            assertBars(app, header: "favorite.editor.header", back: app.buttons["favorite.editor.cancel"])
            XCTAssertEqual(app.buttons["favorite.editor.save"].frame.width, 34, accuracy: 0.75)
            capture(app, "single-row.favorite-manager.\(orientation.isLandscape ? "landscape" : "portrait")")
        }
        rotate(.portrait, in: app)
        let remove = app.buttons["favorite.editor.remove"]
        var previousFrame: CGRect?
        let settled = NSPredicate { _, _ in
            guard app.frame.height > app.frame.width, remove.isHittable else { previousFrame = nil; return false }
            let frame = remove.frame
            defer { previousFrame = frame }
            return previousFrame == frame
        }
        expectation(for: settled, evaluatedWith: app)
        waitForExpectations(timeout: 6)
        remove.tap()
        XCTAssertTrue(app.alerts.buttons["favorite.editor.confirm-remove"].firstMatch.waitForExistence(timeout: 5))
        capture(app, "single-row.favorite-removal-alert")
        app.alerts.buttons["保留收藏"].firstMatch.tap()
        XCTAssertTrue(picker.isHittable)
        app.buttons["favorite.editor.cancel"].tap()
        XCTAssertTrue(app.buttons["detail.site-favorite"].waitForExistence(timeout: 5))
    }
    func testComposerAndTagEntryUseSquareActionsAndKeepBottomBar() {
        let app = launch()
        app.buttons["discover.search-entry"].tap()
        XCTAssertTrue(app.textFields["compose.text"].waitForExistence(timeout: 6))
        assertBars(app, header: "compose.header", back: app.buttons["compose.cancel"])
        XCTAssertEqual(app.buttons["compose.apply"].frame.width, 34, accuracy: 0.75)
        app.buttons["compose.filters"].tap()
        let add = app.buttons["compose.add-tag"]
        for _ in 0..<6 { if add.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(add.isHittable); add.tap()
        XCTAssertTrue(app.textFields["tag.name"].waitForExistence(timeout: 6))
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            rotate(orientation, in: app)
            assertBars(app, header: "tag.header", back: app.buttons["tag.cancel"])
            XCTAssertEqual(app.buttons["tag.confirm"].frame.width, 34, accuracy: 0.75)
            capture(app, "single-row.tag-entry.\(orientation.isLandscape ? "landscape" : "portrait")")
        }
        app.buttons["tag.cancel"].tap(); app.buttons["compose.cancel"].tap()
    }
}
