import XCTest

final class ToolbarTextV20UITests: XCTestCase {
    private func horizontal(_ button: XCUIElement, app: XCUIApplication, name: String) {
        XCTAssertTrue(button.waitForExistence(timeout: 6))
        XCTAssertTrue(button.isHittable || !button.isEnabled)
        let frame = button.frame
        print("TOOLBAR20 \(name) label=\(button.label) frame=\(frame)")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "toolbar20.\(name)"; shot.lifetime = .keepAlways; add(shot)
        // A two-character Chinese action needs its natural text width plus
        // the style padding. A narrow square slot previously stacked it.
        XCTAssertGreaterThanOrEqual(frame.width, 50, "\(name) must fit both characters horizontally")
        XCTAssertLessThanOrEqual(frame.height, 50, "\(name) must remain a compact one-line action")
    }

    func testCancelAndAdjacentActionsStayHorizontalInAllSearchSheets() {
        let app = XCUIApplication()
        app.launchArguments = ["--qa", "--qa-tags-offline", "--qa-dark"]
        app.launch()
        let entry = app.buttons["discover.search-entry"]
        XCTAssertTrue(entry.waitForExistence(timeout: 12)); entry.tap()
        XCTAssertTrue(app.searchComposerTitle("搜索").waitForExistence(timeout: 6))
        horizontal(app.buttons["compose.cancel"], app: app, name: "compose.cancel")
        horizontal(app.buttons["compose.apply"], app: app, name: "compose.search")
        let title = app.searchComposerTitle("搜索")
        let cancel = app.buttons["compose.cancel"], apply = app.buttons["compose.apply"]
        let header = app.descendants(matching: .any)["compose.header"].firstMatch
        XCTAssertEqual(title.frame.minX - cancel.frame.maxX, 4, accuracy: 1)
        XCTAssertEqual(apply.frame.minX - title.frame.maxX, 4, accuracy: 1)
        XCTAssertEqual(title.frame.midX, header.frame.midX, accuracy: 1)
        XCTAssertFalse(header.buttons["compose.save-favorite"].exists)
        XCTAssertFalse(app.buttons["compose.saved-list"].exists)
        XCTAssertEqual(cancel.frame.height, apply.frame.height, accuracy: 1)

        app.buttons["compose.filters"].tap()
        XCTAssertTrue(app.searchComposerTitle("搜索").waitForExistence(timeout: 6))
        let add = app.buttons["compose.add-tag"]
        for _ in 0..<4 { if add.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(add.isHittable); add.tap()
        XCTAssertTrue(app.staticTexts["添加标签"].waitForExistence(timeout: 6))
        horizontal(app.buttons["tag.cancel"], app: app, name: "tag.cancel")
        horizontal(app.buttons["tag.confirm"], app: app, name: "tag.done")
        let tagTitle = app.staticTexts["tag.title"]
        XCTAssertEqual(tagTitle.frame.minX - app.buttons["tag.cancel"].frame.maxX, 4, accuracy: 1)
        XCTAssertEqual(app.buttons["tag.confirm"].frame.minX - tagTitle.frame.maxX, 4, accuracy: 1)
        app.buttons["tag.cancel"].tap()
        XCTAssertTrue(app.searchComposerTitle("搜索").waitForExistence(timeout: 6))
        app.buttons["compose.filters"].tap()
        XCTAssertTrue(app.searchComposerTitle("搜索").waitForExistence(timeout: 6))
        app.buttons["compose.cancel"].tap()
        XCTAssertTrue(entry.waitForExistence(timeout: 6))

        entry.tap()
        let input = app.textFields["compose.text"]
        XCTAssertTrue(input.waitForExistence(timeout: 6)); input.tap(); input.typeText("coast")
        app.buttons["compose.apply"].tap()
        entry.tap()
        let save = app.buttons["compose.save-favorite"]
        XCTAssertTrue(save.waitForExistence(timeout: 8)); save.tap()
        let navigation = app.descendants(matching: .any)["search.save.header"].firstMatch
        XCTAssertTrue(navigation.waitForExistence(timeout: 6))
        horizontal(navigation.buttons["取消"], app: app, name: "save.cancel")
        horizontal(app.buttons["search.save.confirm"], app: app, name: "save.confirm")
        navigation.buttons["取消"].tap()
        XCTAssertTrue(entry.waitForExistence(timeout: 6))
        XCTAssertFalse(navigation.exists)
    }
}

extension XCUIApplication {
    func selectTagNamespace(_ namespace: String) {
        let menu = buttons["tag.namespace-filter"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.tap()
        let target = buttons["tag.namespace.\(namespace)"]
        XCTAssertTrue(target.waitForExistence(timeout: 5))
        target.tap()
    }

    func searchComposerTitle(_ title: String) -> XCUIElement {
        staticTexts.matching(identifier: "compose.title")
            .matching(NSPredicate(format: "label == %@", title)).firstMatch
    }
}
