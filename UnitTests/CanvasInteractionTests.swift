import XCTest
@testable import ExViewer

@MainActor
final class CanvasInteractionTests: XCTestCase {
    private func coordinator(_ actions: CanvasInteractions) -> MediaCanvas.Coordinator {
        .init(onZoomChanged: nil, onImageSizeChanged: nil, interactions: actions, onPresentation: nil)
    }

    func testSingleTapDispatchesOnNextMainTurnWithoutADoubleTapTimer() async {
        var points: [CGPoint] = []
        let coordinator = coordinator(.init(singleTap: { points.append($0) }, allowsDoubleTapZoom: false))
        XCTAssertFalse(coordinator.canvasInteractions.allowsDoubleTapZoom)
        coordinator.canvasInteractions.singleTap?(CGPoint(x: 50, y: 50))
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        XCTAssertEqual(points, [CGPoint(x: 50, y: 50)])
        coordinator.interactions = .init()
        XCTAssertTrue(coordinator.canvasInteractions.allowsDoubleTapZoom)
        XCTAssertNil(coordinator.canvasInteractions.singleTap)
    }

    func testQueuedTapAndLongPressAreDiscardedAfterCanvasInvalidation() async {
        var calls = 0
        let coordinator = coordinator(.init(singleTap: { _ in calls += 1 }, longPress: { calls += 1 }))
        coordinator.reportTap(.zero)
        coordinator.reportLongPress()
        coordinator.invalidatePendingReports()
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        XCTAssertEqual(calls, 0)
    }

    func testValidLongPressReportsOnlyLongPressAndEmptyHandlersStayInactive() async {
        var taps = 0, holds = 0
        let coordinator = coordinator(.init(singleTap: { _ in taps += 1 }, longPress: { holds += 1 }))
        coordinator.canvasInteractions.longPress?()
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        XCTAssertEqual(holds, 1)
        XCTAssertEqual(taps, 0)
        let empty = self.coordinator(.init()).canvasInteractions
        XCTAssertNil(empty.singleTap)
        XCTAssertNil(empty.longPress)
        XCTAssertTrue(empty.allowsDoubleTapZoom)
    }
}
