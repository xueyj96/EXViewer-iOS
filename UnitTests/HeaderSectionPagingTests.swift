import XCTest
import SwiftUI
import UIKit
import Observation
@testable import ExViewer

@MainActor final class HeaderSectionPagingTests: XCTestCase {
    func testSectionChangeNotifiesBeforeTapAndGesturePreparationWithoutRepeatingCurrentTap() async throws {
        let pager = HeaderSectionPager()
        var selecting = true, prepared: [Int] = [], events: [Int] = []
        let subscription = pager.willChangeSection.sink { target in
            XCTAssertTrue(pager.target == nil)
            selecting = false; events.append(target)
        }
        pager.configure(selection: 0, count: 4, enabled: true, prepare: { target in
            XCTAssertFalse(selecting); prepared.append(target)
        }, commit: { _ in })
        pager.resize(400)
        pager.select(0, reducedMotion: true)
        XCTAssertTrue(selecting); XCTAssertTrue(events.isEmpty)
        pager.select(1, reducedMotion: true)
        try await waitForSettlement(pager)
        XCTAssertEqual(events, [1]); XCTAssertEqual(prepared, [1])
        selecting = true
        XCTAssertTrue(pager.begin(fromLeading: false))
        XCTAssertFalse(selecting)
        XCTAssertEqual(events, [1, 2]); XCTAssertEqual(prepared, [1, 2])
        pager.cancel()
        withExtendedLifetime(subscription) {}
    }

    func testCenterRightSwipeExitsSelectionButVerticalLeftAndEdgeSwipesDoNot() {
        XCTAssertTrue(MultiSelectionSwipePolicy.exits(startX: 180, width: 400, translation: .init(width: 90, height: 8)))
        for (start, delta) in [(CGFloat(1), CGSize(width: 100, height: 0)),
                               (399, CGSize(width: 100, height: 0)),
                               (180, CGSize(width: -100, height: 0)),
                               (180, CGSize(width: 25, height: 0)),
                               (180, CGSize(width: 70, height: 90))] {
            XCTAssertFalse(MultiSelectionSwipePolicy.exits(startX: start, width: 400, translation: delta))
        }
    }

    func testCurrentSelectionTapIsAnEventWithoutNavigationOrReplay() async throws {
        var commits: [Int] = [], events: [Int] = []
        let pager = makePager { commits.append($0) }
        let subscription = pager.currentSelectionTaps.sink { events.append($0) }
        pager.select(1, reducedMotion: true)
        XCTAssertEqual(events, [1])
        XCTAssertTrue(commits.isEmpty)
        XCTAssertNil(pager.target)
        XCTAssertNil(pager.mountRequest)
        var replay: [Int] = []
        let later = pager.currentSelectionTaps.sink { replay.append($0) }
        XCTAssertTrue(replay.isEmpty)
        let owner = UUID()
        pager.beginLayoutSettlement(owner)
        pager.select(1, reducedMotion: true)
        XCTAssertEqual(events, [1])
        pager.finishLayoutSettlement(owner)
        pager.select(2, reducedMotion: true)
        try await waitForSettlement(pager)
        XCTAssertEqual(events, [1])
        XCTAssertEqual(commits, [2])
        withExtendedLifetime((subscription, later)) {}
    }
    func testRepeatedAndObsoleteLayoutCompletionsDoNotPublishAgain() async {
        let pager = makePager { _ in }
        let owner = UUID()
        pager.beginLayoutSettlement(owner)
        pager.finishLayoutSettlement(owner)
        let change = expectation(description: "An already released owner does not invalidate chrome")
        change.isInverted = true
        withObservationTracking { _ = pager.canBeginGesture } onChange: { change.fulfill() }
        pager.finishLayoutSettlement(owner)
        pager.finishLayoutSettlement(UUID())
        await fulfillment(of: [change], timeout: 0.02)
    }
    func testVerticalSettlementBlocksAnotherPageUntilItsOwnCompletion() {
        let pager = makePager { _ in }
        let first = UUID(), second = UUID()
        pager.beginLayoutSettlement(first)
        XCTAssertFalse(pager.canBeginGesture)
        XCTAssertFalse(pager.begin(fromLeading: false))
        pager.select(2, reducedMotion: true)
        XCTAssertNil(pager.target)
        pager.beginLayoutSettlement(second)
        pager.finishLayoutSettlement(first)
        XCTAssertFalse(pager.canBeginGesture, "An older completion cannot unlock a newer resize")
        pager.finishLayoutSettlement(second)
        XCTAssertTrue(pager.canBeginGesture)
        XCTAssertTrue(pager.begin(fromLeading: false))
        pager.cancel()
    }
    func test138EdgeTouchOwnersKeepActionsBlockedThroughSettlementAndTail() async throws {
        let gate = EdgeTouchGate(), finger = UUID(), settling = UUID()
        gate.begin(finger); gate.begin(settling); gate.end(finger)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(gate.blocksGalleryActions)
        gate.end(settling)
        XCTAssertTrue(gate.blocksGalleryActions)
        let next = UUID(); gate.begin(next)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(gate.blocksGalleryActions, "An old tail cannot release a new gesture")
        gate.end(next)
        try await Task.sleep(for: .milliseconds(220))
        XCTAssertFalse(gate.blocksGalleryActions)
    }
    private func makePager(selection: Int = 1, count: Int = 4,
                           commit: @escaping (Int) -> Void = { _ in }) -> HeaderSectionPager {
        let pager = HeaderSectionPager()
        pager.configure(selection: selection, count: count, enabled: true, commit: commit)
        pager.resize(400)
        return pager
    }

