import XCTest
import ExViewerCore
@testable import ExViewer

final class FeedSnapshotCoversTests: XCTestCase {
    private actor Probe {
        var started = 0
        var active = 0
        var peak = 0
        var cancelled = 0
        func load(delay: Duration) async throws {
            started += 1; active += 1; peak = max(peak, active)
            defer { active -= 1 }
            do { try await Task.sleep(for: delay) }
            catch { cancelled += 1; throw error }
        }
    }
    private func galleries(_ count: Int) -> [Gallery] {
        (1...count).map {
            Gallery(ref: .init(site: .ex, gid: Int64($0), token: "qa"), title: "Sample",
                    cover: URL(string: "https://fixture.hath.network/cover-\($0).png"))
        }
    }
    func testOnlyLaunchWindowIsWarmedWithThreeConcurrentTransfers() async {
        let probe = Probe()
        let ready = await FeedSnapshotCovers.prepare(galleries(30)) { _ in
            try await probe.load(delay: .milliseconds(5))
        }
        let started = await probe.started, peak = await probe.peak, active = await probe.active
        XCTAssertTrue(ready)
        XCTAssertEqual(started, 12)
        XCTAssertEqual(peak, 3)
        XCTAssertEqual(active, 0)
    }
    func testDeadlineCancelsWarmupInsteadOfReplacingReadySnapshotWithMissingCovers() async {
        let probe = Probe()
        let ready = await FeedSnapshotCovers.prepare(galleries(12), timeout: .milliseconds(30)) { _ in
            try await probe.load(delay: .seconds(30))
        }
        let active = await probe.active, cancelled = await probe.cancelled
        XCTAssertFalse(ready)
        XCTAssertEqual(active, 0)
        XCTAssertEqual(cancelled, 3)
    }
    func testMissingCoverAndTransferFailureNeverClaimSnapshotReady() async {
        var values = galleries(3); values[0].cover = nil
        let missing = await FeedSnapshotCovers.prepare(values) { _ in XCTFail("Missing URL must fail before issuing transfers") }
        XCTAssertFalse(missing)
        let failed = await FeedSnapshotCovers.prepare(galleries(3)) { _ in throw URLError(.cannotConnectToHost) }
        XCTAssertFalse(failed)
    }
}
