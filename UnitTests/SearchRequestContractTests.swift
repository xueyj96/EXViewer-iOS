import XCTest
import ExViewerCore
@testable import ExViewer

@MainActor final class SearchRequestContractTests: XCTestCase {
    func testDraftKeepsLiteralKeywordsAfterParsingAndAfterLoadingStoredQuery() throws {
        for input in [#""-forest""#, #""language:chinese""#, #"title:"language:chinese""#, #"title:"sea  view""#] {
            var draft = SearchDraft(query: SearchQuery(), site: .ex)
            draft.inputText = input
            let applied = try draft.validatedQuery()
            let expected = try applied.url(site: .ex)
            XCTAssertTrue(applied.rules.isEmpty)

            try draft.parseInlineFilters()
            XCTAssertEqual(try draft.validatedQuery().url(site: .ex), expected)

            var reloaded = SearchDraft(query: applied, site: .ex)
            XCTAssertEqual(reloaded.inputText, applied.text)
            try reloaded.parseInlineFilters()
            XCTAssertEqual(try reloaded.validatedQuery().url(site: .ex), expected)
            reloaded.inputText += " temporary edit"
            reloaded.inputText = applied.text
            XCTAssertEqual(try reloaded.validatedQuery().url(site: .ex), expected)
            reloaded.query.matchPhrase = false
            try reloaded.parseInlineFilters()
            let changed = try reloaded.validatedQuery()
            XCTAssertFalse(changed.matchPhrase)
            XCTAssertEqual(changed.text, applied.text)
            XCTAssertTrue(changed.rules.isEmpty)
        }
    }

    func testDraftUsesOnlyRawPageFieldsAfterLoadingAndClearingAStoredRange() throws {
        var query = SearchQuery()
        query.minPages = 40
        query.maxPages = 100
        var draft = SearchDraft(query: query, site: .eh)
        XCTAssertTrue(draft.hasConditions)
        draft.minimumPagesText = ""
        draft.maximumPagesText = ""
        XCTAssertFalse(draft.hasConditions)
        XCTAssertEqual(try draft.validatedQuery(), SearchQuery())

        draft.minimumPagesText = "-"
        XCTAssertTrue(draft.hasConditions)
        XCTAssertThrowsError(try draft.validatedQuery())
        XCTAssertEqual(draft.minimumPagesText, "-")
    }