    private func waitForSettlement(_ pager: HeaderSectionPager,
                                   file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(1)
        while pager.moving && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(pager.moving, file: file, line: line)
        XCTAssertFalse(pager.settling, file: file, line: line)
    }

    func testAnimatedTapWaitsForMountedPaneAndCancelledMountCannotCommit() async throws {
        var commits: [Int] = []
        let pager = makePager { commits.append($0) }
        pager.select(2, reducedMotion: false)
        let request = try XCTUnwrap(pager.mountRequest)
        XCTAssertEqual(pager.target, 2)
        XCTAssertEqual(pager.offset, 0)
        XCTAssertFalse(pager.settling)
        XCTAssertTrue(commits.isEmpty)
        pager.cancel()
        pager.paneMounted(2, request: request)
        await Task.yield()
        XCTAssertTrue(commits.isEmpty)
        XCTAssertNil(pager.target)
        pager.select(3, reducedMotion: false)
        let next = try XCTUnwrap(pager.mountRequest)
        pager.paneMounted(3, request: next)
        try await waitForSettlement(pager)
        XCTAssertEqual(commits, [3])
    }

    func testEdgesCycleBetweenFirstAndLastSectionsButDoNotPageSingleSection() {
        XCTAssertEqual(HeaderSectionSwipePolicy.target(selection: 0, count: 4, fromLeading: true), 3)
        XCTAssertEqual(HeaderSectionSwipePolicy.target(selection: 0, count: 4, fromLeading: false), 1)
        XCTAssertEqual(HeaderSectionSwipePolicy.target(selection: 3, count: 4, fromLeading: true), 2)
        XCTAssertEqual(HeaderSectionSwipePolicy.target(selection: 3, count: 4, fromLeading: false), 0)
        XCTAssertEqual(HeaderSectionSwipePolicy.target(selection: 0, count: 2, fromLeading: true), 1)
        XCTAssertEqual(HeaderSectionSwipePolicy.target(selection: 0, count: 2, fromLeading: false), 1)
        XCTAssertNil(HeaderSectionSwipePolicy.target(selection: 0, count: 1, fromLeading: false))
        XCTAssertNil(HeaderSectionSwipePolicy.target(selection: 0, count: 0, fromLeading: true))
        XCTAssertNil(HeaderSectionSwipePolicy.target(selection: -1, count: 4, fromLeading: true))
    }

    func testTrailingEdgeWrapKeepsForwardContentAndIndicatorDirection() async throws {
        var commits: [Int] = []
        let pager = makePager(selection: 3) { commits.append($0) }
        XCTAssertTrue(pager.begin(fromLeading: false))
        XCTAssertEqual(pager.target, 0)
        XCTAssertEqual(pager.transitionStep, 1)
        XCTAssertEqual(pager.previewOffset, 400)
        pager.update(-100)
        XCTAssertEqual(pager.offset, -100)
        XCTAssertEqual(pager.position, 3.25, accuracy: 0.001)
        pager.update(-160)
        pager.end(velocity: 0, cancelled: false, reducedMotion: true)
        try await waitForSettlement(pager)
        XCTAssertEqual(commits, [0])
        XCTAssertEqual(pager.selection, 0)
        XCTAssertEqual(pager.transitionStep, 0)
        XCTAssertEqual(pager.position, 0)
    }

