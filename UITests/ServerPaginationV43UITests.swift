import XCTest

final class ServerPaginationV43UITests: XCTestCase {
    func testKeywordAndRatingFiltersKeepLaterHigherRatedPagesInForwardBrowsingOrder() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--qa", "--qa-tags-offline", "--qa-feed-cache", "--qa-feed-sort-regression",
                               "--qa-feed-cache-run", "server43-\(UUID().uuidString)"]
        app.launch()
        let state = app.descendants(matching: .any)["feed.qa.state.discover"].firstMatch
        XCTAssertTrue(state.waitForExistence(timeout: 12))
        expectation(for: NSPredicate(format: "value CONTAINS %@", "items=24"), evaluatedWith: state)
        waitForExpectations(timeout: 8)
        app.buttons["discover.search-entry"].tap()
        let text = app.textFields["compose.text"]
        XCTAssertTrue(text.waitForExistence(timeout: 5)); text.tap()
        text.typeText("coast language:chinese -other:watercolor")
        app.buttons["compose.filters"].tap()
        let rating = app.buttons["compose.min-rating"]
        XCTAssertTrue(app.navigationBars["筛选条件"].waitForExistence(timeout: 5))
        for _ in 0..<8 { if rating.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(rating.isHittable); rating.tap(); app.buttons["3 星"].firstMatch.tap()
        app.buttons["compose.apply"].tap()
        XCTAssertTrue(app.buttons["discover.condition-summary"].waitForExistence(timeout: 5))
        for _ in 0..<28 {
            if (state.value as? String)?.contains("items=72") == true { break }
            app.swipeUp()
        }
        XCTAssertTrue((state.value as? String)?.contains("items=72") == true)
        XCTAssertTrue((state.value as? String)?.contains("next=false") == true)
        XCTAssertTrue((state.value as? String)?.contains("failure=false") == true)
        // The third batch has the highest scores. It must be encountered below
        // the earlier batches, instead of being inserted above the reader.
        let later = app.buttons["gallery.open.900049"]
        let header = app.descendants(matching: .any)["discover.header.floating"].firstMatch
        let tab = app.buttons["main.tab.discover"]
        var trace: [String] = []
        func fullyVisible(_ card: XCUIElement) -> Bool {
            card.isHittable && card.frame.minY >= header.frame.maxY && card.frame.maxY < tab.frame.minY
        }
        for _ in 0..<12 {
            let frame = later.exists ? later.frame : .zero
            trace.append("card=\(frame);header=\(header.frame);tab=\(tab.frame);hittable=\(later.isHittable)")
            if fullyVisible(later) { break }
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65))
            let direction: CGFloat = later.exists && frame.minY < header.frame.maxY ? 0.2 : -0.2
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65 + direction))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        let geometry = XCTAttachment(string: trace.joined(separator: "\n")); geometry.name = "search43.later-card-visible-geometry"; geometry.lifetime = .keepAlways; add(geometry)
        let forward = XCTAttachment(screenshot: app.screenshot()); forward.name = "search43.higher-rated-later-batch-visible"; forward.lifetime = .keepAlways; add(forward)
        XCTAssertTrue(fullyVisible(later), "The later higher-rated card must be fully outside both floating control bars")
        let first = app.buttons["gallery.open.900001"]
        for _ in 0..<32 { if fullyVisible(first) { break }; app.swipeDown() }
        XCTAssertTrue(fullyVisible(first))
        XCTAssertLessThan(first.frame.minY, app.buttons["gallery.open.900003"].frame.minY)
        let summary = app.buttons["discover.condition-summary"].value as? String ?? ""
        for term in ["coast", "language:chinese", "排除 other:watercolor", "≥3星"] { XCTAssertTrue(summary.contains(term), summary) }
        XCTAssertFalse(app.buttons["discover.sort-order"].exists)
        let top = XCTAttachment(screenshot: app.screenshot()); top.name = "search43.first-batch-order-retained"; top.lifetime = .keepAlways; add(top)
    }
}
