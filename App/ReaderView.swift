import SwiftUI
import ExViewerCore

enum ReaderPreferenceDefaults {
    static let store: UserDefaults = {
        let defaults = AppMode.qa ? UserDefaults(suiteName: "ExViewer.Reader.QA")! : .standard
        ReaderLoadPolicy.migrate(defaults: defaults)
        return defaults
    }()
}

enum ReaderMode: Int, CaseIterable, Identifiable {
    case continuous = 0
    case singlePage = 1
    var id: Int { rawValue }
    var title: String { self == .continuous ? "连续模式" : "单页模式" }
}

enum ReaderDirection: String, CaseIterable, Identifiable {
    case leftToRight, rightToLeft, topToBottom, bottomToTop
    var id: String { rawValue }
    var horizontal: Bool { self == .leftToRight || self == .rightToLeft }
    var reverseOrder: Bool { self == .rightToLeft || self == .bottomToTop }
    var axis: Axis.Set { horizontal ? .horizontal : .vertical }
    var title: String { switch self { case .leftToRight: "从左到右"; case .rightToLeft: "从右到左"; case .topToBottom: "从上到下"; case .bottomToTop: "从下到上" } }
    var forwardSymbol: String { switch self { case .leftToRight: "arrow.right"; case .rightToLeft: "arrow.left"; case .topToBottom: "arrow.down"; case .bottomToTop: "arrow.up" } }
}

enum ReaderPageSizing {
    static func extent(imageSize: CGSize?, crossAxisExtent: CGFloat, direction: ReaderDirection) -> CGFloat {
        guard crossAxisExtent > 0 else { return 1 }
        guard let imageSize, imageSize.width > 0, imageSize.height > 0 else {
            return direction.horizontal ? crossAxisExtent * 0.72 : crossAxisExtent * 1.32
        }
        let ratio = imageSize.width / imageSize.height
        return direction.horizontal ? crossAxisExtent * ratio : crossAxisExtent / ratio
    }
}

private struct ReaderContentOrigin: PreferenceKey {
    static var defaultValue: CGPoint = .zero
    static func reduce(value: inout CGPoint, nextValue: () -> CGPoint) { value = nextValue() }
}

private struct ReaderPageFrames: PreferenceKey {
    static var defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) { value.merge(nextValue(), uniquingKeysWith: { _, new in new }) }
}

