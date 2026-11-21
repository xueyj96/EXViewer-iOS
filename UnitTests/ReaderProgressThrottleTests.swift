import XCTest
import Combine
import ExViewerCore
@testable import ExViewer

@MainActor final class ReaderProgressThrottleTests: XCTestCase {
    private final class Recorder: @unchecked Sendable {
        // The callback runs on arbitrary producer/timer threads; lock owns all values.
        private let lock = NSLock()
        private var stored: [(ReaderProgressThrottle.Delivery, TimeInterval)] = []
        func append(_ value: ReaderProgressThrottle.Delivery) {
            lock.lock(); stored.append((value, ProcessInfo.processInfo.systemUptime)); lock.unlock()
        }
        var values: [(ReaderProgressThrottle.Delivery, TimeInterval)] {
            lock.lock(); defer { lock.unlock() }; return stored
        }
    }
    @MainActor private final class Transfer {
        var demands: [MediaRequestDemand] = []
        var indices: [Int] = []
        var pending: [CheckedContinuation<URL, Error>] = []
        func load(_ page: GalleryPage, _ demand: MediaRequestDemand) async throws -> URL {
            demands.append(demand); indices.append(page.index)
            return try await withCheckedThrowingContinuation { pending.append($0) }
        }
        func finish(_ error: Error = CancellationError()) {
            let values = pending; pending.removeAll()
            for continuation in values { continuation.resume(throwing: error) }
        }
    }
    private func snapshot(_ source: UUID, _ sequence: UInt64, _ phase: MediaLoadPhase,
                          _ bytes: Int64 = 0) -> MediaRequestDemand.ProgressSnapshot {
        .init(producerUUID: source, sequence: sequence,
              value: .init(phase: phase, completedBytes: bytes, totalBytes: 1_000))
    }
    private func wait(_ condition: () -> Bool) async {
        for _ in 0..<100 { if condition() { return }; try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(condition())
    }
    private var page: GalleryPage { .init(index: 1, url: URL(string: "https://exhentai.org/s/sample/1-1")!) }
    private func scope() -> ReaderMediaScope {
        .init(galleryID: "ex:1", owner: "aa", generation: UUID(), context: UUID())
    }

    func testPhaseTransitionsAndReadyDeliverImmediatelyAndDiscardByteTail() async {
        let recorder = Recorder(), source = UUID()
        let throttle = ReaderProgressThrottle(interval: 10, deliver: recorder.append)
        throttle.receive(snapshot(source, 1, .resolvingPage))
        throttle.receive(snapshot(source, 2, .queued))
        throttle.receive(snapshot(source, 3, .connecting))
        throttle.receive(snapshot(source, 4, .transferring, 10))
        throttle.receive(snapshot(source, 5, .transferring, 20))
        XCTAssertEqual(recorder.values.map { $0.0.snapshot.value.phase }, [.resolvingPage, .queued, .connecting, .transferring])
        throttle.receive(snapshot(source, 6, .ready, 1_000))
        XCTAssertEqual(recorder.values.last?.0.snapshot.value.phase, .ready)
        XCTAssertEqual(recorder.values.last?.0.snapshot.value.completedBytes, 1_000)
        throttle.receive(snapshot(source, 7, .transferring, 50))
        XCTAssertEqual(recorder.values.count, 5, "A terminal ready state cannot be replayed backwards")
        throttle.cancel()
    }

    func testBurstCoalescesBeforeActorHopAndRetainsLatestTail() async {
        let recorder = Recorder(), source = UUID()
        let throttle = ReaderProgressThrottle(deliver: recorder.append)
        for sequence in 1...256 { throttle.receive(snapshot(source, UInt64(sequence), .transferring, Int64(sequence))) }
        XCTAssertEqual(recorder.values.count, 1, "The burst must not enqueue an actor hop for every byte report")
        await wait { recorder.values.count == 2 }
        let values = recorder.values
        XCTAssertEqual(values.last?.0.snapshot.value.completedBytes, 256)
        XCTAssertGreaterThanOrEqual(values[1].1 - values[0].1, 0.09)
        XCTAssertGreaterThan(values[1].0.sequence, values[0].0.sequence)
        throttle.cancel()
    }

    func testCancelDiscardsScheduledTailAndSubsequentReports() async {
        let recorder = Recorder(), source = UUID()
        let throttle = ReaderProgressThrottle(deliver: recorder.append)
        throttle.receive(snapshot(source, 1, .transferring, 10))
        throttle.receive(snapshot(source, 2, .transferring, 20))
        throttle.cancel()
        throttle.receive(snapshot(source, 3, .ready, 1_000))
        try? await Task.sleep(nanoseconds: 180_000_000)
        XCTAssertEqual(recorder.values.count, 1)
        XCTAssertEqual(recorder.values.first?.0.snapshot.value.completedBytes, 10)
    }

    func testReorderedAndDuplicateProducerSequencesCannotRewindProgressOrPhase() async {
        let recorder = Recorder(), source = UUID()
        let throttle = ReaderProgressThrottle(deliver: recorder.append)
        throttle.receive(snapshot(source, 10, .transferring, 100))
        throttle.receive(snapshot(source, 9, .queued))
        throttle.receive(snapshot(source, 11, .transferring, 200))
        throttle.receive(snapshot(source, 10, .transferring, 10))
        throttle.receive(snapshot(source, 11, .connecting))
        await wait { recorder.values.count == 2 }
        XCTAssertEqual(recorder.values.map { $0.0.snapshot.value.completedBytes }, [100, 200])
        XCTAssertEqual(recorder.values.map { $0.0.snapshot.value.phase }, [.transferring, .transferring])
        throttle.cancel()
    }

    func testStoreResetDropsQueuedTailAndOldScopeRequest() async throws {
        let store = ReaderMediaStore(), transfer = Transfer()
        func update(_ scope: ReaderMediaScope) {
            store.update(scope: scope, pages: [page], current: 1, prefetchCount: 0, demandLoader: { page, demand in
                try await transfer.load(page, demand)
            }, isCurrent: { true })
        }
        update(scope())
        await wait { transfer.demands.count == 1 }
        let old = try XCTUnwrap(transfer.demands.first)
        old.reportProgress(.init(phase: .transferring, completedBytes: 10, totalBytes: 100))
        await wait { store.progress[1]?.completedBytes == 10 }
        old.reportProgress(.init(phase: .transferring, completedBytes: 20, totalBytes: 100))
        store.reset()
        update(scope())
        await wait { transfer.demands.count == 2 }
        let current = try XCTUnwrap(transfer.demands.last)
        current.reportProgress(.init(phase: .connecting))
        old.reportProgress(.init(phase: .ready, completedBytes: 100, totalBytes: 100))
        await wait { store.progress[1]?.phase == .connecting }
        try? await Task.sleep(nanoseconds: 180_000_000)
        XCTAssertEqual(store.progress[1]?.phase, .connecting)
        XCTAssertTrue(store.files.isEmpty)
        transfer.finish(); store.reset()
    }

    func testPromotionDoesNotReplayAnOlderQueuedByteSnapshot() async throws {
        let store = ReaderMediaStore(), transfer = Transfer(), readerScope = self.scope()
        let pages = [page, GalleryPage(index: 2, url: URL(string: "https://exhentai.org/s/sample/1-2")!)]
        func update(_ current: Int) {
            store.update(scope: readerScope, pages: pages, current: current, prefetchCount: 1,
                         demandLoader: { page, demand in try await transfer.load(page, demand) }, isCurrent: { true })
        }
        update(1)
        await wait { transfer.demands.count == 2 }
        let position = try XCTUnwrap(transfer.indices.firstIndex(of: 2))
        let next = transfer.demands[position]
        next.reportProgress(.init(phase: .transferring, completedBytes: 10, totalBytes: 100))
        next.reportProgress(.init(phase: .transferring, completedBytes: 20, totalBytes: 100))
        // These callbacks have enqueued actor deliveries, but this update runs
        // first on MainActor and directly exposes the latest demand value.
        update(2)
        XCTAssertEqual(store.progress[2]?.completedBytes, 20)
        var values: [Int64] = []
        let subscription = store.$progress.sink { if let value = $0[2] { values.append(value.completedBytes) } }
        try? await Task.sleep(nanoseconds: 180_000_000)
        XCTAssertTrue(values.allSatisfy { $0 >= 20 }, "A queued old delivery must not rewind promotion: \(values)")
        subscription.cancel(); transfer.finish(); store.reset()
    }

    func testStoreFailureIsNotDelayedByPendingByteTail() async throws {
        let store = ReaderMediaStore(), transfer = Transfer()
        store.update(scope: scope(), pages: [page], current: 1, prefetchCount: 0, demandLoader: { page, demand in
            try await transfer.load(page, demand)
        }, isCurrent: { true })
        await wait { transfer.demands.count == 1 }
        let demand = try XCTUnwrap(transfer.demands.first)
        demand.reportProgress(.init(phase: .transferring, completedBytes: 10, totalBytes: 100))
        await wait { store.progress[1]?.completedBytes == 10 }
        demand.reportProgress(.init(phase: .transferring, completedBytes: 20, totalBytes: 100))
        transfer.finish(ViewerError.network)
        await wait { store.failures[1] != nil }
        XCTAssertNil(store.progress[1])
        try? await Task.sleep(nanoseconds: 180_000_000)
        XCTAssertNil(store.progress[1], "A stale tail must not overwrite the failure presentation")
        store.reset()
    }
}
