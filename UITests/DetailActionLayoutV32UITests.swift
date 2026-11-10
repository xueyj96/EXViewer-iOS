import XCTest
import UIKit

final class DetailActionLayoutV32UITests: XCTestCase {
    func testDarkDesignPreviews() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--qa", "--qa-dark", "--qa-detail-design-preview", "--qa-library-sort", "--qa-tags-offline"]
        app.launch()

        let gallery = app.buttons["gallery.open.1"]
        XCTAssertTrue(gallery.waitForExistence(timeout: 10))
        gallery.tap()
        let info = app.descendants(matching: .any)["detail.info-card"].firstMatch
        XCTAssertTrue(info.waitForExistence(timeout: 5))
        let category = info.descendants(matching: .any)["detail.info.category"].firstMatch
        let pages = info.descendants(matching: .any)["detail.info.pages"].firstMatch
        let rating = info.descendants(matching: .any)["detail.info.rating"].firstMatch
        XCTAssertEqual(category.label, "类别: 西方")
        XCTAssertEqual(pages.label, "页数: 6 页")
        XCTAssertEqual(rating.label, "分数: 2.8")
        let cover = info.descendants(matching: .any)["cover.media.1"].firstMatch
        XCTAssertTrue(cover.exists)
        XCTAssertEqual(cover.frame.height, 126, accuracy: 1)
        assertActionsInsideInfoCard(info)
        let read = info.buttons["detail.read"]
        XCTAssertEqual(cover.frame.midX - read.frame.minX, 42, accuracy: 1)
        XCTAssertEqual(cover.frame.minY - info.frame.minY, 6, accuracy: 1)
        XCTAssertEqual(read.frame.minY + 5 - cover.frame.maxY, 6, accuracy: 1)
        let group = app.descendants(matching: .any)["detail.tags.group.artist"].firstMatch
        XCTAssertEqual(group.frame.minX - info.frame.minX, 4, accuracy: 1)
        XCTAssertEqual(rating.frame.midY, category.frame.midY, accuracy: 1)
        XCTAssertEqual(category.frame.minX - rating.frame.maxX, 6, accuracy: 1)
        XCTAssertEqual(category.frame.midY, pages.frame.midY, accuracy: 1)
        capturePreview("preview-detail", app: app)

