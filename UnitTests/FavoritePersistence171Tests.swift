import XCTest
import Combine
import ExViewerCore
@testable import ExViewer

@MainActor final class FavoritePersistence171Tests: XCTestCase {
    private let ref = GalleryRef(site: .ex, gid: 171, token: "fixture")

    /// Test-only cross-executor probe. Every mutable field is lock protected;
    /// the semaphore blocks only the storage actor, never the UI executor.
    private final class WriteProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var mainCount = 0
        private let gate = DispatchSemaphore(value: 0)
        let holdAt: Int?
        let failAt: Int?
        init(holdFirst: Bool = false, holdAt: Int? = nil, failAt: Int? = nil) {
            self.holdAt = holdAt ?? (holdFirst ? 1 : nil); self.failAt = failAt
        }
        func beforeWrite() throws {
            lock.lock()
            count += 1
            if Thread.isMainThread { mainCount += 1 }
            let index = count
            lock.unlock()
            if index == holdAt {
                guard gate.wait(timeout: .now() + 5) == .success else { throw ViewerError.storage }
            }
            if index == failAt { throw ViewerError.storage }
        }
        var writes: Int { lock.lock(); defer { lock.unlock() }; return count }
        var mainThreadWrites: Int { lock.lock(); defer { lock.unlock() }; return mainCount }
        func release() { gate.signal() }
    }

    @MainActor private final class Server {
        let reference: GalleryRef
        var group: Int?
        var posts = 0
        var reads = 0
        var notifications = 0
        var holdRead = false
        private var readContinuation: CheckedContinuation<Void, Never>?
        init(_ reference: GalleryRef) { self.reference = reference }
        var client: GalleryFavoriteClient {
            .init(isCurrent: { true }, read: {
                self.reads += 1
                if self.holdRead { await withCheckedContinuation { self.readContinuation = $0 } }
                return try GalleryFavoriteForm.read(NativeFavoritesQA.html(reference: self.reference, group: self.group, note: ""), reference: self.reference)
            }, submit: { request in
                self.posts += 1
                let fields = URLComponents(string: "https://example.invalid/?" + String(decoding: request.body, as: UTF8.self))!.queryItems!
                let value = fields.first { $0.name == "favcat" }!.value!
                self.group = value == "favdel" ? nil : Int(value)
            }, didSubmit: { self.notifications += 1 })
        }
        func releaseRead() { holdRead = false; readContinuation?.resume(); readContinuation = nil }
    }

    @MainActor private final class Grant: DownloadBackgroundWork {
        var canContinue = false
        var beginCount = 0
        var endings: [DownloadBackgroundCompletion] = []
        var expired: (@MainActor () -> Void)?
        func beginShort(_ name: String, expired: @escaping @MainActor () -> Void) {
            beginCount += 1; canContinue = true; self.expired = expired
        }
        func requestContinuation(stopped: @escaping @MainActor () -> Void) {}
        func report(completed: Int, total: Int?) {}
        func finish(_ completion: DownloadBackgroundCompletion) { endings.append(completion); canContinue = false }
        func expire() { let callback = expired; expired = nil; callback?() }
    }

    private func scope(owner: String = "aa", generation: UUID = UUID(), reference: GalleryRef? = nil) -> GalleryFavoriteScope {
        .init(reference: reference ?? ref, owner: owner, generation: generation)
    }
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<500 { if condition() { return }; try await Task.sleep(nanoseconds: 2_000_000) }
        XCTFail("Favorite storage did not reach the expected state")
    }
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }

    func testDurableIntentDoesNotBlockMainActorOrGetOverwrittenByQueuedCheckpoint() async throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let probe = WriteProbe(holdFirst: true); defer { probe.release() }
        let cache = SiteFavoriteCache(storageRoot: directory, beforePersistence: { try probe.beforeWrite() })
        let current = scope(), server = Server(ref); server.holdRead = true
        cache.activate(owner: current.owner, generation: current.generation)
        let enqueue = Task { try await cache.enqueueToggle(scope: current, client: server.client, group: 2,
                                                          groupName: NativeFavoritesQA.groups[2], title: "Fixture") }
        try await wait { probe.writes == 1 }
        // This actor is responsive while the writer is intentionally held.
        XCTAssertNil(cache.entry(current))
        XCTAssertEqual(server.posts, 0, "No POST is allowed before durable acceptance")
        let otherRef = GalleryRef(site: .ex, gid: 172, token: "fixture")
        let other = scope(generation: current.generation, reference: otherRef)
        cache.put(.favorited("Other group"), scope: other)
        probe.release()
        try await enqueue.value
        try await cache.flushPersistence()
        let restored = SiteFavoriteCache(storageRoot: directory)
        restored.activate(owner: current.owner, generation: current.generation)
        XCTAssertEqual(restored.entry(current)?.phase, .queued)
        XCTAssertEqual(restored.entry(current)?.state, .favorited(NativeFavoritesQA.groups[2]))
        XCTAssertEqual(restored.entry(other)?.state, .favorited("Other group"))
        XCTAssertEqual(server.posts, 0)
        XCTAssertEqual(probe.mainThreadWrites, 0)
        cache.activate(owner: "bb", generation: UUID()); server.releaseRead()
        try await cache.flushPersistence()
    }

    func testSwitchingAccountsAndReturningKeepsNewestSnapshotForEachOwner() async throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let probe = WriteProbe(holdFirst: true); defer { probe.release() }
        let cache = SiteFavoriteCache(storageRoot: directory, beforePersistence: { try probe.beforeWrite() })
        let first = scope(), second = scope(owner: "bb")
        cache.put(.favorited("Old"), scope: first)
        try await wait { probe.writes == 1 }
        cache.activate(owner: second.owner, generation: second.generation)
        cache.put(.favorited("Second"), scope: second)
        let returnScope = scope(generation: UUID())
        cache.activate(owner: returnScope.owner, generation: returnScope.generation)
        cache.put(.notFavorited, scope: returnScope)
        XCTAssertNil(cache.entry(first), "Old generation must not read the returned account")
        probe.release()
        try await cache.flushPersistence()
        let restored = SiteFavoriteCache(storageRoot: directory)
        restored.activate(owner: returnScope.owner, generation: returnScope.generation)
        XCTAssertEqual(restored.entry(returnScope)?.state, .notFavorited)
        restored.activate(owner: second.owner, generation: second.generation)
        XCTAssertEqual(restored.entry(second)?.state, .favorited("Second"))
        try await restored.flushPersistence()
        XCTAssertEqual(probe.mainThreadWrites, 0)
    }

    func testAccountSwitchDuringDurableAcceptanceCannotPostOrPublishToNewAccount() async throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let probe = WriteProbe(holdFirst: true); defer { probe.release() }
        let cache = SiteFavoriteCache(storageRoot: directory, beforePersistence: { try probe.beforeWrite() })
        let first = scope(), second = scope(owner: "bb"), server = Server(ref)
        cache.activate(owner: first.owner, generation: first.generation)
        let enqueue = Task { try await cache.enqueueToggle(scope: first, client: server.client, group: 2,
                                                          groupName: NativeFavoritesQA.groups[2], title: "Fixture") }
        try await wait { probe.writes == 1 }
        cache.activate(owner: second.owner, generation: second.generation)
        cache.put(.notFavorited, scope: second)
        probe.release()
        do { try await enqueue.value; XCTFail("Old account acceptance must fail") }
        catch { XCTAssertEqual(error as? ViewerError, .stale) }
        try await cache.flushPersistence()
        XCTAssertEqual(server.posts, 0)
        XCTAssertEqual(cache.entry(second)?.state, .notFavorited)
        XCTAssertTrue(cache.changes.isEmpty)
        let restored = SiteFavoriteCache(storageRoot: directory)
        restored.activate(owner: first.owner, generation: first.generation)
        XCTAssertTrue(restored.changes.isEmpty)
        restored.activate(owner: second.owner, generation: second.generation)
        XCTAssertEqual(restored.entry(second)?.state, .notFavorited)
        try await restored.flushPersistence()
    }

    func testSendingCheckpointFailureNeverStartsPost() async throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let probe = WriteProbe(failAt: 2)
        let cache = SiteFavoriteCache(storageRoot: directory, beforePersistence: { try probe.beforeWrite() })
        let current = scope(), server = Server(ref)
        cache.activate(owner: current.owner, generation: current.generation)
        try await cache.enqueueToggle(scope: current, client: server.client, group: 2,
                                      groupName: NativeFavoritesQA.groups[2], title: "Fixture")
        try await wait { cache.entry(current)?.phase == .failed }
        try await cache.flushPersistence()
        XCTAssertEqual(server.posts, 0)
        XCTAssertNotNil(cache.entry(current)?.message)
        let restored = SiteFavoriteCache(storageRoot: directory)
        restored.activate(owner: current.owner, generation: current.generation)
        XCTAssertEqual(restored.entry(current)?.phase, .failed)
        XCTAssertEqual(probe.mainThreadWrites, 0)
    }

    func testFinalCheckpointFailureRemainsCheckOnlyAndNeverReposts() async throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let probe = WriteProbe(failAt: 4)
        let cache = SiteFavoriteCache(storageRoot: directory, beforePersistence: { try probe.beforeWrite() })
        let current = scope(), server = Server(ref)
        cache.activate(owner: current.owner, generation: current.generation)
        try await cache.enqueueToggle(scope: current, client: server.client, group: 2,
                                      groupName: NativeFavoritesQA.groups[2], title: "Fixture")
        try await wait { cache.entry(current)?.phase == .uncertain }
        try await cache.flushPersistence()
        XCTAssertEqual(server.posts, 1)
        cache.check(ref.id)
        try await wait { cache.entry(current)?.phase == nil }
        try await cache.flushPersistence()
        XCTAssertEqual(server.posts, 1)
        XCTAssertEqual(server.reads, 3)
        let restored = SiteFavoriteCache(storageRoot: directory)
        restored.activate(owner: current.owner, generation: current.generation)
        XCTAssertEqual(restored.entry(current)?.state, .favorited(NativeFavoritesQA.groups[2]))
        XCTAssertNil(restored.entry(current)?.phase)
    }


    func testFinalConfirmationRemainsPendingUntilDurableEvenWhenAnotherRecordPublishes() async throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let probe = WriteProbe(holdAt: 4); defer { probe.release() }
        let cache = SiteFavoriteCache(storageRoot: directory, beforePersistence: { try probe.beforeWrite() })
        let current = scope(), server = Server(ref), observation = GalleryFavoriteObservation()
        observation.bind(server.client, reference: ref, cache: cache, scope: current)
        let subscription = cache.$revision.sink { _ in observation.syncFromCache() }
        defer { subscription.cancel() }
        try await cache.enqueueToggle(scope: current, client: server.client, group: 2,
                                      groupName: NativeFavoritesQA.groups[2], title: "Fixture")
        try await wait { probe.writes == 4 }
        XCTAssertEqual(server.posts, 1)
        XCTAssertEqual(server.notifications, 0)
        XCTAssertEqual(cache.entry(current)?.phase, .checking)
        let otherRef = GalleryRef(site: .ex, gid: 173, token: "fixture")
        let other = scope(generation: current.generation, reference: otherRef)
        cache.put(.favorited("Other group"), scope: other)
        XCTAssertEqual(observation.phase, .checking,
                       "An unrelated record's revision must not reveal an uncommitted success")
        XCTAssertTrue(cache.confirmedRemovals.isEmpty)
        probe.release()
        try await wait { observation.phase == nil && server.notifications == 1 }
        try await cache.flushPersistence()
        let restored = SiteFavoriteCache(storageRoot: directory)
        restored.activate(owner: current.owner, generation: current.generation)
        XCTAssertNil(restored.entry(current)?.phase)
        XCTAssertEqual(restored.entry(current)?.state, .favorited(NativeFavoritesQA.groups[2]))
        XCTAssertEqual(restored.entry(other)?.state, .favorited("Other group"))
        XCTAssertEqual(probe.mainThreadWrites, 0)
    }

    func testQueuedMutationsRebaseAfterAnotherKeysDurableConfirmation() async throws {
        // Hold A's final confirmation write, then enqueue each user mutation
        // behind it. No user mutation may write A's old checking snapshot back.
        for operation in ["editor", "toggle", "batch", "rename"] {
            let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
            let probe = WriteProbe(holdAt: 4); defer { probe.release() }
            let cache = SiteFavoriteCache(storageRoot: directory, beforePersistence: { try probe.beforeWrite() })
            let current = scope(), server = Server(ref)
            cache.activate(owner: current.owner, generation: current.generation)
            try await cache.enqueueToggle(scope: current, client: server.client, group: 2,
                                          groupName: NativeFavoritesQA.groups[2], title: "First fixture")
            try await wait { probe.writes == 4 }
            XCTAssertEqual(cache.entry(current)?.phase, .checking)
            let otherRef = GalleryRef(site: .ex, gid: 174, token: "fixture")
            let other = scope(generation: current.generation, reference: otherRef)
            let next = Server(otherRef); next.holdRead = true
            defer { next.releaseRead() }
            let otherForm = try GalleryFavoriteForm.read(NativeFavoritesQA.html(reference: otherRef, group: nil, note: ""), reference: otherRef)
            let renamed = NativeFavoritesQA.groups.enumerated().map { $0.offset == 2 ? "Renamed group" : $0.element }
            let mutation = Task {
                switch operation {
                case "editor":
                    try await cache.enqueue(scope: other, client: next.client, form: otherForm,
                                            action: .move(3), note: "", title: "Second fixture")
                case "toggle":
                    try await cache.enqueueToggle(scope: other, client: next.client, group: 3,
                                                  groupName: NativeFavoritesQA.groups[3], title: "Second fixture")
                case "batch":
                    _ = try await cache.enqueueAdditions([.init(scope: other, client: next.client,
                                                                title: "Second fixture", groupName: NativeFavoritesQA.groups[3], group: 3)], group: 3)
                case "rename":
                    try await cache.updateGroupNames(site: .ex, before: NativeFavoritesQA.groups, after: renamed)
                default: XCTFail("Unexpected fixture")
                }
            }
            // Observe the queued write rather than relying on a sleep/yield to
            // guess whether B has reached the serial persistence boundary.
            try await wait { cache.pendingPersistenceWriteCount >= 2 }
            XCTAssertEqual(server.notifications, 0)
            XCTAssertEqual(next.posts, 0)
            XCTAssertNil(cache.entry(other), "B must not publish before its intent is durable")
            probe.release()
            try await mutation.value
            try await wait { cache.entry(current)?.phase == nil && server.notifications == 1 }
            try await cache.flushPersistence()
            let restored = SiteFavoriteCache(storageRoot: directory)
            restored.activate(owner: current.owner, generation: current.generation)
            XCTAssertNil(restored.entry(current)?.phase, "\(operation) must not resurrect A's pending intent")
            let expected = operation == "rename" ? renamed[2] : NativeFavoritesQA.groups[2]
            XCTAssertEqual(restored.entry(current)?.state, .favorited(expected), "\(operation) must preserve A's confirmed state")
            XCTAssertFalse(restored.includesCachedFavorite(current, category: 1, savedAt: .distantPast))
            if operation != "rename" {
                XCTAssertEqual(restored.entry(other)?.phase, .queued)
                XCTAssertEqual(restored.entry(other)?.pendingGroup, 3)
            }
            XCTAssertEqual(server.posts, 1)
            XCTAssertEqual(next.posts, 0)
            cache.activate(owner: "bb", generation: UUID()); next.releaseRead()
            try await cache.flushPersistence()
            XCTAssertEqual(probe.mainThreadWrites, 0)
        }
    }

    func testLifecycleGrantStaysOpenUntilWriteCompletesAndExpiryDoesNotReportSuccess() async throws {
        for expires in [false, true] {
            let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
            let probe = WriteProbe(holdFirst: true); defer { probe.release() }
            let grant = Grant(), current = scope()
            let cache = SiteFavoriteCache(storageRoot: directory, backgroundWork: grant,
                                          beforePersistence: { try probe.beforeWrite() })
            cache.put(.notFavorited, scope: current)
            cache.flushForLifecycle()
            try await wait { probe.writes == 1 }
            XCTAssertEqual(grant.beginCount, 1)
            XCTAssertTrue(grant.endings.isEmpty, "The window must outlive the awaited disk write")
            if expires { grant.expire(); XCTAssertEqual(grant.endings, [.waiting]) }
            probe.release()
            try await cache.flushPersistence()
            if expires {
                for _ in 0..<20 { await Task.yield() }
                XCTAssertEqual(grant.endings, [.waiting])
            } else {
                try await wait { !grant.endings.isEmpty }
                XCTAssertEqual(grant.endings, [.completed])
            }
            XCTAssertEqual(probe.mainThreadWrites, 0)
        }
    }
}
