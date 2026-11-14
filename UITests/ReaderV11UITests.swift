import XCTest
import UIKit

final class ReaderV11UITests: XCTestCase {
    private func launch(prefetch: Int, delay: Int = 0, arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--qa", "--qa-reset-reader-preferences", "--qa-reader-many", "--qa-reader-transition", "--qa-prefetch=\(prefetch)", "--qa-transfer-ms=\(delay)"] + arguments
        app.launch()
        let gallery = app.staticTexts["海岸线 · 插画与速写"].firstMatch
        XCTAssertTrue(gallery.waitForExistence(timeout: 12)); gallery.tap()
        let read = app.buttons["在线阅读"]
        XCTAssertTrue(read.waitForExistence(timeout: 8)); read.tap()
        XCTAssertTrue(app.buttons["reader.page"].waitForExistence(timeout: 12))
        waitForCache("files=1", app)
        return app
    }
    private func waitForCache(_ value: String, _ app: XCUIApplication) {
        let cache = app.descendants(matching: .any)["reader.cache.qa"].firstMatch
        expectation(for: NSPredicate { _, _ in (cache.value as? String)?.contains(value) == true }, evaluatedWith: cache)
        waitForExpectations(timeout: 12)
    }
    private func waitForCachedPages(_ required: Set<Int>, _ app: XCUIApplication) {
        let cache = app.descendants(matching: .any)["reader.cache.qa"].firstMatch
        expectation(for: NSPredicate { _, _ in
            let diagnostic = cache.value as? String ?? ""
            let field = diagnostic.components(separatedBy: ";").first { $0.hasPrefix("files=") } ?? "files="
            let loaded = Set(field.dropFirst(6).split(separator: ",").compactMap { Int($0) })
            return required.isSubset(of: loaded)
        }, evaluatedWith: cache)
        waitForExpectations(timeout: 12)
    }
    private func waitForPage(_ value: String, _ app: XCUIApplication) {
        let page = app.buttons["reader.page"]
        expectation(for: NSPredicate { _, _ in page.label == value }, evaluatedWith: page)
        waitForExpectations(timeout: 12)
    }
    private func drag(_ app: XCUIApplication, from: CGVector = .init(dx: 0.72, dy: 0.5), to: CGVector = .init(dx: 0.28, dy: 0.5), velocity: XCUIGestureVelocity = .fast, hold: TimeInterval = 0.02) {
        app.coordinate(withNormalizedOffset: from).press(forDuration: 0.03, thenDragTo: app.coordinate(withNormalizedOffset: to), withVelocity: velocity, thenHoldForDuration: hold)
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
    private func visibleColorFraction(_ app: XCUIApplication) -> Double {
        let image = app.screenshot().image.cgImage!
        let canvas = app.descendants(matching: .any)["reader.single.canvas"].firstMatch.frame
        let scale = CGFloat(image.width) / app.frame.width
        let region = CGRect(x: canvas.minX, y: canvas.minY + canvas.height * 0.35, width: canvas.width, height: canvas.height * 0.30)
            .applying(CGAffineTransform(scaleX: scale, y: scale)).integral
        let crop = image.cropping(to: region)!
        var pixels = [UInt8](repeating: 0, count: 80 * 40 * 4)
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: 80, height: 40, bitsPerComponent: 8, bytesPerRow: 80 * 4,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(crop, in: CGRect(x: 0, y: 0, width: 80, height: 40))
        }
        let bright = stride(from: 0, to: pixels.count, by: 4).filter { max(pixels[$0], pixels[$0 + 1], pixels[$0 + 2]) > 70 }.count
        return Double(bright) / Double(80 * 40)
    }
    private func checkSlowTarget(prefetch: Int) {
        let app = launch(prefetch: prefetch, delay: prefetch == 0 ? 6000 : 9000)
        waitForCache("files=1;", app)
        XCTAssertGreaterThan(visibleColorFraction(app), 0.7)
        print("READER11_SLOW_DRAG_BEGIN \(Date().timeIntervalSince1970)")
        drag(app)
        capture(app, "reader11.slow-target.after-release")
        let visible = visibleColorFraction(app)
        print("READER11_SLOW_AFTER_RELEASE \(Date().timeIntervalSince1970) colorFraction=\(visible)")
        XCTAssertEqual(app.buttons["reader.page"].label, "2 / 12")
        if prefetch == 0 {
            XCTAssertLessThan(visible, 0.15, "An uncached target shows its own black loading page")
            XCTAssertTrue(app.descendants(matching: .any)["reader.page.loading.2"].firstMatch.exists)
        }
        XCTAssertFalse(app.staticTexts["正在加载第 2 页…"].exists, "No waiting banner over the old picture")
        waitForPage("2 / 12", app)
        waitForCachedPages([1, 2], app)
        XCTAssertGreaterThan(visibleColorFraction(app), 0.7)
        capture(app, "reader11.slow-target.complete")
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
    }
    func testSlowTargetShowsBlackLoadingPageWithMatchingPageNumber() { checkSlowTarget(prefetch: 0) }
    func testSlowTargetWithTwoPrefetchUsesTargetPage() { checkSlowTarget(prefetch: 2) }
    func testSlowTargetWithSixPrefetchUsesTargetPage() { checkSlowTarget(prefetch: 6) }

