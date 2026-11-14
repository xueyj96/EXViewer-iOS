import XCTest

final class Chrome128UITests: XCTestCase {
    override func tearDown() { XCUIDevice.shared.orientation = .portrait; super.tearDown() }
    private func launch() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--qa", "--qa-tags-offline", "--qa-reader-many", "--qa-reader-transition", "--qa-reset-reader-preferences"]
        app.launch()
        XCTAssertTrue(app.buttons["gallery.open.1"].waitForExistence(timeout: 10))
        return app
    }
    private func edge(_ app: XCUIApplication, left: Bool, fraction: CGFloat) {
        let start = app.coordinate(withNormalizedOffset: .init(dx: left ? 0.005 : 0.995, dy: 0.55))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(.init(dx: (left ? 1 : -1) * app.frame.width * fraction, dy: 0)), withVelocity: .slow, thenHoldForDuration: 0.2)
    }
    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }
    func testDetailBothEdgesReturnAndShortPullReboundsWithFixedBars() {
        let app = launch()
        for left in [false, true] {
            app.buttons["gallery.open.1"].tap()
            let card = app.descendants(matching: .any)["detail.info-card"].firstMatch
            XCTAssertTrue(app.buttons["detail.read"].waitForExistence(timeout: 5))
            let header = app.descendants(matching: .any)["detail.header.floating"].firstMatch
            let tab = app.buttons["main.tab.discover"]
            let headerFrame = header.frame, tabFrame = tab.frame
            let cardX = card.exists ? card.frame.minX : 0
            edge(app, left: left, fraction: 0.08)
            XCTAssertTrue(app.buttons["detail.read"].exists)
            XCTAssertEqual(header.frame, headerFrame)
            XCTAssertEqual(tab.frame, tabFrame)
            if card.exists { XCTAssertEqual(card.frame.minX, cardX, accuracy: 1) }
            let previewGeometry = app.staticTexts["page.edge.qa"].value as? String ?? ""
            print("DETAIL_PREVIEW_GEOMETRY", previewGeometry)
            XCTAssertTrue(previewGeometry.contains("previewScale=1.000,1.000"), "Preview must preserve source scale: \(previewGeometry)")
            shot("detail128.rebound.\(left)")
            edge(app, left: left, fraction: 0.65)
            XCTAssertTrue(app.buttons["gallery.open.1"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["detail.read"].exists)
        }
    }
    func testReaderSquareCapsCenteredTitleImmersionAndFullPageDetailRoundTrip() {
        let app = launch()
        app.buttons["gallery.open.1"].tap(); app.buttons["detail.read"].tap()
        let page = app.buttons["reader.page"], more = app.buttons["reader.settings"]
        XCTAssertTrue(page.waitForExistence(timeout: 8))
        XCTAssertEqual(page.frame.width, more.frame.width, accuracy: 1)
        XCTAssertEqual(page.frame.height, more.frame.height, accuracy: 1)
        let slider = app.sliders["reader.progress"]
        XCTAssertLessThan(page.frame.maxX, slider.frame.minX)
        XCTAssertLessThan(slider.frame.maxX, more.frame.minX)
        let header = app.descendants(matching: .any)["reader.header"].firstMatch
        XCTAssertEqual(app.staticTexts["reader.title"].frame.midX, header.frame.midX, accuracy: 1)
        let initial = page.label
        shot("reader128.square-footer")
        app.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5)).doubleTap()
        XCTAssertTrue(header.exists)
        XCTAssertEqual(page.label, initial)
        XCTAssertFalse(app.descendants(matching: .any)["reader.details"].firstMatch.exists)
        app.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5)).press(forDuration: 0.7)
        XCTAssertTrue(header.waitForNonExistence(timeout: 4))
        app.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5)).doubleTap()
        XCTAssertFalse(header.exists)
        app.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(header.waitForExistence(timeout: 4))
        app.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(header.waitForNonExistence(timeout: 4))
        app.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(header.waitForExistence(timeout: 4))
        for left in [false, true] {
            app.buttons["reader.details.open"].tap()
            let details = app.descendants(matching: .any)["reader.details"].firstMatch
            XCTAssertTrue(details.waitForExistence(timeout: 5))
            XCTAssertGreaterThan(details.frame.height, app.frame.height * 0.9)
            XCTAssertTrue(app.buttons["main.tab.library"].exists)
            shot("reader128.full-detail.\(left)")
            edge(app, left: left, fraction: 0.65)
            XCTAssertTrue(details.waitForNonExistence(timeout: 5))
            XCTAssertEqual(page.label, initial)
        }
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(more.waitForExistence(timeout: 4))
        XCTAssertEqual(page.frame.width, more.frame.width, accuracy: 1)
        shot("reader128.footer.landscape")
    }
    func testReaderDetailMainTabReturnsToSelectedDestination() {
        let app = launch()
        app.buttons["gallery.open.1"].tap(); app.buttons["detail.read"].tap()
        XCTAssertTrue(app.buttons["reader.details.open"].waitForExistence(timeout: 8))
        app.buttons["reader.details.open"].tap()
        XCTAssertTrue(app.buttons["main.tab.library"].waitForExistence(timeout: 5))
        app.buttons["main.tab.library"].tap()
        XCTAssertTrue(app.buttons["library.scope.0"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["reader.page"].exists)
    }
    func testTagPageBackgroundContinuesThroughBothSafeAreas() {
        let app = launch(); app.buttons["main.tab.account"].tap()
        let tags = app.buttons["account.tags"]
        for _ in 0..<4 { if tags.isHittable { break }; app.swipeUp() }
        tags.tap()
        XCTAssertTrue(app.textFields["tags.search"].waitForExistence(timeout: 5))
        shot("tags128.safe-area-background")
    }
    func testReaderBothEdgesReboundThenExitInPortraitAndLandscape() {
        let app = launch()
        app.buttons["gallery.open.1"].tap()
        var expectedPage: String?
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            let read = app.buttons["detail.read"]
            expectation(for: NSPredicate { _, _ in
                orientation == .portrait ? read.frame.width < 180 : read.frame.width > 180
            }, evaluatedWith: read)
            waitForExpectations(timeout: 5)
            for left in [true, false] {
                app.buttons["detail.read"].tap()
                let page = app.buttons["reader.page"]
                XCTAssertTrue(page.waitForExistence(timeout: 8))
                let edgeState = app.descendants(matching: .any)["reader.edge.qa"].firstMatch
                XCTAssertTrue((edgeState.value as? String ?? "").contains("extent=\(Int(app.frame.width))"))
                let before = page.label
                if let expectedPage { XCTAssertEqual(before, expectedPage) }
                else { expectedPage = before }
                let header = app.descendants(matching: .any)["reader.header"].firstMatch
                let headerFrame = header.frame, pageFrame = page.frame
                edge(app, left: left, fraction: 0.08)
                print("READER_EDGE_DIAGNOSTIC \(app.descendants(matching: .any)["reader.edge.qa"].firstMatch.value ?? "missing")")
                XCTAssertTrue(page.exists)
                XCTAssertEqual(page.label, before)
                XCTAssertEqual(header.frame.minX, headerFrame.minX, accuracy: 1)
                XCTAssertEqual(page.frame.minX, pageFrame.minX, accuracy: 1)
                shot("reader129.rebound.\(orientation.rawValue).\(left)")
                edge(app, left: left, fraction: 0.65)
                let diagnostic = app.descendants(matching: .any)["reader.edge.qa"].firstMatch
                if diagnostic.exists { print("READER_EDGE_AFTER_COMMIT \(diagnostic.value ?? "missing")") }
                XCTAssertTrue(page.waitForNonExistence(timeout: 5))
                XCTAssertTrue(app.buttons["detail.read"].waitForExistence(timeout: 5))
                XCTAssertTrue(app.buttons["main.tab.discover"].exists)
            }
        }
        app.buttons["detail.read"].tap()
        let back = app.buttons["reader.close"]
        XCTAssertTrue(back.waitForExistence(timeout: 8))
        XCTAssertEqual(back.label, "返回")
        back.tap()
        XCTAssertTrue(back.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["detail.read"].exists)
    }

    // Four-channel design supersedes the old neutral latest/popular header.
    func testSearchResultsReturnToLatestAndRestoreWithinSearchChannel() {
        let app = launch()
        app.buttons["discover.lane.3"].tap()
        app.buttons["discover.search-entry"].tap()
        let text = app.textFields["compose.text"]
        XCTAssertTrue(text.waitForExistence(timeout: 5)); text.tap(); text.typeText("coast")
        app.buttons["compose.apply"].tap()
        let entry = app.buttons["discover.search-entry"]
        expectation(for: NSPredicate(format: "value CONTAINS %@", "coast"), evaluatedWith: entry)
        waitForExpectations(timeout: 5)
        XCTAssertFalse(app.buttons["discover.condition-summary"].exists)
        XCTAssertTrue(app.buttons["discover.lane.3"].isSelected)
        for index in 0...2 { XCTAssertFalse(app.buttons["discover.lane.\(index)"].isSelected) }
        XCTAssertEqual(entry.frame.midY, app.buttons["discover.saved-menu"].frame.midY, accuracy: 1)
        app.buttons["discover.lane.0"].tap()
        XCTAssertTrue(entry.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["discover.lane.0"].isSelected)
        app.buttons["discover.lane.3"].tap()
        expectation(for: NSPredicate(format: "value CONTAINS %@", "coast"), evaluatedWith: entry)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(app.buttons["discover.lane.3"].isSelected)
    }

}
