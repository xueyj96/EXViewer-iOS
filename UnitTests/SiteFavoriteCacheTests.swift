import XCTest
import ExViewerCore
@testable import ExViewer

@MainActor final class SiteFavoriteCacheTests: XCTestCase {
    private let ref = GalleryRef(site: .ex, gid: 81, token: "preview")
    private func form(_ group: Int?) throws -> GalleryFavoriteForm {
        try GalleryFavoriteForm.read(NativeFavoritesQA.html(reference: ref, group: group, note: ""), reference: ref)
    }
    func testPendingDisplayDistinguishesAddMoveAndRemove() async throws {
        let cache = SiteFavoriteCache(), scope = GalleryFavoriteScope(reference: ref, owner: "aa", generation: UUID())
        cache.activate(owner: scope.owner, generation: scope.generation)
        let client = GalleryFavoriteClient(isCurrent: { true }, read: { throw ViewerError.network }, submit: { _ in })
        try cache.enqueue(scope: scope, client: client, form: form(nil), action: .move(1), note: "", title: "Fixture")
        XCTAssertEqual(cache.changes.first?.action, "加入收藏")
        XCTAssertEqual(cache.changes.first?.groupName, NativeFavoritesQA.groups[1])
        try cache.enqueue(scope: scope, client: client, form: form(nil), action: .remove, note: "", title: "Fixture")
        XCTAssertEqual(cache.changes.first?.action, "取消收藏")
        XCTAssertNil(cache.changes.first?.groupName)
        let moving = SiteFavoriteCache()
        moving.activate(owner: scope.owner, generation: scope.generation)
        try moving.enqueue(scope: scope, client: client, form: form(2), action: .move(1), note: "", title: "Fixture")
        XCTAssertEqual(moving.changes.first?.action, "调整分组")
        for _ in 0..<50 where cache.entry(scope)?.phase != .failed { try await Task.sleep(nanoseconds: 2_000_000) }
    }

