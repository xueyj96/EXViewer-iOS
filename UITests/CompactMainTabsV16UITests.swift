import XCTest
import UIKit

final class CompactMainTabsV16UITests: XCTestCase {
    func testRootTabsAndSearchDraftSurvivePortraitLandscapeRoundTrips() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchArguments = ["--qa"]
        app.launch()

        func roundTrip(_ anchor: XCUIElement, name: String) {
            for (step, orientation) in [UIDeviceOrientation.landscapeLeft, .portrait, .landscapeRight, .portrait].enumerated() {
                XCUIDevice.shared.orientation = orientation
                let stable = NSPredicate { _, _ in
                    (app.frame.width > app.frame.height) == orientation.isLandscape && anchor.isHittable
                }
                expectation(for: stable, evaluatedWith: anchor)
                waitForExpectations(timeout: 8)
                let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                screenshot.name = "rotation-\(name)-\(step)-\(orientation.rawValue)"
                screenshot.lifetime = .keepAlways
                add(screenshot)
            }
        }

        for (name, id) in [("discover", "main.tab.discover"), ("library", "main.tab.library"), ("account", "main.tab.account")] {
            let tab = app.buttons[id]
            XCTAssertTrue(tab.waitForExistence(timeout: 10))
            tab.tap()
            roundTrip(tab, name: name)
            XCTAssertTrue(tab.isSelected)
        }

        app.buttons["main.tab.discover"].tap()
        app.buttons["discover.search-entry"].tap()
        let draft = app.textFields["compose.text"]
        XCTAssertTrue(draft.waitForExistence(timeout: 6))
        draft.tap()
        draft.typeText("rotation draft")
        roundTrip(draft, name: "search")
        XCTAssertEqual(draft.value as? String, "rotation draft")
        app.buttons["compose.cancel"].tap()
        XCTAssertTrue(app.buttons["main.tab.discover"].isSelected)
    }

    func testCompactBarSwitchesAllRootTabsWithoutShowingNativeBar() {
        let app = XCUIApplication()
        app.launchArguments = ["--qa"]
        app.launch()

        let bar = app.descendants(matching: .any)["main.tabs.compact"].firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 12))
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "main.tabs.compact").count, 1)
        XCTAssertEqual(bar.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "main.tab.")).count, 3,
                       "Count navigation controls, excluding SwiftUI's private icon/text descendants")
        XCTAssertLessThanOrEqual(bar.frame.height, 56, "The compact tab bar should remain below 56 points tall")
        XCTAssertEqual(app.tabBars.count, 0, "The native tab bar should remain hidden")

        let tabs = ["main.tab.discover", "main.tab.library", "main.tab.account"]
        for (index, identifier) in tabs.enumerated() {
            let tab = app.buttons[identifier]
            XCTAssertTrue(tab.waitForExistence(timeout: 5))
            XCTAssertTrue(tab.isHittable)
            tab.tap()
            XCTAssertTrue(tab.isSelected, "Tab \(identifier) should become selected")
            XCTAssertEqual(app.tabBars.count, 0)
            if index < tabs.count - 1 {
                XCTAssertTrue(bar.isHittable, "The compact bar should remain available after switching tabs")
            }
        }
    }
}
