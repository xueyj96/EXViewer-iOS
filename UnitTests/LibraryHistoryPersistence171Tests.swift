import XCTest
import Combine
import ExViewerCore
@testable import ExViewer

/// Test-only fault/backpressure seam. Every mutable field is protected by lock;
/// the semaphore models slow disk on the writer actor, never on MainActor.
private final class HistoryDisk171: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var held = false
    private var started = false
    private var fail = false
    private var writes = 0
    private var mainThreadWrites = 0

    func holdFirst() { lock.lock(); held = true; lock.unlock() }
    func failNext() { lock.lock(); fail = true; lock.unlock() }
    func releaseFirst() { gate.signal() }
    var firstStarted: Bool { lock.lock(); defer { lock.unlock() }; return started }
    var counts: (writes: Int, mainThread: Int) {
        lock.lock(); defer { lock.unlock() }; return (writes, mainThreadWrites)
    }
    func write(_ data: Data, to file: URL) throws {
        lock.lock()
        writes += 1; if Thread.isMainThread { mainThreadWrites += 1 }
        let shouldHold = held && writes == 1, shouldFail = fail
        fail = false; started = true
        lock.unlock()
        if shouldHold, gate.wait(timeout: .now() + 5) == .timedOut { throw ViewerError.storage }
        if shouldFail { throw ViewerError.storage }
        try data.write(to: file, options: .atomic)
    }
}

