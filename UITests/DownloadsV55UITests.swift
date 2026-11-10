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
        let downloadScope = app.buttons["library.scope.3"]
        let scopeMenu = app.buttons["library.scope.menu"]
        if scopeMenu.exists { scopeMenu.tap() }
        XCTAssertTrue(downloadScope.waitForExistence(timeout: 5))
        downloadScope.tap()
        XCTAssertTrue(app.buttons["downloads.help"].waitForExistence(timeout: 5))
    }
    private func options(_ app: XCUIApplication) {
        let gallery = app.buttons["gallery.open.1"]
        XCTAssertTrue(gallery.waitForExistence(timeout: 8)); gallery.tap()
        let more = app.buttons["detail.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 8)); more.tap()
        let download = app.buttons["detail.more.download"]
        XCTAssertTrue(download.waitForExistence(timeout: 5)); download.tap()
        XCTAssertTrue(app.staticTexts["downloads.options.title"].waitForExistence(timeout: 5))
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
        XCTAssertTrue(app.staticTexts["downloads.help-page.title"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "缓存")).firstMatch.exists)
        app.buttons["完成"].tap()
        XCTAssertTrue(app.buttons["downloads.help"].waitForExistence(timeout: 5))
    }
    func testExistingOfflineCopyOpensDownloadOptionsWhenDetailFails() {
        XCUIDevice.shared.orientation = .portrait
        let app = launch(["--qa-offline-layout", "--qa-detail-failure"])
        let gallery = app.buttons["gallery.open.1"]
        XCTAssertTrue(gallery.waitForExistence(timeout: 8))
        gallery.tap()
        XCTAssertTrue(app.buttons["重试"].waitForExistence(timeout: 5))
        let localDownload = app.buttons["detail.download"]
        for _ in 0..<4 {
            if localDownload.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(localDownload.isEnabled)
        localDownload.tap()
        XCTAssertTrue(app.staticTexts["downloads.options.title"].waitForExistence(timeout: 5))
        app.buttons["downloads.options.close"].tap()
        app.buttons["detail.more"].tap()
        XCTAssertTrue(app.buttons["detail.more.download"].isEnabled)
        app.buttons["detail.more.download"].tap()
        XCTAssertTrue(app.staticTexts["downloads.options.title"].waitForExistence(timeout: 5))
    }

    func testOfflineDownloadConcurrencyPersistsSeparatelyFromReaderAndSiteSettings() {
        let app = launch(["--qa-reset-reader-preferences"])
        func picker(_ name: String) -> XCUIElement { app.sliders["account.loading.\(name)"] }
        func showDownloadSlider() -> XCUIElement {
            LoadingSettingsUIHelpers.open(in: app)
            let control = app.sliders["account.loading.download-concurrency"]
            for _ in 0..<4 { if control.isHittable { break }; app.swipeUp() }
            XCTAssertTrue(control.isHittable)
            return control
        }
        let download = showDownloadSlider()
        XCTAssertEqual(download.label, "离线下载并发")
        XCTAssertEqual(download.value as? String, "2 路")
        let middle = download.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        download.coordinate(withNormalizedOffset: CGVector(dx: 0.10, dy: 0.5)).press(forDuration: 0.1, thenDragTo: middle)
        let middleValue = Int((download.value as? String ?? "").filter(\.isNumber))
        XCTAssertTrue(middleValue.map { (12...20).contains($0) } == true)
        let end = download.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.5))
        middle.press(forDuration: 0.1, thenDragTo: end)
        XCTAssertEqual(download.value as? String, "32 路")
        XCTAssertEqual(picker("concurrency").value as? String, "16 路")
        XCTAssertEqual(picker("site-concurrency").value as? String, "2 路")
        shot(app, "offline-download.concurrency-settings")
        app.terminate()
        app.launchArguments.removeAll { $0 == "--qa-reset-reader-preferences" }
        app.launchArguments.append("--qa-dark")
        app.launch()
        XCTAssertEqual(showDownloadSlider().value as? String, "32 路")
        shot(app, "offline-download.concurrency-settings-dark")
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
        let row = app.buttons["library.download.item.1"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertEqual(row.value as? String, "等待中")
        row.tap()
        XCTAssertEqual(row.value as? String, "已暂停")
        row.tap()
        XCTAssertEqual(row.value as? String, "等待中")
        shot(app, "downloads55.image-queued")
    }

    func testDetailDownloadStartsOfflineQueueInPlace() {
        let app = launch()
        app.buttons["gallery.open.1"].tap()
        let download = app.buttons["detail.download-action"]
        XCTAssertTrue(download.waitForExistence(timeout: 5))
        XCTAssertEqual(download.label, "离线下载")
        download.tap()
        XCTAssertEqual(download.label, "等待下载")
        XCTAssertEqual(download.value as? String, "等待中")
        XCTAssertTrue(app.buttons["detail.read"].isHittable)
    }

    func testDetailOldAndNewVersionsShowTheSameUpdateAndQueueState() {
        let app = launch(["--qa-offline-layout", "--qa-download-version"])
        let latest = app.buttons["gallery.open.2"]
        XCTAssertTrue(latest.waitForExistence(timeout: 6))
        latest.tap()
        let download = app.buttons["detail.download-action"]
        XCTAssertTrue(download.waitForExistence(timeout: 5))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "更新可用"), object: download)], timeout: 5), .completed)
        download.tap()
        let confirm = app.buttons["更新到新版"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5)); confirm.tap()
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 5))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "等待下载"), object: download)], timeout: 5), .completed)
        app.buttons["BackButton"].tap()
        let old = app.buttons["gallery.open.1"]
        XCTAssertTrue(old.waitForExistence(timeout: 5)); old.tap()
        XCTAssertTrue(download.waitForExistence(timeout: 5))
        XCTAssertEqual(download.label, "等待下载")
        XCTAssertEqual(app.buttons["detail.read"].value as? String, "优先读本机副本")
    }
    func testLongPressSelectsDownloadsAndRemovesOnlyTheSelectedRows() {
        let app = launch(["--qa-library-sort"]); downloads(app)
        let first = app.buttons["library.download.item.7204"]
        let second = app.buttons["library.download.item.7202"]
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        first.press(forDuration: 0.8)
        let remove = app.buttons["downloads.remove"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        XCTAssertEqual(first.value as? String, "已选中")
        second.tap()
        XCTAssertEqual(second.value as? String, "已选中")
        remove.tap()
        app.sheets["移除所选离线副本？"].buttons["移除本机副本"].tap()
        XCTAssertTrue(first.waitForNonExistence(timeout: 5))
        XCTAssertTrue(second.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["library.download.item.7201"].exists)
        XCTAssertTrue(app.buttons["library.download.item.7203"].exists)
    }
    func testTorrentListCopiesMagnetAndPreparesASystemFileShareWithoutCompletingOfflineDownload() {
        let app = launch(); options(app)
        app.buttons["downloads.torrents"].coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap()
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
        let closeShare = app.buttons["header.closeButton"]
        let export = app.buttons["torrent.export"]
        closeShare.tap()
        XCTAssertTrue(share.waitForNonExistence(timeout: 8))
        XCTAssertTrue(export.isHittable)

        export.tap()
        XCTAssertTrue(share.waitForExistence(timeout: 8))
        closeShare.tap()
        XCTAssertTrue(share.waitForNonExistence(timeout: 8))
        XCTAssertTrue(export.isHittable)
        app.descendants(matching: .any)["torrent.header"].firstMatch.buttons["BackButton"].tap()
        XCTAssertTrue(app.staticTexts["downloads.options.title"].waitForExistence(timeout: 5))
        app.buttons["关闭"].tap()
        XCTAssertTrue(app.buttons["detail.more"].waitForExistence(timeout: 5))
        app.buttons["BackButton"].tap(); downloads(app)
        XCTAssertTrue(app.staticTexts["暂无下载"].waitForExistence(timeout: 5))
    }

    func testFailedDownloadOffersRetryAcrossDetailOptionsAndLibrary() {
        XCUIDevice.shared.orientation = .portrait
        let app = launch(["--qa-failed-download"])
        options(app)
        let retry = app.buttons["downloads.save"]
        XCTAssertEqual(retry.label, "重试下载")
        XCTAssertTrue((retry.value as? String)?.contains("已保存 1/3 页") == true)
        shot(app, "download-retry.options")
        app.buttons["downloads.options.close"].tap()
        let detail = app.buttons["detail.download-action"]
        XCTAssertTrue(detail.waitForExistence(timeout: 5))
        XCTAssertEqual(detail.label, "重试下载")
        app.buttons["BackButton"].tap()
        downloads(app)
        let row = app.buttons["library.download.item.1"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertEqual(row.value as? String, "下载失败")
        shot(app, "download-retry.library")
        row.tap()
        let queued = NSPredicate(format: "value == %@", "等待中")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: queued, object: row)], timeout: 5), .completed)
    }
}