    private func presentation(_ page: Int, _ app: XCUIApplication) -> String? {
        let value = app.descendants(matching: .any)["reader.cache.qa"].firstMatch.value as? String ?? ""
        guard let suffix = value.components(separatedBy: ";presentations=").last else { return nil }
        return suffix.components(separatedBy: ",").first { $0.hasPrefix("\(page):") }
    }
    private func checkCachedHandoff(prefetch: Int) {
        let app = launch(prefetch: prefetch)
        drag(app); waitForPage("2 / 12", app)
        let identity = presentation(2, app)
        XCTAssertNotNil(identity); XCTAssertTrue(identity?.hasSuffix(":1") == true)
        XCTAssertGreaterThan(visibleColorFraction(app), 0.7)
        drag(app, from: .init(dx: 0.28, dy: 0.5), to: .init(dx: 0.72, dy: 0.5))
        waitForPage("1 / 12", app)
        XCTAssertEqual(presentation(2, app), identity, "Cached adjacent Canvas stays alive when reading backward")
        drag(app); waitForPage("2 / 12", app)
        XCTAssertEqual(presentation(2, app), identity, "Returning to cached target must reuse the same decoded Canvas")
        XCTAssertGreaterThan(visibleColorFraction(app), 0.7)
        capture(app, "reader11.cached.prefetch\(prefetch)")
    }
    func testZeroPrefetchCachedRoundTripKeepsTheSameDecodedCanvas() { checkCachedHandoff(prefetch: 0) }
    func testSixPrefetchCachedRoundTripKeepsTheSameDecodedCanvas() { checkCachedHandoff(prefetch: 6) }

    func testCurrentLoadingCanvasCanBecomeImageWhileFingerIsStillDragging() {
        let app = XCUIApplication()
        app.launchArguments = ["--qa", "--qa-reset-reader-preferences", "--qa-reader-many", "--qa-reader-transition", "--qa-prefetch=0", "--qa-reader-large-window", "--qa-transfer-ms=2600"]
        app.launch()
        XCTAssertTrue(app.buttons["gallery.open.1"].waitForExistence(timeout: 12))
        app.buttons["gallery.open.1"].tap(); app.buttons["detail.read"].tap()
        XCTAssertTrue(app.buttons["reader.page"].waitForExistence(timeout: 12))
        let a = app.coordinate(withNormalizedOffset: .init(dx: 0.7, dy: 0.48))
        let b = app.coordinate(withNormalizedOffset: .init(dx: 0.3, dy: 0.48))
        a.press(forDuration: 0.03, thenDragTo: b, withVelocity: .slow, thenHoldForDuration: 3)
        expectation(for: NSPredicate(format: "value BEGINSWITH %@", "page 2;"), evaluatedWith: app.descendants(matching: .any)["reader.single.canvas"].firstMatch)
        waitForExpectations(timeout: 5)
        waitForCachedPages([2], app)
        let canvas = app.descendants(matching: .any)["reader.single.canvas"].firstMatch
        XCTAssertTrue((canvas.value as? String ?? "").contains("release=commit=true,target=2"))
    }

    func testNeighborFinishingDuringFingerHoldDoesNotCancelTheDrag() {
        let app = launch(prefetch: 0, delay: 600)
        let a = app.coordinate(withNormalizedOffset: .init(dx: 0.7, dy: 0.48))
        let b = app.coordinate(withNormalizedOffset: .init(dx: 0.3, dy: 0.48))
        a.press(forDuration: 0.03, thenDragTo: b, withVelocity: .slow, thenHoldForDuration: 1.2)
        waitForPage("2 / 12", app)
        let canvas = app.descendants(matching: .any)["reader.single.canvas"].firstMatch
        XCTAssertTrue((canvas.value as? String ?? "").contains("release=commit=true,target=2"))
        XCTAssertGreaterThan(visibleColorFraction(app), 0.7)
        drag(app, from: .init(dx: 0.3, dy: 0.48), to: .init(dx: 0.7, dy: 0.48))
        waitForPage("1 / 12", app)
    }