    private func legacyQuery(_ query: SearchQuery, order: String) throws -> SearchQuery {
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(query)) as? [String: Any])
        fields["sortOrder"] = order
        return try JSONDecoder().decode(SearchQuery.self, from: JSONSerialization.data(withJSONObject: fields))
    }

    func testRetiredLocalOrderDoesNotChangePopularSourceItemsOrContinuation() async throws {
        let session = SiteSession(qa: true), navigation = DiscoveryNavigation(lane: 1)
        try navigation.startCurrent(session: session, qa: true)
        let original = navigation.current, ids = original.pager.items.map(\.id), next = original.pager.next
        for order in ["siteDefault", "ratingDescending", "pagesDescending", "pagesAscending", "title"] {
            let query = try legacyQuery(SearchQuery(), order: order)
            try navigation.submit(query: query, site: .ex, lane: 1, savedID: nil, session: session, qa: true)
            XCTAssertEqual(navigation.current.requestURL.path, "/popular")
            XCTAssertTrue(navigation.current.pager === original.pager)
            XCTAssertEqual(navigation.current.pager.items.map(\.id), ids)
            XCTAssertEqual(navigation.current.pager.next, next)
        }
    }

    func testCompactHeaderSummarizesWithoutChangingSearchMeaningOrQuery() throws {
        var query = SearchQuery()
        query.rules = [.init(tag: .init(namespace: "language", name: "chinese")),
                       .init(tag: .init(namespace: "other", name: "uncensored"), match: .exclude),
                       .init(tag: .init(namespace: "other", name: "watercolor"), match: .any)]
        query.minRating = 3; query.minPages = 24; query.maxPages = 400
        query.uploader = "Preview"; query.excludedCategories = [1, 32]
        let original = query, url = try query.url(site: .ex)
        let summary = SearchPresentation.headerDetails(query)
        XCTAssertTrue(summary.contains("排除")); XCTAssertTrue(summary.hasSuffix("另5项条件"))
        XCTAssertEqual(SearchPresentation.conditionCount(query), 7)
        XCTAssertFalse(summary.contains("language:")); XCTAssertFalse(summary.contains("\n"))
        XCTAssertEqual(SearchPresentation.headerTitle(query, savedName: "常用画集"), "常用画集")
        XCTAssertEqual(query, original); XCTAssertEqual(try query.url(site: .ex), url)
        query.rules.swapAt(0, 2)
        XCTAssertTrue(SearchPresentation.headerDetails(query).hasPrefix("任一"))
        query.text = "coast"
        XCTAssertEqual(SearchPresentation.headerTitle(query, savedName: "常用画集"), "coast")
        XCTAssertEqual(SearchPresentation.headerTitle(SearchQuery(), savedName: nil), "关键词、标签与条件")
    }

    func testPresetPreviewKeepsLimitsVisibleAndPreservesTagOperators() {
        var query = SearchQuery()
        query.rules = [
            .init(tag: .init(namespace: "language", name: "chinese")),
            .init(tag: .init(namespace: "other", name: "animation"), match: .exclude),
            .init(tag: .init(namespace: "other", name: "watercolor"), match: .any)
        ]
        query.minRating = 4; query.minPages = 50
        let preview = SearchPresentation.presetPreview(query)
        XCTAssertFalse(preview.conditions.contains("包含"))
        XCTAssertTrue(preview.conditions.contains("排除"))
        XCTAssertTrue(preview.conditions.hasSuffix("…"))
        XCTAssertEqual(preview.limits, "≥4 星 · ≥50 页")

        query.rules.removeFirst()
        query.maxPages = 120
        let range = SearchPresentation.presetPreview(query)
        XCTAssertTrue(range.conditions.contains("任一"))
        XCTAssertFalse(range.conditions.hasSuffix("…"))
        XCTAssertEqual(range.limits, "≥4 星 · 50–120 页")
        XCTAssertEqual(SearchPresentation.presetPreview(SearchQuery()).conditions, "全部画廊")
    }

    func testFilterPreviewAndBadgeUseTheSameFiveItemsAndExposeEveryCondition() throws {
        var query = SearchQuery()
        query.rules = ["chinese", "english", "japanese", "spanish", "french"].map {
            .init(tag: .init(namespace: "language", name: $0))
        }
        let original = query, request = try query.url(site: .ex)
        XCTAssertEqual(SearchPresentation.conditionCount(query), 5)
        XCTAssertTrue(SearchPresentation.headerDetails(query).hasSuffix("另3项条件"))
        let full = SearchPresentation.conditions(query, includeText: false)
        for rule in query.rules { XCTAssertTrue(full.contains(rule.tag.label)) }
        XCTAssertFalse(full.contains("另3项")); XCTAssertFalse(full.contains("+3"))
        XCTAssertEqual(query, original); XCTAssertEqual(try query.url(site: .ex), request)
    }

    func testFilterCountersSeparateKeywordsAndCountEachSelectedOption() {
        var query = SearchQuery(); query.text = "coast"
        XCTAssertEqual(SearchPresentation.conditionCount(query), 0)
        XCTAssertEqual(SearchPresentation.conditionCount(query, includeText: true), 1)
        XCTAssertEqual(SearchPresentation.headerDetails(query), "关键词搜索")
        query.titleOnly = true; query.matchPhrase = true
        query.artist = "Example"; query.uploader = "Uploader"; query.requireTorrent = true
        query.minPages = 24; query.maxPages = 400; query.minRating = 3
        query.excludedCategories = [1, 32]
        XCTAssertEqual(SearchPresentation.conditionCount(query), 8)
        XCTAssertEqual(SearchPresentation.conditionCount(query, includeText: true), 9)
        XCTAssertTrue(SearchPresentation.conditions(query).contains("coast"))
        XCTAssertFalse(SearchPresentation.conditions(query, includeText: false).contains("coast"))
        XCTAssertEqual(SearchPresentation.conditionCount(SearchQuery()), 0)
    }

    func testSavedCombinationMoveAndEditKeepIdentityPositionConditionsAndAccountScopedPersistence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(qa: true, storageRoot: root)
        var queries = QASamples.savedSearches.map(\.query)
        var fourth = SearchQuery(); fourth.text = "fourth"; queries.append(fourth)
        let ids = try queries.enumerated().map { index, query in
            try XCTUnwrap(store.saveSearch(name: "Preset \(index)", site: .ex, query: query))
        }
        store.bookmark(QASamples.galleries[0]); XCTAssertTrue(store.recordSearch(query: queries[0], site: .ex))
        let historyFile = store.directory.appendingPathComponent("recent-searches.json")
        let historyBytes = try Data(contentsOf: historyFile)
        let manual = store.directory.appendingPathComponent("Offline/retained/page.media")
        try FileManager.default.createDirectory(at: manual.deletingLastPathComponent(), withIntermediateDirectories: true)
        let manualBytes = Data("retained neutral fixture".utf8); try manualBytes.write(to: manual)

        XCTAssertTrue(store.moveSavedSearches(from: IndexSet([1, 3]), to: 0, expectedOwner: "guest"))
        let order = [ids[1], ids[3], ids[0], ids[2]]
        XCTAssertEqual(store.snapshot.saved.map(\.id), order)
        var updated = queries[0]; updated.text = "updated"
        updated.minPages = 24; updated.maxPages = 400; updated.uploader = "Preview Studio"
        XCTAssertEqual(store.saveSearch(name: "Updated", site: .eh, query: updated, replacing: ids[0], expectedOwner: "guest"), ids[0])
        XCTAssertEqual(store.snapshot.saved.map(\.id), order, "Editing must neither append a duplicate nor reset its manual position")
        let reopened = LibraryStore(qa: true, storageRoot: root)
        XCTAssertNil(reopened.error); XCTAssertEqual(reopened.snapshot.saved.map(\.id), order)
        XCTAssertEqual(reopened.snapshot.saved[2].name, "Updated")
        XCTAssertEqual(reopened.snapshot.saved[2].query, updated); XCTAssertEqual(reopened.snapshot.saved[2].site, .eh)
        XCTAssertEqual(reopened.snapshot.bookmarks.map(\.id), [QASamples.galleries[0].id])
        XCTAssertEqual(try Data(contentsOf: historyFile), historyBytes); XCTAssertEqual(try Data(contentsOf: manual), manualBytes)

        reopened.load(owner: "abcdef")
        let other = try XCTUnwrap(reopened.saveSearch(name: "Other", site: .ex, query: fourth))
        _ = reopened.saveSearch(name: "Other second", site: .eh, query: fourth)
        let otherIDs = reopened.snapshot.saved.map(\.id)
        XCTAssertFalse(reopened.moveSavedSearches(from: IndexSet(integer: 0), to: 2, expectedOwner: "guest"))
        XCTAssertNil(reopened.saveSearch(name: "Stale editor", site: .ex, query: updated, replacing: other, expectedOwner: "guest"))
        XCTAssertNil(reopened.saveSearch(name: "Stale new draft", site: .ex, query: updated, expectedOwner: "guest"))
        XCTAssertEqual(reopened.snapshot.saved.map(\.id), otherIDs)
        XCTAssertEqual(reopened.snapshot.saved[0].name, "Other")
        reopened.load(owner: "guest"); XCTAssertEqual(reopened.snapshot.saved.map(\.id), order)
    }

    func testSavedCombinationInvalidMoveAndStorageFailureRetainOriginalOrderAndFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(qa: true, storageRoot: root)
        for saved in QASamples.savedSearches { XCTAssertNotNil(store.saveSearch(name: saved.name, site: saved.site, query: saved.query)) }
        let ids = store.snapshot.saved.map(\.id)
        let file = store.directory.appendingPathComponent("library.json")
        let bytes = try Data(contentsOf: file)
        XCTAssertFalse(store.moveSavedSearches(from: IndexSet(integer: 99), to: 0, expectedOwner: "guest"))
        XCTAssertFalse(store.moveSavedSearches(from: IndexSet(integer: 0), to: -1, expectedOwner: "guest"))
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        let backup = file.appendingPathExtension("backup")
        try FileManager.default.moveItem(at: file, to: backup)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        XCTAssertFalse(store.moveSavedSearches(from: IndexSet(integer: 0), to: 3, expectedOwner: "guest"))
        XCTAssertNotNil(store.error); XCTAssertEqual(store.snapshot.saved.map(\.id), ids)
        XCTAssertEqual(try Data(contentsOf: backup), bytes)
    }

    func testSavedMetadataEditRetainsPagesAnchorAndInFlightContinuation() async throws {
        let session = SiteSession(qa: true)
        var query = SearchQuery(); query.text = "coast"
        let navigation = DiscoveryNavigation(query: query)
        try navigation.startCurrent(session: session, qa: true)
        let original = navigation.current, source = original.pager.items
        original.scrollAnchor = source[2].id
        let cursor = original.pager.next
        original.pager.more(session: session)
        XCTAssertTrue(original.pager.loading)
        let savedID = UUID()
        XCTAssertFalse(try navigation.submit(query: query, site: .ex, lane: 0, savedID: savedID, session: session, qa: true))
        let retained = navigation.current
        XCTAssertTrue(retained.pager === original.pager)
        XCTAssertEqual(retained.pager.next, cursor)
        XCTAssertTrue(retained.pager.loading); XCTAssertFalse(retained.pager.interrupted)
        XCTAssertEqual(retained.scrollAnchor, source[2].id)
        XCTAssertTrue(navigation.history.isEmpty)
        let deadline = Date().addingTimeInterval(2)
        while retained.pager.loading && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(retained.pager.loading)
        XCTAssertEqual(retained.pager.items.count, 6)
        XCTAssertEqual(Array(retained.pager.items.prefix(source.count)).map(\.id), source.map(\.id))
        XCTAssertEqual(retained.scrollAnchor, source[2].id)
    }

    func testLegacyLocalOrdersShareTheActualRequestHistoryAndSavedSearchIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(qa: false, storageRoot: root)
        var query = SearchQuery(); query.text = "coast"; query.minRating = 3
        query.rules = [.init(tag: .init(namespace: "language", name: "chinese"))]
        let key = try RecentSearchRecord.requestKey(site: .ex, query: query)
        let savedID = try XCTUnwrap(store.saveSearch(name: "High rating", site: .ex, query: query))
        for order in ["siteDefault", "ratingDescending", "pagesDescending", "pagesAscending", "title"] {
            let legacy = try legacyQuery(query, order: order)
            XCTAssertEqual(legacy, query)
            XCTAssertEqual(try RecentSearchRecord.requestKey(site: .ex, query: legacy), key)
            XCTAssertTrue(store.recordSearch(query: legacy, site: .ex))
            XCTAssertEqual(store.recentSearches.count, 1)
            XCTAssertEqual(store.savedSearch(matching: legacy, site: .ex)?.id, savedID)
            XCTAssertFalse(SearchPresentation.conditions(legacy).contains("排序"))
            XCTAssertTrue(SearchPresentation.conditions(legacy).contains("≥3星"))
        }
        let reloaded = LibraryStore(qa: false, storageRoot: root)
        XCTAssertNil(reloaded.error); XCTAssertNil(reloaded.searchHistoryError)
        XCTAssertEqual(reloaded.snapshot.saved.first?.query, query)
        XCTAssertEqual(reloaded.recentSearches.first?.query, query)
    }

    func testLegacyLibraryAndHistoryAreReadableAndNotRewrittenOnLoad() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("guest")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var query = SearchQuery(); query.text = "legacy"; query.minRating = 3
        var snapshot = LibrarySnapshot(); snapshot.saved = [.init(name: "Existing", site: .ex, query: query)]
        var library = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        var saved = try XCTUnwrap(library["saved"] as? [[String: Any]])
        var fields = try XCTUnwrap(saved[0]["query"] as? [String: Any]); fields["sortOrder"] = "ratingDescending"
        saved[0]["query"] = fields; library["saved"] = saved
        let libraryBytes = try JSONSerialization.data(withJSONObject: library)
        var onlySort = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(SearchQuery())) as? [String: Any])
        onlySort["sortOrder"] = "pagesDescending"
        let ids = [UUID(), UUID()]
        let history = ["version": 1, "entries": [["id": ids[0].uuidString, "site": "ex", "date": 123, "query": fields],
                                                  ["id": ids[1].uuidString, "site": "eh", "date": 122, "query": onlySort]]] as [String: Any]
        let historyBytes = try JSONSerialization.data(withJSONObject: history)
        let libraryFile = directory.appendingPathComponent("library.json"), historyFile = directory.appendingPathComponent("recent-searches.json")
        try libraryBytes.write(to: libraryFile); try historyBytes.write(to: historyFile)
        let store = LibraryStore(qa: false, storageRoot: root)
        XCTAssertNil(store.error); XCTAssertNil(store.searchHistoryError)
        XCTAssertEqual(store.snapshot.saved.first?.query, query)
        XCTAssertEqual(store.recentSearches.map(\.id), ids)
        XCTAssertEqual(store.recentSearches.first?.query, query)
        XCTAssertEqual(store.recentSearches.last?.query, SearchQuery())
        XCTAssertEqual(try Data(contentsOf: libraryFile), libraryBytes)
        XCTAssertEqual(try Data(contentsOf: historyFile), historyBytes)
    }
}
