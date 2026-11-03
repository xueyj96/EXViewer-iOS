import XCTest
import ExViewerCore
@testable import ExViewer

@MainActor final class DetailTagSearchTests: XCTestCase {
    private let chinese = GalleryTag(namespace: "language", name: "chinese")
    private let artist = GalleryTag(namespace: "artist", name: "Preview Studio")

    func testNewSearchContainsOnlyDistinctSelectedTagsAndUsesGallerySite() throws {
        let draft = DetailTagSearchDraft.newSearch(tags: [artist, chinese, .init(namespace: "LANGUAGE", name: "CHINESE")], site: .eh)
        XCTAssertEqual(draft.origin, .newSearch); XCTAssertEqual(draft.site, .eh)
        XCTAssertEqual(draft.selectedCount, 2); XCTAssertEqual(draft.addedCount, 2)
        XCTAssertEqual(draft.query.rules.map(\.id), [artist.id, chinese.id])
        XCTAssertTrue(draft.query.rules.allSatisfy { $0.match == .all })
        XCTAssertEqual(draft.query.text, ""); XCTAssertEqual(draft.query.artist, "")
        XCTAssertNil(draft.query.minRating); XCTAssertTrue(draft.query.excludedCategories.isEmpty)
        XCTAssertNil(draft.sourceSummary); XCTAssertTrue(draft.originalExclusions.isEmpty)
        XCTAssertEqual(try draft.query.url(site: draft.site).host, "e-hentai.org")
    }

    func testAddingPreservesEveryOldConditionAndDoesNotMutateItsSource() throws {
        var base = SearchQuery(); base.text = "coast"; base.titleOnly = true; base.matchPhrase = true
        base.artist = "Preview Studio"; base.uploader = "Archive"
        base.minRating = 3; base.minPages = 10; base.maxPages = 500; base.excludedCategories = [1, 32]; base.requireTorrent = true
        base.rules = [.init(tag: chinese, match: .any), .init(tag: .init(namespace: "other", name: "city"), match: .exclude)]
        let context = ExecutedGallerySearch(query: base, site: .ex)
        let originalURL = try base.url(site: .ex)
        let color = GalleryTag(namespace: "other", name: "watercolor")
        let draft = DetailTagSearchDraft.adding(tags: [artist, chinese, color, color], to: context)
        var expected = base; expected.rules.append(.init(tag: color))
        XCTAssertEqual(draft.query, expected); XCTAssertEqual(draft.addedCount, 1)
        XCTAssertEqual(draft.selectedCount, 3); XCTAssertEqual(draft.site, .ex)
        XCTAssertEqual(context.query, base); XCTAssertEqual(try context.query.url(site: .ex), originalURL)
        XCTAssertEqual(draft.query.rules.first?.match, .any)
        XCTAssertEqual(draft.sourceSummary, SearchPresentation.conditions(base))
    }

    func testExistingExclusionStaysExcludedAndIsExplicitlyMarked() {
        var base = SearchQuery(); base.rules = [.init(tag: chinese, match: .exclude)]
        let draft = DetailTagSearchDraft.adding(tags: [chinese, artist], to: .init(query: base, site: .eh))
        XCTAssertEqual(draft.originalExclusions, [chinese.id])
        XCTAssertEqual(draft.query.rules.first?.match, .exclude)
        XCTAssertEqual(draft.query.rules.filter { $0.id == chinese.id }.count, 1)
        XCTAssertEqual(base.rules.count, 1); XCTAssertEqual(base.rules.first?.match, .exclude)
    }

    func testBulkTagUpdatesRoundTripAndKeepSavedQueriesAndUnrelatedBlocks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(qa: true, storageRoot: root)
        let savedID = try XCTUnwrap(store.saveSearch(name: "Existing", site: .eh, query: QASamples.savedSearches[0].query))
        let before = store.snapshot
        let existing = GalleryTag(namespace: "other", name: "existing")
        store.block(existing)
        XCTAssertTrue(store.pin([chinese, artist, chinese]))
        XCTAssertTrue(store.block([chinese, artist, chinese]))
        let reopened = LibraryStore(qa: true, storageRoot: root)
        XCTAssertEqual(reopened.snapshot.favoriteTags.filter { $0.id == chinese.id }.count, 1)
        XCTAssertTrue(Set(reopened.snapshot.favoriteTags.map(\.id)).isSuperset(of: [chinese.id, artist.id]))
        XCTAssertTrue(reopened.blockedIDs.isSuperset(of: [existing.id, chinese.id, artist.id]))
        XCTAssertEqual(reopened.snapshot.saved, before.saved)
        XCTAssertEqual(reopened.snapshot.saved.first { $0.id == savedID }?.query, before.saved.first { $0.id == savedID }?.query)
        XCTAssertEqual(reopened.snapshot.bookmarks, before.bookmarks)
        XCTAssertTrue(reopened.unblock([chinese, artist]))
        let final = LibraryStore(qa: true, storageRoot: root)
        XCTAssertTrue(final.blockedIDs.contains(existing.id))
        XCTAssertFalse(final.blockedIDs.contains(chinese.id)); XCTAssertFalse(final.blockedIDs.contains(artist.id))
    }

    func testFailedBulkSaveDoesNotPublishPartialTagState() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(qa: true, storageRoot: root)
        _ = try XCTUnwrap(store.saveSearch(name: "Existing", site: .ex, query: QASamples.savedSearches[0].query))
        let before = store.snapshot
        let file = store.directory.appendingPathComponent("library.json")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        XCTAssertFalse(store.pin([chinese, artist])); XCTAssertNotNil(store.error)
        XCTAssertEqual(store.snapshot.favoriteTags, before.favoriteTags)
        XCTAssertEqual(store.snapshot.saved, before.saved)
        XCTAssertFalse(store.block([chinese, artist]))
        XCTAssertEqual(store.snapshot.blockedTags, before.blockedTags)
    }
}
