import XCTest

final class Chrome132UITests: XCTestCase {
    override func tearDown() { XCUIDevice.shared.orientation = .portrait; super.tearDown() }
    private func launch(_ extra: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(); app.launchArguments = ["--qa", "--qa-tags-offline"] + extra
        app.launch()
        XCTAssertTrue(app.buttons["discover.lane.3"].waitForExistence(timeout: 10))
        return app
    }
    func test168DetailSearchReturnsThroughResultsAndPreservesSourceSelection() {
        let app = launch()
        let source = app.buttons["gallery.open.1"]
        XCTAssertTrue(source.waitForExistence(timeout: 8))
        let originalY = source.frame.minY
        source.tap()
        let tag = app.buttons["detail.tag.language:chinese"]
        XCTAssertTrue(tag.waitForExistence(timeout: 8))
        for _ in 0..<6 { if tag.isHittable { break }; app.swipeUp() }
        tag.tap()
        app.buttons["detail.tags.search-menu"].tap()
        let newSearch = app.buttons["detail.tags.new-search"]
        XCTAssertTrue(newSearch.waitForExistence(timeout: 5))
        XCTAssertEqual(newSearch.label, "新建搜索")
        XCTAssertEqual(app.buttons["detail.tags.pin"].label, "加入常用")
        XCTAssertEqual(app.buttons["detail.tags.block"].label, "屏蔽标签")
        newSearch.tap()
        XCTAssertTrue(app.buttons["discover.search-entry"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["discover.lane.3"].isSelected)
        let back = app.buttons["discover.previous-search"]
        XCTAssertTrue(back.isEnabled)
        let result = app.buttons["gallery.open.2"]
        XCTAssertTrue(result.waitForExistence(timeout: 8)); result.tap()
        XCTAssertTrue(app.buttons["detail.read"].waitForExistence(timeout: 8))
        app.buttons["BackButton"].tap()
        XCTAssertTrue(result.waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["detail.read"].exists)
        XCTAssertEqual(app.descendants(matching: .any)["search.flow.qa.0"].firstMatch.value as? String, "path=0;depth=0;query=1")
        XCTAssertTrue(app.buttons["discover.previous-search"].isHittable)
        result.tap()
        XCTAssertTrue(app.buttons["detail.read"].waitForExistence(timeout: 8))
        let secondTag = app.buttons["detail.tag.other:full color"]
        for _ in 0..<6 { if secondTag.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(secondTag.exists); secondTag.tap()
        app.buttons["detail.tags.search-menu"].tap()
        app.buttons["detail.tags.new-search"].tap()
        XCTAssertTrue(app.buttons["discover.search-entry"].waitForExistence(timeout: 8))
        back.tap()
        XCTAssertTrue(secondTag.waitForExistence(timeout: 8))
        XCTAssertEqual(secondTag.value as? String, "已选中")
        app.buttons["detail.tags.cancel"].tap()
        app.buttons["BackButton"].tap()
        XCTAssertTrue(result.waitForExistence(timeout: 8))
        back.tap()
        XCTAssertTrue(tag.waitForExistence(timeout: 8))
        XCTAssertEqual(tag.value as? String, "已选中")
        app.buttons["detail.tags.cancel"].tap()
        app.buttons["BackButton"].tap()
        XCTAssertTrue(source.waitForExistence(timeout: 8))
        XCTAssertEqual(source.frame.minY, originalY, accuracy: 1)
        XCTAssertTrue(app.buttons["discover.lane.0"].isSelected)
    }

    func test163CoverWindowLoadsVisibleCellsAfterFastScrollReverseAndRotation() {
        let app = launch(["--qa-feed-performance", "--qa-cover-window"])
        let probe = app.staticTexts["cover-window.qa"]
        func visibleIDs() -> [String] {
            let raw = probe.label
            let first = raw.components(separatedBy: ";").first ?? ""
            return first.replacingOccurrences(of: "visible=", with: "").split(separator: ",").map(String.init)
        }
        func assertLoaded() {
            let check = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                let ids = visibleIDs()
                let decoded = (probe.label.components(separatedBy: ";").first { $0.hasPrefix("decoded=") } ?? "")
                    .replacingOccurrences(of: "decoded=", with: "").split(separator: ",").map(String.init)
                return !ids.isEmpty && Set(ids).isSubset(of: Set(decoded))
            }, object: app)
            let result = XCTWaiter.wait(for: [check], timeout: 12)
            if result != .completed {
                print("COVER163_READBACK", probe.label)
                let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "cover163.readback-failure"; shot.lifetime = .keepAlways; add(shot)
            }
            XCTAssertEqual(result, .completed)
        }
        XCTAssertTrue(probe.waitForExistence(timeout: 8))
        assertLoaded()
        let initial = visibleIDs()
        let initialShot = XCTAttachment(screenshot: app.screenshot()); initialShot.name = "cover163.initial-decoded"; initialShot.lifetime = .keepAlways; add(initialShot)
        for _ in 0..<3 { app.swipeUp(velocity: .fast) }
        assertLoaded()
        XCTAssertNotEqual(visibleIDs(), initial)
        for _ in 0..<3 { app.swipeDown(velocity: .fast) }
        assertLoaded()
        XCUIDevice.shared.orientation = .landscapeLeft
        expectation(for: NSPredicate { _, _ in app.windows.firstMatch.frame.width > app.windows.firstMatch.frame.height }, evaluatedWith: app)
        waitForExpectations(timeout: 5)
        assertLoaded()
        XCUIDevice.shared.orientation = .portrait
        assertLoaded()
        let finalShot = XCTAttachment(screenshot: app.screenshot()); finalShot.name = "cover163.after-scroll-reverse-rotation"; finalShot.lifetime = .keepAlways; add(finalShot)
    }

    func test164DetailReturnsToItsSourceDiscoveryLaneForButtonAndBothEdges() {
        let app = launch(["--qa-feed-performance", "--qa-cover-window"])
        for lane in [0, 1] {
            if !app.buttons["discover.lane.\(lane)"].isSelected {
                app.buttons["discover.lane.\(lane)"].tap()
            }
            selected(app, "discover.lane.\(lane)")
            for method in 0..<3 {
                let card = app.buttons["gallery.open.20000"]
                XCTAssertTrue(card.waitForExistence(timeout: 8))
                card.tap()
                XCTAssertTrue(app.buttons["detail.read"].waitForExistence(timeout: 8))
                if method == 0 { app.buttons["BackButton"].tap() }
                else { edge(app, left: method == 1, fraction: 0.7) }
                XCTAssertTrue(card.waitForExistence(timeout: 8))
                print("RETURN164", lane, method, app.descendants(matching: .any)["root.navigation.qa"].firstMatch.value ?? "missing")
                selected(app, "discover.lane.\(lane)")
                XCTAssertTrue(app.buttons["main.tab.discover"].isSelected)
            }
        }
    }

