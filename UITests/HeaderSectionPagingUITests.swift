import XCTest

final class HeaderSectionPagingUITests: XCTestCase {
    override func tearDown() { XCUIDevice.shared.orientation = .portrait; super.tearDown() }
    private func launch(_ extra: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--qa", "--qa-dark", "--qa-library-sort", "--qa-reset-library-sort", "--qa-tags-offline"] + extra
        if extra.contains("--qa-tags-delayed") { app.launchArguments.removeAll { $0 == "--qa-tags-offline" } }
        app.launch()
        XCTAssertTrue(app.buttons["main.tab.library"].waitForExistence(timeout: 12))
        return app
    }
    private func waitSelected(_ app: XCUIApplication, _ id: String) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: app.buttons[id])
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 6), .completed)
    }
    private func edge(_ app: XCUIApplication, leading: Bool, distance: CGFloat) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: leading ? 0.005 : 0.995, dy: 0.55))
        let end = start.withOffset(CGVector(dx: (leading ? 1 : -1) * app.frame.width * distance, dy: 0))
        start.press(forDuration: 0.08, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
    }
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    func test160ClickAndEdgeSwitchExitLibrarySelection() {
        let app = launch(); app.buttons["main.tab.library"].tap()
        let saved = app.buttons["favorites.gallery.7201"]
        XCTAssertTrue(saved.waitForExistence(timeout: 8)); saved.press(forDuration: 0.65)
        XCTAssertTrue(app.buttons["read-later.exit"].waitForExistence(timeout: 5))
        app.buttons["library.scope.3"].tap(); waitSelected(app, "library.scope.3")
        XCTAssertFalse(app.buttons["read-later.exit"].exists)
        app.buttons["downloads.select"].tap()
        XCTAssertTrue(app.buttons["downloads.exit"].waitForExistence(timeout: 5))
        edge(app, leading: false, distance: 0.65); waitSelected(app, "library.scope.0")
        XCTAssertFalse(app.buttons["downloads.exit"].exists)
        XCTAssertTrue(app.buttons["read-later.select"].exists)
        app.buttons["library.scope.2"].tap(); waitSelected(app, "library.scope.2")
        let history = app.buttons["reading-history.item.7203"]
        XCTAssertTrue(history.waitForExistence(timeout: 5)); history.press(forDuration: 0.65)
        XCTAssertTrue(app.buttons["reading-history.exit"].waitForExistence(timeout: 5))
        edge(app, leading: true, distance: 0.65); waitSelected(app, "library.scope.1")
        XCTAssertFalse(app.buttons["reading-history.exit"].exists)
        let manage = app.buttons["favorites.select"]
        XCTAssertTrue(manage.waitForExistence(timeout: 8)); manage.tap()
        XCTAssertTrue(app.buttons["favorites.select-all"].waitForExistence(timeout: 5))
        app.buttons["library.scope.0"].tap(); waitSelected(app, "library.scope.0")
        app.buttons["library.scope.1"].tap(); waitSelected(app, "library.scope.1")
        XCTAssertFalse(app.buttons["favorites.select-all"].exists)
        XCTAssertTrue(manage.exists)
    }

    func test160CenterRightSwipeExitsSelectionAndEdgeSwipeChangesDiscoverySection() {
        let app = launch()
        let card = app.buttons["gallery.open.1"]
        XCTAssertTrue(card.waitForExistence(timeout: 8)); card.press(forDuration: 0.65)
        let exit = app.buttons["discover.exit"]
        XCTAssertTrue(exit.waitForExistence(timeout: 5))
        let start = app.coordinate(withNormalizedOffset: .init(dx: 0.35, dy: 0.5))
        start.press(forDuration: 0.08, thenDragTo: start.withOffset(.init(dx: 0, dy: -70)), withVelocity: .slow, thenHoldForDuration: 0.1)
        XCTAssertTrue(exit.exists)
        start.press(forDuration: 0.08, thenDragTo: start.withOffset(.init(dx: 150, dy: 4)), withVelocity: .slow, thenHoldForDuration: 0.1)
        XCTAssertTrue(exit.waitForNonExistence(timeout: 5)); waitSelected(app, "discover.lane.0")
        XCTAssertFalse(app.buttons["detail.read"].exists)
        XCTAssertTrue(card.waitForExistence(timeout: 5)); card.press(forDuration: 0.65)
        XCTAssertTrue(exit.waitForExistence(timeout: 5))
        edge(app, leading: false, distance: 0.65); waitSelected(app, "discover.lane.1")
        XCTAssertFalse(exit.exists)
        app.buttons["discover.lane.0"].tap(); waitSelected(app, "discover.lane.0")
        XCTAssertFalse(exit.exists)
    }

    func testLibraryEdgesChangeSectionsAndControlsWhileBarsStayFixed() {
        let app = launch(); app.buttons["main.tab.library"].tap()
        waitSelected(app, "library.scope.0")
        let header = app.descendants(matching: .any)["library.header.floating"].firstMatch
        let tab = app.buttons["main.tab.library"]
        let headerFrame = header.frame, tabFrame = tab.frame
        edge(app, leading: false, distance: 0.1)
        waitSelected(app, "library.scope.0")
        edge(app, leading: false, distance: 0.65)
        waitSelected(app, "library.scope.1")
        let favoriteHeader = app.descendants(matching: .any)["favorites.header.floating"].firstMatch
        XCTAssertEqual(favoriteHeader.frame.minY, headerFrame.minY, accuracy: 1)
        XCTAssertEqual(tab.frame, tabFrame)
        edge(app, leading: false, distance: 0.65)
        waitSelected(app, "library.scope.2")
        XCTAssertTrue(app.textFields["reading-history.search-field"].waitForExistence(timeout: 5))
        edge(app, leading: false, distance: 0.65)
        waitSelected(app, "library.scope.3")
        XCTAssertTrue(app.buttons["library.sort.downloads"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.textFields["reading-history.search-field"].exists)
        XCTAssertEqual(tab.frame, tabFrame)
        capture("paging.library.downloads")
        edge(app, leading: true, distance: 0.65)
        waitSelected(app, "library.scope.2")
        XCTAssertTrue(app.textFields["reading-history.search-field"].exists)
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["library.scope.3"].waitForExistence(timeout: 5))
        app.buttons["library.scope.3"].tap(); waitSelected(app, "library.scope.3")
        XCTAssertTrue(app.buttons["library.sort.downloads"].exists)
        capture("paging.library.landscape")
    }
    func testDiscoverHistoryReplacesSecondRowAndTagsEdgesDoNotPopPrematurely() {
        let app = launch()
        let bottom = app.buttons["main.tab.discover"].frame
        app.buttons["discover.lane.2"].tap(); waitSelected(app, "discover.lane.2")
        XCTAssertTrue(app.textFields["reading-history.search-field"].waitForExistence(timeout: 5))
        edge(app, leading: true, distance: 0.65)
        waitSelected(app, "discover.lane.1")
        XCTAssertFalse(app.textFields["reading-history.search-field"].exists)
        XCTAssertTrue(app.buttons["discover.search-entry"].exists)
        XCTAssertEqual(app.buttons["main.tab.discover"].frame, bottom)
        capture("paging.discover.popular")
        app.buttons["main.tab.account"].tap()
        let tags = app.buttons["account.tags"]
        for _ in 0..<6 { if tags.isHittable { break }; app.swipeUp() }
        tags.tap()
        XCTAssertTrue(app.buttons["tags.scope.0"].waitForExistence(timeout: 5))
        edge(app, leading: false, distance: 0.65); waitSelected(app, "tags.scope.1")
        edge(app, leading: true, distance: 0.65); waitSelected(app, "tags.scope.0")
        XCTAssertTrue(app.textFields["tags.search"].exists)
        capture("paging.tags.back-to-common")
    }
    func testScrolledLaneRestoresAnchorAndOverlaySearchDoesNotChangeUnderlyingLane() {
        let app = launch(["--qa-feed-paging"])
        let card = app.buttons["gallery.open.205"]
        let header = app.descendants(matching: .any)["discover.header.floating"].firstMatch
        for _ in 0..<12 {
            if card.exists && card.isHittable { break }
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -180)),
                        withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        XCTAssertTrue(card.isHittable)
        for _ in 0..<5 {
            let distance = card.frame.minY - (header.frame.maxY + 1)
            if abs(distance) < 2 { break }
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -max(-250, min(250, distance)))),
                        withVelocity: .slow, thenHoldForDuration: 0.4)
        }
        app.buttons["discover.lane.1"].tap(); waitSelected(app, "discover.lane.1")
        edge(app, leading: true, distance: 0.65); waitSelected(app, "discover.lane.0")
        let restored = NSPredicate { _, _ in card.exists && card.frame.minY >= header.frame.maxY - 1 && card.frame.minY <= header.frame.maxY + 30 }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: restored, object: card)], timeout: 8), .completed)
        capture("paging.discover.restored-anchor")
    }

    func testNewSearchUsesDiscoveryAndKeepsPopularEntry() {
        let app = launch()
        app.buttons["discover.lane.1"].tap(); waitSelected(app, "discover.lane.1")
        let gallery = app.buttons["gallery.open.1"]
        XCTAssertTrue(gallery.waitForExistence(timeout: 6))
        let y = gallery.frame.minY
        gallery.tap()
        let tag = app.buttons["detail.tag.language:chinese"]
        for _ in 0..<8 { if tag.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(tag.isHittable); tag.tap()
        app.buttons["detail.tags.search-menu"].tap(); app.buttons["detail.tags.new-search"].tap()
        waitSelected(app, "discover.lane.3")
        XCTAssertTrue(app.buttons["main.tab.discover"].isSelected)
        app.buttons["discover.lane.1"].tap(); waitSelected(app, "discover.lane.1")
        XCTAssertTrue(gallery.waitForExistence(timeout: 5))
        XCTAssertEqual(gallery.frame.minY, y, accuracy: 2)
        XCTAssertFalse(app.buttons["detail.tags.search-menu"].exists)
    }

    func testKeyboardBlocksEdgeDragButNotExplicitScopeButtons() {
        let app = launch()
        app.buttons["main.tab.library"].tap()
        app.buttons["library.scope.2"].tap(); waitSelected(app, "library.scope.2")
        let history = app.textFields["reading-history.search-field"]
        history.tap(); history.typeText("unfinished")
        app.buttons["library.scope.3"].tap(); waitSelected(app, "library.scope.3")
        XCTAssertTrue(app.buttons["library.sort.downloads"].exists)
        app.buttons["main.tab.account"].tap()
        let tags = app.buttons["account.tags"]
        for _ in 0..<6 { if tags.isHittable { break }; app.swipeUp() }
        tags.tap()
        let field = app.textFields["tags.search"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText("preview")
        app.buttons["tags.scope.1"].tap(); waitSelected(app, "tags.scope.1")
        XCTAssertNotEqual(field.value as? String, "preview")
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        app.buttons["tags.scope.0"].tap(); waitSelected(app, "tags.scope.0")
        XCTAssertEqual(field.value as? String, "preview")
        capture("paging.keyboard-explicit-scope")
    }

    func testTagSectionsKeepIndependentQueriesNamespacesAndResults() {
        let app = launch()
        app.buttons["main.tab.account"].tap()
        let tags = app.buttons["account.tags"]
        for _ in 0..<6 { if tags.isHittable { break }; app.swipeUp() }
        tags.tap()
        let field = app.textFields["tags.search"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText("英语\n")
        XCTAssertTrue(app.buttons["tag.suggestion.language:english"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["搜索结果"].exists)
        let category = app.buttons["tags.add.namespace"]
        XCTAssertEqual(category.frame.height, 36, accuracy: 1)
        app.buttons["tags.scope.1"].tap(); waitSelected(app, "tags.scope.1")
        XCTAssertFalse(app.buttons["tag.suggestion.language:english"].exists)
        XCTAssertNotEqual(field.value as? String, "英语")
        field.tap(); field.typeText("preview\n")
        category.tap(); app.buttons["tags.add.namespace.artist"].tap()
        XCTAssertTrue(app.buttons["tag.suggestion.artist:preview"].waitForExistence(timeout: 5))
        app.buttons["tags.scope.0"].tap(); waitSelected(app, "tags.scope.0")
        XCTAssertEqual(field.value as? String, "英语")
        XCTAssertTrue(app.buttons["tag.suggestion.language:english"].exists)
        XCTAssertFalse(app.buttons["tag.suggestion.artist:preview"].exists)
        app.buttons["tags.search.clear"].tap()
        XCTAssertFalse(app.descendants(matching: .any)["tags.results"].firstMatch.exists)
        app.buttons["tags.scope.1"].tap(); waitSelected(app, "tags.scope.1")
        XCTAssertEqual(field.value as? String, "preview")
        XCTAssertTrue(app.buttons["tag.suggestion.artist:preview"].exists)
        category.tap()
        XCTAssertTrue(app.buttons["tags.add.namespace.artist"].isSelected)
        app.buttons["tags.add.namespace.artist"].tap()
        capture("tags.independent.blocked-results")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(category.waitForExistence(timeout: 5))
        XCTAssertEqual(category.frame.height, 36, accuracy: 1)
        capture("tags.independent.landscape")
    }

    func testInterruptedTagLookupResumesAfterLeavingAndReturning() {
        let app = launch(["--qa-tags-delayed"])
        app.buttons["main.tab.account"].tap()
        let tags = app.buttons["account.tags"]
        for _ in 0..<6 { if tags.isHittable { break }; app.swipeUp() }
        tags.tap()
        let field = app.textFields["tags.search"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText("nextpreview\n")
        app.buttons["main.tab.library"].tap()
        app.buttons["main.tab.account"].tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "nextpreview")
        XCTAssertTrue(app.buttons["tag.suggestion.group:nextpreview"].waitForExistence(timeout: 8))
        capture("tags.independent.resumed-lookup")
    }

    func testEmptyTagSearchHasExplicitResultRow() {
        let app = launch()
        app.buttons["main.tab.account"].tap()
        let tags = app.buttons["account.tags"]
        for _ in 0..<6 { if tags.isHittable { break }; app.swipeUp() }
        tags.tap()
        let field = app.textFields["tags.search"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText("zzzznomatchingtagfixture\n")
        XCTAssertTrue(app.staticTexts["tags.results.empty"].waitForExistence(timeout: 8))
        capture("tags.independent.empty-results")
    }

    func testEdgeSectionsCycleAtBothEndsWithoutMovingBarsOrPoppingTags() {
        let app = launch()
        let bottom = app.buttons["main.tab.discover"].frame
        edge(app, leading: true, distance: 0.65); waitSelected(app, "discover.lane.2")
        XCTAssertTrue(app.textFields["reading-history.search-field"].exists)
        edge(app, leading: false, distance: 0.65); waitSelected(app, "discover.lane.0")
        XCTAssertEqual(app.buttons["main.tab.discover"].frame, bottom)
        app.buttons["main.tab.library"].tap(); waitSelected(app, "library.scope.0")
        let headerFrame = app.descendants(matching: .any)["library.header.floating"].firstMatch.frame
        edge(app, leading: true, distance: 0.65); waitSelected(app, "library.scope.3")
        XCTAssertEqual(app.descendants(matching: .any)["library.header.floating"].firstMatch.frame, headerFrame)
        edge(app, leading: false, distance: 0.65); waitSelected(app, "library.scope.0")
        capture("paging.cyclic.library.first-last")
        app.buttons["main.tab.account"].tap()
        let tags = app.buttons["account.tags"]
        for _ in 0..<6 { if tags.isHittable { break }; app.swipeUp() }
        tags.tap(); waitSelected(app, "tags.scope.0")
        edge(app, leading: true, distance: 0.65); waitSelected(app, "tags.scope.1")
        XCTAssertTrue(app.textFields["tags.search"].exists)
        edge(app, leading: false, distance: 0.65); waitSelected(app, "tags.scope.0")
        edge(app, leading: false, distance: 0.65); waitSelected(app, "tags.scope.1")
        edge(app, leading: false, distance: 0.65); waitSelected(app, "tags.scope.0")
        capture("paging.cyclic.tags.both-directions")
    }

}
