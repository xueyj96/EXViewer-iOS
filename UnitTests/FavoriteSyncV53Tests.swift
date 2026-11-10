import XCTest
import ExViewerCore
@testable import ExViewer

@MainActor final class FavoriteSyncV53Tests: XCTestCase {
    private let ref = GalleryRef(site: .ex, gid: 83, token: "ReferenceMustRemainInMemory")
    @MainActor private final class Server {
        let ref: GalleryRef
        var group: Int?
        var note = ""
        var reads = 0, posts = 0
        var failures = Set<Int>()
        var postDelay: UInt64 = 0
        var lostReply = false
        var current = true
        init(_ ref: GalleryRef) { self.ref = ref }
        func form() throws -> GalleryFavoriteForm {
            try GalleryFavoriteForm.read(NativeFavoritesQA.html(reference: ref, group: group, note: note), reference: ref)
        }
        var client: GalleryFavoriteClient {
            .init(isCurrent: { self.current }, read: {
                self.reads += 1
                if self.failures.contains(self.reads) { throw URLError(.timedOut) }
                return try self.form()
            }, submit: { request in
                self.posts += 1
                if self.postDelay > 0 { try await Task.sleep(nanoseconds: self.postDelay) }
                let fields = URLComponents(string: "https://example.invalid/?" + String(decoding: request.body, as: UTF8.self).replacingOccurrences(of: "+", with: "%20"))!.queryItems!
                let category = fields.first { $0.name == "favcat" }!.value!
                self.group = category == "favdel" ? nil : Int(category)
                self.note = fields.first { $0.name == "favnote" }!.value!
                if self.lostReply { throw URLError(.networkConnectionLost) }
            })
        }
    }
    private func scope(_ generation: UUID = UUID(), owner: String = "aa", reference: GalleryRef? = nil) -> GalleryFavoriteScope {
        .init(reference: reference ?? ref, owner: owner, generation: generation)
    }
    private func wait(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<250 { if condition() { return true }; try? await Task.sleep(nanoseconds: 2_000_000) }
        return condition()
    }
    private func enqueue(_ cache: SiteFavoriteCache, _ server: Server, _ scope: GalleryFavoriteScope, _ action: FavoriteAction) throws {
        try cache.enqueue(scope: scope, client: server.client, form: server.form(), action: action, note: server.note, title: "Neutral art book")
    }
    func testWarmFormAfterSixteenSecondsIsReusableWithoutTwentyReads() throws {
        let cache = SiteFavoriteCache(), s = scope(), server = Server(ref)
        server.group = 2
        let form = try server.form(); cache.put(form.state, form: form, scope: s)
        let future = Date().addingTimeInterval(16); var hits = 0
        for _ in 0..<20 {
            let observation = GalleryFavoriteObservation(); observation.bind(server.client, reference: ref, cache: cache, scope: s, now: future)
            let draft = observation.preparation(server.client, reference: ref, now: future)
            if draft.initialForm != nil && !draft.requiresRefresh { hits += 1 }
            observation.cancel()
        }
        XCTAssertEqual(hits, 20); XCTAssertEqual(server.reads, 0)
        print("FAVORITE_WARM_FORM_HITS=\(hits)/20;NETWORK_READS=\(server.reads)")
    }
    func testConfirmedStateSurvivesRestartWithoutFormOrReferenceTokenOnDisk() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let cache = SiteFavoriteCache(storageRoot: root), s = scope(), server = Server(ref)
        server.group = 2; server.note = "ServerNoteMustRemainInMemory"
        let form = try server.form(); cache.put(form.state, form: form, scope: s)
        let restored = SiteFavoriteCache(storageRoot: root), fresh = scope()
        restored.activate(owner: fresh.owner, generation: fresh.generation)
        XCTAssertEqual(restored.entry(fresh)?.state, .favorited("已读")); XCTAssertNil(restored.entry(fresh)?.form)
        let data = try Data(contentsOf: root.appendingPathComponent("aa/site-favorites.json"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(ref.token))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(server.note))
    }
    func testQueuedChangePublishesImmediatelyAndFinishesAfterEditorCloses() async throws {
        let cache = SiteFavoriteCache(), s = scope(), server = Server(ref); server.postDelay = 60_000_000
        cache.put(.notFavorited, scope: s)
        try enqueue(cache, server, s, .move(1))
        XCTAssertEqual(cache.entry(s)?.state, .favorited("待阅读")); XCTAssertEqual(cache.entry(s)?.phase, .queued)
        XCTAssertEqual(server.posts, 0)
        let done = await wait { cache.entry(s)?.phase == nil }; XCTAssertTrue(done)
        XCTAssertEqual(server.posts, 1); XCTAssertEqual(cache.entry(s)?.state, .favorited("待阅读"))
    }
    func testBatchAdditionReadsFreshMembershipAndPreservesExistingGroupAndNote() async throws {
        let cache = SiteFavoriteCache(), existingScope = scope(), existing = Server(ref)
        let newReference = GalleryRef(site: .eh, gid: 84, token: "newFixture")
        let newScope = scope(existingScope.generation, reference: newReference), fresh = Server(newReference)
        cache.put(.notFavorited, form: try existing.form(), scope: existingScope)
        existing.group = 2
        existing.note = "Keep this note"
        let additions: [SiteFavoriteCache.BatchAddition] = [
            .init(scope: existingScope, client: existing.client, title: "Existing", groupName: "待阅读"),
            .init(scope: newScope, client: fresh.client, title: "New", groupName: "待阅读"),
        ]
        XCTAssertEqual(try cache.enqueueAdditions(additions, group: 1), 2)
        XCTAssertEqual(try cache.enqueueAdditions(additions, group: 3), 0, "A repeated batch must respect pending changes")
        XCTAssertEqual(cache.entry(newScope)?.state, .unknown)
        XCTAssertEqual(cache.entry(newScope)?.phase, .queued)
        XCTAssertEqual(existing.posts + fresh.posts, 0)
        let done = await wait { cache.entry(existingScope)?.phase == nil && cache.entry(newScope)?.phase == nil }
        XCTAssertTrue(done)
        XCTAssertEqual(existing.reads, 1)
        XCTAssertEqual(existing.posts, 0)
        XCTAssertEqual(existing.group, 2)
        XCTAssertEqual(existing.note, "Keep this note")
        XCTAssertEqual(cache.entry(existingScope)?.state, .favorited(QASamples.favoriteGroupName))
        XCTAssertEqual(fresh.posts, 1)
        XCTAssertEqual(fresh.group, 1)
        XCTAssertEqual(cache.entry(newScope)?.state, .favorited("待阅读"))
    }

    func testBatchOverCapacityDoesNotPartiallyQueue() throws {
        let cache = SiteFavoriteCache(), base = scope()
        cache.activate(owner: base.owner, generation: base.generation)
        let additions = (1...65).map { gid in
            let reference = GalleryRef(site: .eh, gid: Int64(gid), token: "fixture")
            return SiteFavoriteCache.BatchAddition(scope: scope(base.generation, reference: reference),
                                                   client: Server(reference).client, title: "Fixture", groupName: "待阅读")
        }
        XCTAssertThrowsError(try cache.enqueueAdditions(additions, group: 1))
        XCTAssertTrue(cache.changes.isEmpty)
    }
    func testSeveralSelectionsBeforeDispatchCoalesceToOnePost() async throws {
        let cache = SiteFavoriteCache(), s = scope(), server = Server(ref)
        cache.put(.notFavorited, scope: s)
        for group in [1, 3, 2] { try enqueue(cache, server, s, .move(group)) }
        let done = await wait { cache.entry(s)?.phase == nil }; XCTAssertTrue(done)
        XCTAssertEqual(server.posts, 1); XCTAssertEqual(server.group, 2)
    }
    func testNewSelectionDuringPostNeverFlashesBackToOldSelection() async throws {
        let cache = SiteFavoriteCache(), s = scope(), server = Server(ref); server.postDelay = 50_000_000
        cache.put(.notFavorited, scope: s); try enqueue(cache, server, s, .move(1))
        let started = await wait { server.posts == 1 }; XCTAssertTrue(started)
        try enqueue(cache, server, s, .move(3))
        for _ in 0..<70 { XCTAssertEqual(cache.entry(s)?.state, .favorited("画集")); try? await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertNil(cache.entry(s)?.phase); XCTAssertEqual(server.group, 3); XCTAssertEqual(server.posts, 2)
    }
    func testLostPostReplyIsConfirmedWithoutAnotherPost() async throws {
        let cache = SiteFavoriteCache(), s = scope(), server = Server(ref); server.lostReply = true
        cache.put(.notFavorited, scope: s); try enqueue(cache, server, s, .move(2))
        let done = await wait { cache.entry(s)?.phase == nil }; XCTAssertTrue(done); XCTAssertEqual(server.posts, 1)
    }
    func testUnknownResultOnlyChecksAndDoesNotBlindlyResubmit() async throws {
        let cache = SiteFavoriteCache(), s = scope(), server = Server(ref); server.failures = [1, 2]
        cache.put(.notFavorited, scope: s); try enqueue(cache, server, s, .move(2))
        let uncertain = await wait { cache.entry(s)?.phase == .uncertain }; XCTAssertTrue(uncertain)
        XCTAssertEqual(server.posts, 1); cache.check(ref.id)
        let checked = await wait { server.reads == 2 }; XCTAssertTrue(checked)
        XCTAssertEqual(cache.entry(s)?.phase, .uncertain); XCTAssertEqual(server.posts, 1)
        cache.check(ref.id)
        let done = await wait { cache.entry(s)?.phase == nil }; XCTAssertTrue(done); XCTAssertEqual(server.posts, 1)
    }
    func testRemovalBecomesVisibleToTheListOnlyAfterServerConfirmation() async throws {
        let cache = SiteFavoriteCache(), favoriteScope = scope(), server = Server(ref)
        server.group = 2
        server.failures = [1]
        let form = try server.form()
        cache.put(form.state, form: form, scope: favoriteScope)
        try enqueue(cache, server, favoriteScope, .remove)

        let uncertain = await wait { cache.entry(favoriteScope)?.phase == .uncertain }
        XCTAssertTrue(uncertain)
        XCTAssertEqual(server.posts, 1)
        XCTAssertTrue(cache.confirmedRemovals.isEmpty)
        cache.check(ref.id)
        let confirmed = await wait { cache.confirmedRemovals[ref.id] != nil }
        XCTAssertTrue(confirmed)
        XCTAssertEqual(cache.entry(favoriteScope)?.state, .notFavorited)
        XCTAssertEqual(server.posts, 1)
        cache.activate(owner: "bb", generation: UUID())
        XCTAssertTrue(cache.confirmedRemovals.isEmpty)
    }
    func testRestoredInFlightIntentIsReadBeforeAnyResubmission() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let cache = SiteFavoriteCache(storageRoot: root), s = scope(), server = Server(ref); server.postDelay = 90_000_000
        cache.put(.notFavorited, scope: s); try enqueue(cache, server, s, .move(2))
        let sent = await wait { server.posts == 1 }; XCTAssertTrue(sent)
        let restored = SiteFavoriteCache(storageRoot: root), newScope = scope()
        restored.activate(owner: newScope.owner, generation: newScope.generation)
        XCTAssertEqual(restored.entry(newScope)?.phase, .uncertain)
        let finished = await wait { cache.entry(s)?.phase == nil }; XCTAssertTrue(finished)
        restored.register(UUID(), scope: newScope, client: server.client)
        let checked = await wait { restored.entry(newScope)?.phase == nil }; XCTAssertTrue(checked); XCTAssertEqual(server.posts, 1)
    }
    func testAccountSwitchRejectsLateOldAccountResponses() async throws {
        let cache = SiteFavoriteCache(), s = scope(), server = Server(ref); server.postDelay = 50_000_000
        cache.put(.notFavorited, scope: s); try enqueue(cache, server, s, .move(1))
        let started = await wait { server.posts == 1 }; XCTAssertTrue(started)
        let other = scope(owner: "bb"); cache.activate(owner: other.owner, generation: other.generation)
        try? await Task.sleep(nanoseconds: 70_000_000)
        XCTAssertNil(cache.entry(other)); XCTAssertNil(cache.entry(s)); XCTAssertTrue(cache.changes.isEmpty)
    }
    func testOldDetailReadCannotUndoAQueuedIntent() throws {
        let cache = SiteFavoriteCache(), s = scope(), server = Server(ref)
        cache.put(.notFavorited, scope: s); let version = cache.entry(s)?.version
        try enqueue(cache, server, s, .move(2))
        XCTAssertFalse(cache.put(.notFavorited, scope: s, expectedVersion: version, conditional: true))
        XCTAssertEqual(cache.entry(s)?.state, .favorited("已读"))
        cache.activate(owner: "bb", generation: UUID())
    }
    func testForegroundRefreshIsThrottledAndReadsOnlyVisibleWork() async throws {
        final class Clock { var date = Date() }
        let clock = Clock(), cache = SiteFavoriteCache(now: { clock.date }), s = scope(), server = Server(ref)
        cache.put(.notFavorited, scope: s); cache.register(UUID(), scope: s, client: server.client)
        cache.refreshActive(); XCTAssertEqual(server.reads, 0)
        clock.date.addTimeInterval(601)
        for _ in 0..<20 { cache.refreshActive() }
        let read = await wait { server.reads == 1 }; XCTAssertTrue(read)
        for _ in 0..<20 { cache.refreshActive() }
        try? await Task.sleep(nanoseconds: 10_000_000); XCTAssertEqual(server.reads, 1)
    }
    func testListOnlySeedsPositiveMembershipAndPreservesOtherWork() throws {
        let cache = SiteFavoriteCache(), s = scope()
        cache.put(.favorited("已读"), scope: s)
        let other = Gallery(ref: .init(site: .ex, gid: 84, token: "preview"), title: "Other neutral work")
        cache.seedFavorites([other], categories: ["1":"待阅读"], url: URL(string:"https://exhentai.org/favorites.php?favcat=1")!, scopeOwner:s.owner, generation:s.generation)
        XCTAssertEqual(cache.entry(s)?.state, .favorited("已读"))
        XCTAssertEqual(cache.entry(scope(s.generation, reference:other.ref))?.state, .favorited("待阅读"))
    }
    func testStorageFailureDoesNotPretendAnIntentWasQueued() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        try Data("not a directory".utf8).write(to: root)
        let cache = SiteFavoriteCache(storageRoot: root), s = scope(), server = Server(ref)
        cache.activate(owner: s.owner, generation: s.generation)
        XCTAssertThrowsError(try enqueue(cache, server, s, .move(1)))
        XCTAssertTrue(cache.changes.isEmpty); XCTAssertEqual(server.posts, 0)
    }
    func testBackgroundRefreshPreservesChangesMadeWhileWaiting() async throws {
        let server = Server(ref); server.group = 2; let initial = try server.form()
        server.group = 1; server.note = "Remote note"; let updated = try server.form()
        let model = GalleryFavoriteEditorModel(client: .init(isCurrent: { true }, read: {
            try await Task.sleep(nanoseconds: 30_000_000); return updated
        }, submit: { _ in }), initialForm: initial)
        let refresh = Task { await model.reload(preservingEdits: true) }
        let loading = await wait { model.loading }; XCTAssertTrue(loading)
        model.selection = 7; model.note = "My draft"
        _ = await refresh.value
        XCTAssertEqual(model.selection, 7); XCTAssertEqual(model.note, "My draft"); XCTAssertEqual(model.form?.selectedGroup, 1)
    }
    func testBackgroundRefreshUpdatesUneditedCachedDefaults() async throws {
        let server = Server(ref); server.group = 2; let initial = try server.form()
        server.group = 1; server.note = "Remote note"; let updated = try server.form()
        let model = GalleryFavoriteEditorModel(client: .init(isCurrent: { true }, read: { updated }, submit: { _ in }), initialForm: initial)
        _ = await model.reload(preservingEdits: true)
        XCTAssertEqual(model.selection, 1); XCTAssertEqual(model.note, "Remote note")
    }
    func testPersistentAccountsRemainIsolated() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let cache = SiteFavoriteCache(storageRoot: root), a = scope(), b = scope(owner: "bb")
        cache.put(.favorited("已读"), scope: a)
        cache.activate(owner: b.owner, generation: b.generation); cache.put(.notFavorited, scope: b)
        let restored = SiteFavoriteCache(storageRoot: root)
        restored.activate(owner: a.owner, generation: a.generation); XCTAssertEqual(restored.entry(a)?.state, .favorited("已读"))
        restored.activate(owner: b.owner, generation: b.generation); XCTAssertEqual(restored.entry(b)?.state, .notFavorited)
        XCTAssertNil(restored.entry(a))
    }
    func testCorruptCacheIsPreservedAndCannotLosePendingDataThroughOverwrite() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("aa"), withIntermediateDirectories: true)
        let file = root.appendingPathComponent("aa/site-favorites.json"), original = Data("invalid-json".utf8)
        try original.write(to: file)
        let cache = SiteFavoriteCache(storageRoot: root), s = scope(), server = Server(ref)
        cache.activate(owner: s.owner, generation: s.generation)
        XCTAssertThrowsError(try enqueue(cache, server, s, .move(1)))
        let newGeneration = UUID()
        cache.activate(owner: s.owner, generation: newGeneration)
        XCTAssertNotNil(cache.readFailure)
        XCTAssertThrowsError(try enqueue(cache, server, scope(newGeneration), .move(1)))
        XCTAssertEqual(try Data(contentsOf: file), original); XCTAssertTrue(cache.changes.isEmpty)
    }
    func testSlowFormReadCannotOverwriteAConfirmedNewerEdit() async throws {
        let cache = SiteFavoriteCache(), s = scope(), server = Server(ref), observation = GalleryFavoriteObservation()
        cache.put(.notFavorited, scope: s)
        let old = try server.form()
        let slow = GalleryFavoriteClient(isCurrent: { true }, read: {
            try await Task.sleep(nanoseconds: 80_000_000); return old
        }, submit: { _ in })
        observation.bind(slow, reference: ref, cache: cache, scope: s)
        let preparation = observation.preparation(slow, reference: ref)
        let model = GalleryFavoriteEditorModel(client: preparation.client)
        let read = Task { await model.reload() }
        let started = await wait { model.loading }; XCTAssertTrue(started)
        try enqueue(cache, server, s, .move(2))
        let saved = await wait { cache.entry(s)?.phase == nil }; XCTAssertTrue(saved)
        _ = await read.value
        XCTAssertEqual(cache.entry(s)?.state, .favorited("已读")); XCTAssertEqual(server.posts, 1)
    }
    func testFiveThousandCachedWorksRestoreAndQueueLocallyWithoutNetwork() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let cache = SiteFavoriteCache(storageRoot: root), s = scope(), server = Server(ref)
        cache.activate(owner: s.owner, generation: s.generation)
        let galleries = (1...5_001).map { Gallery(ref: .init(site: .ex, gid: Int64($0), token: "preview"), title: "Neutral work") }
        cache.seedFavorites(galleries, categories: [:], url: URL(string: "https://exhentai.org/favorites.php")!, scopeOwner: s.owner, generation: s.generation)
        XCTAssertEqual(cache.cachedCount, 5_000)
        let began = ProcessInfo.processInfo.systemUptime
        try enqueue(cache, server, s, .move(2))
        let enqueueMS = (ProcessInfo.processInfo.systemUptime - began) * 1_000
        XCTAssertEqual(cache.entry(s)?.state, .favorited("已读")); XCTAssertEqual(server.posts, 0)
        cache.activate(owner: "bb", generation: UUID())
        let restoreBegan = ProcessInfo.processInfo.systemUptime
        let restored = SiteFavoriteCache(storageRoot: root)
        restored.activate(owner: s.owner, generation: s.generation)
        let restoreMS = (ProcessInfo.processInfo.systemUptime - restoreBegan) * 1_000
        XCTAssertEqual(restored.cachedCount, 5_000); XCTAssertEqual(restored.changes.count, 1); XCTAssertEqual(server.posts, 0)
        print("FAVORITE_CACHE_5000_ENQUEUE_MS=\(enqueueMS);RESTORE_MS=\(restoreMS);NETWORK_POSTS=\(server.posts)")
    }
    func testLargeLabelsEvictOnlyCacheRecordsAndKeepPendingChangesWithinDiskBound() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let cache = SiteFavoriteCache(storageRoot: root), s = scope(), server = Server(ref)
        cache.activate(owner: s.owner, generation: s.generation)
        let galleries = (1...5_000).map { Gallery(ref: .init(site: .ex, gid: Int64($0), token: "preview"), title: "Neutral") }
        cache.seedFavorites(galleries, categories: ["1":String(repeating:"字",count:200)], url: URL(string:"https://exhentai.org/favorites.php?favcat=1")!, scopeOwner:s.owner, generation:s.generation)
        try enqueue(cache, server, s, .move(2))
        let file = root.appendingPathComponent("aa/site-favorites.json")
        XCTAssertLessThanOrEqual(try Data(contentsOf:file).count,2_000_000)
        let restored = SiteFavoriteCache(storageRoot:root);restored.activate(owner:s.owner,generation:s.generation)
        XCTAssertEqual(restored.entry(s)?.phase,.queued);XCTAssertEqual(restored.changes.count,1)
        cache.activate(owner:"bb",generation:UUID())
    }
    func testKnownUnsentChangeResumesOnForegroundAfterNetworkRecoversWithDetailClosed() async throws {
        final class Clock { var date = Date() }
        let clock = Clock(), cache = SiteFavoriteCache(now:{clock.date}), s = scope(), server = Server(ref)
        let observer = UUID()
        cache.put(.notFavorited,scope:s)
        cache.register(observer, scope: s, client: server.client)
        try enqueue(cache,server,s,.move(2))
        cache.unregister(observer)
        clock.date.addTimeInterval(601);server.failures=[1]
        let waiting = await wait { server.reads == 1 && cache.entry(s)?.message != nil };XCTAssertTrue(waiting)
        XCTAssertEqual(cache.entry(s)?.phase,.queued);XCTAssertEqual(server.posts,0)
        server.failures=[];cache.refreshActive()
        let done = await wait { cache.entry(s)?.phase == nil };XCTAssertTrue(done);XCTAssertEqual(server.posts,1)
    }
}
