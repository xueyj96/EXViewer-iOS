import XCTest
import ExViewerCore
@testable import ExViewer

@MainActor
final class FavoriteBatchSubmissionTests: XCTestCase {
    private func references(_ count: Int) -> [GalleryRef] {
        (1...count).map { .init(site: .eh, gid: Int64($0), token: "fixture") }
    }

    private func awaitIdle(_ submission: FavoriteBatchSubmission) async {
        for _ in 0..<200 {
            if submission.workingCount == nil { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Batch did not stop")
    }

    func testCompletionReportsAllBatchesThenSeparatelyFinishesRefresh() async {
        let submission = FavoriteBatchSubmission(), items = references(51)
        var calls: [[GalleryRef]] = []
        var accepted: [GalleryRef] = []
        var invalidations = 0
        var completions = 0
        submission.start(items, isCurrent: { true }, invalidateCache: {
            invalidations += 1
        }, submit: {
            XCTAssertEqual(invalidations, 1)
            calls.append($0)
        }, onSubmitted: { accepted += $0 }, onComplete: { completions += 1 })
        XCTAssertEqual(submission.workingCount, 51)
        await awaitIdle(submission)
        XCTAssertEqual(calls.map(\.count), [25, 25, 1])
        XCTAssertEqual(accepted, items)
        XCTAssertEqual(completions, 1)
        guard case .refreshingList(submitted: 51) = submission.state else { return XCTFail("Expected pending list refresh") }
        submission.finishListRefresh(succeeded: false)
        guard case .listRefreshFailed = submission.state else { return XCTFail("Expected separate refresh failure") }
    }

    func testLostResponseStopsAfterPartialSuccessWithoutResubmitting() async {
        let submission = FavoriteBatchSubmission(), items = references(51)
        var calls: [[GalleryRef]] = []
        var accepted: [GalleryRef] = []
        submission.start(items, isCurrent: { true }, invalidateCache: {}, submit: { batch in
            calls.append(batch)
            if calls.count == 2 {
                throw FavoriteMutationFailure(requestMayHaveBeenSent: true, underlying: URLError(.networkConnectionLost))
            }
        }, onSubmitted: { accepted += $0 }, onComplete: { XCTFail("Ambiguous request cannot complete the batch") })
        await awaitIdle(submission)
        XCTAssertEqual(calls.map(\.count), [25, 25])
        XCTAssertEqual(accepted, Array(items.prefix(25)))
        guard case .interrupted(submitted: 25, batchCount: 25, reason: .needsVerification) = submission.state else {
            return XCTFail("Expected an ambiguous second batch with the first batch acknowledged")
        }
    }

    func testPreflightRejectionIsReportedAsUnsent() async {
        let submission = FavoriteBatchSubmission()
        submission.start(references(2), isCurrent: { true }, invalidateCache: {}, submit: { _ in
            throw ViewerError.authentication
        }, onSubmitted: { _ in XCTFail("Rejected request cannot be acknowledged") },
           onComplete: { XCTFail("Rejected request cannot complete") })
        await awaitIdle(submission)
        guard case .interrupted(submitted: 0, batchCount: 2, reason: .notSent) = submission.state else {
            return XCTFail("Expected an unsent batch")
        }
    }

    func testAccountChangeWhileRequestIsInFlightDropsItsResult() async {
        let submission = FavoriteBatchSubmission()
        var isCurrent = true
        var calls = 0
        submission.start(references(26), isCurrent: { isCurrent }, invalidateCache: {}, submit: { _ in
            calls += 1
            isCurrent = false
        }, onSubmitted: { _ in XCTFail("Stale results must not update selection") },
           onComplete: { XCTFail("Stale results must not reload the list") })
        await awaitIdle(submission)
        XCTAssertEqual(calls, 1)
        guard case .idle = submission.state else { return XCTFail("Expected stale operation to be discarded") }
    }
}