    func testLeadingEdgeWrapKeepsBackwardDirectionAndTakesPriorityAtFirstSection() async throws {
        var commits: [Int] = []
        let pager = makePager(selection: 0) { commits.append($0) }
        XCTAssertTrue(pager.canPageBack)
        XCTAssertTrue(pager.begin(fromLeading: true))
        XCTAssertEqual(pager.target, 3)
        XCTAssertEqual(pager.transitionStep, -1)
        XCTAssertEqual(pager.previewOffset, -400)
        pager.update(100)
        XCTAssertEqual(pager.offset, 100)
        XCTAssertEqual(pager.position, -0.25, accuracy: 0.001)
        pager.update(160)
        pager.end(velocity: 0, cancelled: false, reducedMotion: true)
        try await waitForSettlement(pager)
        XCTAssertEqual(commits, [3])
        XCTAssertEqual(pager.selection, 3)
    }

    func testWrapCanReverseAndCancelWithoutCommitting() async throws {
        var commits: [Int] = []
        let pager = makePager(selection: 3) { commits.append($0) }
        XCTAssertTrue(pager.begin(fromLeading: false))
        pager.update(-240)
        XCTAssertEqual(pager.position, 3.6, accuracy: 0.001)
        pager.update(-20)
        pager.end(velocity: 0, cancelled: false, reducedMotion: true)
        try await waitForSettlement(pager)
        XCTAssertEqual(pager.selection, 3)
        XCTAssertEqual(pager.position, 3)
        XCTAssertTrue(commits.isEmpty)
        XCTAssertTrue(pager.begin(fromLeading: false))
        pager.update(-300)
        pager.end(velocity: 2_000, cancelled: true, reducedMotion: true)
        try await waitForSettlement(pager)
        XCTAssertEqual(pager.selection, 3)
        XCTAssertTrue(commits.isEmpty)
        let single = makePager(selection: 0, count: 1)
        XCTAssertFalse(single.canPageBack)
        XCTAssertFalse(single.canBeginGesture)
        XCTAssertFalse(single.begin(fromLeading: true))
    }

    func testAcceptanceUsesDistanceAndProjectedVelocityButRequiresMinimumTravel() {
        XCTAssertFalse(HeaderSectionSwipePolicy.commits(distance: 11, velocity: 4_000, width: 400))
        XCTAssertFalse(HeaderSectionSwipePolicy.commits(distance: 100, velocity: 0, width: 400))
        XCTAssertTrue(HeaderSectionSwipePolicy.commits(distance: 132, velocity: 0, width: 400))
        XCTAssertTrue(HeaderSectionSwipePolicy.commits(distance: 60, velocity: 700, width: 400))
        XCTAssertFalse(HeaderSectionSwipePolicy.commits(distance: 180, velocity: -500, width: 400))
        XCTAssertFalse(HeaderSectionSwipePolicy.commits(distance: 180, velocity: 500, width: 0))
    }

    func testDragFollowsFingerClampsAndCanReverseBeforeRelease() {
        let pager = makePager()
        XCTAssertTrue(pager.begin(fromLeading: false))
        pager.update(-100)
        XCTAssertEqual(pager.offset, -100)
        XCTAssertEqual(pager.position, 1.25, accuracy: 0.001)
        pager.update(-30)
        XCTAssertEqual(pager.offset, -30)
        pager.update(20)
        XCTAssertEqual(pager.offset, 0)
        pager.update(-900)
        XCTAssertEqual(pager.offset, -400)
        pager.cancel()
        XCTAssertEqual(pager.selection, 1)
        XCTAssertEqual(pager.offset, 0)
        XCTAssertNil(pager.target)
    }

    func testAcceptedSwipeCommitsExactlyOnceAfterSettlement() async throws {
        var commits: [Int] = []
        let pager = makePager { commits.append($0) }
        XCTAssertTrue(pager.begin(fromLeading: false))
        pager.update(-160)
        XCTAssertTrue(commits.isEmpty)
        pager.end(velocity: 0, cancelled: false, reducedMotion: true)
        pager.end(velocity: 0, cancelled: false, reducedMotion: true)
        XCTAssertFalse(pager.begin(fromLeading: true))
        try await waitForSettlement(pager)
        XCTAssertEqual(commits, [2])
        XCTAssertEqual(pager.selection, 2)
        XCTAssertEqual(pager.offset, 0)
    }

