import SwiftUI
import ExViewerCore
import Observation

/// Navigation-only state. Reading records and downloaded files remain separate.
@Observable @MainActor final class FeedViewportMemory {
    struct Bookmark: Equatable {
        var id: String
        var offsetBelowHeader: CGFloat
    }
    private(set) var revision = UUID()
    private(set) var isAtTop = true
    private(set) var requiresRestore = false
    @ObservationIgnored private(set) var bookmark: Bookmark?
    @ObservationIgnored private var previousIDs: [String] = []

    func reset() {
        bookmark = nil; previousIDs = []; isAtTop = true; requiresRestore = false; revision = UUID()
    }
    func invalidateLayout() { requiresRestore = true; revision = UUID() }
    func finishRestore(revision: UUID) {
        guard self.revision == revision, requiresRestore else { return }
        requiresRestore = false
    }
    func capture(id: String?, offsetBelowHeader: CGFloat, atTop: Bool) {
        guard !requiresRestore else { return }
        if isAtTop != atTop { isAtTop = atTop }
        if atTop { bookmark = nil }
        else if let id, offsetBelowHeader.isFinite { bookmark = .init(id: id, offsetBelowHeader: offsetBelowHeader) }
    }
    func reconcile(_ ids: [String]) {
        defer { previousIDs = ids }
        guard let bookmark, !ids.contains(bookmark.id) else { return }
        let retained = Set(ids)
        let oldIndex = previousIDs.firstIndex(of: bookmark.id) ?? 0
        let successor = previousIDs.dropFirst(oldIndex).first { retained.contains($0) }
        let predecessor = previousIDs.prefix(oldIndex).reversed().first { retained.contains($0) }
        if let id = successor ?? predecessor ?? ids.first {
            self.bookmark = .init(id: id, offsetBelowHeader: bookmark.offsetBelowHeader)
        } else { self.bookmark = nil; isAtTop = true }
    }
}

/// All history cards share one fixed metric; the bookmark stores identity plus
/// the visible fraction of that row, independently of its current sort index.

extension FeedViewportMemory {
    func distance(in ids: [String]) -> CGFloat {
        guard let bookmark, let index = ids.firstIndex(of: bookmark.id) else { return 0 }
        return max(0, CGFloat(index) * Self.rowStride + FeedChrome.contentTopGap - bookmark.offsetBelowHeader)
    }
    static var rowStride: CGFloat { LibraryCardMetrics.height + FeedChrome.contentSpacing }
    func capture(distance: CGFloat, ids: [String]) {
        reconcile(ids)
        guard !ids.isEmpty else { capture(id: nil, offsetBelowHeader: 0, atTop: true); return }
        let index = min(ids.count - 1, max(0, Int(max(0, distance) / Self.rowStride)))
        capture(id: ids[index], offsetBelowHeader: FeedChrome.contentTopGap + CGFloat(index) * Self.rowStride - distance,
                atTop: distance <= 1)
    }
}

/// SwiftUI is the sole scroll owner. No UIKit offset writes or competing
/// scrollTo(id:) commands participate in appearance, reorder or rotation.
struct RememberedFeedScroll<Content: View>: View {
    let memory: FeedViewportMemory
    let revision: UUID
    let ids: [String]
    let topInset: CGFloat
    let identifier: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        GeometryReader { geometry in
            if #available(iOS 18.0, *) {
                NativeRememberedFeedScroll(memory: memory, revision: revision, ids: ids,
                                           topInset: topInset, viewportHeight: geometry.size.height, identifier: identifier, content: content)
                    .id(geometry.size.width)
            } else {
                // iOS 17 retains the same item through the native ID binding.
                LegacyRememberedFeedScroll(memory: memory, revision: revision, ids: ids, topInset: topInset,
                                           identifier: identifier, content: content)
            }
        }
    }
}

@available(iOS 18.0, *)
private struct NativeRememberedFeedScroll<Content: View>: View {
    let memory: FeedViewportMemory
    let revision: UUID
    let ids: [String]
    let topInset: CGFloat
    let identifier: String
    let content: () -> Content
    @Environment(\.headerSectionPreview) private var isPreview
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var position: ScrollPosition
    @State private var restoring = true
    @State private var metrics = Metrics()
    private let initialDistance: CGFloat
    private let expectedContentHeight: CGFloat

