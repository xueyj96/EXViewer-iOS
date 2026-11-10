import XCTest

final class LibraryLayoutV36UITests: XCTestCase {
    private func openLibrary(_ arguments: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--qa", "--qa-reset-reader-preferences", "--qa-library-large-selection"] + arguments
        app.launch()
        let tab = app.buttons["main.tab.library"]
        XCTAssertTrue(tab.waitForExistence(timeout: 12)); tab.tap()
        if app.buttons["library.scope.menu"].exists {
            app.buttons["library.scope.menu"].tap(); app.buttons["library.scope.1"].tap()
        } else { app.buttons["library.scope.1"].tap() }
        XCTAssertTrue(app.buttons["favorites.gallery.10000"].waitForExistence(timeout: 12))
        return app
    }

    private func selectFirst(_ app: XCUIApplication) {
        app.buttons["favorites.gallery.10000"].press(forDuration: 0.8)
        XCTAssertTrue(app.batchSelection("已选 1 项").waitForExistence(timeout: 5))
        let tabs = app.descendants(matching: .any)["main.tabs.compact"].firstMatch
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: tabs)
        waitForExpectations(timeout: 5)
    }

    private func assertActions(_ app: XCUIApplication, managing: Bool = false) {
        let bar = app.descendants(matching: .any)["favorites.actions"].firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        let actions = managing ? ["favorites.move", "favorites.remove", "favorites.back"] : ["favorites.add-read-later", "favorites.download", "favorites.manage"]
        for name in actions {
            let button = app.buttons[name]
            XCTAssertTrue(button.exists && button.isHittable && button.isEnabled, name)
            XCTAssertGreaterThanOrEqual(button.frame.width + 0.000_001, 44, name)
            XCTAssertGreaterThanOrEqual(button.frame.height + 0.000_001, 44, name)
            XCTAssertGreaterThanOrEqual(button.frame.minX, 8, name)
            XCTAssertLessThanOrEqual(button.frame.maxX, app.frame.maxX - 8, name)
            XCTAssertLessThanOrEqual(button.frame.maxY, app.frame.maxY - 10, name)
        }
        XCTAssertFalse(app.buttons["main.tab.library"].exists)
    }

    private func assertSameBarFrame(_ actual: CGRect, as expected: CGRect,
                                    file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 1, file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: 1, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: 1, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: 1, file: file, line: line)
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }

    func testBulkRemoveAndMoveAreReachableAndMainTabsRestoreAfterCompletion() {
        let app = openLibrary()
        let normalFrame = app.buttons["favorites.gallery.10000"].frame
        let tabs = app.descendants(matching: .any)["main.tabs.compact"].firstMatch
        let normalBarFrame = tabs.frame
        selectFirst(app); assertActions(app)
        let actions = app.descendants(matching: .any)["favorites.actions"].firstMatch
        assertSameBarFrame(actions.frame, as: normalBarFrame)
        let card = app.buttons["favorites.select.10000"]
        let cardFrame = card.frame
        XCTAssertEqual(cardFrame.width, normalFrame.width, accuracy: 1)
        XCTAssertEqual(cardFrame.height, normalFrame.height, accuracy: 1)
        let manageFrame = app.buttons["favorites.manage"].frame
        XCTAssertFalse(app.buttons["favorites.favorite"].exists)
        capture(app, "batch-favorites.selection")
        app.buttons["favorites.manage"].tap()
        assertActions(app, managing: true)
        assertSameBarFrame(actions.frame, as: normalBarFrame)
        let back = app.buttons["favorites.back"]
        XCTAssertEqual(back.frame.midX, manageFrame.midX, accuracy: 1)
        XCTAssertEqual(back.frame.midY, manageFrame.midY, accuracy: 1)
        XCTAssertEqual(card.frame.minY, cardFrame.minY, accuracy: 1)
        XCTAssertEqual(card.frame.size, cardFrame.size)
        XCTAssertEqual(card.value as? String, "已选中")
        XCTAssertFalse(app.buttons["favorites.add-read-later"].exists)
        capture(app, "batch-favorites.manage")
        app.buttons["favorites.remove"].tap()
        XCTAssertTrue(app.buttons["移除所选收藏"].waitForExistence(timeout: 4))
        app.buttons["取消"].tap()
        assertActions(app, managing: true)
        app.buttons["favorites.move"].tap()
        let destination = app.buttons["favorites.move-to.0"]
        XCTAssertTrue(destination.waitForExistence(timeout: 4))
        let confirm = app.buttons["favorites.confirm-move"]
        XCTAssertFalse(confirm.isEnabled)
        destination.tap()
        XCTAssertTrue(confirm.isEnabled)
        capture(app, "batch-favorites.groups")
        app.buttons["favorites.groups.back"].tap()
        assertActions(app, managing: true)
        XCTAssertEqual(card.value as? String, "已选中")
        app.buttons["favorites.back"].tap()
        assertActions(app)
        app.buttons["favorites.manage"].tap()
        app.buttons["favorites.remove"].tap(); app.buttons["移除所选收藏"].tap()
        XCTAssertTrue(app.buttons["main.tab.library"].waitForExistence(timeout: 5))
        assertSameBarFrame(tabs.frame, as: normalBarFrame)
        XCTAssertFalse(app.buttons["favorites.remove"].exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "未修改站点收藏")).firstMatch.waitForExistence(timeout: 5))
    }

    func testLargeTypeBulkActionsRemainSingleRowAndExitRestoresNavigation() {
        let app = openLibrary(["--qa-large-type", "--qa-dark"])
        selectFirst(app); assertActions(app)
        app.buttons["favorites.manage"].tap()
        assertActions(app, managing: true)
        let move = app.buttons["favorites.move"], remove = app.buttons["favorites.remove"]
        XCTAssertEqual(move.frame.midY, remove.frame.midY, accuracy: 1)
        XCTAssertLessThanOrEqual(remove.frame.height, 48.000_001)
        capture(app, "library36.large-type-actions")
        remove.tap()
        XCTAssertTrue(app.buttons["移除所选收藏"].waitForExistence(timeout: 4)); app.buttons["取消"].tap()
        app.buttons["favorites.edit"].tap()
        XCTAssertTrue(app.buttons["main.tab.library"].waitForExistence(timeout: 5))
    }

    func testLateCoverRatiosDoNotMoveExistingCardsBetweenColumns() {
        let app = openLibrary(["--qa-grid-aspect-delay"])
        let ids = [10000, 10001, 10002, 10003]
        let initial = Dictionary(uniqueKeysWithValues: ids.map { id -> (Int, CGRect) in
            let card = app.buttons["favorites.gallery.\(id)"]
            XCTAssertTrue(card.waitForExistence(timeout: 4))
            return (id, card.frame)
        })
        // The landscape fixture starts at the unknown-cover fallback ratio.
        // Observe its actual layout change instead of an accessibility child
        // which NavigationLink may merge into the card itself.
        let landscape = app.buttons["favorites.gallery.10001"]
        expectation(for: NSPredicate { _, _ in
            landscape.frame.height < initial[10001]!.height - 20
        }, evaluatedWith: landscape)
        waitForExpectations(timeout: 20)
        for id in ids {
            XCTAssertEqual(app.buttons["favorites.gallery.\(id)"].frame.midX, initial[id]!.midX, accuracy: 1, "Cover resolution must not move card \(id) to the other column")
        }
        capture(app, "library36.stable-columns-after-covers")
    }

    func testOfflineReaderDoesNotStackItsControlsOverMainTabs() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--qa", "--qa-reset-reader-preferences", "--qa-offline-layout"]
        app.launch()
        XCTAssertTrue(app.buttons["main.tab.library"].waitForExistence(timeout: 12)); app.buttons["main.tab.library"].tap()
        app.buttons["library.scope.3"].tap()
        let read = app.buttons["library.download.item.1"]
        XCTAssertTrue(read.waitForExistence(timeout: 5)); read.tap()
        XCTAssertTrue(app.buttons["reader.page"].waitForExistence(timeout: 8))
        let tabs = app.descendants(matching: .any)["main.tabs.compact"].firstMatch
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: tabs)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(app.buttons["reader.settings"].isHittable)
        capture(app, "library36.offline-reader")
        app.buttons["reader.close"].tap()
        XCTAssertTrue(app.buttons["main.tab.library"].waitForExistence(timeout: 5))
    }
}
