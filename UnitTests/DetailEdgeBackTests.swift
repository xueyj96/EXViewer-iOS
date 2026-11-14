import XCTest
@testable import ExViewer

final class DetailEdgeBackTests: XCTestCase {
    func testEitherEdgeRequiresIntentAndReversingVelocityCanCancel() {
        for sign: CGFloat in [-1, 1] {
            XCTAssertTrue(DetailEdgeBackPolicy.commits(distance: 180 * sign, velocity: 0, width: 400, cancelled: false))
            XCTAssertFalse(DetailEdgeBackPolicy.commits(distance: 160 * sign, velocity: -600 * sign, width: 400, cancelled: false))
            XCTAssertFalse(DetailEdgeBackPolicy.commits(distance: 12 * sign, velocity: 2000 * sign, width: 400, cancelled: false))
            XCTAssertFalse(DetailEdgeBackPolicy.commits(distance: 300 * sign, velocity: 1000 * sign, width: 400, cancelled: true))
        }
    }
    func testReaderReservesBothInwardEdgesButNotPagingOrVerticalDrags() {
        XCTAssertTrue(ReaderEdgeBackPolicy.isInwardSwipe(startX: 1, width: 400, translation: .init(width: 80, height: 5)))
        XCTAssertTrue(ReaderEdgeBackPolicy.isInwardSwipe(startX: 399, width: 400, translation: .init(width: -80, height: 5)))
        XCTAssertFalse(ReaderEdgeBackPolicy.isInwardSwipe(startX: 200, width: 400, translation: .init(width: -80, height: 5)))
        XCTAssertFalse(ReaderEdgeBackPolicy.isInwardSwipe(startX: 1, width: 400, translation: .init(width: -80, height: 5)))
        XCTAssertFalse(ReaderEdgeBackPolicy.isInwardSwipe(startX: 399, width: 400, translation: .init(width: 80, height: 5)))
        XCTAssertFalse(ReaderEdgeBackPolicy.isInwardSwipe(startX: 399, width: 400, translation: .init(width: -20, height: 80)))
    }
    func testExpandedEdgeBandAccepts44PointsButKeepsInteriorAndVerticalMotionFree() {
        XCTAssertTrue(ReaderEdgeBackPolicy.isInwardSwipe(startX: 28, width: 400, translation: .init(width: 80, height: 5)))
        XCTAssertTrue(ReaderEdgeBackPolicy.isInwardSwipe(startX: 372, width: 400, translation: .init(width: -80, height: 5)))
        XCTAssertTrue(ReaderEdgeBackPolicy.isInwardSwipe(startX: 44, width: 400, translation: .init(width: 80, height: 5)))
        XCTAssertTrue(ReaderEdgeBackPolicy.isInwardSwipe(startX: 356, width: 400, translation: .init(width: -80, height: 5)))
        XCTAssertFalse(ReaderEdgeBackPolicy.isInwardSwipe(startX: 45, width: 400, translation: .init(width: 80, height: 5)))
        XCTAssertFalse(ReaderEdgeBackPolicy.isInwardSwipe(startX: 355, width: 400, translation: .init(width: -80, height: 5)))
        XCTAssertFalse(ReaderEdgeBackPolicy.isInwardSwipe(startX: 28, width: 400, translation: .init(width: 5, height: 80)))
    }

}
