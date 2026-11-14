import XCTest
@testable import ExViewer

final class GalleryGridPlacementTests: XCTestCase {
    func testCoverPreviewBoundsExtremeAndInvalidRatiosButPreservesNormalCovers() {
        XCTAssertEqual(GalleryCoverLayout.displayAspect(0.02), 0.5)
        XCTAssertEqual(GalleryCoverLayout.displayAspect(50), 2)
        for ratio in [0.5, 0.71, 1, 1.5, 2] {
            XCTAssertEqual(GalleryCoverLayout.displayAspect(ratio), ratio)
        }
        for ratio in [Double.nan, .infinity, -.infinity, 0, -1] {
            XCTAssertEqual(GalleryCoverLayout.displayAspect(ratio), 0.71)
        }
    }

    func testExtremeStripCannotSendAnEntireBatchToTheOppositeColumn() {
        var layout = GalleryGridPlacement()
        let ids = (0..<40).map(String.init)
        let aspects = Dictionary(uniqueKeysWithValues: ids.map { ($0, $0 == "0" ? 0.0001 : 50.0) })
        layout.update(ids: ids, aspects: aspects)
        XCTAssertGreaterThan(layout.columns[0].count, 15)
        XCTAssertGreaterThan(layout.columns[1].count, 15)
        let heights = layout.columns.map { $0.reduce(0.0) { $0 + 1 / GalleryCoverLayout.displayAspect(aspects[$1]!) + 0.36 } }
        XCTAssertLessThan(abs(heights[0] - heights[1]), 2.36)
    }

    func testRemovingAnEntireColumnRepopulatesBothColumns() {
        var layout = GalleryGridPlacement()
        layout.update(ids: ["a", "b", "c", "d", "e", "f"], aspects: [:])
        layout.update(ids: ["a", "c", "e"], aspects: [:])
        XCTAssertEqual(layout.columns, [["a", "e"], ["c"]])
    }

    func testInitialEqualHeightsAlternateWithDeterministicTies() {
        var layout = GalleryGridPlacement()
        layout.update(ids: ["a", "b", "c", "d"], aspects: [:])
        XCTAssertEqual(layout.columns, [["a", "c"], ["b", "d"]])
    }

    func testLateAspectUpdatesDoNotRedistributeExistingCards() {
        var layout = GalleryGridPlacement()
        let ids = ["a", "b", "c", "d"]
        layout.update(ids: ids, aspects: [:])
        let original = layout.columns
        layout.update(ids: ids, aspects: ["a": 0.2, "b": 3, "c": 0.3, "d": 2])
        XCTAssertEqual(layout.columns, original)
    }

    func testAppendUsesCurrentHeightsButPreservesAllExistingMemberships() {
        var layout = GalleryGridPlacement()
        layout.update(ids: ["a", "b", "c", "d"], aspects: [:])
        layout.update(ids: ["a", "b", "c", "d", "e", "f"],
                      aspects: ["a": 0.3, "c": 0.3, "b": 2, "d": 2, "e": 1, "f": 1])
        XCTAssertEqual(layout.columns, [["a", "c"], ["b", "d", "e", "f"]])
    }

    func testRemovalDoesNotReplaceAnAlreadyBetterColumnBalance() {
        var layout = GalleryGridPlacement()
        layout.update(ids: ["a", "b", "c", "d"], aspects: [:])
        layout.update(ids: ["a", "c", "d"], aspects: ["a": 2, "c": 2, "d": 0.2])
        XCTAssertEqual(layout.columns, [["a", "c"], ["d"]])
    }

    func testDeletingSeveralCardsFromOneColumnRebalancesBothNonemptyColumns() {
        var layout = GalleryGridPlacement()
        layout.update(ids: ["a", "b", "c", "d", "e", "f", "g", "h"], aspects: [:])
        layout.update(ids: ["b", "d", "f", "g", "h"], aspects: [:])
        XCTAssertEqual(layout.columns.map(\.count).sorted(), [2, 3])
        XCTAssertEqual(Set(layout.columns.flatMap { $0 }), Set(["b", "d", "f", "g", "h"]))
    }

    func testRemovalCombinedWithReorderingCannotRestoreTheOldOrder() {
        var layout = GalleryGridPlacement()
        layout.update(ids: ["a", "b", "c", "d"], aspects: [:])
        layout.update(ids: ["c", "a", "d"], aspects: ["a": 2, "c": 2, "d": 0.2])
        XCTAssertEqual(layout.columns, [["c", "d"], ["a"]])
    }

    func testPrependAndExplicitReorderResetToTheNewResultOrder() {
        var layout = GalleryGridPlacement()
        layout.update(ids: ["a", "b", "c", "d"], aspects: [:])
        layout.update(ids: ["x", "a", "b", "c", "d"], aspects: [:])
        XCTAssertEqual(layout.columns, [["x", "b", "d"], ["a", "c"]])
        layout.update(ids: ["d", "c", "b", "a", "x"], aspects: [:])
        XCTAssertEqual(layout.columns, [["d", "b", "x"], ["c", "a"]])
    }

    func testDuplicateAndInvalidAspectInputsRemainFiniteAndEmptyResets() {
        var layout = GalleryGridPlacement()
        layout.update(ids: ["a", "a", "b"], aspects: ["a": .nan, "b": 0])
        XCTAssertEqual(layout.order, ["a", "b"])
        XCTAssertEqual(layout.columns, [["a"], ["b"]])
        layout.update(ids: [], aspects: [:])
        XCTAssertEqual(layout.columns, [[], []])
        layout.update(ids: ["new"], aspects: [:])
        XCTAssertEqual(layout.columns, [["new"], []])
    }

    func testThousandCardPagedFeedKeepsMembershipAfterEveryAppend() {
        var layout = GalleryGridPlacement()
        for count in stride(from: 40, through: 1_000, by: 40) {
            let previous = Dictionary(uniqueKeysWithValues: layout.columns.enumerated().flatMap { column, ids in ids.map { ($0, column) } })
            let ids = (0..<count).map(String.init)
            let aspects = Dictionary(uniqueKeysWithValues: ids.enumerated().map { index, id in (id, index.isMultiple(of: 3) ? 0.3 : 2.0) })
            layout.update(ids: ids, aspects: aspects)
            let current = Dictionary(uniqueKeysWithValues: layout.columns.enumerated().flatMap { column, ids in ids.map { ($0, column) } })
            XCTAssertEqual(current.count, count)
            for (id, column) in previous { XCTAssertEqual(current[id], column) }
        }
    }
}