    init(memory: FeedViewportMemory, revision: UUID, ids: [String], topInset: CGFloat, viewportHeight: CGFloat,
         identifier: String, content: @escaping () -> Content) {
        self.memory = memory; self.revision = revision; self.ids = ids
        self.topInset = topInset; self.identifier = identifier; self.content = content
        let contentHeight = CGFloat(ids.count) * FeedViewportMemory.rowStride - (ids.isEmpty ? 0 : FeedChrome.contentSpacing)
            + topInset + FeedChrome.contentTopGap + FeedChrome.sectionSpacing
        expectedContentHeight = contentHeight
        let distance = min(memory.distance(in: ids), max(0, contentHeight - viewportHeight))
        initialDistance = distance
        _position = State(initialValue: ScrollPosition(y: distance))
    }
    private struct Metrics: Equatable {
        var distance: CGFloat = 0
        var maximum: CGFloat = 0
        var contentHeight: CGFloat = 0
    }
    var body: some View {
        ScrollView {
            content()
                .padding(.top, topInset + FeedChrome.contentTopGap)
                .padding(.bottom, FeedChrome.sectionSpacing)
        }
        .scrollPosition($position)
        .onHeaderReselection {
            withAnimation(reduceMotion ? nil : ChromeMotion.control) { position.scrollTo(y: 0) }
        }
        .scrollDismissesKeyboard(.interactively)
        .accessibilityIdentifier(identifier)
        .onScrollGeometryChange(for: Metrics.self) { geometry in
            Metrics(distance: geometry.contentOffset.y + geometry.contentInsets.top,
                    maximum: max(0, geometry.contentSize.height - geometry.containerSize.height),
                    contentHeight: geometry.contentSize.height)
        } action: { _, value in
            metrics = value
            accept(value)
        }
        .onChange(of: isPreview) { _, preview in
            if !preview { accept(metrics) }
        }
        .onScrollPhaseChange { _, phase in
            if phase == .interacting {
                restoring = false
                memory.finishRestore(revision: revision)
            }
        }
        .overlay(alignment: .topLeading) {
            if AppMode.qa {
                Color.clear.frame(width: 1, height: 1).accessibilityElement()
                    .accessibilityIdentifier("history.viewport.qa")
                    .accessibilityValue("offset=\(metrics.distance);maximum=\(metrics.maximum);contentHeight=\(metrics.contentHeight);restoring=\(restoring);target=\(initialDistance);anchor=\(String(describing: memory.bookmark))")
                    .allowsHitTesting(false)
            }
        }
    }
    private func accept(_ value: Metrics) {
        guard revision == memory.revision, !isPreview else { return }
        if restoring {
            guard abs(value.contentHeight - expectedContentHeight) < 1,
                  abs(value.distance - initialDistance) < 1 else { return }
            restoring = false
            memory.finishRestore(revision: revision)
        }
        memory.capture(distance: value.distance, ids: ids)
    }

}

private struct LegacyRememberedFeedScroll<Content: View>: View {
    let memory: FeedViewportMemory
    let revision: UUID
    let ids: [String]
    let topInset: CGFloat
    let identifier: String
    let content: () -> Content
    @Environment(\.headerSectionPreview) private var isPreview
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var anchor: String?
    init(memory: FeedViewportMemory, revision: UUID, ids: [String], topInset: CGFloat,
         identifier: String, content: @escaping () -> Content) {
        self.memory = memory; self.revision = revision; self.ids = ids; self.topInset = topInset
        self.identifier = identifier; self.content = content
        _anchor = State(initialValue: memory.bookmark?.id)
    }
    var body: some View {
        ScrollView {
            content().scrollTargetLayout()
        }
        .contentMargins(.top, topInset + FeedChrome.contentTopGap, for: .scrollContent)
        .contentMargins(.bottom, FeedChrome.sectionSpacing, for: .scrollContent)
        .scrollPosition(id: $anchor, anchor: .top)
        .onHeaderReselection {
            withAnimation(reduceMotion ? nil : ChromeMotion.control) { anchor = ids.first }
        }
        .scrollDismissesKeyboard(.interactively)
        .accessibilityIdentifier(identifier)
        .onChange(of: anchor) { _, _ in accept() }
        .onChange(of: isPreview) { _, preview in if !preview { accept() } }
        .onAppear { accept() }
    }
    private func accept() {
        guard revision == memory.revision, !isPreview else { return }
        memory.finishRestore(revision: revision)
        memory.capture(id: anchor, offsetBelowHeader: FeedChrome.contentTopGap,
                       atTop: anchor == nil || anchor == ids.first)
    }
}