    func testShortAndCancelledSwipesNeverChangeSelection() async throws {
        var commits: [Int] = []
        let pager = makePager { commits.append($0) }
        XCTAssertTrue(pager.begin(fromLeading: true))
        pager.update(40)
        pager.end(velocity: 0, cancelled: false, reducedMotion: true)
        try await waitForSettlement(pager)
        XCTAssertEqual(pager.selection, 1)
        XCTAssertTrue(pager.begin(fromLeading: true))
        pager.update(300)
        pager.end(velocity: 2_000, cancelled: true, reducedMotion: true)
        try await waitForSettlement(pager)
        XCTAssertEqual(pager.selection, 1)
        XCTAssertTrue(commits.isEmpty)
    }

    func testRotationCancelsPendingCommitAndAllowsNewDragAtNewWidth() async throws {
        var commits: [Int] = []
        let pager = makePager { commits.append($0) }
        XCTAssertTrue(pager.begin(fromLeading: false))
        pager.update(-200)
        pager.end(velocity: 0, cancelled: false, reducedMotion: true)
        pager.resize(800)
        try await Task.sleep(for: .milliseconds(15))
        XCTAssertTrue(commits.isEmpty)
        XCTAssertFalse(pager.moving)
        XCTAssertEqual(pager.selection, 1)
        XCTAssertEqual(pager.width, 800)
        XCTAssertTrue(pager.begin(fromLeading: false))
        pager.update(-200)
        XCTAssertEqual(pager.position, 1.25, accuracy: 0.001)
        pager.cancel()
    }

    func testManagementLockCancelsPendingCommitAndRejectsNewInput() async throws {
        var commits: [Int] = []
        let pager = makePager { commits.append($0) }
        pager.select(2, reducedMotion: true)
        pager.locked = true
        try await Task.sleep(for: .milliseconds(15))
        XCTAssertTrue(commits.isEmpty)
        XCTAssertFalse(pager.canPageBack)
        XCTAssertFalse(pager.begin(fromLeading: false))
        pager.select(0, reducedMotion: true)
        XCTAssertFalse(pager.moving)
        pager.locked = false
        XCTAssertTrue(pager.canPageBack)
        XCTAssertTrue(pager.begin(fromLeading: true))
        pager.cancel()
    }

    func testExternalSelectionAndDisableInvalidateOldTransition() async throws {
        var commits: [Int] = []
        let pager = makePager { commits.append($0) }
        pager.select(2, reducedMotion: true)
        pager.configure(selection: 0, count: 4, enabled: true) { commits.append($0) }
        try await Task.sleep(for: .milliseconds(15))
        XCTAssertEqual(pager.selection, 0)
        XCTAssertFalse(pager.moving)
        XCTAssertTrue(commits.isEmpty)
        pager.select(1, reducedMotion: true)
        pager.configure(selection: 0, count: 4, enabled: false) { commits.append($0) }
        try await Task.sleep(for: .milliseconds(15))
        XCTAssertFalse(pager.begin(fromLeading: false))
        XCTAssertEqual(pager.selection, 0)
        XCTAssertTrue(commits.isEmpty)
    }

    func testTapCommitsRequestedNonAdjacentSectionAndIgnoresRepeatedTapDuringTransition() async throws {
        var commits: [Int] = []
        let pager = makePager(selection: 0) { commits.append($0) }
        pager.select(3, reducedMotion: true)
        XCTAssertEqual(pager.position, 3, accuracy: 0.001, "The indicator must settle on the requested section, even for non-adjacent taps")
        pager.select(1, reducedMotion: true)
        try await waitForSettlement(pager)
        XCTAssertEqual(commits, [3])
        XCTAssertEqual(pager.selection, 3)
        XCTAssertNil(pager.target)
    }
    func testKeyboardGestureLockStillAllowsExplicitSectionSelection() async throws {
        var commits: [Int] = []
        let pager = makePager { commits.append($0) }
        pager.gestureLocked = true
        XCTAssertFalse(pager.begin(fromLeading: false))
        pager.select(3, reducedMotion: true)
        try await waitForSettlement(pager)
        XCTAssertEqual(commits, [3])
        XCTAssertEqual(pager.selection, 3)
    }

