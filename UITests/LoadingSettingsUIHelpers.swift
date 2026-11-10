import XCTest

enum ReaderSettingsUIHelpers {
    static func open(in app: XCUIApplication) {
        let settings = app.buttons["reader.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 6))
        settings.tap()
        XCTAssertTrue(app.descendants(matching: .any)["reader.settings-page.header"].firstMatch.waitForExistence(timeout: 5))
    }

    static func close(in app: XCUIApplication) {
        let settings = app.descendants(matching: .any)["reader.settings-page.header"].firstMatch
        settings.buttons["完成"].tap()
        XCTAssertTrue(settings.waitForNonExistence(timeout: 5))
    }

    static func setMode(_ title: String, in app: XCUIApplication) {
        open(in: app)
        app.buttons[title].tap()
        close(in: app)
    }

    static func setDirection(_ direction: String, in app: XCUIApplication) {
        open(in: app)
        app.buttons["reader.settings.direction.\(direction)"].tap()
        close(in: app)
    }
}

enum LoadingSettingsUIHelpers {
    static func open(in app: XCUIApplication) {
        let existingPrefetchSlider = app.sliders["account.loading.prefetch"]
        if existingPrefetchSlider.exists { return }

        let readerSettingsDone = app.descendants(matching: .any)["reader.settings-page.header"].firstMatch.buttons["完成"]
        if readerSettingsDone.exists { readerSettingsDone.tap() }

        let readerClose = app.buttons["reader.close"]
        if readerClose.exists { readerClose.tap() }

        let accountTab = app.buttons["main.tab.account"]
        XCTAssertTrue(accountTab.waitForExistence(timeout: 8), "Account tab should be available")
        accountTab.tap()

        let storageLink = app.buttons["account.storage"]
        for _ in 0..<8 {
            if storageLink.exists && storageLink.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(storageLink.exists && storageLink.isHittable, "Reading and storage settings should be reachable from Account")
        storageLink.tap()
        XCTAssertTrue(app.sliders["account.loading.prefetch"].waitForExistence(timeout: 8))
    }

    static func returnToReader(in app: XCUIApplication) {
        let storageBack = app.descendants(matching: .any)["account.storage-page.header"].buttons["BackButton"]
        if storageBack.exists { storageBack.tap() }

        let discoverTab = app.buttons["main.tab.discover"]
        XCTAssertTrue(discoverTab.waitForExistence(timeout: 8), "Discover tab should be available")
        discoverTab.tap()

        let onlineRead = app.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "在线阅读", "继续阅读")).firstMatch
        if !onlineRead.waitForExistence(timeout: 4) {
            let firstGallery = app.staticTexts["海岸线 · 插画与速写"].firstMatch
            XCTAssertTrue(firstGallery.waitForExistence(timeout: 8), "The first QA gallery should be available in Discover")
            firstGallery.tap()
        }
        XCTAssertTrue(onlineRead.waitForExistence(timeout: 8))
        onlineRead.tap()
        XCTAssertTrue(app.buttons["reader.page"].waitForExistence(timeout: 12))
    }

    static func setPrefetch(_ count: Int, in app: XCUIApplication) {
        XCTAssertTrue((0...128).contains(count), "Prefetch count must be within the account slider range")
        open(in: app)
        let slider = app.sliders["account.loading.prefetch"]
        XCTAssertTrue(slider.waitForExistence(timeout: 5))
        for _ in 0..<5 {
            if slider.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(slider.isHittable, "Account prefetch slider should be reachable")
        let previous = prefetchCount(in: app)
        if let previous, abs(previous - count) >= 16 {
            drag(slider, from: CGFloat(previous) / 128, to: CGFloat(count) / 128)
            XCTAssertNotEqual(prefetchCount(in: app), previous, "Dragging the slider must update its image count")
        }
        if prefetchCount(in: app) != count {
            app.buttons["account.storage-page.action"].tap()
            let alert = app.alerts.firstMatch
            XCTAssertTrue(alert.waitForExistence(timeout: 3))
            XCTAssertTrue(alert.staticTexts["预加载数量"].exists)
            let field = alert.textFields.element(boundBy: 0)
            // The native alert focuses this field and opens the number pad.
            // A second tap during its presentation can open the edit menu and
            // intercept synthesized typing. Wait for the keyboard first.
            if !app.keyboards.firstMatch.exists { field.tap() }
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
            let replacement = String(repeating: XCUIKeyboardKey.delete.rawValue, count: 5) + String(count)
            field.typeText(replacement)
            if field.value as? String != String(count) {
                field.tap()
                field.typeText(replacement)
            }
            XCTAssertEqual(field.value as? String, String(count))
            alert.buttons["保存"].tap()
            // The number-pad dismissal can relocate this native alert during
            // the first synthesized tap. Re-read the still-present alert first.
            if alert.exists { alert.buttons["保存"].tap() }
            XCTAssertFalse(alert.exists, "Saving the exact count must dismiss its alert")
        }
        XCTAssertEqual(prefetchCount(in: app), count, "Account prefetch slider should expose the chosen count")
    }

    static func prefetchCount(in app: XCUIApplication) -> Int? {
        sliderCount(app.sliders["account.loading.prefetch"])
    }

    static func chooseImageConcurrency(_ count: Int, in app: XCUIApplication) {
        chooseConcurrency(count, choices: [2, 4, 8, 16], identifier: "account.loading.concurrency", in: app)
    }

    static func chooseSitePageConcurrency(_ count: Int, in app: XCUIApplication) {
        chooseConcurrency(count, choices: [1, 2, 4], identifier: "account.loading.site-concurrency", in: app)
    }

    private static func chooseConcurrency(_ count: Int, choices: [Int], identifier: String, in app: XCUIApplication) {
        open(in: app)
        let slider = app.sliders[identifier]
        XCTAssertTrue(slider.waitForExistence(timeout: 5))
        for _ in 0..<5 {
            if slider.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(slider.isHittable)
        guard let current = sliderCount(slider), let from = choices.firstIndex(of: current),
              let to = choices.firstIndex(of: count) else {
            return XCTFail("Concurrency slider must expose a supported choice")
        }
        if from != to {
            let last = CGFloat(choices.count - 1)
            drag(slider, from: CGFloat(from) / last, to: CGFloat(to) / last)
        }
        XCTAssertEqual(sliderCount(slider), count)
    }

    private static func sliderCount(_ slider: XCUIElement) -> Int? {
        Int((slider.value as? String ?? "").filter(\.isNumber))
    }

    private static func drag(_ slider: XCUIElement, from: CGFloat, to: CGFloat) {
        let start = slider.coordinate(withNormalizedOffset: .init(dx: 0.04 + from * 0.92, dy: 0.5))
        let end = slider.coordinate(withNormalizedOffset: .init(dx: 0.02 + to * 0.96, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: end)
    }
}