    func testFourDirectionsShortReboundFastReverseAndRepeatedDragsHaveNoBlank() {
        let app = launch(prefetch: 2)
        drag(app); waitForPage("2 / 12", app)
        let directions: [(String, CGVector, CGVector)] = [
            ("leftToRight", .init(dx: 0.70, dy: 0.5), .init(dx: 0.30, dy: 0.5)),
            ("rightToLeft", .init(dx: 0.30, dy: 0.5), .init(dx: 0.70, dy: 0.5)),
            ("topToBottom", .init(dx: 0.50, dy: 0.65), .init(dx: 0.50, dy: 0.35)),
            ("bottomToTop", .init(dx: 0.50, dy: 0.35), .init(dx: 0.50, dy: 0.65))]
        for (title, start, end) in directions {
            ReaderSettingsUIHelpers.setDirection(title, in: app)
            for sign in [-1.0, 1.0] {
                let small = title == "leftToRight" || title == "rightToLeft" ? CGVector(dx: 0.5 + sign * 0.04, dy: 0.5) : CGVector(dx: 0.5, dy: 0.5 + sign * 0.02)
                drag(app, from: .init(dx: 0.5, dy: 0.5), to: small, velocity: .slow, hold: 0.3)
                waitForPage("2 / 12", app)
                XCTAssertGreaterThan(visibleColorFraction(app), 0.7, "Rebound must retain real content: \(title)")
            }
            drag(app, from: start, to: end); waitForPage("3 / 12", app)
            XCTAssertGreaterThan(visibleColorFraction(app), 0.7)
            drag(app, from: end, to: start); waitForPage("2 / 12", app)
            drag(app, from: start, to: end)
            drag(app, from: start, to: end); waitForPage("4 / 12", app)
            XCTAssertGreaterThan(visibleColorFraction(app), 0.7)
            capture(app, "reader11.direction.\(title)")
            drag(app, from: end, to: start); waitForPage("3 / 12", app)
            drag(app, from: end, to: start); waitForPage("2 / 12", app)
        }
    }
    func testSlowLoadingPageCanReverseThenJumpWithoutLatePageChange() {
        let app = launch(prefetch: 0, delay: 9000)
        drag(app)
        waitForPage("2 / 12", app)
        XCTAssertLessThan(visibleColorFraction(app), 0.15)
        XCTAssertTrue(app.descendants(matching: .any)["reader.page.loading.2"].firstMatch.exists)
        drag(app, from: .init(dx: 0.28, dy: 0.5), to: .init(dx: 0.72, dy: 0.5))
        waitForPage("1 / 12", app)
        XCTAssertGreaterThan(visibleColorFraction(app), 0.7)
        let image = app.otherElements["media.static"].firstMatch
        app.coordinate(withNormalizedOffset: .init(dx: 0.22, dy: 0.48)).doubleTap()
        expectation(for: NSPredicate { _, _ in (image.value as? String)?.contains("zoomed") == true }, evaluatedWith: image)
        waitForExpectations(timeout: 5)
        drag(app); waitForPage("1 / 12", app)
        app.sliders["reader.progress"].adjust(toNormalizedSliderPosition: 1)
        waitForPage("12 / 12", app)
        waitForCachedPages([12], app)
        XCTAssertGreaterThan(visibleColorFraction(app), 0.7)
        XCTAssertTrue((app.otherElements["media.static"].firstMatch.value as? String)?.contains("reader-v11-page-12.png") == true)
        capture(app, "reader127.reverse-jump")
    }

    func testTapIntoUncachedPageShowsBlackThenReturnsToCachedPage() {
        let app = launch(prefetch: 0, delay: 6000)
        app.coordinate(withNormalizedOffset: .init(dx: 0.88, dy: 0.5)).tap()
        waitForPage("2 / 12", app)
        XCTAssertLessThan(visibleColorFraction(app), 0.15)
        XCTAssertTrue(app.descendants(matching: .any)["reader.page.loading.2"].firstMatch.exists)
        capture(app, "reader127.tap-target-loading")
        app.coordinate(withNormalizedOffset: .init(dx: 0.12, dy: 0.5)).tap()
        waitForPage("1 / 12", app)
        XCTAssertGreaterThan(visibleColorFraction(app), 0.7)
    }

    func testMissingNextMetadataStopsAtTargetLoadingPageAndCanReturn() {
        let app = launch(prefetch: 0, arguments: ["--qa-reader-paging", "--qa-reader-metadata-stall"])
        drag(app); waitForPage("2 / 12", app)
        drag(app)
        waitForPage("3 / 12", app)
        XCTAssertTrue(app.staticTexts["第 3 页信息载入失败 请重试"].waitForExistence(timeout: 5))
        waitForCache("metadataCalls=1;metadataTask=false;", app)
        XCTAssertLessThan(visibleColorFraction(app), 0.15)
        capture(app, "reader127.metadata-no-progress")
        drag(app, from: .init(dx: 0.28, dy: 0.5), to: .init(dx: 0.72, dy: 0.5))
        waitForPage("2 / 12", app)
        XCTAssertGreaterThan(visibleColorFraction(app), 0.7)
        waitForCache("metadataCalls=1;metadataTask=false;", app)
    }
}
