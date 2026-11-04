import XCTest

final class ReaderPreloadV54UITests: XCTestCase {
    private func value(_ app: XCUIApplication) -> String {
        app.descendants(matching: .any)["reader.cache.qa"].firstMatch.value as? String ?? ""
    }
    private func field(_ key: String, in app: XCUIApplication) -> String? {
        value(app).split(separator: ";").first(where: { $0.hasPrefix(key + "=") }).map { String($0.dropFirst(key.count + 1)) }
    }
    private func wait(_ app: XCUIApplication, _ predicate: @escaping () -> Bool) {
        expectation(for: NSPredicate { _, _ in predicate() }, evaluatedWith: app)
        waitForExpectations(timeout: 8)
    }
    private func ready(_ pages: Set<Int>, in app: XCUIApplication) {
        wait(app) {
            Set((self.field("files", in: app) ?? "").split(separator: ",").compactMap { Int($0) }).isSuperset(of: pages)
        }
    }
    private func turn(_ page: Int, forward: Bool = true, in app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: .init(dx: forward ? 0.82 : 0.18, dy: 0.36)).tap()
        wait(app) { self.field("current", in: app) == String(page) }
    }
    func testForwardWindowKeepsFillingAcrossTenPagesAndCachedReverseReusesPresentation() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--qa", "--qa-reset-reader-preferences", "--qa-reader-transition", "--qa-reader-large-window",
                               "--qa-prefetch=8", "--qa-concurrency=4", "--qa-transfer-ms=250"]
        app.launch()
        let gallery = app.buttons["gallery.open.1"]
        XCTAssertTrue(gallery.waitForExistence(timeout: 12)); gallery.tap()
        let read = app.buttons["在线阅读"]
        XCTAssertTrue(read.waitForExistence(timeout: 8)); read.tap()
        XCTAssertTrue(app.buttons["reader.page"].waitForExistence(timeout: 10))
        ready(Set(1...9), in: app)
        XCTAssertEqual(field("current", in: app), "1")
        XCTAssertEqual(field("prefetch", in: app), "8")
        XCTAssertEqual(field("concurrency", in: app), "4")
        for page in 2...10 { turn(page, in: app) }
        ready(Set(11...18), in: app)
        let presentation = { self.field("presentations", in: app)?.split(separator: ",").first(where: { $0.hasPrefix("10:") }).map(String.init) }
        let initial = presentation()
        XCTAssertNotNil(initial)
        turn(9, forward: false, in: app); turn(10, in: app)
        XCTAssertEqual(presentation(), initial, "A cached current/neighbor handoff must preserve the same presentation")
        ready(Set(11...18), in: app)
        print("READER54_BURST_CURRENT=10;FORWARD_CACHED=11,12,13,14,15,16,17,18;IMAGE10_PRESENTATION_REUSED=true")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "reader54.rolling-window-page10"; shot.lifetime = .keepAlways; add(shot)
    }
}