    func test164SearchDetailReturnsToResultsAfterNewAndExtendedSearch() {
        let app = launch()
        app.buttons["discover.lane.3"].tap()
        app.buttons["discover.search-entry"].tap()
        let text = app.textFields["compose.text"]
        XCTAssertTrue(text.waitForExistence(timeout: 5)); text.tap(); text.typeText("stack164")
        app.buttons["compose.apply"].tap()
        let state = app.descendants(matching: .any)["root.navigation.qa"].firstMatch
        for id in [1, 2, 3] {
            let card = app.buttons["gallery.open.\(id)"]
            XCTAssertTrue(card.waitForExistence(timeout: 8))
            card.tap()
            XCTAssertTrue(app.buttons["detail.read"].waitForExistence(timeout: 8))
            let native = app.descendants(matching: .any)["qa.navigation.flat"].firstMatch
            print("SEARCH_STACK164_OPEN", id, state.value ?? "missing", native.value ?? "no native probe")
            XCTAssertTrue((native.value as? String ?? "").hasPrefix("stack=2;"))
            XCTAssertTrue((state.value as? String ?? "").contains("discovery=1;"))
            if id == 3 {
                for method in 0..<3 {
                    if method > 0 {
                        card.tap()
                        XCTAssertTrue(app.buttons["detail.read"].waitForExistence(timeout: 8))
                    }
                    if method == 0 { app.buttons["BackButton"].tap() }
                    else { edge(app, left: method == 1, fraction: 0.7) }
                    XCTAssertTrue(card.waitForExistence(timeout: 8))
                    XCTAssertTrue(app.buttons["discover.lane.3"].isSelected)
                    XCTAssertFalse(app.buttons["detail.read"].exists)
                    XCTAssertTrue((state.value as? String ?? "").contains("discovery=1;"))
                }
            } else {
                let tag = app.buttons[id == 1 ? "detail.tag.language:chinese" : "detail.tag.other:full color"]
                for _ in 0..<6 { if tag.isHittable { break }; app.swipeUp() }
                tag.tap(); app.buttons["detail.tags.search-menu"].tap()
                if id == 1 { app.buttons["detail.tags.new-search"].tap() }
                else {
                    app.buttons["detail.tags.add-to-search"].tap()
                    XCTAssertTrue(app.buttons["compose.apply"].waitForExistence(timeout: 5))
                    app.buttons["compose.cancel"].tap()
                    XCTAssertTrue(tag.waitForExistence(timeout: 8))
                    XCTAssertEqual(tag.value as? String, "已选中")
                    app.buttons["detail.tags.search-menu"].tap()
                    XCTAssertEqual(app.buttons["detail.tags.add-to-search"].label, "加入搜索")
                    app.buttons["detail.tags.add-to-search"].tap()
                    XCTAssertTrue(app.buttons["compose.apply"].waitForExistence(timeout: 5))
                    app.buttons["compose.apply"].tap()
                }
                XCTAssertTrue(app.buttons["discover.search-entry"].waitForExistence(timeout: 8))
                print("SEARCH_STACK164_RESULTS", id, state.value ?? "missing")
                XCTAssertTrue((state.value as? String ?? "").contains("discovery=1;"))
            }
        }
        let previous = app.buttons["discover.previous-search"]
        XCTAssertEqual(previous.label, "返回上一搜索")
        previous.tap()
        XCTAssertEqual(previous.label, "返回来源")
        previous.tap()
        XCTAssertTrue(app.buttons["detail.tag.language:chinese"].waitForExistence(timeout: 8))
        app.buttons["detail.tags.cancel"].tap()
        app.buttons["BackButton"].tap()
        XCTAssertTrue(app.buttons["discover.search-entry"].waitForExistence(timeout: 8))
        XCTAssertTrue((state.value as? String ?? "").contains("discovery=0;"))
    }
    private func selected(_ app: XCUIApplication, _ id: String) {
        let check = XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: app.buttons[id])
        XCTAssertEqual(XCTWaiter.wait(for: [check], timeout: 5), .completed)
    }
    private func edge(_ app: XCUIApplication, left: Bool, fraction: CGFloat, y: CGFloat = 0.55) {
        let start = app.coordinate(withNormalizedOffset: .init(dx: left ? 0.005 : 0.995, dy: y))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(.init(dx: (left ? 1 : -1) * app.frame.width * fraction, dy: 0)), withVelocity: .slow, thenHoldForDuration: 0.2)
    }
    private func values(_ app: XCUIApplication, _ id: String = "chrome.motion.samples") -> [Double] {
        let probe = app.descendants(matching: .any)[id].firstMatch
        XCTAssertTrue(probe.waitForExistence(timeout: 5))
        return (probe.value as? String ?? "").split(separator: ",").compactMap { Double($0) }
    }
    private func paneCounts(_ app: XCUIApplication, _ identifier: String) -> [Int: Int] {
        let probe = app.descendants(matching: .any)[identifier + ".paging"].firstMatch
        let raw = probe.value as? String ?? ""
        guard let list = raw.components(separatedBy: "instances=").last else { return [:] }
        return Dictionary(uniqueKeysWithValues: list.split(separator: ",").compactMap {
            let pair = $0.split(separator: ":")
            guard pair.count == 2, let key = Int(pair[0]), let value = Int(pair[1]) else { return nil }
            return (key, value)
        })
    }

    func test148SearchDisclosuresAnimateAndRetainConditions() {
        let app = launch(["--qa-library-sort", "--qa-reset-library-sort"])
        app.buttons["discover.lane.3"].tap(); selected(app, "discover.lane.3")
        app.buttons["discover.search-entry"].tap()
        let advanced = app.buttons["compose.filters"]
        XCTAssertTrue(advanced.waitForExistence(timeout: 5))
        let top = advanced.frame.minY, bottom = app.buttons["main.tab.discover"].frame
        func animated(_ name: String) {
            XCTAssertTrue(values(app, "compose.disclosure." + name).contains { $0 > 0.05 && $0 < 0.95 }, "Missing height animation: \(name)")
        }
        func reveal(_ element: XCUIElement) {
            for _ in 0..<8 { if element.isHittable { return }; app.swipeUp() }
            XCTAssertTrue(element.isHittable)
        }
        advanced.tap()
        let tagDisclosure = app.buttons["compose.tags.disclosure"]
        XCTAssertTrue(tagDisclosure.waitForExistence(timeout: 5)); animated("advanced")
        let add = app.buttons["compose.tag-source.0"]
        let common = app.buttons["compose.tag-source.1"]
        XCTAssertFalse(add.exists); XCTAssertFalse(common.exists)
        tagDisclosure.tap()
        XCTAssertTrue(add.waitForExistence(timeout: 5)); animated("tag-group")
        XCTAssertTrue(add.isSelected)
        let lookup = app.textFields["tag.name"]
        XCTAssertTrue(lookup.waitForExistence(timeout: 5))
        lookup.tap(); lookup.typeText("gaping")
        add.tap(); XCTAssertTrue(lookup.exists) // A selected segment never collapses its panel.
        common.tap()
        XCTAssertTrue(lookup.waitForNonExistence(timeout: 5))
        let favorite = app.buttons["compose.favorite-tag.language:english"]
        XCTAssertTrue(favorite.waitForExistence(timeout: 5))
        favorite.tap()
        add.tap(); XCTAssertTrue(favorite.waitForNonExistence(timeout: 5))
        XCTAssertTrue(lookup.waitForExistence(timeout: 5))
        XCTAssertEqual(lookup.value as? String, "gaping")
        tagDisclosure.tap(); XCTAssertTrue(lookup.waitForNonExistence(timeout: 5))
        tagDisclosure.tap(); XCTAssertTrue(lookup.waitForExistence(timeout: 5))
        XCTAssertEqual(lookup.value as? String, "gaping")
        XCTAssertTrue(app.buttons["compose.rule.remove.language:english"].exists)
        let categories = app.buttons["compose.categories.disclosure"]
        reveal(categories)
        let category = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "compose.category.")).firstMatch
        reveal(category); category.tap(); let chosen = category.value as? String
        categories.tap(); XCTAssertTrue(category.waitForNonExistence(timeout: 5))
        animated("categories")
        categories.tap(); XCTAssertTrue(category.waitForExistence(timeout: 5))
        XCTAssertEqual(category.value as? String, chosen)
        categories.tap()
        let matching = app.buttons["compose.matching.disclosure"]
        reveal(matching)
        let titleOnly = app.switches["仅搜标题"]
        reveal(titleOnly); titleOnly.tap(); let option = titleOnly.value as? String
        matching.tap(); XCTAssertTrue(titleOnly.waitForNonExistence(timeout: 5)); animated("matching")
        matching.tap(); XCTAssertTrue(titleOnly.waitForExistence(timeout: 5))
        XCTAssertEqual(titleOnly.value as? String, option)
        matching.tap()
        for _ in 0..<8 { if advanced.isHittable { break }; app.swipeDown() }
        advanced.tap(); XCTAssertTrue(add.waitForNonExistence(timeout: 5))
        advanced.tap(); XCTAssertTrue(add.waitForExistence(timeout: 5))
        XCTAssertEqual(categories.value as? String, "已收起")
        XCTAssertEqual(matching.value as? String, "已收起")
        XCTAssertTrue(app.buttons["compose.rule.remove.language:english"].exists)
        add.tap(); XCTAssertTrue(lookup.waitForExistence(timeout: 5))
        XCTAssertEqual(lookup.value as? String, "gaping")
        XCTAssertEqual(advanced.frame.minY, top, accuracy: 1)
        XCTAssertEqual(app.buttons["main.tab.discover"].frame, bottom)
    }

    func test148LandscapeDisclosureKeepsUsableFields() {
        let app = launch()
        app.buttons["discover.lane.3"].tap(); selected(app, "discover.lane.3")
        app.buttons["discover.search-entry"].tap()
        let advanced = app.buttons["compose.filters"]
        XCTAssertTrue(advanced.waitForExistence(timeout: 5))
        advanced.tap()
        XCTAssertTrue(app.textFields["compose.artist"].waitForExistence(timeout: 5))
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(advanced.waitForExistence(timeout: 5))
        advanced.tap(); XCTAssertTrue(app.textFields["compose.artist"].waitForNonExistence(timeout: 5))
        advanced.tap(); XCTAssertTrue(app.textFields["compose.artist"].waitForExistence(timeout: 5))
        let author = app.textFields["compose.artist"]
        for _ in 0..<5 { if author.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(author.isHittable)
        author.tap(); author.typeText("coast")
        XCTAssertEqual(author.value as? String, "coast")
    }

    func test151SearchGroupsAndTagSourceSegments() {
        let app = launch(["--qa-library-sort", "--qa-reset-library-sort"])
        app.buttons["discover.lane.3"].tap(); selected(app, "discover.lane.3")
        app.buttons["discover.search-entry"].tap()
        let advanced = app.buttons["compose.filters"]
        XCTAssertTrue(advanced.waitForExistence(timeout: 5)); advanced.tap()
        let add = app.buttons["compose.tag-source.0"]
        XCTAssertFalse(add.exists)
        let tagDisclosure = app.buttons["compose.tags.disclosure"]
        let title = app.staticTexts["compose.tags.disclosure.title"]
        XCTAssertTrue(title.exists)
        tagDisclosure.tap()
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        XCTAssertTrue(title.waitForNonExistence(timeout: 5))
        XCTAssertEqual(add.frame.midY, tagDisclosure.frame.midY, accuracy: 1)
        XCTAssertEqual(add.frame.width, app.buttons["compose.tag-source.1"].frame.width, accuracy: 1)
        add.tap()
        let lookup = app.textFields["tag.name"]
        XCTAssertTrue(lookup.waitForExistence(timeout: 5))
        let tags = app.descendants(matching: .any)["compose.tags-group"].firstMatch
        XCTAssertTrue(tags.exists)
        XCTAssertGreaterThanOrEqual(lookup.frame.minX, tags.frame.minX)
        XCTAssertLessThanOrEqual(lookup.frame.maxX, tags.frame.maxX)
        XCTAssertLessThanOrEqual(lookup.frame.maxY, tags.frame.maxY)
        tagDisclosure.tap(); XCTAssertTrue(lookup.waitForNonExistence(timeout: 5))
        tagDisclosure.tap(); XCTAssertTrue(lookup.waitForExistence(timeout: 5))
        XCTAssertEqual(tagDisclosure.frame.width, tagDisclosure.frame.height, accuracy: 1)
        add.tap()
        let categories = app.buttons["compose.categories.disclosure"]
        for _ in 0..<6 { if categories.isHittable { break }; app.swipeUp() }
        let all = app.buttons["compose.categories.select-all"]
        let invert = app.buttons["compose.categories.invert"]
        XCTAssertLessThanOrEqual(app.staticTexts["compose.categories.disclosure.title"].frame.maxX, all.frame.minX)
        XCTAssertEqual(categories.frame.width, categories.frame.height, accuracy: 1)
        XCTAssertGreaterThan(advanced.frame.width, advanced.frame.height)
        XCTAssertLessThanOrEqual(all.frame.maxX, invert.frame.minX)
        XCTAssertLessThanOrEqual(invert.frame.maxX, categories.frame.minX)
        XCTAssertEqual(all.frame.height, categories.frame.height, accuracy: 1)
        categories.tap()
        XCTAssertTrue(app.buttons["compose.categories.invert"].waitForNonExistence(timeout: 5))
        for _ in 0..<6 { if advanced.isHittable { break }; app.swipeDown() }
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "search151.grouped.portrait"; attachment.lifetime = .keepAlways; self.add(attachment)
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        // Existence survives rotation; drive a disclosure to wait for the new layout.
        advanced.tap(); XCTAssertTrue(add.waitForNonExistence(timeout: 5))
        advanced.tap(); XCTAssertTrue(add.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(app.frame.width, app.frame.height)
        XCTAssertLessThanOrEqual(app.buttons["compose.tag-source.1"].frame.maxX, app.frame.maxX)
        let landscape = XCTAttachment(screenshot: app.screenshot())
        landscape.name = "search151.grouped.landscape"; landscape.lifetime = .keepAlways; self.add(landscape)
    }

    func test153OriginalTagOnlyAfterEmptySearchWithLeadingNamespace() {
        let app = launch(["--qa-dark"])
        app.buttons["discover.lane.3"].tap(); selected(app, "discover.lane.3")
        app.buttons["discover.search-entry"].tap()
        let advanced = app.buttons["compose.filters"]
        XCTAssertTrue(advanced.waitForExistence(timeout: 5)); advanced.tap()
        let tags = app.buttons["compose.tags.disclosure"]
        tags.tap()
        let input = app.textFields["tag.name"], clear = app.buttons["tag.clear"]
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        XCTAssertEqual(input.frame.midY, clear.frame.midY, accuracy: 1)
        XCTAssertGreaterThan(clear.frame.minX, app.buttons["tag.namespace-filter"].frame.maxX)
        let topShot = XCTAttachment(screenshot: app.screenshot())
        topShot.name = "search152.dark.initial"; topShot.lifetime = .keepAlways; add(topShot)
        advanced.tap(); XCTAssertTrue(input.waitForNonExistence(timeout: 5))
        let collapsed = XCTAttachment(screenshot: app.screenshot())
        collapsed.name = "search152.dark.collapsed"; collapsed.lifetime = .keepAlways; add(collapsed)
        advanced.tap(); XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap(); input.typeText("gap")
        let candidate = app.buttons["tag.suggestion.female:gaping"]
        XCTAssertTrue(candidate.waitForExistence(timeout: 8))
        let candidateFrame = candidate.frame
        let original = app.descendants(matching: .any)["tag.stage"].firstMatch
        XCTAssertFalse(original.exists) // Partial candidate matches do not expose raw-name entry.
        clear.tap(); input.tap(); input.typeText("zzqaoriginal153")
        XCTAssertTrue(original.waitForExistence(timeout: 8))
        XCTAssertTrue(candidate.waitForNonExistence(timeout: 5))
        XCTAssertEqual(original.frame.minX, candidateFrame.minX, accuracy: 1)
        XCTAssertEqual(original.frame.width, candidateFrame.width, accuracy: 1)
        XCTAssertEqual(original.frame.height, candidateFrame.height, accuracy: 1)
        let namespacePicker = app.buttons["tag.stage.namespace"]
        let addOriginal = app.buttons["tag.stage.add"]
        XCTAssertFalse(addOriginal.isEnabled)
        XCTAssertLessThan(namespacePicker.frame.maxX, addOriginal.frame.minX)
        namespacePicker.tap()
        let namespace = app.buttons["tag.stage.namespace.language"]
        XCTAssertTrue(namespace.waitForExistence(timeout: 5)); namespace.tap()
        XCTAssertTrue(addOriginal.isEnabled)
        XCTAssertEqual(input.value as? String, "zzqaoriginal153")
        addOriginal.tap()
        XCTAssertTrue(app.buttons["compose.rule.remove.language:zzqaoriginal153"].waitForExistence(timeout: 5))
        clear.tap(); XCTAssertTrue(clear.exists)
        XCTAssertEqual(input.value as? String, input.placeholderValue)
        XCTAssertTrue(original.waitForNonExistence(timeout: 5))
        tags.tap()
        let work = app.buttons["compose.work.disclosure"], author = app.textFields["compose.artist"]
        XCTAssertTrue(author.waitForExistence(timeout: 5))
        author.tap(); author.typeText("coast")
        work.tap(); XCTAssertTrue(author.waitForNonExistence(timeout: 5))
        work.tap(); XCTAssertTrue(author.waitForExistence(timeout: 5))
        XCTAssertEqual(author.value as? String, "coast")
        work.tap()
        let save = app.buttons["compose.save-favorite"], reset = app.buttons["compose.clear"]
        for _ in 0..<8 { if save.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(save.isHittable); XCTAssertTrue(reset.isHittable)
        XCTAssertEqual(save.frame.midY, reset.frame.midY, accuracy: 1)
        XCTAssertEqual(save.frame.width, reset.frame.width, accuracy: 1)
        XCTAssertEqual(save.frame.height, reset.frame.height, accuracy: 1)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "search152.actions"; shot.lifetime = .keepAlways; add(shot)
    }

    func test153DetailTagSearchReopensWithExecutedTags() {
        let app = launch()
        let gallery = app.buttons["gallery.open.1"]
        XCTAssertTrue(gallery.waitForExistence(timeout: 8)); gallery.tap()
        let tag = app.buttons["detail.tag.language:chinese"]
        XCTAssertTrue(tag.waitForExistence(timeout: 8))
        for _ in 0..<8 { if tag.isHittable { break }; app.swipeUp() }
        tag.tap()
        app.buttons["detail.tags.search-menu"].tap()
        let search = app.buttons["detail.tags.new-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap()
        let results = app.buttons["discover.search-entry"]
        XCTAssertTrue(results.waitForExistence(timeout: 8))
        XCTAssertTrue((results.value as? String ?? "").contains("language:chinese"))
        for lane in 0..<4 { XCTAssertTrue(app.buttons["discover.lane.\(lane)"].exists) }
        selected(app, "discover.lane.3")
        XCTAssertTrue(app.buttons["main.tab.discover"].isSelected)
        XCTAssertFalse(app.buttons["search.results.close"].exists)
        XCTAssertFalse(app.buttons["detail.tags.search-menu"].exists)
        app.buttons["discover.filters"].tap()
        let rule = app.buttons["compose.rule.remove.language:chinese"]
        XCTAssertTrue(rule.waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["compose.tags.disclosure"].value as? String, "已展开")
        XCTAssertTrue(app.buttons["compose.rule.match.language:chinese"].exists)
        app.buttons["compose.cancel"].tap()
        XCTAssertTrue(results.waitForExistence(timeout: 5))
        results.tap()
        let advanced = app.buttons["compose.filters"]
        XCTAssertTrue(advanced.waitForExistence(timeout: 5)); advanced.tap()
        XCTAssertTrue(rule.waitForExistence(timeout: 5))
    }

    func test160PreviousSearchButtonHasFixedSlotAndRestoresPreviousQuery() {
        let app = launch()
        app.buttons["discover.lane.3"].tap(); selected(app, "discover.lane.3")
        let back = app.buttons["discover.previous-search"]
        let common = app.buttons["discover.saved-menu"]
        XCTAssertTrue(back.waitForExistence(timeout: 5)); XCTAssertFalse(back.isEnabled)
        XCTAssertEqual(back.frame.width, common.frame.width, accuracy: 1)
        XCTAssertLessThan(back.frame.maxX, common.frame.maxX)
        let shortcuts = app.descendants(matching: .any)["discover.search-shortcuts"].firstMatch
        let filters = app.buttons["discover.filters"]
        let search = app.buttons["discover.search-entry"]
        XCTAssertLessThanOrEqual(shortcuts.frame.maxX, search.frame.minX)
        XCTAssertEqual(shortcuts.frame.width, app.buttons["discover.lane.3"].frame.width, accuracy: 2)
        XCTAssertEqual(back.frame.midY, common.frame.midY, accuracy: 1)
        XCTAssertEqual(search.frame.midY, common.frame.midY, accuracy: 1)
        XCTAssertGreaterThan(filters.frame.minX, shortcuts.frame.maxX)
        let frame = back.frame
        app.buttons["discover.search-entry"].tap()
        let text = app.textFields["compose.text"]
        XCTAssertTrue(text.waitForExistence(timeout: 5)); text.tap(); text.typeText("first-query\n")
        app.buttons["compose.apply"].tap()
        XCTAssertTrue(back.waitForExistence(timeout: 5)); XCTAssertFalse(back.isEnabled)
        app.buttons["gallery.open.1"].tap()
        let tag = app.buttons["detail.tag.language:chinese"]
        XCTAssertTrue(tag.waitForExistence(timeout: 8))
        for _ in 0..<6 { if tag.isHittable { break }; app.swipeUp() }
        tag.tap(); app.buttons["detail.tags.search-menu"].tap(); app.buttons["detail.tags.new-search"].tap()
        let returned = back.waitForExistence(timeout: 8)
        if !returned {
            print("ROOT_SEARCH_RETURN", app.descendants(matching: .any)["root.navigation.qa"].firstMatch.value ?? "missing")
            let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "search160.return-failure"; shot.lifetime = .keepAlways; add(shot)
        }
        XCTAssertTrue(returned); XCTAssertTrue(back.isEnabled)
        XCTAssertEqual(back.frame, frame)
        back.tap()
        expectation(for: NSPredicate(format: "value CONTAINS %@", "first-query"), evaluatedWith: search)
        waitForExpectations(timeout: 5)
        XCTAssertFalse(back.isEnabled)
        XCTAssertEqual(back.frame, frame)
        XCTAssertTrue(app.buttons["gallery.open.1"].exists)
        common.tap()
        XCTAssertTrue(app.buttons["search-presets.close"].waitForExistence(timeout: 5))
        app.buttons["search-presets.close"].tap()
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        XCUIDevice.shared.orientation = .landscapeLeft
        expectation(for: NSPredicate { _, _ in
            app.windows.firstMatch.frame.width > app.windows.firstMatch.frame.height
        }, evaluatedWith: app)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(common.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(shortcuts.frame.maxX, search.frame.minX)
        XCTAssertEqual(back.frame.width, common.frame.width, accuracy: 1)
        XCTAssertEqual(shortcuts.frame.width, app.buttons["discover.lane.3"].frame.width, accuracy: 2)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "search161.compact-shortcuts.landscape"; shot.lifetime = .keepAlways; add(shot)
    }

    func test159LibraryDetailSearchUsesMainPageAndLandscapeTagMenu() {
        let app = launch(["--qa-library-sort", "--qa-reset-library-sort"])
        app.buttons["main.tab.library"].tap()
        let item = app.buttons["favorites.gallery.7201"]
        XCTAssertTrue(item.waitForExistence(timeout: 8)); item.tap()
        let tag = app.buttons["detail.tag.language:chinese"]
        XCTAssertTrue(tag.waitForExistence(timeout: 8))
        for _ in 0..<6 { if tag.isHittable { break }; app.swipeUp() }
        tag.tap(); app.buttons["detail.tags.search-menu"].tap()
        app.buttons["detail.tags.new-search"].tap()
        let search = app.buttons["discover.search-entry"]
        XCTAssertTrue(search.waitForExistence(timeout: 8))
        selected(app, "discover.lane.3")
        XCTAssertTrue(app.buttons["main.tab.discover"].isSelected)
        XCTAssertTrue((search.value as? String ?? "").contains("language:chinese"))
        XCTAssertFalse(app.descendants(matching: .any)["discover.search.empty"].exists)
        let header = app.descendants(matching: .any)["discover.header.floating"].firstMatch
        let height = header.frame.height
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        XCTAssertEqual(header.frame.height, height, accuracy: 2)
        // Row hit areas may share a boundary; the control faces carry their own insets.
        XCTAssertGreaterThanOrEqual(search.frame.minY, app.buttons["discover.lane.3"].frame.maxY)
        app.buttons["discover.filters"].tap()
        let rule = app.buttons["compose.rule.remove.language:chinese"]
        XCTAssertTrue(rule.waitForExistence(timeout: 5))
        let category = app.staticTexts.matching(identifier: "tag.category.language").firstMatch
        XCTAssertTrue(category.waitForExistence(timeout: 5)); category.press(forDuration: 0.65)
        let save = app.buttons["tag.library.favorite"]
        XCTAssertTrue(save.waitForExistence(timeout: 5)); save.tap()
        XCTAssertTrue(rule.exists)
        app.buttons["compose.cancel"].tap()
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        app.buttons["discover.previous-search"].tap()
        XCTAssertTrue(tag.waitForExistence(timeout: 8))
        XCTAssertEqual(tag.value as? String, "已选中")
        XCTAssertTrue(app.buttons["main.tab.library"].isSelected)
        app.buttons["detail.tags.cancel"].tap()
        app.buttons["BackButton"].tap()
        XCTAssertTrue(item.waitForExistence(timeout: 5))
    }

    func test159ReaderDetailSearchLeavesReaderForMainSearchPage() {
        let app = launch()
        app.buttons["gallery.open.1"].tap()
        let read = app.buttons["detail.read"]
        XCTAssertTrue(read.waitForExistence(timeout: 8)); read.tap()
        let page = app.buttons["reader.page"]
        XCTAssertTrue(page.waitForExistence(timeout: 12))
        let originalPage = page.label
        XCTAssertFalse(originalPage.isEmpty)
        let info = app.buttons["reader.details.open"]
        XCTAssertTrue(info.waitForExistence(timeout: 5)); info.tap()
        let tag = app.buttons["detail.tag.language:chinese"]
        XCTAssertTrue(tag.waitForExistence(timeout: 8))
        for _ in 0..<6 { if tag.isHittable { break }; app.swipeUp() }
        tag.tap(); app.buttons["detail.tags.search-menu"].tap()
        app.buttons["detail.tags.new-search"].tap()
        let search = app.buttons["discover.search-entry"]
        XCTAssertTrue(search.waitForExistence(timeout: 8))
        selected(app, "discover.lane.3")
        XCTAssertTrue((search.value as? String ?? "").contains("language:chinese"))
        XCTAssertFalse(app.buttons["reader.close"].exists)
        XCTAssertTrue(app.buttons["main.tab.discover"].isSelected)
        app.buttons["discover.previous-search"].tap()
        XCTAssertTrue(tag.waitForExistence(timeout: 8))
        XCTAssertEqual(tag.value as? String, "已选中")
        let readerDetail = app.descendants(matching: .any)["reader.details"].firstMatch
        readerDetail.buttons["detail.tags.cancel"].tap()
        readerDetail.buttons["BackButton"].tap()
        XCTAssertTrue(page.waitForExistence(timeout: 8))
        XCTAssertEqual(page.label, originalPage)
        app.buttons["reader.close"].tap()
        XCTAssertTrue(app.buttons["detail.read"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["main.tab.discover"].isSelected)
    }

    func test159SearchCandidateToggleAndSharedTagManagement() {
        let app = launch(["--qa-library-sort", "--qa-reset-library-sort"])
        app.buttons["discover.lane.3"].tap()
        app.buttons["discover.search-entry"].tap()
        let advanced = app.buttons["compose.filters"]
        XCTAssertTrue(advanced.waitForExistence(timeout: 5))
        if advanced.value as? String != "已展开" { advanced.tap() }
        let disclosure = app.buttons["compose.tags.disclosure"]
        XCTAssertTrue(disclosure.waitForExistence(timeout: 5))
        if disclosure.value as? String != "已展开" { disclosure.tap() }
        let field = app.textFields["tag.name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap(); field.typeText("gaping\n")
        let candidate = app.buttons["tag.suggestion.female:gaping"]
        XCTAssertTrue(candidate.waitForExistence(timeout: 8))
        let rule = app.buttons["compose.rule.remove.female:gaping"]
        candidate.tap(); XCTAssertTrue(rule.waitForExistence(timeout: 5))
        candidate.tap(); XCTAssertTrue(rule.waitForNonExistence(timeout: 5))
        candidate.press(forDuration: 0.65)
        let favorite = app.buttons["tag.library.favorite"]
        XCTAssertTrue(favorite.waitForExistence(timeout: 5))
        XCTAssertEqual(favorite.label, "加入常用"); favorite.tap()
        XCTAssertFalse(rule.exists, "Long press management must not select a search rule")
        candidate.press(forDuration: 0.65)
        XCTAssertTrue(favorite.waitForExistence(timeout: 5))
        XCTAssertEqual(favorite.label, "移出常用")
        let block = app.buttons["tag.library.block"]
        XCTAssertEqual(block.label, "屏蔽标签"); block.tap()
        candidate.tap(); XCTAssertTrue(rule.waitForExistence(timeout: 5))
        // Press the rule's category instead of the remove button or match menu.
        let categories = app.staticTexts.matching(identifier: "tag.category.female")
        XCTAssertTrue(categories.firstMatch.waitForExistence(timeout: 5))
        let category = categories.allElementsBoundByIndex.last!
        category.press(forDuration: 0.65)
        XCTAssertTrue(block.waitForExistence(timeout: 5))
        XCTAssertEqual(block.label, "解除屏蔽"); block.tap()
        XCTAssertTrue(rule.exists)
        category.press(forDuration: 0.65)
        XCTAssertTrue(favorite.waitForExistence(timeout: 5))
        XCTAssertEqual(favorite.label, "移出常用"); favorite.tap()
        XCTAssertTrue(rule.exists)
        app.buttons["compose.tag-source.1"].tap()
        let saved = app.buttons["compose.favorite-tag.language:english"]
        XCTAssertTrue(saved.waitForExistence(timeout: 5))
        saved.tap(); XCTAssertTrue(app.buttons["compose.rule.remove.language:english"].exists)
        saved.tap(); XCTAssertFalse(app.buttons["compose.rule.remove.language:english"].exists)
        XCTAssertTrue(app.buttons["main.tab.discover"].exists)
    }

    func test157FeedFailureUsesCenteredToastAndRealRetryButton() {
        let app = launch(["--qa-feed-cache", "--qa-feed-cache-failure", "--qa-feed-cache-run", UUID().uuidString, "--qa-dark"])
        let toast = app.staticTexts["gallery.load-error"]
        let retry = app.buttons.matching(NSPredicate(format: "label == %@", "重试加载")).firstMatch
        XCTAssertTrue(retry.waitForExistence(timeout: 8))
        XCTAssertGreaterThanOrEqual(retry.frame.height, 36)
        // Startup feedback may finish while launch() waits for the process to idle.
        _ = toast.waitForNonExistence(timeout: 5)
        retry.tap()
        XCTAssertTrue(toast.waitForExistence(timeout: 5))
        XCTAssertEqual(toast.frame.midY, app.frame.midY, accuracy: 32)
        XCTAssertFalse(toast.label.contains("。"))
        XCTAssertFalse(toast.label.contains("，"))
        XCTAssertTrue(toast.waitForNonExistence(timeout: 5))
        XCTAssertTrue(retry.isHittable)
        XCTAssertTrue(app.buttons["main.tab.discover"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "feedback157.feed-error"; shot.lifetime = .keepAlways; add(shot)
    }

    func test156CategoryActionsUseTheirVisibleTargetsAndValidateOnlyOnSubmit() {
        let app = launch()
        app.buttons["discover.lane.3"].tap(); selected(app, "discover.lane.3")
        app.buttons["discover.search-entry"].tap()
        let history = app.buttons["compose.records"]
        let back = app.buttons["compose.cancel"]
        XCTAssertTrue(history.waitForExistence(timeout: 5))
        XCTAssertEqual(history.frame.width, back.frame.width, accuracy: 1)
        XCTAssertEqual(history.frame.height, back.frame.height, accuracy: 1)
        let advanced = app.buttons["compose.filters"]
        advanced.tap()
        app.buttons["compose.work.disclosure"].tap()
        let categories = app.buttons["compose.categories.disclosure"]
        let invert = app.buttons["compose.categories.invert"]
        let all = app.buttons["compose.categories.select-all"]
        XCTAssertTrue(invert.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(all.frame.maxX, invert.frame.minX)
        XCTAssertLessThanOrEqual(invert.frame.maxX, categories.frame.minX)
        let category = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "compose.category.")).firstMatch
        // Both visible ends are actionable; neither leaks into the disclosure.
        invert.coordinate(withNormalizedOffset: .init(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(category.value as? String, "未选择")
        XCTAssertEqual(categories.value as? String, "已展开")
        XCTAssertFalse(app.staticTexts["compose.categories.empty"].exists)
        XCTAssertFalse(app.staticTexts["compose.error"].exists)
        let y = categories.frame.minY
        let submit = app.buttons["compose.apply"]
        XCTAssertTrue(submit.isEnabled); submit.tap()
        let toast = app.staticTexts["compose.error"]
        XCTAssertTrue(toast.waitForExistence(timeout: 3))
        XCTAssertTrue(toast.label.contains("画廊分类"))
        XCTAssertEqual(toast.frame.midY, app.frame.midY, accuracy: 32)
        XCTAssertFalse(toast.label.contains("。"))
        XCTAssertFalse(toast.label.contains("，"))
        XCTAssertEqual(categories.frame.minY, y, accuracy: 1)
        XCTAssertTrue(toast.waitForNonExistence(timeout: 5))
        for left in [true, false] {
            edge(app, left: left, fraction: 0.55)
            XCTAssertTrue(toast.waitForExistence(timeout: 3))
            XCTAssertTrue(submit.exists)
            XCTAssertEqual(category.value as? String, "未选择")
            XCTAssertEqual(categories.frame.minY, y, accuracy: 1)
            XCTAssertTrue(toast.waitForNonExistence(timeout: 5))
        }
        all.coordinate(withNormalizedOffset: .init(dx: 0.1, dy: 0.5)).tap()
        XCTAssertEqual(category.value as? String, "已选择")
        invert.coordinate(withNormalizedOffset: .init(dx: 0.1, dy: 0.5)).tap()
        XCTAssertEqual(category.value as? String, "未选择")
        all.coordinate(withNormalizedOffset: .init(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(category.value as? String, "已选择")
        XCTAssertEqual(categories.value as? String, "已展开")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "search156.category-actions"; shot.lifetime = .keepAlways; add(shot)
    }

    func test155LookupDefaultsToIncludeAndDisclosureHeaderUsesWholeRow() {
        let app = launch(["--qa-library-sort", "--qa-reset-library-sort"])
        app.buttons["discover.lane.3"].tap(); selected(app, "discover.lane.3")
        app.buttons["discover.search-entry"].tap()
        let advanced = app.buttons["compose.filters"]
        XCTAssertTrue(advanced.waitForExistence(timeout: 5))
        // The leading caption is now part of the disclosure hit area.
        advanced.coordinate(withNormalizedOffset: .init(dx: 0.15, dy: 0.5)).tap()
        let tags = app.buttons["compose.tags.disclosure"]
        XCTAssertTrue(tags.waitForExistence(timeout: 5))
        tags.coordinate(withNormalizedOffset: .init(dx: 0.15, dy: 0.5)).tap()
        let input = app.textFields["tag.name"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["tag.match.0"].exists)
        XCTAssertFalse(app.buttons["tag.match.1"].exists)
        XCTAssertFalse(app.buttons["tag.match.2"].exists)
        input.tap(); input.typeText("gap")
        let candidate = app.buttons["tag.suggestion.female:gaping"]
        XCTAssertTrue(candidate.waitForExistence(timeout: 8)); candidate.tap()
        input.typeText("\n")
        // Switch away from the long candidate list before editing the selected row.
        app.buttons["compose.tag-source.1"].tap()
        let match = app.buttons["compose.rule.match.female:gaping"]
        for _ in 0..<6 { if match.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(match.isHittable)
        XCTAssertEqual(match.value as? String, "包含")
        match.tap()
        let exclude = app.buttons["排除"]
        XCTAssertTrue(exclude.waitForExistence(timeout: 5)); exclude.tap()
        XCTAssertEqual(match.value as? String, "排除")
        let categories = app.buttons["compose.categories.disclosure"]
        for _ in 0..<6 { if categories.isHittable { break }; app.swipeUp() }
        let invert = app.buttons["compose.categories.invert"]
        XCTAssertTrue(invert.isHittable); invert.tap()
        XCTAssertEqual(categories.value as? String, "已展开")
        categories.tap()
        XCTAssertTrue(invert.waitForNonExistence(timeout: 5))
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "search155.shared-disclosures"; shot.lifetime = .keepAlways; add(shot)
    }

    func test154SelectedTagsShareCategoryChipsWithCandidates() {
        let app = launch(["--qa-library-sort", "--qa-reset-library-sort"])
        app.buttons["discover.lane.3"].tap(); selected(app, "discover.lane.3")
        app.buttons["discover.search-entry"].tap()
        let advanced = app.buttons["compose.filters"]
        XCTAssertTrue(advanced.waitForExistence(timeout: 5)); advanced.tap()
        app.buttons["compose.tags.disclosure"].tap()
        app.buttons["compose.tag-source.1"].tap()
        let favorite = app.buttons["compose.favorite-tag.language:english"]
        XCTAssertTrue(favorite.waitForExistence(timeout: 5)); favorite.tap()
        app.buttons["compose.tag-source.0"].tap()
        let input = app.textFields["tag.name"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap(); input.typeText("gap")
        let candidate = app.buttons["tag.suggestion.female:gaping"]
        XCTAssertTrue(candidate.waitForExistence(timeout: 8))
        let chosenChip = app.staticTexts["tag.category.language"].firstMatch
        let candidateChip = candidate.staticTexts["tag.category.female"].firstMatch
        XCTAssertTrue(chosenChip.exists); XCTAssertTrue(candidateChip.exists)
        XCTAssertEqual(chosenChip.label, "语言")
        XCTAssertEqual(chosenChip.frame.width, candidateChip.frame.width, accuracy: 1)
        XCTAssertEqual(chosenChip.frame.height, candidateChip.frame.height, accuracy: 1)
        XCTAssertEqual(chosenChip.frame.height, 28, accuracy: 1)
        XCTAssertTrue(app.staticTexts["english"].exists)
        XCTAssertFalse(app.staticTexts["language:english"].exists)
        XCTAssertTrue(app.buttons["compose.rule.match.language:english"].exists)
        let remove = app.buttons["compose.rule.remove.language:english"]
        XCTAssertTrue(remove.exists)
        XCTAssertEqual(remove.frame.height, candidate.frame.height, accuracy: 1)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "search154.category-chips"; shot.lifetime = .keepAlways; add(shot)
        remove.tap()
        XCTAssertTrue(remove.waitForNonExistence(timeout: 5))
    }

    func test147ReaderFailureRetryKeepsPageAndReturnsToLoadingThenImage() {
        let app = launch(["--qa-reader-transition", "--qa-reader-many", "--qa-reset-reader-preferences", "--qa-prefetch=0",
                          "--qa-reader-initial-failure", "--qa-reader-large-window", "--qa-transfer-ms=3000", "--qa-transfer-progress"])
        app.buttons["gallery.open.1"].tap(); app.buttons["detail.read"].tap()
        let retry = app.buttons["reader.page.retry.1"]
        XCTAssertTrue(retry.waitForExistence(timeout: 8))
        let originalPage = app.buttons["reader.page"].label
        XCTAssertTrue(originalPage.hasPrefix("1 /"))
        XCTAssertEqual(retry.label, "重试")
        XCTAssertGreaterThanOrEqual(retry.frame.height, 44)
        let failure = XCTAttachment(screenshot: app.screenshot())
        failure.name = "reader147.failure"; failure.lifetime = .keepAlways; add(failure)
        retry.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.9)).tap()
        XCTAssertTrue(retry.waitForNonExistence(timeout: 3))
        let loading = app.descendants(matching: .any)["reader.page.loading.1"].firstMatch
        XCTAssertTrue(loading.waitForExistence(timeout: 3))
        let progress = XCTAttachment(screenshot: app.screenshot())
        progress.name = "reader147.loading"; progress.lifetime = .keepAlways; add(progress)
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@ OR identifier == %@", "media.static", "media.animated")).firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(loading.waitForNonExistence(timeout: 4))
        XCTAssertEqual(app.buttons["reader.page"].label, originalPage)
    }
    func test145InlineTagsKeepLookupDraftAndPageRangeSharesOneRow() {
        let app = launch()
        app.buttons["discover.lane.3"].tap(); selected(app, "discover.lane.3")
        app.buttons["discover.search-entry"].tap()
        let add = app.buttons["compose.tags.disclosure"]
        let filters = app.buttons["compose.filters"]
        XCTAssertTrue(filters.waitForExistence(timeout: 5))
        XCTAssertFalse(add.exists)
        XCTAssertFalse(app.textFields["compose.artist"].exists)
        XCTAssertEqual(filters.value as? String, "已收起")
        filters.tap()
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(add.frame.minY, filters.frame.minY)
        add.tap()
        let lookup = app.textFields["tag.name"]
        XCTAssertTrue(lookup.waitForExistence(timeout: 5))
        lookup.tap(); lookup.typeText("gaping")
        filters.tap(); XCTAssertTrue(lookup.waitForNonExistence(timeout: 5))
        XCTAssertFalse(add.exists)
        filters.tap(); XCTAssertTrue(lookup.waitForExistence(timeout: 5))
        XCTAssertEqual(lookup.value as? String, "gaping")
        let candidate = app.buttons["tag.suggestion.female:gaping"]
        XCTAssertTrue(candidate.waitForExistence(timeout: 8)); candidate.tap()
        app.buttons["tag.clear"].tap()
        XCTAssertTrue(app.buttons["compose.rule.remove.female:gaping"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["tag.confirm"].exists)
        XCTAssertTrue(app.buttons["compose.apply"].exists)
        add.tap()
        let minimum = app.textFields["compose.min-pages"], maximum = app.textFields["compose.max-pages"]
        for _ in 0..<6 { if maximum.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(minimum.isHittable); XCTAssertTrue(maximum.isHittable)
        XCTAssertEqual(minimum.placeholderValue, "0")
        XCTAssertEqual(maximum.placeholderValue, "∞")
        let author = app.textFields["compose.artist"], uploader = app.textFields["compose.uploader"]
        for field in [author, uploader] {
            XCTAssertEqual(field.frame.minX, minimum.frame.minX, accuracy: 1)
            XCTAssertEqual(field.frame.maxX, maximum.frame.maxX, accuracy: 1)
        }
        XCTAssertEqual(minimum.frame.midY, maximum.frame.midY, accuracy: 1)
        XCTAssertEqual(minimum.frame.width, maximum.frame.width, accuracy: 1)
        maximum.tap(); maximum.typeText("9")
        let warning = app.staticTexts["compose.page-range-warning"]
        XCTAssertTrue(warning.waitForExistence(timeout: 5))
        XCTAssertTrue(warning.label.contains("最大页数小于 10"))
        maximum.typeText(XCUIKeyboardKey.delete.rawValue)
        XCTAssertTrue(warning.waitForNonExistence(timeout: 5))
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            for _ in 0..<6 { if maximum.isHittable { break }; app.swipeUp() }
            XCTAssertTrue(maximum.waitForExistence(timeout: 5))
            XCTAssertEqual(minimum.frame.midY, maximum.frame.midY, accuracy: 1)
            XCTAssertEqual(minimum.frame.width, maximum.frame.width, accuracy: 1)
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "search145.range.\(orientation.isLandscape ? "landscape" : "portrait")"
            shot.lifetime = .keepAlways; self.add(shot)
        }
    }
    func test145SearchPrioritizesTagAndInputConditionsAndKeepsHistoryActionsSeparate() {
        let app = launch()
        app.buttons["discover.lane.3"].tap(); selected(app, "discover.lane.3")
        app.buttons["discover.search-entry"].tap()
        let input = app.textFields["compose.text"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap(); input.typeText("priority145")
        app.buttons["compose.apply"].tap()
        XCTAssertTrue(app.buttons["discover.search-entry"].waitForExistence(timeout: 5))
        app.buttons["discover.search-entry"].tap()
        let filters = app.buttons["compose.filters"]
        if !(filters.value as? String ?? "").hasPrefix("已展开") { filters.tap() }
        let add = app.buttons["compose.tags.disclosure"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["compose.site"].exists)
        XCTAssertFalse(app.staticTexts["最近搜索"].exists)
        XCTAssertLessThan(add.frame.minY, app.textFields["compose.artist"].frame.minY)
        let save = app.buttons["compose.save-favorite"]
        for _ in 0..<10 { if save.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(save.isHittable)
        XCTAssertEqual(save.frame.midY, app.buttons["compose.clear"].frame.midY, accuracy: 1)
        for _ in 0..<10 { if app.buttons["compose.records"].isHittable { break }; app.swipeDown() }
        app.buttons["compose.records"].tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "search-history.load.")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        let bookmark = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "search-history.save.")).firstMatch
        XCTAssertTrue(bookmark.isHittable)
        XCTAssertGreaterThan(row.frame.width, bookmark.frame.width * 3)
        bookmark.tap()
        XCTAssertTrue(app.textFields["search.save.name"].waitForExistence(timeout: 5))
        app.buttons["search.save.cancel"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(row.frame.height, 44)
        row.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.9)).tap()
        XCTAssertTrue(app.buttons["discover.search-entry"].waitForExistence(timeout: 5))
        XCTAssertTrue((app.buttons["discover.search-entry"].value as? String ?? "").contains("priority145"))
        XCTAssertFalse(app.buttons["compose.apply"].exists)
    }
    func test144CurrentSectionTapReturnsHistoryToTopWithoutReplayingOnReturn() {
        let app = launch(["--qa-library-sort", "--qa-library-long-history", "--qa-reset-library-sort"])
        app.buttons["discover.lane.2"].tap(); selected(app, "discover.lane.2")
        let first = historyAnchor(app), id = first.identifier, initialY = first.frame.minY
        app.scrollViews["reading-history"].swipeUp()
        XCTAssertTrue(historyAnchor(app).identifier != id || abs(app.buttons[id].frame.minY - initialY) > 10)
        app.buttons["discover.lane.2"].tap()
        historyPosition(app, id: id, y: initialY)
        app.scrollViews["reading-history"].swipeUp()
        let middle = historyAnchor(app), middleID = middle.identifier, middleY = middle.frame.minY
        app.buttons["discover.lane.0"].tap(); selected(app, "discover.lane.0")
        app.buttons["discover.lane.2"].tap(); selected(app, "discover.lane.2")
        historyPosition(app, id: middleID, y: middleY)
    }
    func test144CurrentLatestTapRefreshesOnlyOnceAndDoesNotReplayAfterDetail() {
        let app = launch()
        func refreshCount() -> Int {
            let value = app.descendants(matching: .any)["feed.refresh.state"].firstMatch.value as? String ?? ""
            return value.split(separator: ";").first { $0.hasPrefix("refreshes=") }
                .flatMap { Int($0.dropFirst("refreshes=".count)) } ?? -1
        }
        XCTAssertTrue(app.descendants(matching: .any)["feed.refresh.state"].firstMatch.waitForExistence(timeout: 5))
        let before = refreshCount()
        XCTAssertGreaterThanOrEqual(before, 0)
        app.buttons["discover.lane.0"].tap()
        let refreshed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in refreshCount() == before + 1 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [refreshed], timeout: 5), .completed)
        app.buttons["gallery.open.1"].tap()
        XCTAssertTrue(app.buttons["detail.read"].waitForExistence(timeout: 5))
        app.buttons["BackButton"].tap()
        XCTAssertTrue(app.buttons["gallery.open.1"].waitForExistence(timeout: 5))
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        XCTAssertEqual(refreshCount(), before + 1)
    }
    func test137IncomingPaneIsNotRemountedAfterSelectionCommit() {
        let app = launch()
        for lane in [3, 2, 3, 0, 1, 2, 3] {
            let before = paneCounts(app, "discover.lane")[lane] ?? 0
            app.buttons["discover.lane.\(lane)"].tap(); selected(app, "discover.lane.\(lane)")
            XCTAssertEqual(paneCounts(app, "discover.lane")[lane], before + 1, "The incoming pane is created once and retained on commit")
        }
        let source = paneCounts(app, "discover.lane")[3]
        edge(app, left: true, fraction: 0.08, y: 0.55)
        selected(app, "discover.lane.3")
        XCTAssertEqual(paneCounts(app, "discover.lane")[3], source, "Rollback keeps the source pane")
        let before = paneCounts(app, "discover.lane")[0] ?? 0
        edge(app, left: false, fraction: 0.7, y: 0.55)
        selected(app, "discover.lane.0")
        XCTAssertEqual(paneCounts(app, "discover.lane")[0], before + 1)
        app.buttons["main.tab.library"].tap()
        for scope in [1, 2, 3, 0] {
            let old = paneCounts(app, "library.scope")[scope] ?? 0
            app.buttons["library.scope.\(scope)"].tap(); selected(app, "library.scope.\(scope)")
            XCTAssertEqual(paneCounts(app, "library.scope")[scope], old + 1)
        }
    }
    func test137SectionHandoffsForFrameReview() {
        let app = launch()
        for lane in [3, 2, 3, 0, 2, 3] {
            print("CHROME137_BEFORE", lane, Date().timeIntervalSince1970)
            app.buttons["discover.lane.\(lane)"].tap()
            selected(app, "discover.lane.\(lane)")
            print("CHROME137_AFTER", lane, Date().timeIntervalSince1970)
        }
        app.buttons["main.tab.library"].tap()
        for scope in [1, 2, 3, 0] {
            print("CHROME137_LIBRARY_BEFORE", scope, Date().timeIntervalSince1970)
            app.buttons["library.scope.\(scope)"].tap()
            selected(app, "library.scope.\(scope)")
            print("CHROME137_LIBRARY_AFTER", scope, Date().timeIntervalSince1970)
        }
    }
    func test137LongSectionHandoffsForFrameReview() {
        for dark in [false, true] {
            let app = launch(dark ? ["--qa-dark"] : [])
            for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
                XCUIDevice.shared.orientation = orientation
                app.buttons["main.tab.discover"].tap()
                XCTAssertTrue(app.buttons["discover.lane.3"].waitForExistence(timeout: 5))
                for lane in [3, 2, 3, 0, 1, 2, 3] {
                    print("CHROME137_LONG_BEFORE", dark, orientation.rawValue, lane, Date().timeIntervalSince1970)
                    let unchanged = app.buttons["discover.lane.\(lane)"].isSelected
                    let old = paneCounts(app, "discover.lane")[lane] ?? 0
                    app.buttons["discover.lane.\(lane)"].tap()
                    selected(app, "discover.lane.\(lane)")
                    XCTAssertEqual(paneCounts(app, "discover.lane")[lane], old + (unchanged ? 0 : 1))
                    RunLoop.current.run(until: Date().addingTimeInterval(1.2))
                    print("CHROME137_LONG_AFTER", dark, orientation.rawValue, lane, Date().timeIntervalSince1970)
                }
                app.buttons["main.tab.library"].tap()
                for scope in [0, 1, 2, 3, 0] {
                    print("CHROME137_LONG_LIBRARY_BEFORE", dark, orientation.rawValue, scope, Date().timeIntervalSince1970)
                    let unchanged = app.buttons["library.scope.\(scope)"].isSelected
                    let old = paneCounts(app, "library.scope")[scope] ?? 0
                    app.buttons["library.scope.\(scope)"].tap()
                    selected(app, "library.scope.\(scope)")
                    XCTAssertEqual(paneCounts(app, "library.scope")[scope], old + (unchanged ? 0 : 1))
                    RunLoop.current.run(until: Date().addingTimeInterval(1.2))
                    print("CHROME137_LONG_LIBRARY_AFTER", dark, orientation.rawValue, scope, Date().timeIntervalSince1970)
                }
            }
            XCUIDevice.shared.orientation = .portrait
            app.buttons["main.tab.account"].tap()
            let tags = app.buttons["account.tags"]
            for _ in 0..<5 { if tags.isHittable { break }; app.swipeUp() }
            tags.tap()
            XCTAssertTrue(app.buttons["tags.scope.0"].waitForExistence(timeout: 5))
            for scope in [1, 0, 1, 0] {
                let old = paneCounts(app, "tags.scope")[scope] ?? 0
                app.buttons["tags.scope.\(scope)"].tap(); selected(app, "tags.scope.\(scope)")
                XCTAssertEqual(paneCounts(app, "tags.scope")[scope], old + 1)
                RunLoop.current.run(until: Date().addingTimeInterval(1.2))
                print("CHROME137_LONG_TAG_AFTER", dark, scope, Date().timeIntervalSince1970)
            }
        }
    }
    func testShellAnimatesWhileEachRouteKeepsItsOwnClearance() {
        let app = launch(), bottom = app.buttons["main.tab.discover"].frame
        let shell = app.descendants(matching: .any)["chrome.surface.geometry"].firstMatch
        let initial = shell.frame
        app.buttons["discover.lane.3"].tap()
        XCTAssertTrue(app.buttons["discover.search-entry"].waitForExistence(timeout: 5))
        let expansion = values(app)
        XCTAssertTrue(expansion.contains { $0 > 50.5 && $0 < 87.5 }, "Expansion must render intermediate heights: \(expansion)")
        XCTAssertEqual(expansion.last ?? 0, 88, accuracy: 0.5)
        XCTAssertEqual(shell.frame.minY, initial.minY, accuracy: 1)
        app.buttons["discover.search-entry"].tap()
        XCTAssertTrue(app.buttons["compose.apply"].waitForExistence(timeout: 5))
        let incoming = values(app, "chrome.placeholder.compose.header")
        XCTAssertEqual(incoming.first ?? 0, 50, accuracy: 0.5, "A route owns its clearance from its first layout")
        XCTAssertTrue(incoming.allSatisfy { abs($0 - 50) < 0.5 }, "Shell motion must not relayout another route: \(incoming)")
        XCTAssertEqual(incoming.last ?? 0, 50, accuracy: 0.5)
        XCTAssertEqual(app.buttons["main.tab.discover"].frame, bottom)
        app.buttons["compose.cancel"].tap()
        XCTAssertTrue(app.buttons["discover.search-entry"].waitForExistence(timeout: 5))
        XCTAssertEqual(values(app).last ?? 0, 88, accuracy: 0.5)
        app.buttons["discover.lane.0"].tap(); selected(app, "discover.lane.0")
        XCTAssertEqual(values(app).last ?? 0, 50, accuracy: 0.5)
    }
    func test138HistorySearchNeverShrinksBetweenDoubleRowHeaders() {
        let app = launch()
        app.buttons["discover.lane.2"].tap(); selected(app, "discover.lane.2")
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
          XCUIDevice.shared.orientation = orientation
          for lane in [3, 2, 3, 2] {
            let old = values(app)
            print("CHROME138_DOUBLE_BEFORE", lane, Date().timeIntervalSince1970)
            app.buttons["discover.lane.\(lane)"].tap(); selected(app, "discover.lane.\(lane)")
            let trace = Array(values(app).dropFirst(old.count))
            print("CHROME138_DOUBLE_TRACE", lane, trace)
            XCTAssertTrue(trace.allSatisfy { abs($0 - 88) < 0.5 }, "Double-row handoff must not visit a single-row owner: \(trace)")
          }
        }
    }
    private func historyAnchor(_ app: XCUIApplication) -> XCUIElement {
        let headerBottom = app.buttons["discover.lane.2"].exists
            ? app.buttons["discover.lane.2"].frame.maxY + 44
            : app.buttons["library.scope.2"].frame.maxY + 44
        let bottom = app.buttons["main.tab.discover"].frame.minY
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "reading-history.item."))
            .allElementsBoundByIndex.filter { $0.frame.minY > headerBottom && $0.frame.maxY < bottom }
        XCTAssertFalse(rows.isEmpty)
        return rows.sorted { $0.frame.minY < $1.frame.minY }.first!
    }
    private func historyPosition(_ app: XCUIApplication, id: String, y: CGFloat, accuracy: CGFloat = 3) {
        let item = app.buttons[id]
        let check = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in item.exists && abs(item.frame.minY - y) < accuracy }, object: item)
        let result = XCTWaiter.wait(for: [check], timeout: 5)
        print("HISTORY_POSITION", id, "expected", y, "actual", item.exists ? item.frame.minY : -999,
              "state", app.descendants(matching: .any)["history.viewport.qa"].firstMatch.value ?? "missing")
        XCTAssertEqual(result, .completed)
    }
    func test141HistoryRestoresPositionAfterSectionDetailAndRotation() {
        let app = launch(["--qa-library-sort", "--qa-library-long-history", "--qa-reset-library-sort", "--qa-reader-transition"])
        app.buttons["discover.lane.2"].tap(); selected(app, "discover.lane.2")
        let scroll = app.scrollViews["reading-history"]
        scroll.swipeUp()
        let anchor = historyAnchor(app), id = anchor.identifier, y = anchor.frame.minY
        app.buttons["discover.lane.1"].tap(); selected(app, "discover.lane.1")
        let previousHeights = values(app)
        app.buttons["discover.lane.2"].tap(); selected(app, "discover.lane.2")
        let restoredHeights = values(app).dropFirst(previousHeights.count)
        XCTAssertTrue(restoredHeights.contains { $0 > 50.5 && $0 < 87.5 }, "The header must still resize at a restored middle viewport: \(restoredHeights)")
        historyPosition(app, id: id, y: y)
        XCTAssertTrue(values(app, "feed.layout.clearance").allSatisfy { abs($0 - 88) < 0.5 }, "A restored middle viewport must not perform the top-of-list inset animation")
        app.buttons[id].tap()
        XCTAssertTrue(app.buttons["detail.read"].waitForExistence(timeout: 5))
        app.buttons["BackButton"].tap()
        historyPosition(app, id: id, y: y)
        app.buttons["reading-history.item.7305"].tap()
        XCTAssertTrue(app.buttons["detail.read"].waitForExistence(timeout: 5))
        app.buttons["detail.read"].tap()
        XCTAssertTrue(app.buttons["reader.close"].waitForExistence(timeout: 8))
        app.buttons["reader.close"].tap()
        XCTAssertTrue(app.buttons["detail.read"].waitForExistence(timeout: 5))
        app.buttons["BackButton"].tap()
        historyPosition(app, id: id, y: y)
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons[id].waitForExistence(timeout: 5))
        let landscapeY = app.buttons[id].frame.minY
        app.buttons["discover.lane.1"].tap(); selected(app, "discover.lane.1")
        app.buttons["discover.lane.2"].tap(); selected(app, "discover.lane.2")
        historyPosition(app, id: id, y: landscapeY)
        XCUIDevice.shared.orientation = .portrait
        historyPosition(app, id: id, y: y)
        app.scrollViews["reading-history"].swipeDown(velocity: .slow)
        let moved = historyAnchor(app), movedID = moved.identifier, movedY = moved.frame.minY
        XCTAssertTrue(movedID != id || abs(movedY - y) > 5, "A restored viewport must release to a real user scroll")
        app.buttons["discover.lane.1"].tap(); selected(app, "discover.lane.1")
        app.buttons["discover.lane.2"].tap(); selected(app, "discover.lane.2")
        historyPosition(app, id: movedID, y: movedY)
    }
    func test141BottomHistoryRestoreClampsWithoutAddingBlankContent() {
        let app = launch(["--qa-library-sort", "--qa-library-long-history", "--qa-reset-library-sort", "--qa-reader-transition"])
        func metric(_ key: String) -> Double {
            let value = app.descendants(matching: .any)["history.viewport.qa"].firstMatch.value as? String ?? ""
            let item = value.split(separator: ";").first { $0.hasPrefix(key + "=") }
            let number = item.flatMap { Double($0.dropFirst(key.count + 1).replacingOccurrences(of: ",", with: "")) }
            XCTAssertNotNil(number, value)
            return number ?? -999
        }
        app.buttons["discover.lane.2"].tap(); selected(app, "discover.lane.2")
        app.scrollViews["reading-history"].swipeUp(); app.scrollViews["reading-history"].swipeUp()
        XCTAssertEqual(metric("offset"), metric("maximum"), accuracy: 1)
        let contentHeight = metric("contentHeight")
        let anchor = historyAnchor(app), id = anchor.identifier
        app.buttons["reading-history.item.7305"].tap()
        XCTAssertTrue(app.buttons["detail.read"].waitForExistence(timeout: 5))
        app.buttons["detail.read"].tap()
        XCTAssertTrue(app.buttons["reader.close"].waitForExistence(timeout: 8))
        app.buttons["reader.close"].tap()
        XCTAssertTrue(app.buttons["detail.read"].waitForExistence(timeout: 5))
        app.buttons["BackButton"].tap()
        XCTAssertTrue(app.buttons[id].waitForExistence(timeout: 5))
        print("BOTTOM_RETURN", app.buttons[id].frame, "detail", app.buttons["detail.read"].exists,
              "edge", app.descendants(matching: .any)["chrome.edge.interaction"].firstMatch.value ?? "missing",
              "pager", app.descendants(matching: .any)["discover.lane.paging"].firstMatch.value ?? "missing",
              "state", app.descendants(matching: .any)["history.viewport.qa"].firstMatch.value ?? "missing")
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "history141.bottom-return"; shot.lifetime = .keepAlways; add(shot)
        XCTAssertTrue(app.buttons[id].isHittable)
        XCTAssertEqual(metric("offset"), metric("maximum"), accuracy: 1)
        XCTAssertEqual(metric("contentHeight"), contentHeight, accuracy: 1)
    }
    func test141HistoryDraftAndViewportAreIndependentAcrossEntrances() {
        let app = launch(["--qa-library-sort", "--qa-library-long-history", "--qa-reset-library-sort"])
        app.buttons["discover.lane.2"].tap(); selected(app, "discover.lane.2")
        let field = app.textFields["reading-history.search-field"]
        field.tap(); field.typeText("History\n")
        app.scrollViews["reading-history"].swipeUp()
        let anchor = historyAnchor(app), id = anchor.identifier, y = anchor.frame.minY
        app.buttons["discover.lane.0"].tap(); selected(app, "discover.lane.0")
        app.buttons["discover.lane.2"].tap(); selected(app, "discover.lane.2")
        XCTAssertEqual(field.value as? String, "History")
        historyPosition(app, id: id, y: y)
        app.buttons["main.tab.library"].tap(); app.buttons["library.scope.2"].tap(); selected(app, "library.scope.2")
        XCTAssertEqual(field.value as? String, "作品名")
        app.scrollViews["reading-history"].swipeUp()
        let other = historyAnchor(app), otherID = other.identifier, otherY = other.frame.minY
        app.buttons["library.scope.0"].tap(); selected(app, "library.scope.0")
        app.buttons["library.scope.2"].tap(); selected(app, "library.scope.2")
        historyPosition(app, id: otherID, y: otherY)
        app.buttons["main.tab.discover"].tap()
        XCTAssertEqual(field.value as? String, "History")
        historyPosition(app, id: id, y: y)
        app.buttons["reading-history.clear-search"].tap()
        let first = app.buttons["reading-history.item.7203"]
        XCTAssertTrue(first.waitForExistence(timeout: 5)); XCTAssertTrue(first.isHittable)
    }
    func test140IncomingFeedKeepsSourceClearanceThenResizesBothDirections() {
        let app = launch(["--qa-library-sort", "--qa-library-long-history"])
        let bottom = app.buttons["main.tab.discover"].frame
        func swipe(leading: Bool) {
            let probe = app.descendants(matching: .any)["discover.lane.paging"].firstMatch
            let fields = Dictionary(uniqueKeysWithValues: probe.label.split(separator: ";").compactMap { part -> (String, Double)? in
                let pair = part.split(separator: "=")
                guard pair.count == 2, let value = Double(pair[1]) else { return nil }
                return (String(pair[0]), value)
            })
            let x = leading ? (fields["left"] ?? 0) + 28 : app.frame.width - (fields["right"] ?? 0) - 28
            let origin = app.coordinate(withNormalizedOffset: .init(dx: x / app.frame.width, dy: 0.55))
            origin.press(forDuration: 0.08, thenDragTo: origin.withOffset(.init(dx: app.frame.width * (leading ? 0.65 : -0.65), dy: 0)), withVelocity: .slow, thenHoldForDuration: 0.4)
        }
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            app.buttons["discover.lane.1"].tap(); selected(app, "discover.lane.1")
            swipe(leading: false); selected(app, "discover.lane.2")
            let expansion = values(app, "feed.layout.clearance")
            XCTAssertEqual(expansion.first ?? 0, 50, accuracy: 0.5, "Incoming history must first occupy the source single-row inset: \(expansion)")
            XCTAssertEqual(expansion.last ?? 0, 88, accuracy: 0.5)
            XCTAssertTrue(expansion.contains { $0 > 50.5 && $0 < 87.5 }, "Content must move down with intermediate frames: \(expansion)")
            swipe(leading: true); selected(app, "discover.lane.1")
            let collapse = values(app, "feed.layout.clearance")
            XCTAssertEqual(collapse.first ?? 0, 88, accuracy: 0.5, "Incoming popular must keep the source double-row inset until arrival: \(collapse)")
            XCTAssertEqual(collapse.last ?? 0, 50, accuracy: 0.5)
            XCTAssertTrue(collapse.contains { $0 > 50.5 && $0 < 87.5 }, "Content must move up with intermediate frames: \(collapse)")
            if orientation == .portrait { XCTAssertEqual(app.buttons["main.tab.discover"].frame, bottom) }
        }
    }
    func test139SavedSearchCopyAndSaveState() {
        let app = launch()
        app.buttons["discover.lane.3"].tap()
        app.buttons["discover.search-entry"].tap()
        let text = app.textFields["compose.text"]
        XCTAssertTrue(text.waitForExistence(timeout: 5)); text.tap(); text.typeText("copy139")
        let save = app.buttons["compose.save-favorite"]
        XCTAssertEqual(save.label, "加入常用搜索组合")
        save.tap()
        XCTAssertTrue(app.textFields["search.save.name"].waitForExistence(timeout: 5))
        app.buttons["search.save.confirm"].tap()
        XCTAssertTrue(app.buttons["compose.save-favorite"].waitForExistence(timeout: 5))
        XCTAssertEqual(save.label, "已加入常用搜索组合")
    }
    func test139FloatingBarsKeepScrollContentBehindTheirEdges() {
        let app = launch(["--qa-dark", "--qa-library-sort", "--qa-library-long-history"])
        app.buttons["main.tab.library"].tap()
        app.buttons["library.scope.2"].tap(); selected(app, "library.scope.2")
        let scroll = app.scrollViews["reading-history"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 5))
        scroll.swipeUp(velocity: .slow)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "chrome139.history.behind-floating-bars"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["library.scope.3"].tap(); selected(app, "library.scope.3")
        let downloads = XCTAttachment(screenshot: app.screenshot())
        downloads.name = "chrome139.downloads.behind-floating-bars"; downloads.lifetime = .keepAlways; add(downloads)
    }
    func test144ExpandedBandPagesAndReturnsFrom40Points() {
        let app = launch(["--qa-reader-many"])
        var safeLeft: CGFloat = 0
        var safeRight: CGFloat = 0
        func swipe(left: Bool) {
            let x = left ? safeLeft + 40 : app.frame.width - safeRight - 40
            let start = app.coordinate(withNormalizedOffset: .init(dx: x / app.frame.width, dy: 0.55))
            start.press(forDuration: 0.08, thenDragTo: start.withOffset(.init(dx: app.frame.width * (left ? 0.7 : -0.7), dy: 0)), withVelocity: .slow, thenHoldForDuration: 0.1)
        }
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            let probe = app.descendants(matching: .any)["discover.lane.paging"].firstMatch
            XCTAssertTrue(probe.waitForExistence(timeout: 5))
            let fields = Dictionary(uniqueKeysWithValues: probe.label.split(separator: ";").compactMap { part -> (String, Double)? in
                let pair = part.split(separator: "=")
                guard pair.count == 2, let value = Double(pair[1]) else { return nil }
                return (String(pair[0]), value)
            })
            XCTAssertEqual(fields["width"] ?? 0, app.frame.width, accuracy: 1)
            safeLeft = fields["left"] ?? 0; safeRight = fields["right"] ?? 0
            swipe(left: false); selected(app, "discover.lane.1")
            XCTAssertFalse(app.buttons["detail.read"].exists)
            swipe(left: true); selected(app, "discover.lane.0")
            app.buttons["gallery.open.1"].tap()
            XCTAssertTrue(app.buttons["detail.read"].waitForExistence(timeout: 5))
            app.buttons["detail.read"].tap()
            XCTAssertTrue(app.staticTexts["reader.edge.qa"].waitForExistence(timeout: 5))
            swipe(left: false)
            XCTAssertTrue(app.buttons["detail.read"].waitForExistence(timeout: 5))
            swipe(left: true)
            XCTAssertTrue(app.buttons["gallery.open.1"].waitForExistence(timeout: 5))
        }
    }
    func test142ButtonAndLandscapeEdgeReturnKeepDiscoveryUsable() {
        let app = launch(["--qa-dark"])
        let card = app.buttons["gallery.open.1"]
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        card.tap(); XCTAssertTrue(app.buttons["detail.read"].waitForExistence(timeout: 5))
        app.buttons["BackButton"].tap()
        XCTAssertTrue(card.waitForExistence(timeout: 5)); XCTAssertTrue(card.isHittable)
        XCUIDevice.shared.orientation = .landscapeLeft
        let rotated = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.frame.width > app.frame.height && card.exists && card.frame.width > app.frame.width * 0.35
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [rotated], timeout: 5), .completed)
        for left in [true, false] {
            // A tall landscape card extends beyond the viewport. Tap its visible
            // cover, not XCTest's offscreen whole-card centre/auto-scroll path.
            let visible = card.frame.intersection(app.frame.insetBy(dx: 100, dy: 90))
            XCTAssertFalse(visible.isEmpty)
            app.coordinate(withNormalizedOffset: .zero).withOffset(.init(dx: visible.midX, dy: visible.midY)).tap()
            XCTAssertTrue(app.buttons["detail.read"].waitForExistence(timeout: 5))
            let probe = app.descendants(matching: .any)["discover.lane.paging"].firstMatch
            let x = left ? 75.0 : app.frame.width - 75.0
            let origin = app.coordinate(withNormalizedOffset: .init(dx: x / app.frame.width, dy: 0.5))
            origin.press(forDuration: 0.08, thenDragTo: origin.withOffset(.init(dx: app.frame.width * (left ? 0.7 : -0.7), dy: 0)), withVelocity: .slow, thenHoldForDuration: 0.1)
            XCTAssertTrue(card.waitForExistence(timeout: 5), probe.exists ? String(describing: probe.value) : "return")
            XCTAssertTrue(card.isHittable)
        }
    }
    func test142DetailToDiscoverySettledContentDoesNotRefreshAgain() {
        let app = launch(["--qa-dark"])
        for search in [false, true] {
            if search {
                app.buttons["discover.lane.3"].tap()
                app.buttons["discover.search-entry"].tap()
                let field = app.textFields["compose.text"]
                XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText("return142")
                app.buttons["compose.apply"].tap()
            }
            for left in [true, false] {
                let card = app.buttons["gallery.open.1"]
                XCTAssertTrue(card.waitForExistence(timeout: 5))
                let y = card.frame.minY
                let before = values(app, "discover.content.motion")
                let pane = paneCounts(app, "discover.lane")
                print("RETURN142_OPEN", search, left, Date().timeIntervalSince1970)
                card.tap(); XCTAssertTrue(app.buttons["detail.read"].waitForExistence(timeout: 5))
                edge(app, left: left, fraction: 0.7)
                XCTAssertTrue(card.waitForExistence(timeout: 5))
                print("RETURN142_ARRIVED", search, left, Date().timeIntervalSince1970)
                for delay in [0.1, 0.3, 0.8, 1.6] {
                    RunLoop.current.run(until: Date().addingTimeInterval(delay))
                    let shot = XCTAttachment(screenshot: app.screenshot())
                    shot.name = "return142.\(search).\(left).\(delay)"; shot.lifetime = .keepAlways; add(shot)
                    XCTAssertEqual(card.frame.minY, y, accuracy: 1)
                }
                let trace = Array(values(app, "discover.content.motion").dropFirst(before.count))
                print("RETURN142_SETTLED", search, left, trace, "pane", paneCounts(app, "discover.lane"))
                XCTAssertEqual(paneCounts(app, "discover.lane"), pane)
            }
        }
    }
    func test138DetailEdgeReturnCompletesOnceAndReleasesInteractionGate() {
        let app = launch()
        app.buttons["discover.lane.3"].tap()
        app.buttons["discover.search-entry"].tap()
        let field = app.textFields["compose.text"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText("motion")
        app.buttons["compose.apply"].tap()
        for left in [true, false] {
            XCTAssertTrue(app.buttons["gallery.open.1"].waitForExistence(timeout: 5))
            app.buttons["gallery.open.1"].tap()
            XCTAssertTrue(app.buttons["detail.read"].waitForExistence(timeout: 5))
            let old = values(app)
            print("CHROME138_RETURN_BEFORE", left, Date().timeIntervalSince1970)
            edge(app, left: left, fraction: 0.7)
            XCTAssertTrue(app.buttons["gallery.open.1"].waitForExistence(timeout: 5), "Edge state: \(app.staticTexts["page.edge.qa"].firstMatch.value ?? "missing"); live: \(app.otherElements["qa.edge.installation"].firstMatch.value ?? "missing"); nav: \(app.otherElements["qa.navigation.flat"].firstMatch.value ?? "missing")")
            let trace = Array(values(app).dropFirst(old.count))
            print("CHROME138_RETURN_TRACE", left, trace)
            XCTAssertTrue(trace.contains { $0 > 50.5 && $0 < 87.5 }, "Return must interpolate the fixed shell height: \(trace)")
            XCTAssertEqual(trace.last ?? 0, 88, accuracy: 0.5)
            let state = app.descendants(matching: .any)["chrome.edge.interaction"].firstMatch
            let idle = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "pending=false;blocked=false"), object: state)
            XCTAssertEqual(XCTWaiter.wait(for: [idle], timeout: 3), .completed)
            XCTAssertFalse(app.buttons["detail.read"].exists)
        }
        app.buttons["gallery.open.1"].tap()
        XCTAssertTrue(app.buttons["detail.read"].waitForExistence(timeout: 5))
        let beforeButton = values(app)
        app.buttons["BackButton"].tap()
        XCTAssertTrue(app.buttons["gallery.open.1"].waitForExistence(timeout: 5))
        let buttonTrace = Array(values(app).dropFirst(beforeButton.count))
        XCTAssertTrue(buttonTrace.contains { $0 > 50.5 && $0 < 87.5 }, "Button return must interpolate the fixed shell height: \(buttonTrace)")
        XCTAssertEqual(buttonTrace.last ?? 0, 88, accuracy: 0.5)
        let old = values(app)
        app.buttons["discover.lane.0"].tap(); selected(app, "discover.lane.0")
        let trace = Array(values(app).dropFirst(old.count))
        XCTAssertTrue(trace.contains { $0 > 50.5 && $0 < 87.5 }, "Normal section resizing must remain animated after the return")
    }
    func test138TinyEdgeMotionCannotTurnIntoGalleryTapAndNormalTapStillWorks() {
        let app = launch()
        XCTAssertTrue(app.buttons["gallery.open.1"].waitForExistence(timeout: 5))
        for left in [true, false] {
            for distance: CGFloat in [8, 30] {
                let start = app.coordinate(withNormalizedOffset: .zero).withOffset(.init(dx: left ? 19 : app.frame.width - 19, dy: app.frame.height * 0.3))
                start.press(forDuration: 0.08, thenDragTo: start.withOffset(.init(dx: left ? distance : -distance, dy: 0)), withVelocity: .slow, thenHoldForDuration: 0.08)
                XCTAssertFalse(app.buttons["detail.read"].exists)
                selected(app, "discover.lane.0")
            }
        }
        print("CHROME138_EDGE_ACTIVATION", app.otherElements["chrome.edge.interaction"].firstMatch.label)
        app.buttons["gallery.open.1"].press(forDuration: 0.65)
        XCTAssertTrue(app.buttons["discover.exit"].waitForExistence(timeout: 5))
        app.buttons["discover.exit"].tap()
        app.buttons["gallery.open.1"].tap()
        XCTAssertTrue(app.buttons["detail.read"].waitForExistence(timeout: 5))
    }
    func testDoubleRowDetailReturnDoesNotReverseHeaderHeight() {
        let app = launch()
        app.buttons["discover.lane.3"].tap()
        app.buttons["discover.search-entry"].tap()
        let field = app.textFields["compose.text"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap(); field.typeText("motion")
        app.buttons["compose.apply"].tap()
        XCTAssertTrue(app.buttons["gallery.open.1"].waitForExistence(timeout: 5))
        XCTAssertEqual(values(app).last ?? 0, 88, accuracy: 0.5)
        for left in [true, false] {
            let source = values(app, "discover.content.motion")
            let sourceY = source.last ?? 0
            app.buttons["gallery.open.1"].tap()
            XCTAssertTrue(app.buttons["detail.read"].waitForExistence(timeout: 5))
            let baseline = values(app)
            XCTAssertEqual(baseline.last ?? 0, 50, accuracy: 0.5)
            edge(app, left: left, fraction: 0.7)
            XCTAssertTrue(app.buttons["gallery.open.1"].waitForExistence(timeout: 5))
            let after = values(app)
            let trajectory = Array(after.dropFirst(baseline.count))
            print("RETURN_HEIGHT_TRACE", left, trajectory)
            let positions = values(app, "discover.content.motion")
            print("RETURN_CONTENT_TRACE", left, positions)
            for y in positions.dropFirst(source.count) {
                XCTAssertEqual(y, sourceY, accuracy: 1, "Covered source and live return must share their layout")
            }
            XCTAssertEqual(after.last ?? 0, 88, accuracy: 0.5)
            for pair in zip(trajectory, trajectory.dropFirst()) {
                XCTAssertGreaterThanOrEqual(pair.1 + 0.5, pair.0, "Return must expand once, without shrinking again: \(trajectory)")
            }
        }
    }
    func testHistorySearchAndSingleRowRoundTripKeepChromeAnchors() {
        let app = launch()
        let bottom = app.buttons["main.tab.discover"].frame
        let surface = app.descendants(matching: .any)["chrome.surface.geometry"].firstMatch
        let top = surface.frame.minY
        app.buttons["discover.lane.2"].tap()
        XCTAssertTrue(app.buttons["reading-history.period"].waitForExistence(timeout: 5))
        let doubleHeight = surface.frame.height
        app.buttons["discover.lane.3"].tap()
        XCTAssertTrue(app.buttons["discover.search-entry"].waitForExistence(timeout: 5))
        XCTAssertEqual(surface.frame.height, doubleHeight, accuracy: 1)
        XCTAssertEqual(surface.frame.minY, top, accuracy: 1)
        app.buttons["discover.lane.0"].tap()
        XCTAssertTrue(app.buttons["gallery.open.1"].waitForExistence(timeout: 5))
        let source = values(app, "discover.content.motion")
        let y = source.last ?? 0
        app.buttons["gallery.open.1"].tap()
        XCTAssertTrue(app.buttons["detail.read"].waitForExistence(timeout: 5))
        edge(app, left: true, fraction: 0.7)
        XCTAssertTrue(app.buttons["gallery.open.1"].waitForExistence(timeout: 5))
        for position in values(app, "discover.content.motion").dropFirst(source.count) {
            XCTAssertEqual(position, y, accuracy: 1)
        }
        XCTAssertEqual(app.buttons["main.tab.discover"].frame, bottom)
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["discover.lane.3"].waitForExistence(timeout: 5))
        app.buttons["discover.lane.3"].tap()
        XCTAssertTrue(app.buttons["discover.search-entry"].waitForExistence(timeout: 5))
        app.buttons["discover.lane.2"].tap()
        XCTAssertTrue(app.buttons["reading-history.period"].waitForExistence(timeout: 5))
    }
    func testDarkHomeBackgroundSurvivesDetailAndReaderReturn() {
        let app = launch(["--qa-dark", "--qa-reader-transition", "--qa-reader-many"])
        func assertDark(_ label: String) {
            let image = XCUIScreen.main.screenshot().image
            guard let source = image.cgImage,
                  let pixel = source.cropping(to: CGRect(x: 3, y: source.height / 2, width: 1, height: 1)) else {
                XCTFail("No screenshot pixel"); return
            }
            var rgba = [UInt8](repeating: 0, count: 4)
            let context = CGContext(data: &rgba, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            XCTAssertLessThan(Int(rgba[0]) + Int(rgba[1]) + Int(rgba[2]), 100, label)
            let shot = XCTAttachment(image: image); shot.name = label; shot.lifetime = .keepAlways; add(shot)
        }
        assertDark("dark-home-initial")
        app.buttons["gallery.open.1"].tap()
        XCTAssertTrue(app.buttons["detail.read"].waitForExistence(timeout: 5))
        app.buttons["detail.read"].tap()
        XCTAssertTrue(app.buttons["reader.close"].waitForExistence(timeout: 8))
        app.buttons["reader.close"].tap()
        XCTAssertTrue(app.buttons["detail.read"].waitForExistence(timeout: 5))
        edge(app, left: false, fraction: 0.7)
        XCTAssertTrue(app.buttons["gallery.open.1"].waitForExistence(timeout: 5))
        assertDark("dark-home-after-reader-and-edge-return")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["discover.lane.3"].waitForExistence(timeout: 5))
        app.buttons["discover.lane.3"].tap()
        XCTAssertTrue(app.buttons["discover.search-entry"].waitForExistence(timeout: 5))
        assertDark("dark-home-landscape-search")
    }
    func testTagEntryEdgesConfirmAndButtonReturnsWithoutCommitting() {
        let app = launch()
        app.buttons["discover.lane.3"].tap(); app.buttons["discover.search-entry"].tap()
        let filters = app.buttons["compose.filters"]
        XCTAssertTrue(filters.waitForExistence(timeout: 5))
        if (filters.value as? String ?? "").hasPrefix("已收起") { filters.tap() }
        func open() {
            let add = app.buttons["compose.tags.disclosure"]
            for _ in 0..<4 { if add.isHittable { break }; app.swipeUp() }
            add.tap()
            XCTAssertTrue(app.textFields["tag.name"].waitForExistence(timeout: 5))
        }
        for left in [true, false] {
            open()
            let field = app.textFields["tag.name"]
            field.tap(); field.typeText(left ? "eng\n" : "chinese\n")
            let id = left ? "language:english" : "language:chinese"
            let candidate = app.buttons["tag.suggestion.\(id)"]
            XCTAssertTrue(candidate.waitForExistence(timeout: 10))
            XCTAssertEqual(candidate.frame.height, 36, accuracy: 1)
            candidate.tap()
            edge(app, left: left, fraction: 0.7, y: 0.44)
            XCTAssertTrue(field.waitForNonExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts[id].waitForExistence(timeout: 5))
        }
        open()
        let field = app.textFields["tag.name"]
        field.tap(); field.typeText("japanese\n")
        let cancelled = app.buttons["tag.suggestion.language:japanese"]
        XCTAssertTrue(cancelled.waitForExistence(timeout: 10)); cancelled.tap()
        app.buttons["tag.cancel"].tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["language:english"].exists)
        XCTAssertTrue(app.staticTexts["language:chinese"].exists)
        XCTAssertFalse(app.staticTexts["language:japanese"].exists)
    }
    func testSearchGestureSubmitsButButtonReturnsAndInvalidGestureShowsToast() {
        let app = launch()
        app.buttons["discover.lane.3"].tap(); app.buttons["discover.search-entry"].tap()
        let field = app.textFields["compose.text"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText("edge-query")
        app.buttons["compose.cancel"].tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 5)); XCTAssertFalse(app.buttons["gallery.open.1"].exists)
        app.buttons["discover.search-entry"].tap(); XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap(); field.typeText("gesture-query")
        edge(app, left: false, fraction: 0.7, y: 0.55)
        let submitted = field.waitForNonExistence(timeout: 5)
        if !submitted {
            print("EDGE_SEARCH_DIAGNOSTIC", app.staticTexts["page.edge.qa"].value ?? "missing")
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.lifetime = .keepAlways; add(shot)
        }
        XCTAssertTrue(submitted)
        expectation(for: NSPredicate(format: "value CONTAINS %@", "gesture-query"), evaluatedWith: app.buttons["discover.search-entry"])
        waitForExpectations(timeout: 5)
        XCTAssertTrue(app.buttons["gallery.open.1"].waitForExistence(timeout: 5))
        // Assert the submitted destination, not historical intermediate samples from
        // the native edge-handoff buffer. Dedicated chrome tests own animation timing.
        let afterGesture = values(app)
        XCTAssertEqual(afterGesture.last ?? -1, 88, accuracy: 1)
        app.buttons["discover.filters"].tap()
        let invert = app.buttons["compose.categories.invert"]
        XCTAssertTrue(invert.waitForExistence(timeout: 5)); invert.tap()
        edge(app, left: true, fraction: 0.7, y: 0.55)
        XCTAssertTrue(app.buttons["compose.apply"].exists)
        XCTAssertTrue(app.staticTexts["compose.error"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["compose.cancel"].isHittable)
    }
    func testRejectedGestureSubmissionReboundsKeepsDraftAndShowsToast() {
        let app = launch(["--qa-reject-search-commit"])
        app.buttons["discover.lane.3"].tap(); app.buttons["discover.search-entry"].tap()
        let field = app.textFields["compose.text"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText("keep-draft")
        edge(app, left: true, fraction: 0.7, y: 0.55)
        XCTAssertTrue(field.exists)
        XCTAssertEqual(field.value as? String, "keep-draft")
        XCTAssertTrue(app.buttons["compose.cancel"].isHittable)
        XCTAssertTrue(app.staticTexts["compose.error"].waitForExistence(timeout: 3))
        let motion = values(app, "page.edge.motion")
        XCTAssertEqual(motion.last ?? -1, 0, accuracy: 1)
        XCTAssertTrue(motion.contains { $0 > app.frame.width * 0.95 }, "Rejection is exercised after the committing slide: \(motion)")
        app.buttons["compose.cancel"].tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 5))
    }
    func testReaderShortStrokesInBothOrientationsAndImmediateTapPath() {
        let app = launch(["--qa-reader-transition", "--qa-reader-many", "--qa-reset-reader-preferences", "--qa-prefetch=3"])
        app.buttons["gallery.open.1"].tap(); app.buttons["detail.read"].tap()
        let page = app.buttons["reader.page"]
        XCTAssertTrue(page.waitForExistence(timeout: 10))
        let cache = app.descendants(matching: .any)["reader.cache.qa"].firstMatch
        expectation(for: NSPredicate(format: "value CONTAINS %@", "files=1,2,3"), evaluatedWith: cache)
        waitForExpectations(timeout: 15)
        func pageIs(_ n: Int) {
            expectation(for: NSPredicate(format: "label == %@", "\(n) / 12"), evaluatedWith: page)
            waitForExpectations(timeout: 5)
        }
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            pageIs(1)
            let start = app.coordinate(withNormalizedOffset: .init(dx: 0.62, dy: 0.48))
            start.press(forDuration: 0.03, thenDragTo: start.withOffset(.init(dx: -60, dy: 0)), withVelocity: .slow, thenHoldForDuration: 0.1)
            pageIs(2)
            let back = app.coordinate(withNormalizedOffset: .init(dx: 0.38, dy: 0.48))
            back.press(forDuration: 0.03, thenDragTo: back.withOffset(.init(dx: 60, dy: 0)), withVelocity: .slow, thenHoldForDuration: 0.1)
            pageIs(1)
            start.press(forDuration: 0.03, thenDragTo: start.withOffset(.init(dx: -20, dy: 0)), withVelocity: .slow, thenHoldForDuration: 0.1)
            pageIs(1)
            app.coordinate(withNormalizedOffset: .init(dx: 0.82, dy: 0.48)).tap(); pageIs(2)
            app.coordinate(withNormalizedOffset: .init(dx: 0.18, dy: 0.48)).tap(); pageIs(1)
        }
    }
    func testDirectFavoriteToggleDoesNotOpenManagement() {
        let app = launch(["--qa-favorite-existing"])
        app.buttons["gallery.open.1"].tap()
        let favorite = app.buttons["detail.site-favorite"]
        expectation(for: NSPredicate(format: "label BEGINSWITH %@", "取消收藏"), evaluatedWith: favorite)
        waitForExpectations(timeout: 5)
        favorite.tap()
        expectation(for: NSPredicate(format: "label == %@", "添加收藏"), evaluatedWith: favorite)
        waitForExpectations(timeout: 5)
        XCTAssertFalse(app.buttons["favorite.editor.cancel"].exists)
        XCTAssertEqual(app.alerts.count, 0)
        favorite.tap()
        expectation(for: NSPredicate(format: "label BEGINSWITH %@", "取消收藏"), evaluatedWith: favorite)
        waitForExpectations(timeout: 5)
    }
    func testFavoritesThreeActionsCustomConfirmationAndGroupEdgeReturns() {
        let app = launch()
        app.buttons["main.tab.library"].tap(); app.buttons["library.scope.1"].tap()
        let card = app.buttons["favorites.gallery.1"]
        XCTAssertTrue(card.waitForExistence(timeout: 8)); card.press(forDuration: 0.7)
        for id in ["favorites.remove", "favorites.download", "favorites.move"] { XCTAssertTrue(app.buttons[id].waitForExistence(timeout: 5)) }
        XCTAssertFalse(app.buttons["favorites.add-read-later"].exists)
        app.buttons["favorites.remove"].tap()
        XCTAssertTrue(app.otherElements["favorites.remove.dialog"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.alerts.count, 0)
        edge(app, left: false, fraction: 0.7, y: 0.55)
        XCTAssertTrue(app.buttons["library.scope.1"].isSelected)
        app.buttons["favorites.remove.cancel"].tap()
        app.buttons["favorites.move"].tap()
        let confirm = app.buttons["favorites.confirm-move"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertEqual(confirm.frame.width, app.buttons["favorites.groups.back"].frame.width, accuracy: 1)
        edge(app, left: false, fraction: 0.7, y: 0.55)
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["favorites.move"].exists)
        app.buttons["favorites.move"].tap()
        XCTAssertTrue(app.buttons["favorites.move-to.1"].waitForExistence(timeout: 5))
        app.buttons["favorites.move-to.1"].tap()
        edge(app, left: true, fraction: 0.7, y: 0.55)
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["账号或筛选条件已变化，请重新加载。"].exists)
    }
    func testEmptySearchEdgeReturnsWithoutReplacingExistingResults() {
        let app = launch()
        app.buttons["discover.lane.3"].tap(); app.buttons["discover.search-entry"].tap()
        let field = app.textFields["compose.text"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText("kept")
        app.buttons["compose.apply"].tap()
        XCTAssertTrue(app.buttons["discover.search-entry"].waitForExistence(timeout: 5))
        app.buttons["discover.search-entry"].tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 4))
        edge(app, left: false, fraction: 0.7, y: 0.55)
        XCTAssertTrue(field.waitForNonExistence(timeout: 5))
        XCTAssertTrue((app.buttons["discover.search-entry"].value as? String ?? "").contains("kept"))
    }
    func testEdgeSwipeAndReboundDoNotOpenTheGalleryUnderTheTouch() {
        let app = launch()
        XCTAssertTrue(app.buttons["gallery.open.1"].waitForExistence(timeout: 5))
        for left in [false, true] {
            edge(app, left: left, fraction: 0.08, y: 0.3)
            XCTAssertFalse(app.buttons["detail.read"].exists)
            selected(app, "discover.lane.0")
        }
        edge(app, left: false, fraction: 0.7, y: 0.3)
        selected(app, "discover.lane.1")
        XCTAssertFalse(app.buttons["detail.read"].exists)
    }
    func testSavedAndRecentSearchesExecuteDirectlyAndSavedListHasBothEdgeReturns() {
        let app = launch()
        app.buttons["discover.lane.3"].tap(); app.buttons["discover.search-entry"].tap()
        let field = app.textFields["compose.text"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText("saved-132")
        app.buttons["compose.save-favorite"].tap()
        XCTAssertTrue(app.textFields["search.save.name"].waitForExistence(timeout: 5))
        app.buttons["search.save.confirm"].tap()
        XCTAssertTrue(app.buttons["compose.apply"].waitForExistence(timeout: 5)); app.buttons["compose.apply"].tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 5))
        for left in [true, false] {
            app.buttons["discover.saved-menu"].tap()
            XCTAssertTrue(app.buttons["search-presets.close"].waitForExistence(timeout: 5))
            edge(app, left: left, fraction: 0.7, y: 0.55)
            XCTAssertTrue(app.buttons["search-presets.close"].waitForNonExistence(timeout: 5))
            XCTAssertFalse(field.exists)
        }
        app.buttons["discover.saved-menu"].tap()
        let saved = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "search-favorites.load.")).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 5)); saved.tap()
        XCTAssertTrue(saved.waitForNonExistence(timeout: 5)); XCTAssertFalse(field.exists)
        app.buttons["discover.search-entry"].tap(); app.buttons["compose.records"].tap()
        let recent = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "search-history.load.")).firstMatch
        XCTAssertTrue(recent.waitForExistence(timeout: 5)); recent.tap()
        XCTAssertTrue(recent.waitForNonExistence(timeout: 5)); XCTAssertFalse(field.exists)
        XCTAssertTrue(app.buttons["gallery.open.1"].exists)
    }
}