struct ReaderView: View {
    private static var usesAutomaticImmersion: Bool {
        !AppMode.qa || ProcessInfo.processInfo.arguments.contains("--qa-automatic-immersion")
    }
    var gallery: Gallery
    var offline = false
    var searchTarget: DetailSearchTarget? = nil
    var openingDetail: ReaderOpeningDetail? = nil
    @EnvironmentObject private var session: SiteSession
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = ReaderModel()
    @StateObject private var media = ReaderMediaStore(backgroundWork: AppMode.qa ? nil : BackgroundWork())
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @State private var current = 1
    @State private var scrollPosition: Int? = 1
    @AppStorage("reader.mode", store: ReaderPreferenceDefaults.store) private var mode = 0
    @AppStorage("reader.direction", store: ReaderPreferenceDefaults.store) private var storedDirection = ReaderDirection.leftToRight.rawValue
    @AppStorage("reader.prefetchCount", store: ReaderPreferenceDefaults.store) private var prefetchCount = ReaderLoadPolicy.defaultPrefetchCount
    @AppStorage("reader.downloadConcurrency", store: ReaderPreferenceDefaults.store) private var downloadConcurrency = ReaderLoadPolicy.defaultConcurrency
    @State private var pageSizes: [Int: CGSize] = [:]
    @State private var progressHUD = false
    @State private var progressRevision = UUID()
    private var direction: ReaderDirection {
        get { ReaderDirection(rawValue: storedDirection) ?? .leftToRight }
        nonmutating set { storedDirection = newValue.rawValue }
    }
    private var readingAnchor: UnitPoint {
        // A stable tracking anchor also identifies short pages at clamped edges.
        // Direction-specific boundary alignment belongs to the snapping policy.
        direction.horizontal ? .center : .top
    }
    private var motionReduced: Bool { reduceMotion || (AppMode.qa && ProcessInfo.processInfo.arguments.contains("--qa-reduce-motion")) }
    @State private var progressTarget = 1.0
    @State private var pageZoomed = false
    @State private var settings = false
    @State private var detailsShowing = false
    @State private var immersive = Self.usesAutomaticImmersion
    @State private var readerTouched = false
    @State private var controlsIdleRevision = UUID()
    @State private var jump = false
    @State private var jumpText = ""
    @State private var findingPage = false
    @State private var holdingPosition = false
    @State private var userScrolling = false
    @State private var draggingCanvas = false
    @State private var scrollEndTask: Task<Void, Never>?
    @State private var contentOrigin: CGPoint = .zero
    @State private var visiblePageFrames: [Int: CGRect] = [:]
    @State private var seekRevision = UUID()
    @State private var slideProgress: CGFloat = 1
    @State private var slideForward = true
    @State private var slideRevision = UUID()
    @State private var slideTask: Task<Void, Never>?
    @State private var historyCheckpoint: ReaderHistoryCheckpoint?
    @StateObject private var favoriteObservation = GalleryFavoriteObservation()
    @State private var favoriteEditing = false
    @State private var favoriteAfterSettings = false
    @State private var singleTurn = ReaderSinglePageTurn()
    @State private var decodeFailures: [Int: URL] = [:]
    @State private var decodeRetryIDs: [Int: UUID] = [:]
    @State private var presentations: [Int: ImageCanvasPresentation] = [:]
    @State private var decodedFiles: [Int: URL] = [:]
    @State private var singleMetadataTask: Task<Void, Never>?
    @State private var singleMetadataRevision = UUID()
    @State private var singleMetadataAttemptedTarget: Int?
    @State private var singleMetadataError: String?
    @State private var automaticMetadataTask: Task<Void, Never>?
    @State private var automaticMetadataCursor: URL?
    @State private var automaticMetadataRevision = UUID()
    @State private var ignoreCanvasTapUntil = Date.distantPast
    @State private var lastDragEvidence = "none"
    @State private var lastReleaseEvidence = "none"
    @GestureState private var singleFingerDown = false
    @State private var viewportFrame: CGRect = .zero
    private struct ReadingContext: Equatable {
        let id = UUID()
        var generation: UUID
        var owner: String
    }
    @State private var readingContext: ReadingContext?
    private var readerGesturesActive: Bool {
        readingContext != nil && scenePhase == .active && !settings && !detailsShowing && !favoriteEditing && !jump
    }
    private var controlsIdleID: UUID? {
        guard Self.usesAutomaticImmersion, !immersive, !voiceOverEnabled, readerGesturesActive,
              !readerTouched, !progressHUD, !findingPage, !userScrolling, !draggingCanvas, !singleTurn.isDraggingOrSettling else { return nil }
        return controlsIdleRevision
    }
    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
            VStack(spacing: 0) {
                if let error = model.error, model.pages.isEmpty || mode == ReaderMode.continuous.rawValue { StatusMessage(title: error) { Task { guard let context = readingContext, isCurrent(context) else { return }; await model.load(gallery: gallery, offline: offline, session: session, library: library) } } }
                if model.loading && model.pages.isEmpty { Spacer(); ProgressView(); Spacer() }
                GeometryReader { geometry in
                    ZStack {
                        if mode == ReaderMode.continuous.rawValue {
                            continuousPages
                            if model.pages.isEmpty && immersive {
                                Color.clear.contentShape(Rectangle()).onTapGesture { immersive = false }
                            }
                        } else {
                            singlePage.simultaneousGesture(singleDragGesture(size: geometry.size), including: pageZoomed ? .subviews : .all)
                        }
                    }
                    .contentShape(Rectangle())
                    .onAppear { updateViewportFrame(geometry.frame(in: .global)) }
                    .onChange(of: geometry.frame(in: .global)) { _, frame in updateViewportFrame(frame) }
                    .accessibilityAction(named: Text("下一页")) { changePage(by: 1) }
                    .accessibilityAction(named: Text("上一页")) { changePage(by: -1) }
                    .accessibilityAction(named: Text(immersive ? "显示阅读控件" : "隐藏阅读控件")) { toggleImmersive() }
                }
            }
                .ignoresSafeArea(.container)
                .background(Color.black)
                .toolbar(.hidden, for: .navigationBar)
                .preferredColorScheme(.dark)
                .task {
                    media.setForeground(scenePhase != .background)
                    let context = ReadingContext(generation: session.generation, owner: library.owner)
                    readingContext = context
                    library.pinOfflineReader(gallery.ref, context: context.id)
                    let expectedSession = session, expectedLibrary = library, expectedGallery = gallery
                    historyCheckpoint = ReaderHistoryCheckpoint(isCurrent: { [weak expectedSession, weak expectedLibrary] in
                        expectedSession?.generation == context.generation && expectedLibrary?.owner == context.owner
                    }, persist: { [weak expectedLibrary] page in
                        expectedLibrary?.remember(expectedGallery, page: page)
                    })
                    automaticMetadataCursor = nil
                    if AppMode.qa, ProcessInfo.processInfo.arguments.contains("--qa-reader-transition") {
                        mode = ReaderMode.singlePage.rawValue
                        if let value = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--qa-prefetch=") })?.split(separator: "=").last.flatMap({ Int($0) }), (0...ReaderLoadPolicy.maxPrefetchCount).contains(value) { prefetchCount = value }
                        if let value = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--qa-concurrency=") })?.split(separator: "=").last.flatMap({ Int($0) }), (2...ReaderLoadPolicy.maxConcurrency).contains(value) { downloadConcurrency = value }
                    }
                    await model.load(gallery: gallery, offline: offline, session: session, library: library, openingDetail: openingDetail)
                    guard !Task.isCancelled, isCurrent(context) else { return }
                    let desired = library.snapshot.history.first(where: { $0.id == gallery.id })?.page ?? 1
                    await seek(desired)
                }
                .onDisappear(perform: closeReading)
                .onChange(of: scenePhase) { _, phase in
                    if phase != .active { historyCheckpoint?.flush() }
                    if phase == .background { media.setForeground(false) }
                    if phase == .active { media.setForeground(true); updateMedia() }
                }
                .onChange(of: current) { _, value in
                    progressTarget = Double(value); pageZoomed = false
                    pageSizes = pageSizes.filter { abs($0.key - value) <= 2 }
                    presentations = presentations.filter { abs($0.key - value) <= 1 }
                    decodeFailures = decodeFailures.filter { abs($0.key - value) <= 1 }
                    decodeRetryIDs = decodeRetryIDs.filter { abs($0.key - value) <= 1 }
                    decodedFiles = decodedFiles.filter { abs($0.key - value) <= 1 }
                    updateMedia()
                }
                .onChange(of: model.pages) { _, _ in updateMedia() }
                .onChange(of: model.loading) { _, loading in if !loading { updateMedia() } }
                .onChange(of: media.files) { _, files in
                    presentations = presentations.filter { files[$0.key] == $0.value.file && abs($0.key - current) <= 1 }
                    decodeFailures = decodeFailures.filter { files[$0.key] == $0.value }
                    if ReaderNetworkMetrics.enabled { decodedFiles = decodedFiles.filter { files[$0.key] == $0.value && abs($0.key - current) <= 1 } }
                    if let context = readingContext, isCurrent(context) { updatePinnedFiles(context) }
                    if AppMode.qa, singleTurn.isDraggingOrSettling, let preview = singleTurn.dragPreview {
                        lastDragEvidence = "\(current)+\(preview);offset=\(Int(abs(singleTurn.dragOffset)));neighborFile=\(files[preview] != nil)"
                    }
                }
                .onChange(of: prefetchCount) { _, value in
                    if !(0...ReaderLoadPolicy.maxPrefetchCount).contains(value) { prefetchCount = ReaderLoadPolicy.clampedPrefetchCount(value) }
                    if value == 0 {
                        automaticMetadataRevision = UUID()
                        automaticMetadataTask?.cancel(); automaticMetadataTask = nil; automaticMetadataCursor = nil
                    }
                    updateMedia()
                }
                .onChange(of: downloadConcurrency) { _, value in
                    if !(2...ReaderLoadPolicy.maxConcurrency).contains(value) { downloadConcurrency = ReaderLoadPolicy.clampedConcurrency(value) }
                    updateMedia()
                }
                .onChange(of: media.prefetchPaused) { _, paused in
                    if paused {
                        if !model.hasForegroundMetadataDemand {
                            automaticMetadataRevision = UUID()
                            automaticMetadataTask?.cancel(); automaticMetadataTask = nil; automaticMetadataCursor = nil
                        }
                    } else { updateMedia() }
                }
                .onChange(of: findingPage) { _, finding in if !finding { updateMedia() } }
                .onChange(of: pageZoomed) { _, zoomed in if zoomed { stopTrackingScroll(); cancelSingleDrag() } }
                .onChange(of: model.total) { _, total in if let total { progressTarget = min(progressTarget, Double(max(1, total))) } }
                .onChange(of: mode) { _, newMode in
                    progressHUD = false; pageZoomed = false; cancelPageAnimation()
                    if newMode == ReaderMode.continuous.rawValue { let page = current; Task { await seek(page) } }
                }
                .onChange(of: storedDirection) { _, _ in
                    progressHUD = false; pageZoomed = false; cancelPageAnimation()
                    let page = current; Task { await seek(page) }
                }
                .onChange(of: readerGesturesActive) { _, active in
                    if active { finishPendingTurnIfReady() }
                    else {
                        readerTouched = false
                        controlsIdleRevision = UUID()
                    }
                }
                .onChange(of: settings) { _, shown in if shown { progressHUD = false; stopTrackingScroll(); cancelSingleDrag() } }
                .onChange(of: detailsShowing) { _, shown in if shown { progressHUD = false; stopTrackingScroll(); cancelSingleDrag() } }
                .onChange(of: singleFingerDown) { _, down in
                    if !down {
                        let intent = seekRevision
                        Task {
                            await Task.yield()
                            guard seekRevision == intent, !singleFingerDown else { return }
                            finishSingleDrag(commit: false)
                        }
                    }
                }
                .alert("跳转到页码", isPresented: $jump) { TextField("页码", text: $jumpText).keyboardType(.numberPad); Button("跳转") { if let page = Int(jumpText) { Task { await seek(page) } } }; Button("取消", role: .cancel) { } } message: { Text("动图完整播放，按一张图片计算一页。") }
                .overlay(alignment: .top) { if findingPage { ProgressView("正在定位页面").font(.caption).padding(8).allowsHitTesting(false) } }
                .sheet(isPresented: $settings, onDismiss: {
                    if favoriteAfterSettings { favoriteAfterSettings = false; favoriteEditing = true }
                }) { readerSettings }
                .sheet(isPresented: $detailsShowing) {
                    NavigationStack {
                        GalleryDetailView(gallery: gallery, onResumeReading: { detailsShowing = false }, searchTarget: searchTarget)
                    }
                    .galleryDetailPresentations()
                    .statusBarHidden(false)
                    .accessibilityIdentifier("reader.details")
                }
                if !immersive { readerHeader }
            }
            .overlay(alignment: .bottom) {
                VStack(spacing: FeedChrome.panelSpacing) {
                    if let target = singleTurn.pendingPage { pendingTurnStatus(target) }
                    if !immersive { readerControls }
                }
            }
        }
        .statusBarHidden(immersive && !settings && !detailsShowing)
        .persistentSystemOverlays(immersive ? .hidden : .automatic)
        .background {
            ReaderGestureBridge(tracksActivity: Self.usesAutomaticImmersion && readerGesturesActive,
                                allowsBack: readerGesturesActive && !pageZoomed && !progressHUD,
                                onActivity: { active in
                                    guard readerGesturesActive else { return }
                                    readerTouched = active
                                    if !active { controlsIdleRevision = UUID() }
                                }, onBack: { dismiss() })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
        }
        .task(id: controlsIdleID) {
            guard let id = controlsIdleID else { return }
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            guard !Task.isCancelled, controlsIdleID == id else { return }
            withAnimation(motionReduced ? nil : .easeOut(duration: 0.16)) { immersive = true }
        }
        .onDisappear { favoriteObservation.cancel() }
        .onAppear(perform: bindFavoriteState)
        .onChange(of: GalleryFavoriteScope(gallery, session)) { _, _ in bindFavoriteState() }
        .onReceive(session.favoriteStateCache.$revision) { _ in favoriteObservation.syncFromCache() }
        .sheet(isPresented: $favoriteEditing) {
            GalleryFavoriteEditorView(gallery: gallery, session: session, preparation: favoriteObservation.preparation(favoriteClient(for: gallery, session: session), reference: gallery.ref)) { favoriteObservation.accept($0, form: $1) }
        }
        .overlay {
            if progressHUD, let total = model.total {
                Text("\(Int(progressTarget.rounded())) / \(total)")
                    .font(.subheadline.weight(.semibold).monospacedDigit()).foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(FloatingChrome.readerBackground, in: AppShape.control)
                    .accessibilityIdentifier("reader.progress.hud")
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if AppMode.qa || ReaderNetworkMetrics.enabled {
                Text("QA").font(.system(size: 1)).foregroundStyle(.clear).frame(width: 1, height: 1)
                    .accessibilityIdentifier(AppMode.qa ? "reader.cache.qa" : "reader.metrics.state").accessibilityValue(cacheDiagnostic).allowsHitTesting(false)
                    .background { if AppMode.qa { ReaderSystemChromeProbe().frame(width: 1, height: 1).allowsHitTesting(false) } }
            }
        }
    }

    private var continuousPages: some View {
        GeometryReader { geometry in
            ScrollView(direction.axis) {
                if direction.horizontal {
                    LazyHStack(spacing: 2) { continuousPageContent(geometry: geometry) }
                        .scrollTargetLayout()
                        .background { scrollOriginReporter }
                } else {
                    LazyVStack(spacing: 2) { continuousPageContent(geometry: geometry) }
                        .scrollTargetLayout()
                        .background { scrollOriginReporter }
                }
            }
            .contentMargins(.all, 0, for: .scrollContent)
            .scrollDisabled(pageZoomed)
            .scrollTargetBehavior(ReaderSnappingBehavior(ranges: visiblePageFrames.compactMap { index, rect in
                guard pageSizes[index] != nil else { return nil }
                return rect.offsetBy(dx: -contentOrigin.x, dy: -contentOrigin.y)
            }, direction: direction, zoomed: pageZoomed))
            .coordinateSpace(name: "reader.canvas")
            .scrollPosition(id: $scrollPosition, anchor: readingAnchor)
            .simultaneousGesture(DragGesture(minimumDistance: 5)
                .onChanged { value in
                    guard !pageZoomed else { return }
                    if isEdgeBackDrag(value) {
                        stopTrackingScroll()
                        return
                    }
                    scrollEndTask?.cancel()
                    userScrolling = true
                    draggingCanvas = true
                }
                .onEnded { _ in draggingCanvas = false; finishScrollWhenStable() })
            .onPreferenceChange(ReaderContentOrigin.self) { origin in contentOrigin = origin; if userScrolling && !draggingCanvas { finishScrollWhenStable() } }
            .onPreferenceChange(ReaderPageFrames.self) { frames in visiblePageFrames = frames }
            .onChange(of: scrollPosition) { _, page in if userScrolling && !pageZoomed && !findingPage && !holdingPosition, let page { current = page; remember() } }
        }
    }

    private var scrollOriginReporter: some View {
        GeometryReader { geometry in
            Color.clear.preference(key: ReaderContentOrigin.self, value: geometry.frame(in: .named("reader.canvas")).origin)
        }
    }

    private func stopTrackingScroll() {
        scrollEndTask?.cancel(); scrollEndTask = nil; userScrolling = false; draggingCanvas = false
    }

    private func finishScrollWhenStable() {
        guard userScrolling, !draggingCanvas else { return }
        scrollEndTask?.cancel()
        scrollEndTask = Task {
            // Geometry keeps extending this window during inertial scrolling.
            // Once motion settles, later image-size updates cannot write history.
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }
            userScrolling = false; scrollEndTask = nil
        }
    }

    @ViewBuilder private func continuousPageContent(geometry: GeometryProxy) -> some View {
        let ordered = direction.reverseOrder ? Array(model.pages.reversed()) : model.pages
        let expectedGeneration = session.generation
        let expectedOwner = library.owner
        let expectedContext = readingContext
        if direction.reverseOrder && model.next != nil { loadMorePagesButton }
        ForEach(ordered) { page in
            let extent = ReaderPageSizing.extent(imageSize: pageSizes[page.index], crossAxisExtent: direction.horizontal ? geometry.size.height : geometry.size.width, direction: direction)
            ReaderPage(page: page, active: abs(page.index - current) <= 1,
                       file: media.files[page.index], failure: media.failures[page.index],
                       loading: media.inflight[page.index] != nil, progress: media.progress[page.index], animated: page.index == current,
                       retry: { media.retry(page: page.index) }, interactions: canvasInteractions,
                       onZoomChanged: { zoomed in
                           guard page.index == self.current,
                                 let expectedContext, self.readingContext == expectedContext,
                                 expectedGeneration == session.generation, expectedOwner == library.owner,
                                 isCurrent(expectedContext) else { return }
                           pageZoomed = zoomed
                       },
                       onImageSizeChanged: { size in
                           guard let expectedContext, self.readingContext == expectedContext,
                                 expectedGeneration == session.generation, expectedOwner == library.owner,
                                 isCurrent(expectedContext) else { return }
                           pageSizes[page.index] = size
                       }, onPresentation: { value in
                           guard let expectedContext, isCurrent(expectedContext), media.files[page.index] == value.file else { return }
                           recordDecoded(page.index, file: value.file)
                       })
                .id("\(page.index):\(storedDirection)")
                .frame(width: direction.horizontal ? extent : geometry.size.width,
                       height: direction.horizontal ? geometry.size.height : extent)
                .background { GeometryReader { proxy in Color.clear.preference(key: ReaderPageFrames.self, value: [page.index: proxy.frame(in: .named("reader.canvas"))]) } }
                .accessibilityElement(children: .contain).accessibilityIdentifier("reader.page.frame")
                .accessibilityValue(AppMode.qa ? "page \(page.index)" : "第 \(page.index) 页")
                .id(page.index)
        }
        if !direction.reverseOrder && model.next != nil { loadMorePagesButton }
        if model.loading { ProgressView().tint(.white).padding() }
    }

    private var loadMorePagesButton: some View {
        Button("继续加载后续页面") {
            Task { await loadNextPagesKeepingPosition() }
        }
        .disabled(model.loading)
        .padding(24).foregroundStyle(.white)
        .accessibilityIdentifier("reader.load-more")
    }

    private var singlePage: some View {
        GeometryReader { geometry in
            let travel = ReaderSlidePolicy.travel(direction: direction, forward: slideForward, size: geometry.size)
            let translation = singleTurn.isDraggingOrSettling ? singleTurn.dragOffset : (direction.horizontal ? travel.width : travel.height) * (1 - slideProgress)
            ZStack {
                Color.black
                // A page keeps its Canvas while its role changes from neighboring
                // preview to current. Position depends on page order, never on
                // the sign of an offset that is animating back to zero.
                ForEach(singlePageIndices, id: \.self) { index in
                    let offset = ReaderDragPolicy.pageOffset(index: index, current: current, direction: direction, size: geometry.size, translation: translation)
                    singlePageContent(index)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .offset(x: offset.width, y: offset.height)
                        .allowsHitTesting(index == current && !singleTurn.isDraggingOrSettling)
                        .accessibilityHidden(index != current)
                }
            }
            .clipped()
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("reader.single.canvas")
            .accessibilityValue(AppMode.qa ? "page \(current); \(singleTurn.isDraggingOrSettling ? "dragging" : (singleTurn.pendingPage != nil ? "waiting" : (slideProgress < 1 ? "transitioning" : "settled"))); reduced=\(motionReduced); lastDrag=\(lastDragEvidence); release=\(lastReleaseEvidence)" : "第 \(current) 页")
        }
    }

    private var singlePageIndices: [Int] {
        let last = max(current, model.total ?? model.pages.last?.index ?? (model.next == nil ? current : current + 1))
        return Array(max(1, current - 1)...min(last, current + 1))
    }

    @ViewBuilder private func singlePageContent(_ index: Int) -> some View {
        if let page = model.pages.first(where: { $0.index == index }) {
            pageCanvas(page)
        } else {
            ReaderLoadingPage(index: index, metadata: true,
                              failure: offline ? "离线副本中没有这一页。" : (index == current ? singleMetadataError : nil),
                              retry: offline || model.next == nil ? nil : retrySinglePageMetadata,
                              interactions: canvasInteractions)
        }
    }

    private func pageCanvas(_ page: GalleryPage) -> some View {
        let expected = readingContext
        return ReaderPage(page: page, active: true, file: media.files[page.index],
                          failure: media.failures[page.index], loading: media.inflight[page.index] != nil, progress: media.progress[page.index],
                          animated: page.index == current, retry: { media.retry(page: page.index) }, interactions: canvasInteractions, onZoomChanged: { value in
            guard page.index == current, let expected, isCurrent(expected) else { return }
            pageZoomed = value
        }, onImageSizeChanged: { size in
            guard let expected, isCurrent(expected), abs(page.index - current) <= 1 else { return }
            pageSizes[page.index] = size
        }, onPresentation: { value in
            guard let expected, isCurrent(expected), abs(page.index - current) <= 1,
                  media.files[page.index] == value.file else { return }
            presentations[page.index] = value
            decodeFailures[page.index] = nil
            recordDecoded(page.index, file: value.file)
            finishPendingTurnIfReady()
        }, onDecodeFailure: { file in
            guard let expected, isCurrent(expected), abs(page.index - current) <= 1,
                  media.files[page.index] == file else { return }
            presentations[page.index] = nil
            decodeFailures[page.index] = file
        })
        .id("\(page.index):\(storedDirection):\(decodeRetryIDs[page.index]?.uuidString ?? "")")
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(media.files[page.index] == nil ? "reader.page.loading.\(page.index)" : "reader.page.frame")
    }

    private func recordDecoded(_ page: Int, file: URL) {
        guard ReaderNetworkMetrics.enabled, decodedFiles[page] != file else { return }
        decodedFiles[page] = file
        ReaderNetworkMetrics.record(UUID(), phase: "decoded", page: page)
    }

    private func displayPage(_ page: Int, animatedTurn: Bool) {
        cancelSingleDrag(updateDemand: false)
        let old = current
        slideTask?.cancel(); slideTask = nil; slideRevision = UUID()
        let animate = animatedTurn && mode == ReaderMode.singlePage.rawValue && !motionReduced && old != page
        slideForward = page > old
        var transaction = Transaction(); transaction.disablesAnimations = true
        withTransaction(transaction) { slideProgress = animate ? 0 : 1; current = page }
        updateMedia()
        guard animate, let context = readingContext else { return }
        let token = slideRevision
        slideTask = Task {
            await Task.yield()
            guard !Task.isCancelled, token == slideRevision, isCurrent(context), current == page else { return }
            withAnimation(.easeOut(duration: 0.22)) { slideProgress = 1 }
            try? await Task.sleep(nanoseconds: 240_000_000)
            guard !Task.isCancelled, token == slideRevision, isCurrent(context) else { return }
            slideTask = nil
            historyCheckpoint?.flush()
        }
    }

    private func cancelPageAnimation(updateDemand: Bool = true) {
        cancelSingleDrag(updateDemand: updateDemand)
        slideTask?.cancel(); slideTask = nil; slideRevision = UUID()
        var transaction = Transaction(); transaction.disablesAnimations = true
        withTransaction(transaction) { slideProgress = 1 }
    }

    private var cacheDiagnostic: String {
        let readyFiles = media.files.keys.sorted().map(String.init).joined(separator: ",")
        let decodedPages = decodedFiles.keys.sorted().map(String.init).joined(separator: ",")
        let canvasIdentities = presentations.sorted { $0.key < $1.key }.map { page, presentation in
            "\(page):\(presentation.canvasIdentity):\(presentation.loadCount)"
        }.joined(separator: ",")
        return [
            "current=\(current)",
            "prefetch=\(media.prefetchCount)",
            "files=\(readyFiles)",
            "tasks=\(media.inflight.count)",
            "metadataCalls=\(model.qaMetadataCalls)",
            "metadataTask=\(singleMetadataTask != nil)",
            "automaticMetadata=\(automaticMetadataTask != nil)",
            "metadataLoading=\(model.loading)",
            "decoded=\(decodedPages)",
            "concurrency=\(downloadConcurrency)",
            "presentations=\(canvasIdentities)",
        ].joined(separator: ";")
    }

    private func closeReading() {
        historyCheckpoint?.flush()
        historyCheckpoint = nil
        let context = readingContext
        readingContext = nil
        cancelSingleDrag(updateDemand: false)
        singleMetadataRevision = UUID()
        singleMetadataTask?.cancel(); singleMetadataTask = nil
        automaticMetadataTask?.cancel(); automaticMetadataTask = nil
        scrollEndTask?.cancel(); scrollEndTask = nil
        slideTask?.cancel()
        seekRevision = UUID()
        media.reset()
        presentations = [:]
        decodedFiles = [:]
        decodeFailures = [:]
        decodeRetryIDs = [:]
        userScrolling = false
        draggingCanvas = false
        progressHUD = false
        model.cancel()
        if let context {
            MediaRepository.shared.releasePinnedFiles(context: context.id)
            library.unpinOfflineReader(context: context.id)
        }
    }

    private func updateMedia() {
        guard let context = readingContext, isCurrent(context) else { return }
        let scope = ReaderMediaScope(galleryID: gallery.id, owner: context.owner,
                                     generation: context.generation, context: context.id)
        media.update(scope: scope, pages: model.pages, current: current,
                     prefetchCount: prefetchCount, downloadConcurrency: downloadConcurrency,
                     preview: singleTurn.requestedNeighbor,
                     validateCachedFile: { FileManager.default.fileExists(atPath: $0.path) },
                     demandLoader: { page, demand in
            try await loadMedia(page, demand: demand, context: context)
        }, isCurrent: { isCurrent(context) })
        updatePinnedFiles(context)
        requestSingleMetadataIfNeeded(context)
        requestNextMetadataIfNeeded(context)
    }

    private func loadMedia(_ page: GalleryPage, demand: MediaRequestDemand, context: ReadingContext) async throws -> URL {
        if AppMode.qa {
            if ProcessInfo.processInfo.arguments.contains("--qa-reader-prefetch-timeout"), page.index == 2, demand.priority == .prefetch {
                throw RequestFailure.transport(.media, URLError.timedOut.rawValue)
            }
            let largeWindowFixture = ProcessInfo.processInfo.arguments.contains("--qa-reader-large-window")
            if (page.index > 1 || largeWindowFixture), let delay = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--qa-transfer-ms=") })?.split(separator: "=").last.flatMap({ UInt64($0) }) {
                if ProcessInfo.processInfo.arguments.contains("--qa-transfer-progress") {
                    demand.reportProgress(MediaLoadProgress(phase: .transferring, completedBytes: 25_000, totalBytes: 100_000))
                }
                try await Task.sleep(nanoseconds: min(delay, 15_000) * 1_000_000)
            }
            if ProcessInfo.processInfo.arguments.contains("--qa-media-delayed"), demand.priority == .prefetch {
                try await Task.sleep(nanoseconds: 350_000_000)
            }
            return page.url
        }
        if page.url.isFileURL { return page.url }
        return try await ReaderNetworkMetrics.measure(demand.id, phase: "pipeline", page: page.index) {
            try await PageMediaLoader.readerFile(page, session: session, owner: context.owner, request: demand,
                                                 isCurrent: { isCurrent(context) })
        }
    }

    private func updatePinnedFiles(_ context: ReadingContext) {
        guard isCurrent(context) else { return }
        let files = Set(media.files.filter { abs($0.key - current) <= 1 }.map(\.value))
        MediaRepository.shared.setPinnedFiles(files, owner: context.owner, context: context.id)
    }

    private func requestNextMetadataIfNeeded(_ context: ReadingContext) {
        guard scenePhase != .background, !offline, prefetchCount > 0, !media.prefetchPaused, !findingPage, !model.loading, model.error == nil,
              automaticMetadataTask == nil, singleMetadataTask == nil,
              let cursor = model.next, cursor != automaticMetadataCursor,
              let last = model.pages.last?.index, last - current <= prefetchCount + 1 else { return }
        automaticMetadataCursor = cursor
        let revision = UUID(); automaticMetadataRevision = revision
        automaticMetadataTask = Task {
            await loadNextPagesKeepingPosition(priority: .prefetch)
            guard automaticMetadataRevision == revision, isCurrent(context), !Task.isCancelled else { return }
            automaticMetadataTask = nil
            updateMedia()
        }
    }

    private var neededSingleMetadataTarget: Int? {
        guard mode == ReaderMode.singlePage.rawValue else { return nil }
        if !model.pages.contains(where: { $0.index == current }) { return current }
        if let target = singleTurn.requestedNeighbor, !model.pages.contains(where: { $0.index == target }) { return target }
        return nil
    }

    private func requestSingleMetadataIfNeeded(_ context: ReadingContext) {
        let target = neededSingleMetadataTarget
        if target != nil { model.promotePendingMetadata() }
        if target != singleMetadataAttemptedTarget {
            singleMetadataRevision = UUID(); singleMetadataTask?.cancel(); singleMetadataTask = nil
            singleMetadataAttemptedTarget = nil; singleMetadataError = nil
        }
        guard !offline, let target, singleMetadataTask == nil, !model.loading,
              singleMetadataAttemptedTarget != target else { return }
        guard model.next != nil else {
            if !model.pages.isEmpty { singleMetadataError = "未能取得第 \(target) 页的页面信息。" }
            return
        }
        singleMetadataAttemptedTarget = target
        let revision = UUID(); singleMetadataRevision = revision
        singleMetadataTask = Task {
            var attempts = 0
            while !model.pages.contains(where: { $0.index == target }), model.next != nil, attempts < 100 {
                guard !Task.isCancelled, isCurrent(context), singleMetadataRevision == revision,
                      neededSingleMetadataTarget == target else { return }
                if model.loading { try? await Task.sleep(nanoseconds: 20_000_000); continue }
                let count = model.pages.count, cursor = model.next
                attempts += 1
                await model.more(gallery: gallery, session: session, library: library)
                guard !Task.isCancelled, isCurrent(context), singleMetadataRevision == revision,
                      neededSingleMetadataTarget == target || model.pages.contains(where: { $0.index == target }) else { return }
                if model.pages.contains(where: { $0.index == target }) { break }
                if model.error != nil || model.pages.count == count || model.next == cursor {
                    singleMetadataError = model.error ?? "未能取得第 \(target) 页的页面信息，请重试。"
                    break
                }
            }
            guard !Task.isCancelled, isCurrent(context), singleMetadataRevision == revision else { return }
            singleMetadataTask = nil
            if model.pages.contains(where: { $0.index == target }) { singleMetadataError = nil; remember() }
            else if singleMetadataError == nil { singleMetadataError = "未能取得第 \(target) 页的页面信息，请重试。" }
            updateMedia()
        }
    }

    private func pendingTurnStatus(_ target: Int) -> some View {
        let needsMetadata = neededSingleMetadataTarget == target
        let failed = media.failures[target] != nil || decodeFailures[target] != nil ||
            (needsMetadata && (singleMetadataError != nil || offline))
        let canRetry = failed && (!needsMetadata || (!offline && model.next != nil))
        return HStack(spacing: FeedChrome.controlSpacing) {
            if failed {
                Text("第 \(target) 页加载失败，当前页已保留")
                if canRetry {
                    Button("重试") { retryPendingTurn(target) }
                        .frame(minHeight: FeedChrome.rowHeight)
                        .accessibilityIdentifier("reader.page.retry.\(target)")
                }
            } else {
                ProgressView().tint(.white)
                Text("正在加载第 \(target) 页…")
            }
        }
        .font(.caption)
        .padding(.horizontal, FeedChrome.contentSpacing)
        .frame(minHeight: FeedChrome.compactFormRowHeight)
        .foregroundStyle(.white)
        .background(FloatingChrome.readerBackground, in: AppShape.control)
        .padding(.horizontal, FeedChrome.contentInset)
        .padding(.bottom, immersive ? FeedChrome.contentSpacing : 0)
        .allowsHitTesting(canRetry)
    }

    private func retryPendingTurn(_ target: Int) {
        guard singleTurn.pendingPage == target else { return }
        if decodeFailures.removeValue(forKey: target) != nil {
            decodeRetryIDs[target] = UUID()
        } else if media.failures[target] != nil {
            media.retry(page: target)
        } else {
            retrySinglePageMetadata()
        }
    }

    private func retrySinglePageMetadata() {
        singleMetadataAttemptedTarget = nil
        singleMetadataError = nil
        updateMedia()
    }

    private func isPagePresented(_ page: Int) -> Bool {
        guard let file = media.files[page] else { return false }
        return presentations[page]?.file == file
    }

    private func finishPendingTurnIfReady() {
        guard let target = singleTurn.pendingPage, !singleTurn.isDraggingOrSettling, !pageZoomed, !progressHUD,
              readerGesturesActive, mode == ReaderMode.singlePage.rawValue,
              let context = readingContext, isCurrent(context), isPagePresented(target) else { return }
        displayPage(target, animatedTurn: true)
        syncSinglePagePosition()
        remember()
    }

    private func syncSinglePagePosition() {
        scrollPosition = current
        progressTarget = Double(current)
    }

    private var readerControls: some View {
        HStack(spacing: FeedChrome.panelSpacing) {
            if let total = model.total, total > 1 {
                Slider(value: $progressTarget, in: 1...Double(total)) { editing in
                    if editing {
                        cancelSingleDrag()
                        progressRevision = UUID()
                        progressHUD = true
                    } else {
                        let target = Int(progressTarget.rounded()), token = progressRevision
                        Task { await seek(target); if progressRevision == token { progressHUD = false } }
                    }
                }
                .frame(minWidth: 56, maxWidth: .infinity, minHeight: 44)
                .accessibilityLabel("阅读进度")
                .accessibilityValue("第 \(current) 页，共 \(total) 页")
                .accessibilityIdentifier("reader.progress")
            } else {
                Spacer(minLength: 0)
            }
            Button { jumpText = String(current); jump = true } label: {
                Text("\(current) / \(model.total.map(String.init) ?? "未知")")
                    .font(.caption.weight(.semibold).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.65)
                    .foregroundStyle(.white).padding(.horizontal, 5)
                    .frame(minWidth: 54, minHeight: 44).fixedSize(horizontal: true, vertical: false)
                    .contentShape(Rectangle())
            }
            .accessibilityIdentifier("reader.page")
            .accessibilityHint("跳转到指定页码")
            Button { settings = true } label: {
                Image(systemName: "ellipsis").font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white).frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .accessibilityLabel("阅读设置").accessibilityIdentifier("reader.settings")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, FeedChrome.panelSpacing)
        .background { readerPanelSurface }
        .frame(maxWidth: 460)
        .padding(.horizontal, FeedChrome.contentInset)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reader.controls.compact")
    }

    private var readerSettings: some View {
        let symbol = if case .favorited = favoriteObservation.state { "star.fill" } else { "star" }
        return ReaderSettingsPanel(mode: $mode, direction: Binding(get: { direction }, set: { direction = $0 }),
                                   favoriteSymbol: symbol, favoriteValue: favoriteAccessibilityValue,
                                   readLater: library.containsReadLater(gallery),
                                   onFavorite: { favoriteAfterSettings = true; settings = false },
                                   onReadLater: { library.toggleReadLater(gallery) })
    }
    private func bindFavoriteState() {
        favoriteObservation.bind(favoriteClient(for: gallery, session: session), reference: gallery.ref,
                                 cache: session.favoriteStateCache, scope: GalleryFavoriteScope(gallery, session))
    }
    private var favoriteAccessibilityValue: String {
        let value = favoriteStateDescription(favoriteObservation.state) + (favoriteObservation.phase.map { "，" + $0.label } ?? "")
        if AppMode.qa && ProcessInfo.processInfo.arguments.contains("--qa-favorite-counters") {
            return value + ";" + NativeFavoritesQA.counts(reference: gallery.ref)
        }
        return value
    }

    private var closeButton: some View {
        Button { dismiss() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: FeedChrome.rowHeight, height: FeedChrome.rowSurfaceHeight)
                .background(FloatingChrome.readerBackground, in: AppShape.control)
                .overlay { AppShape.control.strokeBorder(.white.opacity(0.08), lineWidth: 0.5).allowsHitTesting(false) }
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("关闭")
        .accessibilityIdentifier("reader.close")
    }

    private var readerHeader: some View {
        HStack(spacing: FeedChrome.panelSpacing) {
            closeButton
            Text(gallery.title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, FeedChrome.controlSpacing)
                .frame(height: FeedChrome.rowSurfaceHeight)
                .background(FloatingChrome.readerBackground, in: AppShape.control)
                .overlay { AppShape.control.strokeBorder(.white.opacity(0.08), lineWidth: 0.5).allowsHitTesting(false) }
        }
        .frame(height: 44)
        .padding(.horizontal, FeedChrome.panelSpacing)
        .background { readerPanelSurface }
        .frame(maxWidth: 460)
        .padding(.horizontal, FeedChrome.contentInset)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reader.header")
    }

    private var readerPanelSurface: some View {
        FeedChrome.panelShape.fill(FloatingChrome.readerBackground)
            .overlay { FeedChrome.panelShape.strokeBorder(.white.opacity(0.08), lineWidth: 0.5) }
            .frame(height: FeedChrome.singleRowPanelHeight)
            .allowsHitTesting(false)
    }

    private func canvasTapped(_ point: CGPoint) {
        guard !pageZoomed, !singleTurn.isDraggingOrSettling, Date() >= ignoreCanvasTapUntil,
              let context = readingContext, isCurrent(context), viewportFrame.width > 0 else { return }
        switch ReaderTapPolicy.action(at: point, in: viewportFrame, direction: direction,
                                      mode: ReaderMode(rawValue: mode) ?? .continuous) {
        case .previous: changePage(by: -1)
        case .next: changePage(by: 1)
        case .center: if immersive { immersive = false }
        case nil: break
        }
    }

    private var canvasInteractions: CanvasInteractions {
        .init(singleTap: canvasTapped, doubleTap: canvasDoubleTapped, longPress: toggleImmersive)
    }

    private func canvasDoubleTapped(_ point: CGPoint) -> Bool {
        guard !singleTurn.isDraggingOrSettling, !settings, !detailsShowing, Date() >= ignoreCanvasTapUntil,
              let context = readingContext, isCurrent(context),
              ReaderTapPolicy.action(at: point, in: viewportFrame, direction: direction,
                                     mode: ReaderMode(rawValue: mode) ?? .continuous) == .center else { return false }
        detailsShowing = true
        return true
    }

    private func toggleImmersive() {
        guard !singleTurn.isDraggingOrSettling, !settings, !detailsShowing,
              let context = readingContext, isCurrent(context) else { return }
        progressHUD = false; stopTrackingScroll(); cancelPageAnimation()
        immersive.toggle()
        ignoreCanvasTapUntil = Date().addingTimeInterval(0.25)
    }

    private func updateViewportFrame(_ frame: CGRect) {
        guard frame.width.isFinite, frame.height.isFinite, frame.width > 0, frame.height > 0 else { return }
        if viewportFrame.size != frame.size { cancelPageAnimation() }
        viewportFrame = frame
    }

    private func isEdgeBackDrag(_ value: DragGesture.Value) -> Bool {
        readerGesturesActive && !pageZoomed && !progressHUD &&
            ReaderEdgeBackPolicy.isLeadingSwipe(startX: value.startLocation.x + viewportFrame.minX,
                                                translation: value.translation)
    }

    private func singleDragGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .updating($singleFingerDown) { _, down, _ in down = true }
            .onChanged { value in
                guard mode == ReaderMode.singlePage.rawValue, !pageZoomed,
                      let context = readingContext, isCurrent(context) else { return }
                if isEdgeBackDrag(value) {
                    if singleTurn.isDraggingOrSettling { cancelSingleDrag() }
                    return
                }
                if case .settling = singleTurn.dragPhase { cancelPageAnimation(updateDemand: false) }
                let raw = direction.horizontal ? value.translation.width : value.translation.height
                let cross = direction.horizontal ? value.translation.height : value.translation.width
                let extent = direction.horizontal ? size.width : size.height
                guard extent.isFinite, extent > 0 else { return }
                guard singleTurn.isDraggingOrSettling || abs(raw) > max(8, abs(cross)) else { return }
                if !singleTurn.isDraggingOrSettling {
                    cancelPageAnimation(updateDemand: false)
                    seekRevision = UUID()
                    findingPage = false
                    singleTurn.dragPhase = .dragging(extent: extent)
                }
                guard case let .dragging(dragExtent) = singleTurn.dragPhase else { return }
                ignoreCanvasTapUntil = Date().addingTimeInterval(0.45)
                let delta = ReaderDragPolicy.pageDelta(offset: raw, direction: direction)
                let preview = adjacentPage(by: delta)
                let changed = preview != singleTurn.dragPreview
                singleTurn.dragPreview = preview
                // Keep the current canvas centered until the neighbor can actually draw.
                singleTurn.dragOffset = if let preview, !isPagePresented(preview) { 0 }
                    else { ReaderDragPolicy.boundedOffset(raw, extent: dragExtent, hasNeighbor: preview != nil) }
                if changed {
                    updateMedia()
                }
                if AppMode.qa, let preview {
                    lastDragEvidence = "\(current)+\(preview);offset=\(Int(abs(singleTurn.dragOffset)));neighborFile=\(media.files[preview] != nil)"
                }
            }
            .onEnded { value in
                guard case .dragging = singleTurn.dragPhase, !pageZoomed else { return }
                let raw = direction.horizontal ? value.translation.width : value.translation.height
                let predicted = direction.horizontal ? value.predictedEndTranslation.width : value.predictedEndTranslation.height
                let extent = direction.horizontal ? size.width : size.height
                finishSingleDrag(commit: singleTurn.dragPreview != nil && ReaderDragPolicy.commits(offset: raw, predicted: predicted, extent: extent))
            }
    }

    private func finishSingleDrag(commit: Bool) {
        // Use the geometry captured when the gesture started, even if the viewport
        // preference temporarily reports zero while the target page is loading.
        guard case let .dragging(extent) = singleTurn.dragPhase,
              let context = readingContext, isCurrent(context) else { return }
        let releaseID = UUID()
        singleTurn.dragPhase = .settling(releaseID)
        ignoreCanvasTapUntil = Date().addingTimeInterval(0.4)
        let target = commit ? singleTurn.dragPreview : nil
        let oldPage = current
        if target != nil { seekRevision = UUID(); findingPage = false }
        let intent = seekRevision
        let releaseDirection = storedDirection
        if AppMode.qa {
            lastReleaseEvidence = "commit=\(commit),target=\(target ?? 0),extent=\(extent),from=\(singleTurn.dragOffset),fileReady=\(target.map { media.files[$0] != nil } ?? false)"
        }
        switch singleTurn.release(commit: commit, isPresented: isPagePresented) {
        case .commit(let target):
            let offset = ReaderDragPolicy.pageOffset(index: target, current: oldPage, direction: direction,
                                                     size: CGSize(width: extent, height: extent), translation: singleTurn.dragOffset)
            var transaction = Transaction(); transaction.disablesAnimations = true
            withTransaction(transaction) {
                current = target
                syncSinglePagePosition()
                singleTurn.dragPreview = nil
                singleTurn.dragOffset = direction.horizontal ? offset.width : offset.height
            }
            remember()
            updateMedia()
        case .waitForPresentation(let target):
            singleTurn.pendingPage = target
        case .rebound:
            break
        }
        withAnimation(motionReduced ? nil : .easeOut(duration: 0.18), completionCriteria: .removed) {
            singleTurn.dragOffset = 0
        } completion: {
            guard singleTurn.dragPhase == .settling(releaseID),
                  isCurrent(context), seekRevision == intent,
                  mode == ReaderMode.singlePage.rawValue, storedDirection == releaseDirection else { return }
            resetSingleDrag()
            historyCheckpoint?.flush()
            updateMedia()
            finishPendingTurnIfReady()
        }
    }

    private func cancelSingleDrag(updateDemand: Bool = true) {
        let hadDemand = singleTurn.isDraggingOrSettling || singleTurn.requestedNeighbor != nil
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { singleTurn.cancel() }
        if updateDemand { historyCheckpoint?.finishMotion(fingerDown: singleFingerDown) }
        if hadDemand && updateDemand { updateMedia() }
    }

    private func resetSingleDrag() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { singleTurn.resetDrag() }
    }

    private func adjacentPage(by offset: Int) -> Int? {
        let target = current + offset
        guard target > 0, model.total.map({ target <= $0 }) ??
            (model.next != nil || model.pages.contains(where: { $0.index == target })) else { return nil }
        return target
    }

    private func changePage(by offset: Int) {
        guard offset != 0 else { return }
        if mode == ReaderMode.singlePage.rawValue {
            guard let target = adjacentPage(by: offset), target <= (model.total ?? 2000) else {
                cancelSingleDrag()
                return
            }
            guard singleTurn.pendingPage != target else { return }
            cancelPageAnimation(updateDemand: false)
            seekRevision = UUID()
            findingPage = false
            singleTurn.pendingPage = target
            updateMedia()
            finishPendingTurnIfReady()
            return
        }
        Task {
            let target = max(1, current + offset)
            guard model.total == nil || target <= (model.total ?? target) else { return }
            await seek(target, animatedTurn: true)
            if mode != ReaderMode.singlePage.rawValue, target >= (model.pages.last?.index ?? 0) - 2, let context = readingContext, isCurrent(context) {
                await loadNextPagesKeepingPosition()
            }
        }
    }

    private func isCurrent(_ context: ReadingContext) -> Bool {
        readingContext == context && context.generation == session.generation && context.owner == library.owner
    }
    private func remember() {
        guard let context = readingContext, isCurrent(context), current > 0,
              model.total.map({ current <= $0 }) ?? model.pages.contains(where: { $0.index == current }) else { return }
        if singleTurn.isDraggingOrSettling || slideTask != nil, let historyCheckpoint {
            historyCheckpoint.stage(current)
        } else {
            historyCheckpoint?.discard()
            library.remember(gallery, page: current)
        }
    }
    private func loadNextPagesKeepingPosition(priority: MediaRequestPriority = .foreground) async {
        guard let context = readingContext, isCurrent(context), !holdingPosition else { return }
        let startedIntent = seekRevision
        var page: Int?
        defer { holdingPosition = false }
        await model.more(gallery: gallery, session: session, library: library, priority: priority, beforeAppending: {
            // Keep accepting scrolling and seeks while I/O is pending. Pin the
            // user's latest page only for the actual layout mutation.
            page = current; holdingPosition = true
        })
        guard !Task.isCancelled, isCurrent(context), let page else { return }
        if mode == ReaderMode.singlePage.rawValue { return }
        // A pending jump can still have the old current page while it waits for
        // metadata. Internal layout repair must not replace that newer intent.
        if seekRevision == startedIntent { await seek(page, expectedIntent: startedIntent) }
        else if !findingPage { await seek(current, expectedIntent: seekRevision) }
    }
    private func seek(_ page: Int, animatedTurn: Bool = false, expectedIntent: UUID? = nil) async {
        guard let context = readingContext, isCurrent(context), !Task.isCancelled,
              page > 0, page <= (model.total ?? 2000) else { return }
        if let expectedIntent, expectedIntent != seekRevision { return }
        cancelSingleDrag(updateDemand: false)
        let intent = expectedIntent ?? UUID(); seekRevision = intent
        stopTrackingScroll()
        if mode == ReaderMode.singlePage.rawValue {
            findingPage = false
            displayPage(page, animatedTurn: animatedTurn)
            syncSinglePagePosition()
            remember()
            return
        }
        findingPage = true; defer { if seekRevision == intent { findingPage = false } }
        var count = 0
        while !model.pages.contains(where: { $0.index == page }), model.next != nil, model.error == nil, count < 100 {
            guard !Task.isCancelled, isCurrent(context), seekRevision == intent else { return }
            if model.loading { try? await Task.sleep(nanoseconds: 20_000_000); continue }
            count += 1; await model.more(gallery: gallery, session: session, library: library)
            guard !Task.isCancelled, isCurrent(context), seekRevision == intent else { return }
        }
        guard !Task.isCancelled, isCurrent(context), seekRevision == intent else { return }
        if model.pages.contains(where: { $0.index == page }) {
            displayPage(page, animatedTurn: animatedTurn); scrollPosition = nil
            await Task.yield()
            guard !Task.isCancelled, isCurrent(context), seekRevision == intent else { return }
            scrollPosition = page
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled, isCurrent(context), seekRevision == intent else { return }
            current = page; progressTarget = Double(page); remember()
        }
    }
}

