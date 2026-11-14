import SwiftUI
import UIKit
import ExViewerCore
import ImageIO

/// Keep NavigationLink's native ownership, but check the shared touch gate at
/// its actual activation boundary, rather than waiting for a hit-test redraw.
private struct GuardedGalleryNavigationStyle: PrimitiveButtonStyle {
    @Environment(\.edgeTouchGate) private var edgeTouches
    func makeBody(configuration: Configuration) -> some View {
        Button {
            guard edgeTouches?.permitsGalleryActivation() != false else { return }
            configuration.trigger()
        } label: { configuration.label }
        .buttonStyle(.plain)
    }
}

private struct GalleryCellFrames: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

// Retain the last measurement for viewport-only changes without publishing
// every scroll pixel as view state.
private final class GalleryCoverFrames {
    var values: [String: CGRect] = [:]
}

struct GalleryRows: View {
    var galleries: [Gallery]
    var sourceIdentity: String? = nil
    var selectionStore: LibrarySelectionStore
    var isSelecting = false
    var isLoading = false
    var loadFailure: String? = nil
    var openIdentifier = "gallery.open"
    var selectionIdentifier = "favorites.select"
    var onLongPressSelect: (Gallery) -> Void
    var onNearEnd: (() -> Void)? = nil
    var viewport: GalleryFeedViewport? = nil
    var onVisibleAnchor: ((String) -> Void)? = nil
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var session: SiteSession
    @Environment(\.headerSectionPreview) private var isSectionPreview
    @Environment(\.displayScale) private var displayScale
    private static let restorationMarkerHeight: CGFloat = 1
    private let aspectCache = CoverAspectCache.shared
    @State private var preparedVisible: [Gallery]?
    @State private var preparedUnknown = 0
    @State private var preparedColumns: [[Gallery]]?
    @State private var placement = GalleryGridPlacement()
    @State private var placementSource: String?
    @State private var lastAutomaticAnchor: String?
    @State private var coverEdges: [GalleryFeedViewport.CoverEdge] = []
    @State private var coverWindow = GalleryFeedViewport.CoverWindow()
    @State private var measuredCoverFrames = GalleryCoverFrames()
    private var visible: [Gallery] { preparedVisible ?? filterGalleries().visible }
    private var unknown: Int { preparedVisible == nil ? filterGalleries().unknown : preparedUnknown }
    private var markerHeight: CGFloat { onVisibleAnchor == nil ? 0 : Self.restorationMarkerHeight }

    var body: some View {
        LazyVStack(spacing: 0) {
            if unknown > 0 && isLoading && visible.isEmpty {
                GalleryLoadingIndicator(label: "正在载入").frame(maxWidth: .infinity)
            }
            HStack(alignment: .top, spacing: FeedChrome.contentSpacing) {
                ForEach(Array(gridColumns.enumerated()), id: \.offset) { entry in
                    LazyVStack(alignment: .leading, spacing: FeedChrome.contentSpacing - markerHeight) {
                        ForEach(entry.element) { gallery in
                            VStack(spacing: 0) {
                                restorationAnchor(gallery)
                                gridCell(gallery)
                            }.id(gallery.id).background { measure(gallery) }
                        }
                    }.scrollTargetLayout().frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
                }
            }.padding(.horizontal, FeedChrome.contentInset)
                .padding(.top, FeedChrome.contentTopGap - markerHeight)
        }
        .appToast(message: loadFailure == nil && !isLoading && unknown > 0 ? "标签资料尚未载入 请重试" :
                    (loadFailure == nil && !galleries.isEmpty && visible.isEmpty && unknown == 0 ? "当前结果已被本机标签屏蔽" : nil),
                  identifier: "gallery.filter-feedback")
        .onAppear(perform: prepareLayout)
        .onChange(of: galleries) { _, _ in prepareLayout() }
        .onChange(of: library.blockedIDs) { _, _ in prepareLayout() }
        .onChange(of: library.owner) { _, _ in prepareLayout() }
        .onChange(of: sourceIdentity) { _, _ in prepareLayout() }
        .background { upcomingCoverTasks }
        .overlay(alignment: .topLeading) {
            if AppMode.qa && ProcessInfo.processInfo.arguments.contains("--qa-cover-window") {
                Text("visible=" + coverWindow.visible.sorted().joined(separator: ",") + ";nearby=" + coverWindow.nearby.sorted().joined(separator: ",")
                     + ";decoded=" + CoverWindowQA.shared.decoded.intersection(coverWindow.visible).sorted().joined(separator: ","))
                    .font(.system(size: 1)).frame(width: 1, height: 1).opacity(0.01)
                    .accessibilityIdentifier("cover-window.qa").allowsHitTesting(false)
            }
        }
        .onPreferenceChange(GalleryCellFrames.self) { frames in
            measuredCoverFrames.values = frames
            observedFrames(frames)
        }
        .onChange(of: viewport?.height) { _, _ in observedFrames(measuredCoverFrames.values) }
        .onChange(of: viewport?.topOcclusion) { _, _ in observedFrames(measuredCoverFrames.values) }
    }