    func testReaderAndDetailShareConfirmedEditAndDoNotReadAgainOnRevision() async throws {
        let cache = SiteFavoriteCache(), scope = GalleryFavoriteScope(reference: ref, owner: "aa", generation: UUID())
        let detail = GalleryFavoriteObservation(), reader = GalleryFavoriteObservation()
        var group: Int?, reads = 0
        let client = GalleryFavoriteClient(isCurrent: { true }, read: { reads += 1; return try self.form(group) }, submit: { _ in group = 2 })
        detail.bind(client, reference: ref, cache: cache, scope: scope)
        reader.bind(client, reference: ref, cache: cache, scope: scope); XCTAssertEqual(reads, 0)
        let p = reader.preparation(client, reference: ref)
        let edit = GalleryFavoriteEditorModel(client: p.client, initialForm: p.initialForm)
        await edit.reload(); edit.selection = 2
        let saved = await edit.save(); XCTAssertTrue(saved)
        reader.accept(edit.observedState, form: edit.form); detail.syncFromCache()
        XCTAssertEqual(reader.state, .favorited("已读")); XCTAssertEqual(detail.state, reader.state)
        detail.bind(client, reference: ref, cache: cache, scope: scope)
        XCTAssertEqual(reads, 2, "Only initial read and post-submit verification are needed")
        let remove = reader.preparation(client, reference: ref)
        let removal = GalleryFavoriteEditorModel(client: remove.client, initialForm: remove.initialForm)
        // Verify publication of a removal independently of the mock submit body.
        let none = try form(nil); reader.accept(.notFavorited, form: none); detail.syncFromCache()
        XCTAssertEqual(detail.state, .notFavorited); XCTAssertNotNil(removal.form)
    }
    func testRenamingRefreshesCachedLabelAndInvalidatesOldForms() throws {
        let cache = SiteFavoriteCache(), scope = GalleryFavoriteScope(reference: ref, owner: "aa", generation: UUID())
        cache.put(.favorited(NativeFavoritesQA.groups[2]), form: try form(2), scope: scope)
        var names = NativeFavoritesQA.groups; names[2] = "Renamed"
        try cache.updateGroupNames(site: .ex, before: NativeFavoritesQA.groups, after: names)
        XCTAssertEqual(cache.entry(scope)?.state, .favorited("Renamed"))
        XCTAssertNil(cache.entry(scope)?.form)
    }
    func testDuplicateGroupNamesRemainIdentifiableAfterRestart() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = SiteFavoriteCache(storageRoot: root), scope = GalleryFavoriteScope(reference: ref, owner: "aa", generation: UUID())
        var names = NativeFavoritesQA.groups; names[2] = "Same"; names[3] = "Same"
        let value = try form(2).replacingGroupNames(names)
        cache.put(value.state, form: value, scope: scope)
        let restored = SiteFavoriteCache(storageRoot: root)
        restored.activate(owner: scope.owner, generation: scope.generation)
        var renamed = names; renamed[2] = "Reading"
        try restored.updateGroupNames(site: .ex, before: names, after: renamed)
        XCTAssertEqual(restored.entry(scope)?.state, .favorited("Reading"))
        let legacy = SiteFavoriteCache()
        legacy.put(.favorited("Same"), scope: scope)
        try legacy.updateGroupNames(site: .ex, before: names, after: renamed)
        XCTAssertEqual(legacy.entry(scope)?.state, .favorited("站点收藏"), "Legacy duplicate names must not guess a category")
    }
    func testOldEditorReadWithoutExistingRecordCannotReintroduceNames() async throws {
        let cache = SiteFavoriteCache(), scope = GalleryFavoriteScope(reference: ref, owner: "aa", generation: UUID())
        let observation = GalleryFavoriteObservation(), old = try form(2)
        var held: CheckedContinuation<Void, Never>?
        let client = GalleryFavoriteClient(isCurrent: { true }, read: {
            await withCheckedContinuation { held = $0 }; return old
        }, submit: { _ in XCTFail("No POST") })
        observation.bind(client, reference: ref, cache: cache, scope: scope)
        let prepared = observation.preparation(client, reference: ref)
        let reading = Task { try await prepared.client.read() }
        for _ in 0..<100 where held == nil { try await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertNotNil(held)
        var names = NativeFavoritesQA.groups; names[2] = "Reading"
        try cache.updateGroupNames(site: .ex, before: NativeFavoritesQA.groups, after: names)
        held?.resume()
        do { _ = try await reading.value; XCTFail("Old read must be rejected") }
        catch { XCTAssertEqual(error as? ViewerError, .stale) }
        XCTAssertNil(cache.entry(scope))
    }
    func testInFlightAdditionKeepsActualMembershipAndLatestNamesWithoutAnotherPost() async throws {
        let cache = SiteFavoriteCache(), scope = GalleryFavoriteScope(reference: ref, owner: "aa", generation: UUID())
        cache.activate(owner: scope.owner, generation: scope.generation)
        let old = try form(2)
        var held: CheckedContinuation<Void, Never>?, posts = 0
        let client = GalleryFavoriteClient(isCurrent: { true }, read: {
            await withCheckedContinuation { held = $0 }; return old
        }, submit: { _ in posts += 1 })
        _ = try cache.enqueueAdditions([.init(scope: scope, client: client, title: "Fixture", groupName: "Default", group: 0)], group: 0)
        for _ in 0..<100 where held == nil { try await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertNotNil(held)
        var names = NativeFavoritesQA.groups; names[2] = "Reading"
        try cache.updateGroupNames(site: .ex, before: NativeFavoritesQA.groups, after: names)
        held?.resume()
        for _ in 0..<100 where cache.entry(scope)?.phase != nil { try await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertEqual(posts, 0)
        XCTAssertEqual(cache.entry(scope)?.state, .favorited("Reading"))
        XCTAssertEqual(cache.entry(scope)?.form?.selectedGroup, 2)
        XCTAssertEqual(cache.entry(scope)?.form?.state, .favorited("Reading"))
    }
    func testOldReadCannotOverwriteNewerLocalConfirmationAndFailureRemainsUnknown() async throws {
        let cache = SiteFavoriteCache(), scope = GalleryFavoriteScope(reference: ref, owner: "aa", generation: UUID())
        let o = GalleryFavoriteObservation(), value = try form(nil)
        o.bind(.init(isCurrent: { true }, read: { value }, submit: { _ in }), reference: ref, cache: cache, scope: scope)
        let initialVersion = cache.entry(scope)?.version
        cache.put(.favorited("已读"), form: try form(2), scope: scope, force: true)
        XCTAssertFalse(cache.put(value.state, scope: scope, expectedVersion: initialVersion, conditional: true))
        o.syncFromCache()
        XCTAssertEqual(o.state, .favorited("已读"))
        let version = cache.entry(scope)?.version
        cache.put(.unknown, scope: scope, force: true)
        XCTAssertFalse(cache.put(.favorited("stale"), scope: scope, expectedVersion: version, conditional: true))
        o.syncFromCache(); XCTAssertEqual(o.state, .unknown)
    }
    func testCacheIsBoundedAndCannotCarryStateOrFormsAcrossAccountsAndSessions() throws {
        let cache = SiteFavoriteCache(capacity: 64), generation = UUID()
        for id in 1...80 {
            cache.put(.notFavorited, scope: .init(reference: .init(site: .ex, gid: Int64(id), token: "preview"), owner: "aa", generation: generation))
        }
        XCTAssertNil(cache.entry(.init(reference: .init(site: .ex, gid: 1, token: "preview"), owner: "aa", generation: generation)))
        let old = GalleryFavoriteScope(reference: ref, owner: "aa", generation: generation)
        cache.put(.favorited("已读"), form: try form(2), scope: old)
        XCTAssertNotNil(cache.recent(old)); XCTAssertNil(cache.recent(old, now: Date().addingTimeInterval(601)))
        let other = GalleryFavoriteScope(reference: ref, owner: "bb", generation: UUID())
        XCTAssertNil(cache.entry(other)); cache.activate(owner: other.owner, generation: other.generation); cache.put(.notFavorited, scope: other)
        XCTAssertNil(cache.entry(old)); XCTAssertEqual(cache.entry(other)?.state, .notFavorited)
    }
}
