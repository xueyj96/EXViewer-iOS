import XCTest

final class FeedCacheV13UITests: XCTestCase {
    private func launch(_ app: XCUIApplication, runID: String, offline: Bool = false) {
        app.launchArguments = ["--qa", "--screen", "browse", "--qa-feed-cache", "--qa-feed-cache-run", runID]
        if offline { app.launchArguments.append("--qa-feed-cache-offline") }
        app.launch()
    }

    private func state(_ app: XCUIApplication, _ lane: String) -> XCUIElement {
        app.descendants(matching: .any)["feed.qa.state.\(lane)"]
    }

    private func waitForState(_ app: XCUIApplication, lane: String, contains value: String, timeout: TimeInterval = 12) {
        let element = state(app, lane)
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "Missing QA feed state for \(lane)")
        let predicate = NSPredicate(format: "value CONTAINS %@", value)
        expectation(for: predicate, evaluatedWith: element)
        waitForExpectations(timeout: timeout)
    }

    private func openFavorites(_ app: XCUIApplication) {
        app.buttons["main.tab.library"].tap()
        let scope = app.buttons["library.scope.1"]
        XCTAssertTrue(scope.waitForExistence(timeout: 8))
        scope.tap()
        XCTAssertTrue(app.staticTexts["QA Feed Favorites 01"].waitForExistence(timeout: 12))
    }

    private func refreshField(_ field: String, in element: XCUIElement) -> String? {
        let value = element.value as? String ?? ""
        return value.split(separator: ";").first { $0.hasPrefix(field + "=") }.map { String($0.dropFirst(field.count + 1)) }
    }

    private func assertVisiblePullAndReturn(_ app: XCUIApplication, lane: String, counter: String,
                                           firstCard: XCUIElement, header: XCUIElement) {
        let initialTop = firstCard.frame.minY
        let diagnostic = app.descendants(matching: .any)["feed.refresh.state"].firstMatch
        XCTAssertTrue(diagnostic.waitForExistence(timeout: 3))
        expectation(for: NSPredicate(format: "value CONTAINS %@", "attached=true"), evaluatedWith: diagnostic)
        waitForExpectations(timeout: 3)
        let priorShows = Int(refreshField("shows", in: diagnostic) ?? "0") ?? 0
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.28))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
        let indicator = app.descendants(matching: .any)["feed.refresh.indicator"].firstMatch
        // Capture before asserting so a missing/changed AX type still leaves visual evidence.
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "pull-refresh.\(lane).after-pull"; attachment.lifetime = .keepAlways; add(attachment)
        let matches = app.descendants(matching: .any).matching(identifier: "feed.refresh.indicator").allElementsBoundByIndex
        let types = matches.map { "type=\($0.elementType.rawValue);frame=\($0.frame)" }.joined(separator: "\n")
        let typeAttachment = XCTAttachment(string: "\(diagnostic.value ?? "missing diagnostic")\n\(types)")
        typeAttachment.name = "pull-refresh.\(lane).indicator-types"; typeAttachment.lifetime = .keepAlways; add(typeAttachment)
        // XCTest synchronizes the native gesture through refresh and return; inspect
        // actual rendered geometry events rather than sampling after that animation ended.
        expectation(for: NSPredicate { _, _ in
            (Int(self.refreshField("shows", in: diagnostic) ?? "0") ?? 0) > priorShows
        }, evaluatedWith: diagnostic)
        waitForExpectations(timeout: 3)
        let values = (refreshField("indicator", in: diagnostic) ?? "").split(separator: ",").compactMap { Double($0) }
        XCTAssertEqual(values.count, 4, "Missing actual indicator geometry: \(diagnostic.value ?? "")")
        guard values.count == 4 else { return }
        let shownFrame = CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
        XCTAssertGreaterThanOrEqual(shownFrame.height, 18)
        XCTAssertGreaterThan(shownFrame.width, 0)
        XCTAssertEqual(shownFrame.midX, app.frame.midX, accuracy: 2)
        XCTAssertGreaterThanOrEqual(shownFrame.minY, header.frame.maxY - 1)
        print("PULL_REFRESH_RENDERED_PHASE lane=\(lane);frame=\(shownFrame);state=\(diagnostic.value ?? ""); XCTest gesture returned after native refresh quiescence")
        waitForState(app, lane: lane == "favorites" ? "favorites" : "discover", contains: counter)
        waitForState(app, lane: lane == "favorites" ? "favorites" : "discover", contains: "loading=false;items=24")
        XCTAssertTrue(indicator.waitForNonExistence(timeout: 5))
        expectation(for: NSPredicate { _, _ in abs(firstCard.frame.minY - initialTop) <= 2 }, evaluatedWith: firstCard)
        waitForExpectations(timeout: 5)
    }

    func testLatestAndPopularPullRefreshOnceAndKeepFloatingBarsFixed() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--qa", "--screen", "browse", "--qa-feed-cache", "--qa-feed-cache-run", UUID().uuidString, "--qa-feed-cache-refresh-delay"]
        app.launch()
        waitForState(app, lane: "discover", contains: "loading=false;items=24", timeout: 15)
        let header = app.descendants(matching: .any)["discover.header.floating"].firstMatch
        let tab = app.buttons["main.tab.discover"]
        let headerFrame = header.frame, tabFrame = tab.frame
        for lane in 0...1 {
            if lane == 1 {
                app.buttons["discover.lane.1"].tap()
                waitForState(app, lane: "discover", contains: "popularRequests=1")
                waitForState(app, lane: "discover", contains: "loading=false;items=24")
            }
            assertVisiblePullAndReturn(app, lane: lane == 0 ? "latest" : "popular",
                                       counter: lane == 0 ? "latestRequests=2" : "popularRequests=2",
                                       firstCard: app.buttons["gallery.open.900001"], header: header)
            XCTAssertEqual(header.frame, headerFrame)
            XCTAssertEqual(tab.frame, tabFrame)
        }
    }

    func testFavoritesPullRefreshUsesTheSameVisibleIndicatorAndReturns() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--qa", "--screen", "browse", "--qa-feed-cache", "--qa-feed-cache-run", UUID().uuidString, "--qa-feed-cache-refresh-delay"]
        app.launch()
        XCTAssertTrue(app.buttons["main.tab.library"].waitForExistence(timeout: 12))
        openFavorites(app)
        waitForState(app, lane: "favorites", contains: "loading=false;items=24", timeout: 15)
        let header = app.descendants(matching: .any)["favorites.header.floating"].firstMatch
        let headerFrame = header.frame, tabFrame = app.buttons["main.tab.library"].frame
        assertVisiblePullAndReturn(app, lane: "favorites", counter: "favoriteRequests=2",
                                   firstCard: app.buttons["favorites.gallery.910001"], header: header)
        XCTAssertEqual(header.frame, headerFrame)
        XCTAssertEqual(app.buttons["main.tab.library"].frame, tabFrame)
    }

    func testDiskSnapshotShowsBeforeOfflineRevalidationForBothFeeds() {
        let runID = UUID().uuidString
        let app = XCUIApplication()
        launch(app, runID: runID)
        XCTAssertTrue(app.staticTexts["QA Feed Discover 01"].waitForExistence(timeout: 15))
        waitForState(app, lane: "discover", contains: "loading=false;items=24")
        openFavorites(app)
        waitForState(app, lane: "favorites", contains: "loading=false;items=24")

        app.terminate()
        launch(app, runID: runID, offline: true)
        XCTAssertTrue(app.staticTexts["QA Feed Discover 01"].waitForExistence(timeout: 8))
        waitForState(app, lane: "discover", contains: "cached=true;loading=true", timeout: 8)
        XCTAssertFalse(app.activityIndicators.matching(NSPredicate(format: "label == %@", "正在载入")).firstMatch.exists, "Cached search revalidation stays quiet")
        waitForState(app, lane: "discover", contains: "failure=true", timeout: 18)
        XCTAssertTrue((state(app, "discover").value as? String)?.contains("items=24") == true)
        XCTAssertTrue(app.staticTexts["QA Feed Discover 01"].exists, "Offline revalidation must retain cached rows")

        openFavorites(app)
        waitForState(app, lane: "favorites", contains: "cached=true;loading=true", timeout: 8)
        XCTAssertFalse(app.activityIndicators.matching(NSPredicate(format: "label == %@", "正在载入")).firstMatch.exists, "Cached favorites revalidation stays quiet")
        waitForState(app, lane: "favorites", contains: "failure=true", timeout: 18)
        XCTAssertTrue((state(app, "favorites").value as? String)?.contains("items=24") == true)
        XCTAssertTrue(app.staticTexts["QA Feed Favorites 01"].exists, "Favorites snapshot must survive failed revalidation")
    }

    func testEarlyPreloadAppendsOneDistinctSecondPage() {
        let app = XCUIApplication()
        launch(app, runID: UUID().uuidString)
        XCTAssertTrue(app.staticTexts["QA Feed Discover 01"].waitForExistence(timeout: 15))
        for _ in 0..<14 {
            if (state(app, "discover").value as? String)?.contains("items=48") == true { break }
            app.swipeUp()
        }
        waitForState(app, lane: "discover", contains: "items=48", timeout: 10)
        XCTAssertFalse(app.staticTexts["QA Feed Discover 24"].isHittable, "The next batch should arrive while the tail of the first page is still ahead")
        for _ in 0..<6 { if app.staticTexts["QA Feed Discover 25"].isHittable { break }; app.swipeUp() }
        XCTAssertTrue(app.staticTexts["QA Feed Discover 25"].waitForExistence(timeout: 8))
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == %@", "QA Feed Discover 25")).count, 1)
        waitForState(app, lane: "discover", contains: "items=48;next=false;failure=false")
    }
}