    @ViewBuilder private func measure(_ gallery: Gallery) -> some View {
        if let viewport {
            GeometryReader { geometry in
                Color.clear.preference(key: GalleryCellFrames.self,
                                       value: [gallery.id: geometry.frame(in: .named(viewport.space))])
            }
        }
    }

    @ViewBuilder private func restorationAnchor(_ gallery: Gallery) -> some View {
        if onVisibleAnchor != nil {
            Color.clear.frame(height: Self.restorationMarkerHeight)
                .id(GalleryFeedViewport.restorationID(for: gallery.id))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private func observedFrames(_ frames: [String: CGRect]) {
        guard !isSectionPreview, let viewport, viewport.height > 0 else { return }
        let edges = viewport.coverEdges(in: frames)
        if coverEdges != edges { coverEdges = edges }
        let window = viewport.coverWindow(in: frames, columns: gridColumns)
        if coverWindow != window { coverWindow = window }
        let visibleTop = viewport.contentTop
        let anchor = viewport.nearestVisibleAnchor(in: frames)
        if let anchor {
            onVisibleAnchor?(anchor)
        }
        // SwiftUI can create lazy cells before they enter the viewport. Only
        // an actual tail cell near the visible bottom may request another page.
        if let anchor, lastAutomaticAnchor != anchor, visible.suffix(2).contains(where: { gallery in
            guard let frame = frames[gallery.id] else { return false }
            return frame.maxY > visibleTop && frame.minY <= viewport.height + max(1, viewport.height - visibleTop)
        }) {
            // One automatic batch per visible-anchor advance prevents a short
            // feed from recursively fetching every page while the user is idle.
            lastAutomaticAnchor = anchor; onNearEnd?()
        }
    }

    @ViewBuilder private var upcomingCoverTasks: some View {
        if (!AppMode.qa || ProcessInfo.processInfo.arguments.contains("--qa-cover-window")) && !isSelecting && !isSectionPreview {
            let columns = gridColumns
            let requests = coverEdges.flatMap { edge in
                GalleryFeedViewport.upcomingCovers(after: edge.id, in: columns).map { gallery in
                    CoverPrefetchRequest(gallery: gallery, width: edge.width, scale: displayScale,
                                         owner: library.owner, generation: session.generation)
                }
            }
            ZStack {
                ForEach(requests, id: \.gallery.id) { request in
                    Color.clear.frame(width: 0, height: 0)
                        .task(id: request) { await prefetchCover(request) }
                }
            }
        }
    }

    private struct CoverPrefetchRequest: Hashable {
        let gallery: Gallery
        let width: CGFloat
        let scale: CGFloat
        let owner: String
        let generation: UUID
    }

    private func prefetchCover(_ request: CoverPrefetchRequest) async {
        let gallery = request.gallery
        guard let file = try? await GalleryCoverLoader.file(for: gallery, owner: request.owner,
                                                            generation: request.generation, session: session,
                                                            storedCoverQA: AppMode.qa && ProcessInfo.processInfo.arguments.contains("--qa-cover-window"),
                                                            priority: .thumbnailPrefetch),
              !Task.isCancelled else { return }
        let ratio = aspectCache.hasAspect(for: gallery) ? aspectCache.aspect(for: gallery) : await coverAspectRatio(at: file)
        guard !Task.isCancelled, library.owner == request.owner, session.generation == request.generation else { return }
        if let ratio { aspectCache.set(ratio, for: gallery) }
        let aspect = GalleryCoverLayout.displayAspect(Double(ratio ?? 0))
        let size = CGSize(width: request.width, height: request.width / CGFloat(aspect))
        let pixels = StaticCover.thumbnailPixelSize(for: size, scale: request.scale)
        _ = await StaticCoverImageCache.shared.thumbnail(for: file, maxPixelSize: pixels)
    }

    private func gridCell(_ gallery: Gallery) -> some View {
        GallerySelectionLink(gallery: gallery, store: selectionStore,
                             entry: selectionStore.entry(for: gallery.id), isSelecting: isSelecting,
                             openIdentifier: "\(openIdentifier).\(gallery.ref.gid)",
                             selectionIdentifier: "\(selectionIdentifier).\(gallery.ref.gid)",
                             selectionLabel: { selectionLabel(gallery) }, onLongPressSelect: { onLongPressSelect(gallery) }) {
            GalleryGridCell(gallery: gallery, selected: $0,
                            coverPriority: isSectionPreview ? nil : viewport == nil ? .thumbnail : coverWindow.priority(for: gallery.id))
        }
    }

    private func selectionLabel(_ gallery: Gallery) -> String {
        guard AppMode.qa, ProcessInfo.processInfo.arguments.contains("--qa-library-delayed-covers")
                || ProcessInfo.processInfo.arguments.contains("--qa-stored-bookmark-covers") else { return gallery.title }
        return gallery.title + (CoverAspectCache.shared.hasAspect(for: gallery) ? "，封面已载入" : "，封面载入中")
    }

    /// Existing cards keep their columns; only appended cards use the current
    /// height estimates. Ratio updates can resize a cover within its own column.
    private var gridColumns: [[Gallery]] { preparedColumns ?? makeGridColumns(for: visible) }

    private func filterGalleries() -> (visible: [Gallery], unknown: Int) {
        LibrarySelectionPolicy.filtered(galleries, blocked: library.blockedIDs)
    }

    private func prepareLayout() {
        let source = "\(library.owner)|\(sourceIdentity ?? "")"
        if placementSource != source {
            placement = GalleryGridPlacement()
            placementSource = source
            coverEdges = []
            coverWindow = GalleryFeedViewport.CoverWindow()
        }
        let result = filterGalleries()
        preparedVisible = result.visible
        preparedUnknown = result.unknown
        selectionStore.updateLoadedIDs(Set(result.visible.map(\.id)))
        prepareColumns(for: result.visible)
    }

    private func prepareColumns(for items: [Gallery]) {
        let aspects = Dictionary(items.map { ($0.id, Double(aspectCache.aspect(for: $0))) }, uniquingKeysWith: { first, _ in first })
        placement.update(ids: items.map(\.id), aspects: aspects)
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        preparedColumns = placement.columns.map { $0.compactMap { byID[$0] } }
    }

    private func makeGridColumns(for visible: [Gallery]) -> [[Gallery]] {
        var initial = GalleryGridPlacement()
        let byID = Dictionary(visible.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        initial.update(ids: visible.map(\.id), aspects: byID.mapValues { Double(aspectCache.aspect(for: $0)) })
        return initial.columns.map { $0.compactMap { byID[$0] } }
    }
}

struct GallerySelectionLink<Label: View>: View {
    @Environment(\.edgeTouchGate) private var edgeTouches
    @Environment(\.galleryNavigation) private var navigation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let gallery: Gallery
    let store: LibrarySelectionStore
    @ObservedObject var entry: LibrarySelectionEntry
    let isSelecting: Bool
    let openIdentifier: String
    let selectionIdentifier: String
    let selectionLabel: () -> String
    let onLongPressSelect: () -> Void
    @ViewBuilder let label: (Bool?) -> Label

    var body: some View {
        Group {
            if let navigation {
                Button { navigation.open(gallery, animated: !reduceMotion) } label: {
                    label(isSelecting ? entry.isSelected : nil)
                }
            } else {
                NavigationLink(value: gallery) { label(isSelecting ? entry.isSelected : nil) }
            }
        }
        .buttonStyle(GuardedGalleryNavigationStyle())
        .accessibilityIdentifier(openIdentifier)
        .accessibilityHint("轻点打开详情，长按选择并管理")
        .accessibilityAction(named: Text("选择并管理")) { onLongPressSelect() }
        .highPriorityGesture(LongPressGesture(minimumDuration: 0.55).onEnded { _ in
            guard edgeTouches?.blocksGalleryActions != true else { return }
            onLongPressSelect()
        }, including: isSelecting ? .none : .all)
        .allowsHitTesting(!isSelecting)
        .accessibilityHidden(isSelecting)
        // The cover stays mounted in the link when only the tap action changes.
        .overlay {
            if isSelecting {
                Button {
                    guard edgeTouches?.blocksGalleryActions != true else { return }
                    SelectionPerformanceProbe.markAction(id: gallery.id)
                    guard store.toggle(gallery.id) else { return }
                    SelectionPerformanceProbe.markStateSet(id: gallery.id, count: store.selectedIDs.count)
                } label: {
                    Color.clear.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(selectionLabel())
                .accessibilityValue(entry.isSelected ? "已选中" : "未选中")
                .accessibilityHint("轻点切换选择状态")
                .accessibilityIdentifier(selectionIdentifier)
            }
        }
        .onChange(of: entry.isSelected) { _, selected in
            SelectionPerformanceProbe.markSelectionViewUpdate(id: gallery.id, selected: selected)
        }
        .allowsHitTesting(edgeTouches?.blocksGalleryActions != true)
    }
}

struct GalleryGridCell: View {
    let gallery: Gallery
    let selected: Bool?
    var coverPriority: MediaRequestPriority?
    @ObservedObject private var aspect: CoverAspectEntry
    init(gallery: Gallery, selected: Bool? = nil, coverPriority: MediaRequestPriority? = .thumbnail) {
        self.gallery = gallery
        self.selected = selected
        self.coverPriority = coverPriority
        _aspect = ObservedObject(wrappedValue: CoverAspectCache.shared.entry(for: gallery))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: FeedChrome.contentSpacing) {
            Color(uiColor: .secondarySystemGroupedBackground)
                .aspectRatio(GalleryCoverLayout.displayAspect(Double(aspect.aspect)), contentMode: .fit)
                .overlay {
                    CoverView(gallery: gallery, contentMode: .fill,
                              alignment: aspect.aspect < GalleryCoverLayout.minimumAspect ? .top : .center,
                              showsLoadingIndicator: false, requestPriority: coverPriority)
                }
                .clipShape(AppShape.control)
                .overlay(alignment: .topTrailing) {
                    if let selected {
                        Image(systemName: selected ? "checkmark" : "circle")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(selected ? Palette.accent : FloatingChrome.readerBackground, in: Circle())
                            .padding(6)
                            .accessibilityHidden(true)
                            .allowsHitTesting(false)
                    }
                }
                .accessibilityElement(children: .contain).accessibilityIdentifier("gallery.cover.\(gallery.ref.gid)")
            Text(gallery.title).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                .lineLimit(2).truncationMode(.tail).multilineTextAlignment(.leading)
                .accessibilityIdentifier("gallery.title.\(gallery.ref.gid)")
            if !gallery.category.isEmpty || gallery.pages != nil {
                HStack(spacing: FeedChrome.panelSpacing) {
                    if !gallery.category.isEmpty { Text(gallery.category).lineLimit(1) }
                    Spacer(minLength: 0)
                    if let pages = gallery.pages { Text("\(pages) 页").fixedSize() }
                }.font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("gallery.metadata.\(gallery.ref.gid)")
            }
        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }
}

@MainActor final class CoverAspectEntry: ObservableObject {
    @Published private(set) var aspect: CGFloat = 0.71
    @Published private(set) var hasAspect = false
    fileprivate func set(_ value: CGFloat) {
        guard aspect != value || !hasAspect else { return }
        aspect = value; hasAspect = true
    }
}

@MainActor final class CoverAspectCache: ObservableObject {
    static let shared = CoverAspectCache()
    private var entries: [String: CoverAspectEntry] = [:]
    private init() {}

    func aspect(for gallery: Gallery) -> CGFloat {
        entry(for: gallery).aspect
    }

    func hasAspect(for gallery: Gallery) -> Bool { entry(for: gallery).hasAspect }

    func set(_ aspect: CGFloat, for gallery: Gallery) {
        guard aspect.isFinite, aspect > 0 else { return }
        let item = entry(for: gallery)
        guard item.aspect != aspect || !item.hasAspect else { return }
        item.set(aspect)
    }

    func entry(for gallery: Gallery) -> CoverAspectEntry {
        let identity = key(for: gallery)
        if let entry = entries[identity] { return entry }
        let entry = CoverAspectEntry()
        entries[identity] = entry
        return entry
    }

    private func key(for gallery: Gallery) -> String { "\(gallery.id)|\(gallery.cover?.absoluteString ?? "")" }
}

struct GalleryFact: Identifiable {
    let id: String
    let label: String
    let value: String
    var text: String { "\(label): \(value)" }

    private static let categoryTranslations = TagTranslationCatalog.bundled?.namespaces["reclass"] ?? [:]

    static func items(for gallery: Gallery, pageCount: Int? = nil) -> [Self] {
        var facts: [Self] = []
        if let rating = gallery.rating {
            facts.append(.init(id: "rating", label: "分数", value: String(format: "%.1f", rating)))
        }
        let category = gallery.category.trimmingCharacters(in: .whitespacesAndNewlines)
        if !category.isEmpty {
            let key = category.lowercased().filter { !$0.isWhitespace }
            facts.append(.init(id: "category", label: "类别", value: categoryTranslations[key] ?? category))
        }
        if let pages = pageCount ?? gallery.pages {
            facts.append(.init(id: "pages", label: "页数", value: "\(pages) 页"))
        }
        return facts
    }
}

enum LibraryCardMetrics {
    static let height = FeedChrome.rowHeight * 3
    static let coverSize = CGSize(width: 72, height: height - 2 * FeedChrome.sectionSpacing)
}

struct LibraryCardCover: Hashable {
    let gallery: Gallery
    var localFile: URL? = nil
}

struct LibraryCardRows<Item: Identifiable, Row: View>: View {
    let items: [Item]
    let cover: (Item) -> LibraryCardCover?
    @ViewBuilder let row: (Item) -> Row

    @State private var visibleIDs: Set<Item.ID> = []
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var session: SiteSession
    @Environment(\.displayScale) private var displayScale

    private struct CoverRequest: Hashable {
        let cover: LibraryCardCover
        let owner: String
        let generation: UUID
        let pixelSize: Int
    }

    var body: some View {
        LazyVStack(spacing: FeedChrome.contentSpacing) {
            ForEach(items) { item in
                row(item)
                    .onGeometryChange(for: Bool.self) { geometry in
                        guard let scrollBounds = geometry.bounds(of: .scrollView) else { return false }
                        let viewport = CGRect(origin: .zero, size: scrollBounds.size)
                        return geometry.frame(in: .scrollView).intersects(viewport)
                    } action: { visible in
                        if visible { visibleIDs.insert(item.id) } else { visibleIDs.remove(item.id) }
                    }
                    .onDisappear { visibleIDs.remove(item.id) }
            }
        }
        .background {
            ForEach(prefetchRequests, id: \.cover.gallery.id) { request in
                Color.clear.frame(width: 0, height: 0)
                    .task(id: request) { await prefetch(request) }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private var prefetchRequests: [CoverRequest] {
        guard !visibleIDs.isEmpty,
              let first = items.firstIndex(where: { visibleIDs.contains($0.id) }),
              let last = items.lastIndex(where: { visibleIDs.contains($0.id) }) else { return [] }
        let before = items[max(0, first - 1)..<first]
        let after = items.dropFirst(last + 1).prefix(3)
        let pixelSize = StaticCover.thumbnailPixelSize(for: LibraryCardMetrics.coverSize, scale: displayScale)
        return (Array(before) + after).compactMap { item in
            cover(item).map { CoverRequest(cover: $0, owner: library.owner, generation: session.generation, pixelSize: pixelSize) }
        }
    }

    private func prefetch(_ request: CoverRequest) async {
        let file: URL?
        if let localFile = request.cover.localFile {
            file = localFile
        } else if AppMode.qa {
            file = request.cover.gallery.cover ?? QASamples.cover(seed: Int(request.cover.gallery.ref.gid))
        } else {
            file = try? await GalleryCoverLoader.file(for: request.cover.gallery, owner: request.owner,
                                                       generation: request.generation, session: session,
                                                       priority: .thumbnailPrefetch)
        }
        guard let file, !Task.isCancelled, library.owner == request.owner, session.generation == request.generation else { return }
        _ = await StaticCoverImageCache.shared.thumbnail(for: file, maxPixelSize: request.pixelSize)
    }
}

struct LibraryGalleryCard<Cover: View>: View {
    let gallery: Gallery
    var pageCount: Int? = nil
    let context: String
    var selected: Bool? = nil
    var actionSymbol = "chevron.right"
    var progress: CGFloat = 0
    @ViewBuilder let cover: () -> Cover

    var body: some View {
        HStack(spacing: FeedChrome.sectionSpacing) {
            cover()
                .frame(width: LibraryCardMetrics.coverSize.width, height: LibraryCardMetrics.coverSize.height)
                .clipShape(AppShape.control)
            VStack(alignment: .leading, spacing: FeedChrome.contentSpacing) {
                Text(gallery.title)
                    .font(.subheadline.weight(.semibold))
                Text(GalleryFact.items(for: gallery, pageCount: pageCount).map(\.text).joined(separator: " · "))
                    .foregroundStyle(.secondary)
                Text(context)
                    .foregroundStyle(.secondary)
            }
            .font(FeedChrome.DetailCard.metadataFont)
            .lineLimit(1).truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: selected.map { $0 ? "checkmark.circle.fill" : "circle" } ?? actionSymbol)
                .font(FeedChrome.labelFont)
                .foregroundStyle(selected == true ? Color.accentColor : Color.secondary)
                .frame(width: 24)
                .accessibilityHidden(true)
        }
        .padding(FeedChrome.sectionSpacing)
        .frame(maxWidth: .infinity, minHeight: LibraryCardMetrics.height, alignment: .leading)
        .background {
            GeometryReader { geometry in
                Rectangle()
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: geometry.size.width * progress)
            }
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(AppShape.card)
        }
        .overlay {
            AppShape.card.strokeBorder(selected == true ? Color.accentColor : Color.primary.opacity(0.10),
                                       lineWidth: selected == true ? 1 : 0.5)
                .allowsHitTesting(false)
        }
        .contentShape(AppShape.card)
        .accessibilityElement(children: .combine)
    }
}

struct CoverView: View {
    var gallery: Gallery
    var contentMode: ContentMode = .fit
    var alignment: Alignment = .center
    var showsLoadingIndicator = true
    var showsRetryButton = true
    var fitsExtremeAspects = false
    var requestPriority: MediaRequestPriority? = .thumbnail
    @EnvironmentObject private var session: SiteSession
    @EnvironmentObject private var library: LibraryStore
    @State private var file: URL?
    @State private var fileContext: String?
    @State private var failure: String?
    @State private var userRetryContext: String?
    @State private var retry = UUID()
    @State private var activeDemand: MediaRequestDemand?
    private var storedCoverQA: Bool { AppMode.qa && ProcessInfo.processInfo.arguments.contains("--qa-stored-bookmark-covers") }
    private struct RequestIdentity: Hashable { var owner: String; var gallery: String; var cover: URL?; var revision: UUID; var retry: UUID; var enabled: Bool }
    private var requestIdentity: RequestIdentity { .init(owner: library.owner, gallery: gallery.id, cover: gallery.cover, revision: session.generation, retry: retry, enabled: requestPriority != nil) }
    private var contextIdentity: String { "\(library.owner)|\(session.generation.uuidString)" }
    var body: some View {
        ZStack {
            Color(uiColor: fitsExtremeAspects ? .tertiarySystemGroupedBackground : .secondarySystemGroupedBackground)
            if let file, fileContext == contextIdentity, failure == nil || showsRetryButton {
                StaticCover(file: file,
                            contextIdentity: contextIdentity,
                            requestIdentity: "\(gallery.id)|\(gallery.cover?.absoluteString ?? "none")|\(retry.uuidString)",
                            contentMode: contentMode, alignment: alignment,
                            fitsExtremeAspects: fitsExtremeAspects,
                            onDecodeFailure: { failure = ErrorMessages.message(ViewerError.unsupported) },
                            onDecoded: { CoverWindowQA.shared.record(gallery.id) })
                    .overlay(alignment: .bottom) {
                        if let failure, showsRetryButton {
                            Button {
                                userRetryContext = contextIdentity
                                Task {
                                    let owner = library.owner, generation = session.generation
                                    await MediaRepository.shared.discardUndecodableBrowseFile(file, owner: owner)
                                    guard owner == library.owner, generation == session.generation else { return }
                                    retry = UUID()
                                }
                            } label: {
                                Label("重试", systemImage: "arrow.clockwise").font(.caption).padding(8)
                            }.buttonStyle(.borderless).background(FloatingChrome.background, in: AppShape.control)
                                .accessibilityLabel("重新载入封面").accessibilityHint(failure)
                        }
                    }
            }
            else if AppMode.qa && !storedCoverQA && !ProcessInfo.processInfo.arguments.contains("--qa-cover-window") { QACover(seed: Int(gallery.ref.gid)) }
            else if let failure, showsRetryButton {
                VStack(spacing: 4) {
                    Button { userRetryContext = contextIdentity; retry = UUID() } label: { Label("重试", systemImage: "arrow.clockwise").font(.caption).frame(minHeight: 44) }
                        .buttonStyle(.borderless).accessibilityLabel("重新载入封面").accessibilityHint(failure)
                }.padding(5)
            }
            else if !showsRetryButton {
                Image(systemName: "book.closed").font(.caption).foregroundStyle(.secondary)
            }
            else if showsLoadingIndicator { ProgressView() }
        }
        .appToast(message: showsRetryButton && userRetryContext == contextIdentity ? failure : nil,
                  identifier: "cover.error.\(gallery.ref.gid)")
        .accessibilityElement(children: .contain).accessibilityIdentifier("cover.media.\(gallery.ref.gid)")
        .accessibilityValue(failure != nil ? "载入失败" : file == nil ? (requestPriority == nil ? "未请求" : "载入中") : "已载入")
        .onChange(of: requestPriority) { _, priority in
            if let priority { activeDemand?.setPriority(priority) }
        }
        .onDisappear {
            if AppMode.qa && ProcessInfo.processInfo.arguments.contains("--qa-cover-window") {
                CoverWindowQA.shared.invalidate(gallery.id)
            }
        }
        .task(id: requestIdentity) {
            guard !Task.isCancelled, let priority = requestPriority else { return }
            let demand = MediaRequestDemand(priority: priority)
            activeDemand = demand
            defer { if activeDemand?.id == demand.id { activeDemand = nil } }
            // Keep a successfully displayed image while the same gallery is
            // revalidated. Identity changes recreate this task/context safely.
            failure = nil
            let currentContext = contextIdentity
            if fileContext != currentContext { file = nil; fileContext = nil }
            if AppMode.qa && !storedCoverQA {
                if ProcessInfo.processInfo.arguments.contains("--qa-library-delayed-covers") {
                    try? await Task.sleep(nanoseconds: 60_000_000_000)
                    guard !Task.isCancelled else { return }
                }
                if ProcessInfo.processInfo.arguments.contains("--qa-grid-aspect-delay") {
                    try? await Task.sleep(nanoseconds: 15_000_000_000)
                    guard !Task.isCancelled else { return }
                }
                let fixture = gallery.cover.flatMap { $0.isFileURL ? $0 : nil } ?? QASamples.cover(seed: Int(gallery.ref.gid))
                fileContext = currentContext; file = fixture
                if let ratio = await coverAspectRatio(at: fixture) { CoverAspectCache.shared.set(ratio, for: gallery) }
                return
            }
            let revision = session.generation, owner = library.owner
            do {
                failure = nil
                let result = try await GalleryCoverLoader.file(for: gallery, owner: owner, generation: revision,
                                                                session: session, storedCoverQA: storedCoverQA, demand: demand)
                try Task.checkCancellation()
                guard revision == session.generation, owner == library.owner else { return }
                fileContext = currentContext; file = result
                if !CoverAspectCache.shared.hasAspect(for: gallery),
                   let ratio = await coverAspectRatio(at: result) {
                    try Task.checkCancellation()
                    guard revision == session.generation, owner == library.owner else { return }
                    CoverAspectCache.shared.set(ratio, for: gallery)
                }
            } catch is CancellationError { }
            catch {
                guard revision == session.generation, owner == library.owner else { return }
                StoredCoverResolver.shared.invalidate(gallery.ref, context: currentContext)
                failure = (error as? StoredCoverResolver.Failure)?.errorDescription ?? ErrorMessages.message(error)
            }
        }
    }
}

@MainActor private enum GalleryCoverLoader {
    static func file(for gallery: Gallery, owner: String, generation: UUID, session: SiteSession,
                     storedCoverQA: Bool = false, priority: MediaRequestPriority = .thumbnail,
                     demand: MediaRequestDemand? = nil) async throws -> URL {
        let cover: URL
        if let source = gallery.cover { cover = source }
        else {
            cover = try await StoredCoverResolver.shared.source(for: gallery, context: "\(owner)|\(generation.uuidString)") { batch in
                if storedCoverQA {
                    if ProcessInfo.processInfo.arguments.contains("--qa-stored-cover-missing") { return batch }
                    return batch.map { gallery in
                        var resolved = gallery
                        resolved.cover = QASamples.cover(seed: Int(gallery.ref.gid))
                        return resolved
                    }
                }
                return try await session.galleryMetadata(batch, priority: .thumbnail)
            }
        }
        try Task.checkCancellation()
        guard generation == session.generation else { throw CancellationError() }
        if storedCoverQA { return cover }
        return try await MediaRepository.shared.file(for: cover, owner: owner,
                                                     request: demand ?? MediaRequestDemand(priority: priority))
    }
}

private func coverAspectRatio(at file: URL) async -> CGFloat? {
    await Task.detached(priority: .utility) {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let rawWidth = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let rawHeight = properties[kCGImagePropertyPixelHeight] as? NSNumber else { return nil }
        var width = CGFloat(rawWidth.doubleValue)
        var height = CGFloat(rawHeight.doubleValue)
        if let orientation = properties[kCGImagePropertyOrientation] as? NSNumber,
           [5, 6, 7, 8].contains(orientation.intValue) { swap(&width, &height) }
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
        return width / height
    }.value
}