private struct ReaderSettingsPanel: View {
    @Binding var mode: Int
    @Binding var direction: ReaderDirection
    let favoriteSymbol: String
    let favoriteValue: String
    let readLater: Bool
    let onFavorite: () -> Void
    let onReadLater: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.verticalSizeClass) private var heightClass
    @State private var contentHeight: CGFloat = 300

    private let modes = [
        FeedScopeOption(id: ReaderMode.continuous.rawValue, title: ReaderMode.continuous.title, symbol: "rectangle.split.1x2"),
        FeedScopeOption(id: ReaderMode.singlePage.rawValue, title: ReaderMode.singlePage.title, symbol: "book")
    ]

    private var detent: PresentationDetent {
        if heightClass == .compact || typeSize.isAccessibilitySize { return .large }
        return .height(contentHeight + 52)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if typeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: FeedChrome.panelSpacing) {
                            sectionTitle("阅读方式")
                            ForEach(modes) { item in
                                choice(item.title, symbol: item.symbol, selected: mode == item.id) { mode = item.id }
                                    .accessibilityIdentifier("reader.settings.mode.\(item.id)")
                            }
                        }
                    } else {
                        HStack(spacing: FeedChrome.controlSpacing) {
                            sectionTitle("阅读方式").fixedSize()
                            FeedScopePicker(selection: $mode, options: modes, identifier: "reader.settings.mode")
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        sectionTitle("翻页方向")
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: FeedChrome.panelSpacing),
                                                 count: typeSize.isAccessibilitySize ? 1 : 2), spacing: FeedChrome.panelSpacing) {
                            ForEach(ReaderDirection.allCases) { item in
                                choice(item.title, symbol: item.forwardSymbol, selected: direction == item) { direction = item }
                                    .accessibilityValue(direction == item ? "已选择" : "未选择")
                                    .accessibilityIdentifier("reader.settings.direction.\(item.rawValue)")
                            }
                        }
                    }
                    VStack(spacing: 0) {
                        Divider()
                        galleryAction("站点收藏", symbol: favoriteSymbol, opensEditor: true, action: onFavorite)
                            .accessibilityValue(favoriteValue)
                            .accessibilityIdentifier("reader.settings.site-favorite")
                        Divider().padding(.leading, 28)
                        galleryAction(readLater ? "移出稍后再读" : "加入稍后再读",
                                      symbol: readLater ? "checkmark" : "text.badge.plus", action: onReadLater)
                            .accessibilityIdentifier("reader.settings.read-later")
                    }
                    Text("双击中间看详情 · 长按隐藏或显示控件")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .padding(.horizontal, FeedChrome.contentInset)
                .padding(.top, FeedChrome.contentTopGap).padding(.bottom, FeedChrome.sectionSpacing)
                .onGeometryChange(for: CGFloat.self) { ceil($0.size.height) } action: { height in
                    if height > 0 { contentHeight = height }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .floatingPageHeader("阅读设置", identifier: "reader.settings-page") {
                EmptyView()
            } trailing: {
                Button("完成") { dismiss() }
                    .buttonStyle(FeedHeaderButtonStyle()).foregroundStyle(Color.accentColor)
                    .accessibilityIdentifier("reader.settings.done")
            }
        }
        .presentationDetents([detent])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(FeedChrome.panelShape.cornerSize.width)
        .presentationBackground(FloatingChrome.headerBackground)
        .statusBarHidden(false)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }

    private func choice(_ title: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(selected ? Color.accentColor : Color.primary)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .appControlSurface(selected: selected)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func galleryAction(_ title: String, symbol: String, opensEditor: Bool = false,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).frame(width: 20).foregroundStyle(Color.accentColor).accessibilityHidden(true)
                Text(title)
                Spacer(minLength: 6)
                if opensEditor {
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
                }
            }
            .font(.subheadline)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// XCTest's app hierarchy omits the system status bar on current iOS.
