import XCTest
@testable import ExViewer

final class TransferGateV15Tests: XCTestCase {
    private actor Results {
        var leases: [MediaRequestPriority] = []
        func append(_ value: MediaRequestPriority) { leases.append(value) }
        func count() -> Int { leases.count }
    }
    private func waitUntil(_ predicate: () async -> Bool) async -> Bool {
        for _ in 0..<200 {
            if await predicate() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await predicate()
    }
    func testVisibleCoverOvertakesQueuedCoverLookahead() async throws {
        let gate = TransferGate(limit: 3)
        let active = try await gate.acquire(request: MediaRequestDemand(priority: .thumbnail))
        let foreground = try await gate.acquire(request: MediaRequestDemand(priority: .foreground))
        let results = Results()
        func request(_ priority: MediaRequestPriority) -> Task<MediaRequestPriority, Error> {
            Task {
                let lease = try await gate.acquire(request: MediaRequestDemand(priority: priority))
                await results.append(lease)
                return lease
            }
        }

        let upcoming = request(.thumbnailPrefetch)
        defer { upcoming.cancel() }
        let upcomingQueued = await waitUntil { await gate.queuedCount == 1 }
        XCTAssertTrue(upcomingQueued)
        let visible = request(.thumbnail)
        defer { visible.cancel() }
        let bothQueued = await waitUntil { await gate.queuedCount == 2 }
        XCTAssertTrue(bothQueued)
        guard upcomingQueued, bothQueued else { return }

        await gate.release(priority: active)
        let acquired = await waitUntil { await results.count() == 1 }
        XCTAssertTrue(acquired)
        let first = await results.leases.first
        XCTAssertEqual(first, .thumbnail)
        guard first == .thumbnail else { return }

        await gate.release(priority: try await visible.value)
        let lookaheadStarted = await waitUntil { await results.count() == 2 }
        XCTAssertTrue(lookaheadStarted)
        if lookaheadStarted { await gate.release(priority: try await upcoming.value) }
        await gate.release(priority: foreground)
    }

    func testSixteenPermitsAreActuallyUsableAndSeventeenthWaits() async throws {
        let gate = TransferGate(limit: 16, prefetchLimit: 15, allowFullWithForeground: true), results = Results()
        let current = try await gate.acquire(request: MediaRequestDemand(priority: .foreground))
        let tasks = (0..<16).map { _ in Task {
            let lease = try await gate.acquire(request: MediaRequestDemand(priority: .prefetch))
            await results.append(lease)
        } }
        var releasedPrefetch = 0
        defer {
            tasks.forEach { $0.cancel() }
            let alreadyReleased = releasedPrefetch
            Task {
                for task in tasks { _ = try? await task.value }
                let acquired = await results.count()
                for _ in alreadyReleased..<acquired { await gate.release(priority: .prefetch) }
                await gate.release(priority: current)
            }
        }
        let full = await waitUntil {
            let count = await results.count(), queued = await gate.queuedCount
            return count == 15 && queued == 1
        }
        XCTAssertTrue(full, "One current plus fifteen preloads must hold sixteen real transfer permits")
        guard full else { return }
        let heldCount = await results.count()
        XCTAssertEqual(heldCount, 15)
        await gate.release(priority: .prefetch); releasedPrefetch += 1
        let next = await waitUntil { await results.count() == 16 }
        XCTAssertTrue(next, "The seventeenth transfer can start only after a permit is released")
    }
    func testVisibleCoverStartsDuringThirtyTwoOfflineTransfersAndVisibleReading() async throws {
        let gate = TransferGate.mediaTransfers()
        var held: [MediaRequestPriority] = []
        for _ in 0..<32 { held.append(try await gate.acquire(request: MediaRequestDemand(priority: .download))) }
        held.append(try await gate.acquire(request: MediaRequestDemand(priority: .foreground)))
        let results = Results()
        let cover = Task {
            let lease = try await gate.acquire(request: MediaRequestDemand(priority: .thumbnail))
            await results.append(lease)
            return lease
        }
        let heldLeases = held
        defer {
            cover.cancel()
            Task {
                if let lease = try? await cover.value { await gate.release(priority: lease) }
                for lease in heldLeases { await gate.release(priority: lease) }
            }
        }
        let started = await waitUntil { await results.count() == 1 }
        XCTAssertTrue(started, "Visible covers must not wait for offline transfers or the current reading image to finish")
    }

    func testCoverLookaheadRunsThreeTransfersAndLeavesRoomForVisibleCover() async throws {
        let gate = TransferGate.mediaTransfers(), results = Results()
        let upcoming = (0..<4).map { _ in Task {
            let lease = try await gate.acquire(request: MediaRequestDemand(priority: .thumbnailPrefetch))
            await results.append(lease)
            return lease
        } }
        let visibleResults = Results()
        var visible: Task<MediaRequestPriority, Error>?
        defer {
            upcoming.forEach { $0.cancel() }; visible?.cancel()
            let visibleTask = visible
            Task {
                for task in upcoming {
                    if let lease = try? await task.value { await gate.release(priority: lease) }
                }
                if let lease = try? await visibleTask?.value { await gate.release(priority: lease) }
            }
        }
        let filled = await waitUntil {
            let count = await results.count(), queued = await gate.queuedCount
            return count == 3 && queued == 1
        }
        XCTAssertTrue(filled, "Three lookahead covers should transfer together while reserving the fourth cover slot")
        visible = Task {
            let lease = try await gate.acquire(request: MediaRequestDemand(priority: .thumbnail))
            await visibleResults.append(lease)
            return lease
        }
        let visibleStarted = await waitUntil { await visibleResults.count() == 1 }
        XCTAssertTrue(visibleStarted, "Visible cover must start without waiting for speculative cover transfers")
    }

    func testCoverReservationSurvivesFullReaderPrefetchBudget() async throws {
        let gate = TransferGate.mediaTransfers()
        var held = [try await gate.acquire(request: MediaRequestDemand(priority: .foreground))]
        for _ in 0..<15 { held.append(try await gate.acquire(request: MediaRequestDemand(priority: .prefetch))) }
        let results = Results()
        let covers = (0..<4).map { index in Task {
            let lease = try await gate.acquire(request: MediaRequestDemand(priority: index == 3 ? .thumbnail : .thumbnailPrefetch))
            await results.append(lease)
            return lease
        } }
        let heldLeases = held
        defer {
            covers.forEach { $0.cancel() }
            Task {
                for cover in covers {
                    if let lease = try? await cover.value { await gate.release(priority: lease) }
                }
                for lease in heldLeases { await gate.release(priority: lease) }
            }
        }
        let started = await waitUntil { await results.count() == 4 }
        XCTAssertTrue(started, "Reader prefetch must not consume the dedicated visible/lookahead cover slots")
    }

}
