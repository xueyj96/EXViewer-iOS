import XCTest

final class DownloadsV55UITests: XCTestCase {
    private func launch(_ extra: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--qa", "--qa-detail-actions", "--qa-download-actions"] + extra
        app.launch()
        XCTAssertTrue(app.buttons["main.tab.library"].waitForExistence(timeout: 12))
        return app
    }
    private func downloads(_ app: XCUIApplication) {
        app.buttons["main.tab.library"].tap()
        app.buttons["library.scope.3"].tap()
        XCTAssertTrue(app.buttons["downloads.help"].waitForExistence(timeout: 5))
    }
    private func options(_ app: XCUIApplication) {
        let gallery = app.buttons["gallery.open.1"]
        XCTAssertTrue(gallery.waitForExistence(timeout: 8)); gallery.tap()
        let more = app.buttons["detail.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 8)); more.tap()
        let download = app.buttons["detail.more.download"]
        XCTAssertTrue(download.waitForExistence(timeout: 5)); download.tap()
        XCTAssertTrue(app.navigationBars["下载方式"].waitForExistence(timeout: 5))
    }
    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testDownloadPageKeepsOnlyStatusAndPutsInstructionsBehindInfo() {
        let app = launch(); downloads(app)
        XCTAssertTrue(app.staticTexts["暂无下载"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["清理浏览缓存不会移除已保存的离线副本。"].exists)
        XCTAssertGreaterThanOrEqual(app.buttons["downloads.help"].frame.width, 44)
        shot(app, "downloads55.quiet-empty")
        app.buttons["downloads.help"].tap()
        XCTAssertTrue(app.navigationBars["下载说明"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "缓存")).firstMatch.exists)
        app.buttons["完成"].tap()
        XCTAssertTrue(app.buttons["downloads.help"].waitForExistence(timeout: 5))
    }
    func testSaveUsesTheExistingOfflineQueueAndDoesNotExposeArchivePurchase() {
        let app = launch(); options(app)
        XCTAssertTrue(app.buttons["downloads.save"].exists)
        XCTAssertTrue(app.buttons["downloads.torrents"].exists)
        XCTAssertFalse(app.buttons["detail.archive"].exists)
        shot(app, "downloads55.methods")
        app.buttons["downloads.save"].tap()
        XCTAssertTrue(app.buttons["BackButton"].waitForExistence(timeout: 5)); app.buttons["BackButton"].tap()
        downloads(app)
        XCTAssertTrue(app.staticTexts["等待中"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["继续"].exists)
        XCTAssertFalse(app.staticTexts["下载完成"].exists)
        shot(app, "downloads55.image-queued")
    }
    func testTorrentListCopiesMagnetAndPreparesASystemFileShareWithoutCompletingOfflineDownload() {
        let app = launch(); options(app)
        app.buttons["downloads.torrents"].tap()
        XCTAssertTrue(app.buttons["torrent.export"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["海岸线 · 中性示例"].exists)
        XCTAssertTrue(app.staticTexts["4 B · 做种 3 · 下载 1"].exists)
        app.buttons["torrent.copy-magnet"].tap()
        XCTAssertTrue(app.buttons["torrent.copy-magnet"].label.contains("已复制"))
        shot(app, "downloads55.native-torrents")
        app.buttons["torrent.export"].tap()
        let share = app.otherElements["ActivityListView"]
        XCTAssertTrue(share.waitForExistence(timeout: 8))
        shot(app, "downloads55.public-torrent-share")
        // No recipient or downloader is selected during QA.
        app.buttons["header.closeButton"].tap()
        XCTAssertTrue(app.buttons["torrent.export"].waitForExistence(timeout: 5))
        app.navigationBars["BT 种子"].buttons["BackButton"].tap()
        XCTAssertTrue(app.navigationBars["下载方式"].waitForExistence(timeout: 5))
        app.buttons["关闭"].tap()
        XCTAssertTrue(app.buttons["detail.more"].waitForExistence(timeout: 5))
        app.navigationBars["画廊详情"].buttons["BackButton"].tap(); downloads(app)
        XCTAssertTrue(app.staticTexts["暂无下载"].waitForExistence(timeout: 5))
    }
}