/// Read its actual scene state rather than treating that omission as hidden.
private struct ReaderSystemChromeProbe: UIViewRepresentable {
    final class Probe: UIView {
        override var accessibilityValue: String? {
            get {
                guard let window, let manager = window.windowScene?.statusBarManager else { return "unavailable" }
                let safe = window.safeAreaLayoutGuide.layoutFrame
                return "hidden=\(manager.isStatusBarHidden);height=\(manager.statusBarFrame.height);safeMinX=\(safe.minX);safeMaxX=\(safe.maxX)"
            }
            set { }
        }
    }
    func makeUIView(context: Context) -> Probe {
        let view = Probe()
        view.isAccessibilityElement = true
        view.accessibilityIdentifier = "reader.system.chrome.qa"
        return view
    }
    func updateUIView(_ view: Probe, context: Context) { }
}

struct ReaderPage: View {
    var page: GalleryPage
    var active: Bool
    var file: URL?
    var failure: Error?
    var loading: Bool
    var progress: MediaLoadProgress? = nil
    var animated: Bool
    var retry: () -> Void
    var interactions = CanvasInteractions()
    var onZoomChanged: ((Bool) -> Void)? = nil
    var onImageSizeChanged: ((CGSize) -> Void)? = nil
    var onPresentation: ((ImageCanvasPresentation) -> Void)? = nil
    var onDecodeFailure: ((URL) -> Void)? = nil
    var body: some View {
        ZStack {
            Color.black
            if active, let file {
                MediaCanvas(file: file, animated: animated, onZoomChanged: onZoomChanged,
                            onImageSizeChanged: onImageSizeChanged, interactions: interactions, onPresentation: onPresentation,
                            onDecodeFailure: onDecodeFailure)
            } else if active, let failure {
                ReaderLoadingPage(index: page.index, failure: ErrorMessages.message(failure), retry: retry, interactions: interactions)
            } else if active { ReaderLoadingPage(index: page.index, progress: progress, interactions: interactions) }
            else { Text("第 \(page.index) 页").font(.caption).foregroundStyle(.white.opacity(0.4)) }
        }
        .onChange(of: active) { _, value in if !value { onZoomChanged?(false) } }
        .onChange(of: file) { _, _ in onZoomChanged?(false) }
    }
}
