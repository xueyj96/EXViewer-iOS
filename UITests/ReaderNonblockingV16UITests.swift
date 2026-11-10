import XCTest
import UIKit

final class ReaderNonblockingV16UITests: XCTestCase {
    private func openReader(_ extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--qa", "--qa-reset-reader-preferences", "--qa-reader-many", "--qa-reader-transition"
        ] + extraArguments
        app.launch()
        let gallery = app.staticTexts["海岸线 · 插画与速写"].firstMatch
        XCTAssertTrue(gallery.waitForExistence(timeout: 12))
        gallery.tap()
        let read = app.buttons["在线阅读"]
        XCTAssertTrue(read.waitForExistence(timeout: 8))
        read.tap()
        let page = app.buttons["reader.page"]
        XCTAssertTrue(page.waitForExistence(timeout: 12))
        ReaderSettingsUIHelpers.setMode("单页模式", in: app)
        return app
    }

    private func waitForPage(_ label: String, app: XCUIApplication, timeout: TimeInterval = 3) {
        let page = app.buttons["reader.page"]
        expectation(for: NSPredicate { _, _ in page.label == label }, evaluatedWith: page)
        waitForExpectations(timeout: timeout)
    }

    private func cacheValue(_ app: XCUIApplication) -> String {
        app.descendants(matching: .any)["reader.cache.qa"].firstMatch.value as? String ?? ""
    }

    private func waitForLoadedPage(_ index: Int, app: XCUIApplication, timeout: TimeInterval = 12) {
        let cache = app.descendants(matching: .any)["reader.cache.qa"].firstMatch
        expectation(for: NSPredicate { _, _ in
            let value = cache.value as? String ?? ""
            guard let field = value.components(separatedBy: ";").first(where: { $0.hasPrefix("files=") }) else { return false }
            return Set(field.dropFirst("files=".count).split(separator: ",").compactMap { Int($0) }).contains(index)
        }, evaluatedWith: cache)
        waitForExpectations(timeout: timeout)
    }

    private func turnNext(_ app: XCUIApplication, to pageNumber: Int, timeout: TimeInterval = 2) {
        app.coordinate(withNormalizedOffset: .init(dx: 0.82, dy: 0.5)).tap()
        waitForPage("\(pageNumber) / 12", app: app, timeout: timeout)
    }

    private func turnPrevious(_ app: XCUIApplication, to pageNumber: Int, timeout: TimeInterval = 2) {
        app.coordinate(withNormalizedOffset: .init(dx: 0.18, dy: 0.5)).tap()
        waitForPage("\(pageNumber) / 12", app: app, timeout: timeout)
    }

    private func dragForward(_ app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5))
            .press(forDuration: 0.03,
                   thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)),
                   withVelocity: .fast, thenHoldForDuration: 0.02)
    }

    private func loadingPlaceholder(_ page: Int, app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["reader.page.loading.\(page)"].firstMatch
    }

    func testSlowAdjacentTapKeepsTheCurrentPageAndManualJumpSupersedesIt() {
        let app = openReader(["--qa-prefetch=0", "--qa-concurrency=16", "--qa-transfer-ms=6000"])
        app.coordinate(withNormalizedOffset: .init(dx: 0.82, dy: 0.5)).tap()
        let pending = app.staticTexts["正在加载第 2 页…"]
        XCTAssertTrue(pending.waitForExistence(timeout: 3))
        XCTAssertEqual(app.buttons["reader.page"].label, "1 / 12")
        XCTAssertTrue((app.otherElements["media.static"].firstMatch.value as? String)?.contains("reader-v11-page-1.png") == true)

        app.sliders["reader.progress"].adjust(toNormalizedSliderPosition: 1)
        waitForPage("12 / 12", app: app, timeout: 3)
        XCTAssertFalse(pending.exists)
        waitForLoadedPage(12, app: app)
        XCTAssertEqual(app.buttons["reader.page"].label, "12 / 12")
    }

    func testAdjacentTurnWaitsForMetadataAndImage() {
        let app = openReader(["--qa-reader-paging", "--qa-prefetch=0", "--qa-metadata-ms=5500"])
        turnNext(app, to: 2, timeout: 4)
        dragForward(app)
        XCTAssertTrue(app.staticTexts["正在加载第 3 页…"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.buttons["reader.page"].label, "2 / 12")
        waitForPage("3 / 12", app: app, timeout: 12)
        XCTAssertFalse(loadingPlaceholder(3, app: app).exists)
    }

    func testMissingPageMetadataShowsExplicitRetryInsteadOfAutoRetryLoop() {
        let app = openReader(["--qa-reader-paging", "--qa-prefetch=0", "--qa-reader-metadata-stall"])
        turnNext(app, to: 2, timeout: 4)
        dragForward(app)
        let retry = app.buttons["reader.page.retry.3"]
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        XCTAssertTrue(cacheValue(app).contains("metadataCalls=1;"))
        XCTAssertEqual(app.buttons["reader.page"].label, "2 / 12")
        retry.tap()
        let diagnostic = app.descendants(matching: .any)["reader.cache.qa"].firstMatch
        expectation(for: NSPredicate { _, _ in
            (diagnostic.value as? String)?.contains("metadataCalls=2;metadataTask=false;") == true
        }, evaluatedWith: diagnostic)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(retry.exists)
        XCTAssertEqual(app.buttons["reader.page"].label, "2 / 12")
    }

    func testCachedNeighborRoundTripKeepsPresentationIdentity() {
        let app = openReader(["--qa-prefetch=2", "--qa-concurrency=16"])
        let diagnostic = app.descendants(matching: .any)["reader.cache.qa"].firstMatch
        expectation(for: NSPredicate { _, _ in
            let value = diagnostic.value as? String ?? ""
            guard let list = value.components(separatedBy: ";presentations=").last,
                  let presentation = list.components(separatedBy: ",").first(where: { $0.hasPrefix("2:") }) else { return false }
            return presentation.hasSuffix(":1")
        }, evaluatedWith: diagnostic)
        waitForExpectations(timeout: 12)
        let initial = cacheValue(app)
        let presentation = { (value: String) -> String? in
            guard let list = value.components(separatedBy: ";presentations=").last else { return nil }
            return list.components(separatedBy: ",").first(where: { $0.hasPrefix("2:") })
        }
        let identity = presentation(initial)
        XCTAssertNotNil(identity)

        turnNext(app, to: 2)
        XCTAssertEqual(presentation(cacheValue(app)), identity)
        turnPrevious(app, to: 1)
        turnNext(app, to: 2)
        XCTAssertEqual(presentation(cacheValue(app)), identity, "A cached neighboring page should retain its decoded presentation across a round trip")
    }

    func testSlowTurnsCanBeCancelledInAllFourDirections() {
        let app = openReader(["--qa-prefetch=0", "--qa-transfer-ms=15000"])
        let directions: [(String, CGVector, CGVector)] = [
            ("leftToRight", .init(dx: 0.75, dy: 0.5), .init(dx: 0.25, dy: 0.5)),
            ("rightToLeft", .init(dx: 0.25, dy: 0.5), .init(dx: 0.75, dy: 0.5)),
            ("topToBottom", .init(dx: 0.5, dy: 0.72), .init(dx: 0.5, dy: 0.28)),
            ("bottomToTop", .init(dx: 0.5, dy: 0.28), .init(dx: 0.5, dy: 0.72))
        ]
        for (title, start, end) in directions {
            ReaderSettingsUIHelpers.setDirection(title, in: app)
            app.coordinate(withNormalizedOffset: start).press(forDuration: 0.03,
                thenDragTo: app.coordinate(withNormalizedOffset: end), withVelocity: .fast, thenHoldForDuration: 0.02)
            XCTAssertTrue(app.staticTexts["正在加载第 2 页…"].waitForExistence(timeout: 3))
            XCTAssertEqual(app.buttons["reader.page"].label, "1 / 12")
            app.coordinate(withNormalizedOffset: end).press(forDuration: 0.03,
                thenDragTo: app.coordinate(withNormalizedOffset: start), withVelocity: .fast, thenHoldForDuration: 0.02)
            waitForPage("1 / 12", app: app, timeout: 2)
            XCTAssertTrue(app.staticTexts["正在加载第 2 页…"].waitForNonExistence(timeout: 2))
        }
    }
}