@MainActor final class LibraryHistoryPersistence171Tests: XCTestCase {
    private func gallery(_ gid: Int64) -> Gallery {
        Gallery(ref: .init(site: .ex, gid: gid, token: "preview"), title: "Neutral fixture \(gid)", pages: 100)
    }
    private func seededRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let dir = root.appendingPathComponent("guest")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var seed = LibrarySnapshot()
        seed.bookmarks = [gallery(2)]
        seed.history = [.init(gallery: gallery(1), page: 1, date: .distantPast)]
        try JSONEncoder().encode(seed).write(to: dir.appendingPathComponent("library.json"), options: .atomic)
        return root
    }
    private func wait(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<1_000 { if condition() { return true }; try? await Task.sleep(nanoseconds: 1_000_000) }
        return condition()
    }
    func testReadingPagesCoalesceOffMainWithoutRewritingOrBroadcastingWholeLibrary() async throws {
        let root = try seededRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let disk = HistoryDisk171(), writer = LibraryHistoryWriter { try disk.write($0, to: $1) }
        let store = LibraryStore(qa: true, storageRoot: root, historyWriter: writer, historyCheckpointDelay: 60_000_000_000)
        let file = store.directory.appendingPathComponent("library.json"), seed = try Data(contentsOf: file)
        var updates = 0
        let subscription = store.objectWillChange.sink { updates += 1 }; defer { subscription.cancel() }
        for page in 2...25 { store.remember(gallery(1), page: page) }
        XCTAssertEqual(store.snapshot.history.first?.page, 25, "Read-after-stage is immediate")
        XCTAssertEqual(updates, 0, "Continuous page boundaries must not broadcast the whole library")
        XCTAssertEqual(disk.counts.writes, 0)
        XCTAssertEqual(try Data(contentsOf: file), seed)
        let saved = await store.flushReadingHistory(); XCTAssertTrue(saved)
        XCTAssertEqual(disk.counts.writes, 1)
        XCTAssertEqual(disk.counts.mainThread, 0)
        XCTAssertEqual(updates, 1)
        XCTAssertEqual(try Data(contentsOf: file), seed)
        let reopened = LibraryStore(qa: true, storageRoot: root)
        XCTAssertNil(reopened.error)
        XCTAssertEqual(reopened.snapshot.history.first?.page, 25)
        XCTAssertEqual(reopened.snapshot.bookmarks.map(\.id), [gallery(2).id])
    }
    func testLateWriteCannotReviveHistoryAfterDurableLibraryReset() async throws {
        let root = try seededRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let disk = HistoryDisk171(); disk.holdFirst(); defer { disk.releaseFirst() }
        let writer = LibraryHistoryWriter { try disk.write($0, to: $1) }
        let store = LibraryStore(qa: true, storageRoot: root, historyWriter: writer, historyCheckpointDelay: 60_000_000_000)
        store.remember(gallery(1), page: 20)
        let flush = Task { await store.flushReadingHistory() }
        let started = await wait { disk.firstStarted }; XCTAssertTrue(started)
        let file = store.directory.appendingPathComponent("library.json")
        var replacement = LibrarySnapshot(); replacement.bookmarks = [gallery(3)]
        try JSONEncoder().encode(replacement).write(to: file, options: .atomic)
        store.load(owner: "guest")
        XCTAssertTrue(store.snapshot.history.isEmpty)
        disk.releaseFirst()
        _ = await flush.value
        XCTAssertTrue(store.snapshot.history.isEmpty)
        let reopened = LibraryStore(qa: true, storageRoot: root)
        XCTAssertNil(reopened.error)
        XCTAssertTrue(reopened.snapshot.history.isEmpty, "Sidecar from the old basis cannot revive removed history")
        XCTAssertEqual(reopened.snapshot.bookmarks.map(\.id), [gallery(3).id])
    }
    func testOldAccountWriteCannotPublishIntoNewOwnerAndBothFinalPagesPersist() async throws {
        let root = try seededRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let disk = HistoryDisk171(); disk.holdFirst(); defer { disk.releaseFirst() }
        let writer = LibraryHistoryWriter { try disk.write($0, to: $1) }
        let store = LibraryStore(qa: true, storageRoot: root, historyWriter: writer, historyCheckpointDelay: 60_000_000_000)
        store.remember(gallery(1), page: 7)
        let old = Task { await store.flushReadingHistory() }
        let started = await wait { disk.firstStarted }; XCTAssertTrue(started)
        store.load(owner: "bb")
        store.remember(gallery(4), page: 9)
        disk.releaseFirst()
        _ = await old.value
        let saved = await store.flushReadingHistory(); XCTAssertTrue(saved)
        XCTAssertEqual(store.owner, "bb")
        XCTAssertEqual(store.snapshot.history.map(\.id), [gallery(4).id])
        XCTAssertEqual(store.snapshot.history.first?.page, 9)
        let reopened = LibraryStore(qa: true, storageRoot: root)
        XCTAssertEqual(reopened.snapshot.history.first?.page, 7)
        reopened.load(owner: "bb")
        XCTAssertEqual(reopened.snapshot.history.first?.page, 9)
    }
    func testFailurePreservesLastAtomicCheckpointAndRetainsLatestPageForRetry() async throws {
        let root = try seededRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let disk = HistoryDisk171(), writer = LibraryHistoryWriter { try disk.write($0, to: $1) }
        let store = LibraryStore(qa: true, storageRoot: root, historyWriter: writer, historyCheckpointDelay: 60_000_000_000)
        store.remember(gallery(1), page: 4)
        let initial = await store.flushReadingHistory(); XCTAssertTrue(initial)
        let file = store.directory.appendingPathComponent("history-progress.json"), previous = try Data(contentsOf: file)
        disk.failNext(); store.remember(gallery(1), page: 8)
        let failed = await store.flushReadingHistory(); XCTAssertFalse(failed)
        XCTAssertEqual(store.error, "阅读进度保存失败 请重试")
        XCTAssertEqual(try Data(contentsOf: file), previous)
        store.remember(gallery(1), page: 11)
        let retried = await store.flushReadingHistory(); XCTAssertTrue(retried)
        XCTAssertNil(store.error)
        let reopened = LibraryStore(qa: true, storageRoot: root)
        XCTAssertEqual(reopened.snapshot.history.first?.page, 11)
    }
    func testCriticalCommitInvalidatesOldSidecarAndKeepsDurableSuccessAPI() async throws {
        let root = try seededRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(qa: true, storageRoot: root, historyCheckpointDelay: 60_000_000_000)
        store.remember(gallery(1), page: 5)
        let saved = await store.flushReadingHistory(); XCTAssertTrue(saved)
        let journal = store.directory.appendingPathComponent("history-progress.json"), old = try Data(contentsOf: journal)
        let tag = GalleryTag(namespace: "other", name: "neutral")
        XCTAssertTrue(store.pin([tag]))
        let reopened = LibraryStore(qa: true, storageRoot: root)
        XCTAssertEqual(reopened.snapshot.favoriteTags, [tag])
        XCTAssertEqual(reopened.snapshot.history.first?.page, 5)
        XCTAssertEqual(try Data(contentsOf: journal), old, "No synchronous journal cleanup is required")
        let basis = LibraryHistoryJournal.basis(for: try Data(contentsOf: store.directory.appendingPathComponent("library.json")))
        XCTAssertNil(try LibraryHistoryJournal.restore(from: journal, libraryBasis: basis))
    }
    func testCorruptSidecarIsPreservedAndCannotBeSilentlyOverwritten() async throws {
        let root = try seededRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("guest/history-progress.json"), original = Data("not valid json".utf8)
        try original.write(to: file)
        let store = LibraryStore(qa: true, storageRoot: root)
        XCTAssertEqual(store.error, "资料库暂不可读 原文件保留")
        store.remember(gallery(1), page: 20)
        _ = await store.flushReadingHistory()
        XCTAssertEqual(try Data(contentsOf: file), original)
    }
    func testSidecarCorruptedAfterLoadIsNotOverwrittenByAnAlreadyStagedPage() async throws {
        let root = try seededRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(qa: true, storageRoot: root, historyCheckpointDelay: 60_000_000_000)
        store.remember(gallery(1), page: 20)
        let file = store.directory.appendingPathComponent("history-progress.json")
        let original = Data("unreadable replacement".utf8)
        try original.write(to: file, options: .atomic)
        let saved = await store.flushReadingHistory()
        XCTAssertFalse(saved)
        XCTAssertEqual(store.error, "阅读进度保存失败 请重试")
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testEquivalentResetRotatesBasisAndCannotReviveAnOldSidecar() throws {
        let root = try seededRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("guest/library.json")
        var empty = LibrarySnapshot(); empty.bookmarks = [gallery(2)]
        let legacy = try JSONEncoder().encode(empty)
        try legacy.write(to: file, options: .atomic)
        let store = LibraryStore(qa: true, storageRoot: root)
        XCTAssertNil(store.snapshot.historyCheckpointBasis, "Legacy v1 without the additive key remains readable")
        XCTAssertEqual(try Data(contentsOf: file), legacy, "Load must not rewrite a legacy library")
        XCTAssertTrue(store.removeReadLater([]))
        let firstBasis = store.snapshot.historyCheckpointBasis
        XCTAssertNotNil(firstBasis)
        let prior = try Data(contentsOf: file)
        let delayed = LibraryHistoryJournal(libraryBasis: LibraryHistoryJournal.basis(for: prior),
                                           history: [.init(gallery: gallery(1), page: 22, date: .now)])
        let journal = store.directory.appendingPathComponent("history-progress.json")
        try JSONEncoder().encode(delayed).write(to: journal, options: .atomic)
        // A reset/removal can leave exactly the same logical base contents.
        // Its new nonce still invalidates the previous generation's sidecar.
        XCTAssertTrue(store.removeReadLater([]))
        XCTAssertNotEqual(store.snapshot.historyCheckpointBasis, firstBasis)
        XCTAssertTrue(store.snapshot.history.isEmpty)
        let reopened = LibraryStore(qa: true, storageRoot: root)
        XCTAssertNil(reopened.error)
        XCTAssertTrue(reopened.snapshot.history.isEmpty)
        XCTAssertEqual(reopened.snapshot.bookmarks.map(\.id), [gallery(2).id])
    }

    func testWriterRejectsAnOlderDelayedRevision() async throws {
        let root = try seededRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("guest/history-progress.json"), scope = UUID()
        let writer = LibraryHistoryWriter()
        let basis = LibraryHistoryJournal.basis(for: try Data(contentsOf: root.appendingPathComponent("guest/library.json")))
        let newer = LibraryHistoryWrite(owner: "guest", scope: scope, revision: 2, libraryBasis: basis, file: file,
                                        history: [.init(gallery: gallery(1), page: 9, date: .now)])
        let older = LibraryHistoryWrite(owner: "guest", scope: scope, revision: 1, libraryBasis: basis, file: file,
                                        history: [.init(gallery: gallery(1), page: 2, date: .distantPast)])
        try await writer.write(newer); try await writer.write(older)
        XCTAssertEqual(try LibraryHistoryJournal.restore(from: file, libraryBasis: basis)?.first?.page, 9)
    }
}