struct GalleryFeedViewport {
    var space: String
    var height: CGFloat
    var topOcclusion: CGFloat = 0
    var contentTop: CGFloat { min(max(0, topOcclusion), max(0, height)) }

    static func restorationID(for galleryID: String) -> String { "feed.restore.\(galleryID)" }

    // The one-point marker restores immediately below the floating header,
    // independently of the cover's aspect ratio.
    var restorationAlignment: UnitPoint {
        UnitPoint(x: 0.5, y: min(max(0, topOcclusion) / max(1, height - 1), 1))
    }

    struct CoverEdge: Equatable {
        let id: String
        let width: CGFloat
    }

    func coverEdges(in frames: [String: CGRect]) -> [CoverEdge] {
        guard height > contentTop else { return [] }
        // Each masonry column has a different bottom visible card.
        var columns: [CGFloat: (id: String, frame: CGRect)] = [:]
        for (id, frame) in frames where frame.maxY > contentTop && frame.minY < height && frame.width > 0 {
            if let current = columns[frame.minX], current.frame.minY >= frame.minY { continue }
            columns[frame.minX] = (id, frame)
        }
        return columns.keys.sorted().compactMap { columns[$0] }
            .map { CoverEdge(id: $0.id, width: $0.frame.width) }
    }

    struct CoverWindow: Equatable {
        var visible: Set<String> = []
        var nearby: Set<String> = []

        func priority(for id: String) -> MediaRequestPriority? {
            if visible.contains(id) { return .thumbnail }
            return nearby.contains(id) ? .thumbnailPrefetch : nil
        }
    }

    /// Lazy stacks may construct cells far outside the viewport. Construction
    /// alone must not grant a visible transfer or keep an old transfer alive.
    func coverWindow(in frames: [String: CGRect], columns: [[Gallery]]) -> CoverWindow {
        guard height > contentTop else { return CoverWindow() }
        let visible = Set(frames.compactMap { id, frame in
            frame.width > 0 && frame.maxY > contentTop && frame.minY < height ? id : nil
        })
        var nearby = Set<String>()
        for column in columns {
            let indices = column.indices.filter { visible.contains(column[$0].id) }
            guard let first = indices.first, let last = indices.last else { continue }
            // Two cards behind support a quick reversal; six ahead retain the
            // existing bounded lookahead without retaining the whole lazy stack.
            let lower = max(column.startIndex, first - 2)
            let upper = min(column.endIndex, last + 1 + Self.coverLookaheadPerColumn)
            nearby.formUnion(column[lower..<upper].map(\.id))
        }
        nearby.subtract(visible)
        return CoverWindow(visible: visible, nearby: nearby)
    }

    // Keep a bounded horizon beyond both visible column edges. Requests remain
    // thumbnailPrefetch priority and share the existing transfer/cache pipeline.
    static let coverLookaheadPerColumn = 6
    static func upcomingCovers(after id: String, in columns: [[Gallery]]) -> ArraySlice<Gallery> {
        for column in columns {
            guard let index = column.firstIndex(where: { $0.id == id }) else { continue }
            return column.dropFirst(index + 1).prefix(coverLookaheadPerColumn)
        }
        return []
    }

    func nearestVisibleAnchor(in frames: [String: CGRect]) -> String? {
        guard height > contentTop else { return nil }
        return frames.filter { $0.value.maxY > contentTop && $0.value.minY < height }.min { lhs, rhs in
            let a = abs(lhs.value.minY - contentTop), b = abs(rhs.value.minY - contentTop)
            if a != b { return a < b }
            if lhs.value.minY != rhs.value.minY { return lhs.value.minY < rhs.value.minY }
            if lhs.value.minX != rhs.value.minX { return lhs.value.minX < rhs.value.minX }
            return lhs.key < rhs.key
        }?.key
    }
}

/// Debug fixture readback after ImageIO decoding, without changing button
/// accessibility or substituting the production cover rendering path.
@MainActor @Observable final class CoverWindowQA {
    static let shared = CoverWindowQA()
    private(set) var decoded: Set<String> = []
    func invalidate(_ id: String) { decoded.remove(id) }
    func record(_ id: String) {
        guard AppMode.qa, ProcessInfo.processInfo.arguments.contains("--qa-cover-window") else { return }
        if decoded.count >= 2048 { decoded.removeAll() }
        decoded.insert(id)
    }
}