    func testMenuPresentationsBlockEdgesAndReleaseIndependentlyOfKeyboardLock() {
        let pager = makePager()
        let first = UUID(), second = UUID()
        pager.setMenuPresentation(first, visible: true)
        XCTAssertFalse(pager.canBeginGesture)
        XCTAssertFalse(pager.begin(fromLeading: false))
        pager.select(3, reducedMotion: true)
        XCTAssertFalse(pager.moving)
        pager.setMenuPresentation(second, visible: true)
        pager.setMenuPresentation(first, visible: false)
        XCTAssertFalse(pager.canBeginGesture)
        pager.gestureLocked = true
        pager.setMenuPresentation(second, visible: false)
        XCTAssertFalse(pager.canBeginGesture)
        pager.gestureLocked = false
        XCTAssertTrue(pager.canBeginGesture)
        XCTAssertTrue(pager.begin(fromLeading: false))
    }

    func testMenuPlacementUsesAvailableSafeAreaAndCompleteRows() {
        let safe = CGRect(x: 62, y: 20, width: 700, height: 280)
        let nearTop = AppMenuPlacement.frame(anchor: CGRect(x: 70, y: 25, width: 56, height: 36), available: safe, contentHeight: 400, maximumRows: 4)
        XCTAssertTrue(safe.contains(nearTop))
        XCTAssertEqual(nearTop.minX, safe.minX)
        XCTAssertEqual(nearTop.minY, 65)
        XCTAssertEqual(nearTop.height, FormMenuMetrics.height(rows: 4))
        let nearBottom = AppMenuPlacement.frame(anchor: CGRect(x: 730, y: 250, width: 30, height: 36), available: safe, contentHeight: 400, maximumRows: 4)
        XCTAssertTrue(safe.contains(nearBottom))
        XCTAssertEqual(nearBottom.maxX, safe.maxX)
        XCTAssertEqual(nearBottom.maxY, 246)
        let narrow = AppMenuPlacement.frame(anchor: CGRect(x: 20, y: 10, width: 40, height: 36), available: CGRect(x: 10, y: 0, width: 180, height: 130), contentHeight: 400, maximumRows: 7)
        XCTAssertEqual(narrow.width, 180)
        XCTAssertEqual(narrow.height, FormMenuMetrics.height(rows: 1))
    }

}


@MainActor final class AnimatedDisclosureContentTests: XCTestCase {
    private final class State: ObservableObject {
        @Published var expanded = true
        @Published var text = "draft"
        var appearances = 0
        var disappearances = 0
    }
    private struct Harness: View {
        @ObservedObject var state: State
        var body: some View {
            VStack(spacing: 0) {
                AnimatedDisclosureContent(isExpanded: state.expanded, identifier: "disclosure.test") {
                    TextField("Input", text: $state.text)
                        .frame(height: 80)
                        .accessibilityIdentifier("disclosure.test.input")
                        .onAppear { state.appearances += 1 }
                        .onDisappear { state.disappearances += 1 }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
    private func waitFor(_ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(2)
        while !condition(), Date() < end { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition())
    }
    func testClosingThenReopeningBeforeCompletionDoesNotUnmountTheLiveInput() async throws {
        try XCTSkipIf(UIAccessibility.isReduceMotionEnabled, "This case exercises an interrupted animated transition")
        let state = State()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: Harness(state: state))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        try await waitFor { state.appearances == 1 }
        state.expanded = false
        try await Task.sleep(for: .milliseconds(60))
        state.expanded = true
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(state.expanded)
        XCTAssertEqual(state.appearances, 1)
        XCTAssertEqual(state.disappearances, 0, "The old closing completion must not destroy the reopened input")
        XCTAssertEqual(state.text, "draft")
    }
    func testDisabledAnimationsCompleteClosingAndPreserveParentDraft() async throws {
        let state = State()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: Harness(state: state).transaction { $0.disablesAnimations = true })
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        try await waitFor { state.appearances == 1 }
        state.expanded = false
        try await waitFor { state.disappearances == 1 }
        state.expanded = true
        try await waitFor { state.appearances == 2 }
        XCTAssertEqual(state.text, "draft")
    }
}