        app.buttons["BackButton"].tap()
        let search = app.buttons["discover.search-entry"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        let filters = app.buttons["compose.filters"]
        XCTAssertTrue(filters.waitForExistence(timeout: 5))
        let input = app.textFields["compose.text"]
        input.tap()
        input.typeText("language:english other:comic")
        filters.tap()
        let selectAll = app.buttons["compose.categories.select-all"]
        let invert = app.buttons["compose.categories.invert"]
        XCTAssertTrue(selectAll.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["已选 10/10"].exists)
        XCTAssertEqual(selectAll.frame.midY, invert.frame.midY, accuracy: 1)
        XCTAssertEqual(selectAll.frame.width, invert.frame.width, accuracy: 1)
        let scopeRows = [app.staticTexts["搜索范围"], app.switches["仅搜标题"],
                         app.switches["匹配完整短语"], app.textFields["compose.artist"]]
        for row in scopeRows { XCTAssertTrue(row.exists) }
        for (first, second) in zip(scopeRows, scopeRows.dropFirst()) {
            XCTAssertEqual(second.frame.midY - first.frame.midY, 40, accuracy: 1)
        }
        let addTag = app.buttons["compose.add-tag"]
        XCTAssertTrue(addTag.isHittable)
        let commonTag = app.buttons["compose.common-tags"]
        XCTAssertEqual(addTag.frame.width, commonTag.frame.width, accuracy: 1)
        XCTAssertEqual(commonTag.frame.midY, addTag.frame.midY, accuracy: 1)
        XCTAssertFalse(app.staticTexts["compose.current-summary"].exists)
        capturePreview("preview-search-filters", app: app)

        let searchHeaderY = app.descendants(matching: .any)["compose.header"].firstMatch.frame.minY
        addTag.tap()
        let confirm = app.buttons["tag.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        let tagHeader = app.descendants(matching: .any)["tag.header"].firstMatch
        XCTAssertEqual(tagHeader.frame.minY, searchHeaderY, accuracy: 1)
        XCTAssertEqual(confirm.label, "完成")
        XCTAssertFalse(app.staticTexts["建议"].exists)
        capturePreview("preview-tag-entry", app: app)
        app.selectTagNamespace("language")
        XCTAssertEqual(app.buttons["tag.namespace-filter"].value as? String, "语言")
        let tagInput = app.textFields["tag.name"]
        tagInput.tap()
        tagInput.typeText("bad\\tag\n")
        XCTAssertTrue(app.staticTexts["tag.manual-validation"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["tag.stage"].exists)
    }

    private func capturePreview(_ name: String, app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testOnlineReadingAndExistingTagsAreAvailableWhileDetailIsLoading() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--qa", "--qa-detail-delay", "--qa-reset-reader-preferences"]
        app.launch()
        let card = app.buttons["gallery.open.1"]
        XCTAssertTrue(card.waitForExistence(timeout: 12))
        card.tap()

        let read = app.buttons["detail.read"]
        XCTAssertTrue(read.waitForExistence(timeout: 4))
        XCTAssertTrue(read.isEnabled)
        XCTAssertTrue(app.buttons["detail.tag.artist:preview studio"].exists)
        read.tap()
        XCTAssertTrue(app.buttons["reader.page"].waitForExistence(timeout: 6))
    }

    func testDetailSiteAndDownloadCardsOpenAndReturnToTheSameGallery() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--qa"]
        app.launch()
        let gallery = app.buttons["gallery.open.1"]
        XCTAssertTrue(gallery.waitForExistence(timeout: 10))
        gallery.tap()

        let original = app.buttons["detail.site-page"]
        XCTAssertTrue(original.waitForExistence(timeout: 5))
        if !original.isHittable { app.swipeUp() }
        original.tap()
        XCTAssertTrue(app.staticTexts["画廊原网页"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["exhentai.org"].exists)
        XCTAssertTrue(app.staticTexts["子页面兼容检查通过"].waitForExistence(timeout: 15))
        app.buttons["official-web.close"].tap()

        let options = app.buttons["detail.download"]
        XCTAssertTrue(options.waitForExistence(timeout: 5))
        if !options.isHittable { app.swipeUp() }
        options.tap()
        XCTAssertTrue(app.staticTexts["下载方式"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["downloads.save"].exists)
        XCTAssertTrue(app.buttons["downloads.torrents"].exists)
        app.buttons["downloads.options.close"].tap()
        XCTAssertTrue(app.staticTexts["画廊详情"].waitForExistence(timeout: 5))
        XCTAssertTrue(original.exists)
    }

    func testDetailFavoriteAndDownloadSheetsRemainReachableInLandscape() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchArguments = ["--qa", "--qa-favorite-existing"]
        app.launch()
        let gallery = app.buttons["gallery.open.1"]
        XCTAssertTrue(gallery.waitForExistence(timeout: 10))
        gallery.tap()
        let favorite = app.buttons["detail.site-favorite"]
        XCTAssertTrue(favorite.waitForExistence(timeout: 5))
        XCUIDevice.shared.orientation = .landscapeLeft
        let settled = NSPredicate { _, _ in app.frame.width > app.frame.height && favorite.isHittable }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: settled, object: favorite)], timeout: 6), .completed)
        favorite.tap()
        let edit = app.buttons["favorite.editor.edit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        XCTAssertTrue(edit.isHittable)
        capturePreview("detail-landscape-favorite-editor", app: app)
        app.buttons["favorite.editor.cancel"].tap()

        let options = app.buttons["detail.download"]
        for _ in 0..<5 { if options.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(options.isHittable)
        options.tap()
        XCTAssertTrue(app.buttons["downloads.save"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["downloads.torrents"].isHittable)
        capturePreview("detail-landscape-download-options", app: app)
        app.buttons["downloads.options.close"].tap()
        XCTAssertTrue(app.staticTexts["画廊详情"].waitForExistence(timeout: 5))
    }

    func testLandscapeDetailKeepsTheHeaderCardsAndActionsInOneColumn() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchArguments = ["--qa", "--qa-offline-layout"]
        app.launch()
        let card = app.buttons["gallery.open.1"]
        XCTAssertTrue(card.waitForExistence(timeout: 12))
        card.tap()
        let read = app.buttons["detail.read"]
        XCTAssertTrue(read.waitForExistence(timeout: 5))

        for orientation in [UIDeviceOrientation.landscapeLeft, .landscapeRight] {
            XCUIDevice.shared.orientation = orientation
            let header = app.descendants(matching: .any)["detail.header.floating"].firstMatch
            let info = app.descendants(matching: .any)["detail.info-card"].firstMatch
            let tags = app.descendants(matching: .any)["detail.tags-card"].firstMatch
            let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                app.frame.width > app.frame.height && header.frame.width >= app.frame.width * 0.75 &&
                    abs(header.frame.midX - app.frame.midX) <= 2
            }, object: header)
            XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 5), .completed)
            XCTAssertEqual(header.frame.midX, app.frame.midX, accuracy: 2)
            for card in [info, tags] {
                XCTAssertEqual(card.frame.minX, header.frame.minX, accuracy: 1)
                XCTAssertEqual(card.frame.maxX, header.frame.maxX, accuracy: 1)
            }
            let leftTab = app.buttons["main.tab.discover"]
            let rightTab = app.buttons["main.tab.account"]
            XCTAssertEqual(leftTab.frame.minX - header.frame.minX, 4, accuracy: 1)
            XCTAssertEqual(header.frame.maxX - rightTab.frame.maxX, 4, accuracy: 1)
            assertActionsInsideInfoCard(info)
            assertCoverAndMetadataLayout(info)
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = orientation == .landscapeLeft ? "detail-landscape-left" : "detail-landscape-right"
            shot.lifetime = .keepAlways
            add(shot)

            XCUIDevice.shared.orientation = .portrait
            let restored = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                app.frame.height > app.frame.width && abs(header.frame.width - (app.frame.width - 40)) <= 1
            }, object: header)
            XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 6), .completed)
            XCTAssertEqual(info.frame.minX, header.frame.minX, accuracy: 1)
            assertCoverAndMetadataLayout(info)
            XCTAssertTrue(read.isHittable)
            let restoredShot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            restoredShot.name = "detail-restored-portrait"
            restoredShot.lifetime = .keepAlways
            add(restoredShot)
        }
    }

    private func assertActionsInsideInfoCard(_ info: XCUIElement, faceInset: CGFloat = 5) {
        let read = info.buttons["detail.read"]
        let favorite = info.buttons["detail.site-favorite"]
        let download = info.buttons["detail.download-action"]
        for button in [read, favorite, download] {
            XCTAssertTrue(button.isHittable)
            XCTAssertEqual(button.frame.width, read.frame.width, accuracy: 1)
            XCTAssertEqual(button.frame.midY, read.frame.midY, accuracy: 1)
        }
        XCTAssertEqual(read.frame.minX - info.frame.minX, 6, accuracy: 1)
        XCTAssertEqual(info.frame.maxX - download.frame.maxX, 6, accuracy: 1)
        XCTAssertEqual(info.frame.maxY - (read.frame.maxY - faceInset), 6, accuracy: 1)
        XCTAssertEqual(favorite.frame.minX - read.frame.maxX, 4, accuracy: 1)
        XCTAssertEqual(download.frame.minX - favorite.frame.maxX, 4, accuracy: 1)
    }

    private func assertCoverAndMetadataLayout(_ info: XCUIElement) {
        let title = info.staticTexts["海岸线 · 插画与速写"]
        let artistLabel = info.staticTexts["作者："]
        let artist = info.staticTexts["preview studio"]
        let uploaderLabel = info.staticTexts["上传："]
        let uploader = info.staticTexts["Preview Studio"]
        let rating = info.descendants(matching: .any)["detail.info.rating"].firstMatch
        let category = info.descendants(matching: .any)["detail.info.category"].firstMatch
        let pages = info.descendants(matching: .any)["detail.info.pages"].firstMatch
        for element in [title, artist, uploader, rating, category, pages] {
            XCTAssertTrue(element.exists)
            XCTAssertLessThanOrEqual(element.frame.maxX, info.frame.maxX)
        }
        XCTAssertGreaterThan(title.frame.minX - info.frame.minX, 60)
        for element in [artistLabel, uploaderLabel, rating] {
            XCTAssertEqual(element.frame.minX, title.frame.minX, accuracy: 2, element.label)
        }
        XCTAssertEqual(artist.frame.minX, uploader.frame.minX, accuracy: 1)
        XCTAssertEqual(artist.frame.midY, artistLabel.frame.midY, accuracy: 3)
        XCTAssertEqual(uploader.frame.midY, uploaderLabel.frame.midY, accuracy: 3)
        XCTAssertGreaterThan(rating.frame.minY, uploader.frame.maxY)
        XCTAssertEqual(rating.frame.midY, category.frame.midY, accuracy: 1)
        XCTAssertEqual(category.frame.minX - rating.frame.maxX, 6, accuracy: 1)
        XCTAssertEqual(category.label, "类别: 无H")
        XCTAssertEqual(pages.label, "页数: 3 页")
        XCTAssertEqual(pages.frame.minX - category.frame.maxX, 6, accuracy: 1)
        XCTAssertEqual(category.frame.midY, pages.frame.midY, accuracy: 1)
        XCTAssertGreaterThanOrEqual(info.buttons["detail.read"].frame.minY + 5 - category.frame.maxY, 5)
    }

    func testMissingCreditsKeepTheirRowsAndShowNA() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--qa", "--qa-detail-missing-credits"]
        app.launch()
        let gallery = app.buttons["gallery.open.1"]
        XCTAssertTrue(gallery.waitForExistence(timeout: 10))
        gallery.tap()
        let info = app.descendants(matching: .any)["detail.info-card"].firstMatch
        XCTAssertTrue(info.waitForExistence(timeout: 6))
        let unavailable = info.staticTexts.matching(identifier: "N/A")
        XCTAssertEqual(unavailable.count, 2)
        let artist = info.staticTexts["作者："], uploader = info.staticTexts["上传："]
        XCTAssertEqual(artist.frame.minX, uploader.frame.minX, accuracy: 1)
        XCTAssertEqual(unavailable.element(boundBy: 0).frame.midY, artist.frame.midY, accuracy: 1)
        XCTAssertEqual(unavailable.element(boundBy: 1).frame.midY, uploader.frame.midY, accuracy: 1)
    }

    func testReadingFavoriteAndDownloadShareTheRowEvenly() {
        continueAfterFailure = false
        let cases: [(String, [String], String)] = [
            ("Favorites 0", ["--qa-offline-layout"], "下载完成"),
            ("A deliberately long favorite group name", ["--qa-dark", "--qa-large-type", "--qa-detail-long-tag"], "离线下载")
        ]
        for (name, extra, downloadTitle) in cases {
            let app = XCUIApplication()
            app.launchArguments = ["--qa", "--qa-favorite-existing", "--qa-favorite-group=" + name] + extra
            app.launch()
            let card = app.buttons["gallery.open.1"]
            XCTAssertTrue(card.waitForExistence(timeout: 12))
            card.tap()

            let read = app.buttons["detail.read"]
            let favorite = app.buttons["detail.site-favorite"]
            let download = app.buttons["detail.download-action"]
            XCTAssertTrue(download.waitForExistence(timeout: 8))
            XCTAssertEqual(download.label, downloadTitle)
            XCTAssertEqual(read.label, extra.contains("--qa-offline-layout") ? "开始阅读" : "在线阅读")
            XCTAssertTrue(favorite.label.contains("收藏完成"))
            XCTAssertTrue(favorite.label.contains(name))
            for button in [read, favorite, download] {
                XCTAssertTrue(button.isHittable)
                XCTAssertGreaterThanOrEqual(button.frame.width, 44 - 0.01)
                XCTAssertGreaterThanOrEqual(button.frame.height, 44 - 0.01)
                XCTAssertEqual(button.frame.width, read.frame.width, accuracy: 1)
                XCTAssertEqual(button.frame.height, read.frame.height, accuracy: 1)
                XCTAssertEqual(button.frame.midY, read.frame.midY, accuracy: 1)
            }
            XCTAssertEqual(favorite.frame.minX - read.frame.maxX, 4, accuracy: 1)
            XCTAssertEqual(download.frame.minX - favorite.frame.maxX, 4, accuracy: 1)
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = extra.contains("--qa-dark") ? "detail-download.dark-large" : "detail-download.light"
            screenshot.lifetime = .keepAlways
            add(screenshot)

            let header = app.descendants(matching: .any)["detail.header.floating"].firstMatch
            assertActionsInsideInfoCard(app.descendants(matching: .any)["detail.info-card"].firstMatch,
                                        faceInset: extra.contains("--qa-large-type") ? 0 : 5)
            for id in ["detail.info-card", "detail.tags-card", "detail.site-card"] {
                let section = app.descendants(matching: .any)[id].firstMatch
                XCTAssertTrue(section.exists)
                XCTAssertEqual(section.frame.minX, header.frame.minX, accuracy: 1, id)
                XCTAssertEqual(section.frame.maxX, header.frame.maxX, accuracy: 1, id)
            }
            let tags = app.descendants(matching: .any)["detail.tags-card"].firstMatch
            XCTAssertFalse(tags.staticTexts["标签"].exists)
            XCTAssertFalse(tags.staticTexts["detail.tags.feedback"].exists)
            let artist = tags.descendants(matching: .any)["detail.tags.group.artist"].firstMatch
            let language = tags.descendants(matching: .any)["detail.tags.group.language"].firstMatch
            for (group, label, tagID) in [(artist, "作者：", "artist:preview studio"), (language, "语言：", "language:chinese")] {
                let title = group.staticTexts[label]
                let chip = group.buttons["detail.tag.\(tagID)"]
                XCTAssertTrue(chip.exists)
                XCTAssertEqual(title.frame.minX - group.frame.minX, 8, accuracy: 1)
                XCTAssertEqual(chip.frame.minX - title.frame.maxX, 4, accuracy: 1)
                XCTAssertEqual(chip.frame.midY, title.frame.midY, accuracy: 1)
                XCTAssertEqual(chip.frame.height, max(32, title.frame.height), accuracy: 1)
                XCTAssertEqual(group.frame.minX - tags.frame.minX, 4, accuracy: 1)
                XCTAssertEqual(tags.frame.maxX - group.frame.maxX, 4, accuracy: 1)
            }
            XCTAssertEqual(artist.frame.minX - tags.frame.minX, 4, accuracy: 1)
            XCTAssertEqual(artist.frame.minY - tags.frame.minY, 4, accuracy: 1)
            if !extra.contains("--qa-large-type") {
                XCTAssertEqual(language.frame.minY - artist.frame.maxY, 4, accuracy: 1)
            }
            let site = app.descendants(matching: .any)["detail.site-card"].firstMatch
            let sitePage = site.buttons["detail.site-page"]
            let siteDownload = site.buttons["detail.download"]
            XCTAssertEqual(sitePage.frame.minX - site.frame.minX, 4, accuracy: 1)
            XCTAssertEqual(sitePage.frame.minY - site.frame.minY, 4, accuracy: 1)
            XCTAssertEqual(site.frame.maxX - siteDownload.frame.maxX, 4, accuracy: 1)
            XCTAssertEqual(siteDownload.frame.minY - sitePage.frame.maxY, 4, accuracy: 1)
            XCTAssertEqual(site.frame.maxY - siteDownload.frame.maxY, 4, accuracy: 1)
            if extra.contains("--qa-detail-long-tag") {
                let group = tags.descendants(matching: .any)["detail.tags.group.character"].firstMatch
                let title = group.staticTexts["角色："]
                let chip = group.buttons["detail.tag.character:a deliberately long character name to test the first tag wrapping beside its group"]
                XCTAssertTrue(chip.exists)
                XCTAssertEqual(chip.frame.minX - title.frame.maxX, 4, accuracy: 1)
                XCTAssertEqual(chip.frame.minY - group.frame.minY, 2, accuracy: 1)
                XCTAssertLessThanOrEqual(chip.frame.maxX, group.frame.maxX - 7)
            }
            XCTAssertLessThan(app.buttons["detail.more"].frame.maxY, read.frame.minY)
            favorite.tap()
            XCTAssertTrue(app.buttons["favorite.editor.edit"].waitForExistence(timeout: 6))
            app.buttons["favorite.editor.cancel"].tap()
            if !extra.contains("--qa-large-type") {
                for id in ["artist:preview studio", "language:chinese"] {
                    let tag = tags.buttons["detail.tag.\(id)"]
                    XCTAssertTrue(tag.isHittable)
                    tag.tap()
                    XCTAssertEqual(tag.value as? String, "已选中")
                }
                XCTAssertTrue(app.staticTexts["已选 2 个"].exists)
                let artistTag = tags.buttons["detail.tag.artist:preview studio"]
                artistTag.press(forDuration: 0.8)
                let pin = app.buttons["加入常用标签"]
                XCTAssertTrue(pin.waitForExistence(timeout: 5))
                pin.tap()
                let feedback = tags.staticTexts["detail.tags.feedback"]
                XCTAssertTrue(feedback.waitForExistence(timeout: 5))
                XCTAssertTrue(feedback.label.contains("常用"))
                XCTAssertTrue(app.staticTexts["已选 2 个"].exists)
                app.buttons["detail.tags.search-menu"].tap()
                app.buttons["detail.tags.new-search"].tap()
                XCTAssertTrue(app.searchComposerTitle("新建搜索").waitForExistence(timeout: 5))
                app.buttons["compose.cancel"].tap()
                let cancel = app.buttons["detail.tags.cancel"]
                XCTAssertTrue(cancel.waitForExistence(timeout: 5))
                cancel.tap()
                XCTAssertEqual(artistTag.value as? String, "未选中")
                XCTAssertFalse(feedback.exists)
            }
            app.terminate()
        }
    }
}
