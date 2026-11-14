import SwiftUI
import UIKit
import Observation

enum PageEdgeGestureMetrics {
    static let activationWidth: CGFloat = 44
    static func contains(_ x: CGFloat, in window: UIWindow, leading: Bool) -> Bool {
        leading ? x <= window.safeAreaInsets.left + activationWidth
            : x >= window.bounds.width - window.safeAreaInsets.right - activationWidth
    }
}

/// A custom edge return has already animated its outgoing content. Keep the
/// following native pop/chrome handoff atomic until the source is visible.
@Observable @MainActor final class EdgeReturnChromeHandoff {
    private(set) var pending = false
    @ObservationIgnored private var revision = UUID()
    func begin() { revision = UUID(); pending = true }
    func destinationHeaderDidCommit() {
        guard pending else { return }
        let token = revision
        Task { @MainActor in
            await Task.yield()
            guard revision == token else { return }
            cancel()
        }
    }
    func cancel() { revision = UUID(); pending = false }
}

extension EnvironmentValues {
    @Entry var edgeReturnChromeHandoff: EdgeReturnChromeHandoff? = nil
    @Entry var edgeTouchGate: EdgeTouchGate? = nil
}

/// Gesture owners hold leases through settling. A short release tail also
/// excludes delayed NavigationLink activation from the same physical touch.
@Observable @MainActor final class EdgeTouchGate {
    private(set) var blocksGalleryActions = false
    @ObservationIgnored private var owners = Set<UUID>()
    @ObservationIgnored private var release: Task<Void, Never>?
    @ObservationIgnored private(set) var rejectedGalleryActivations = 0
    func permitsGalleryActivation() -> Bool {
        guard !blocksGalleryActions else {
            if AppMode.qa { rejectedGalleryActivations += 1 }
            return false
        }
        return true
    }
    func begin(_ owner: UUID) {
        release?.cancel(); release = nil
        owners.insert(owner)
        if !blocksGalleryActions { blocksGalleryActions = true }
    }
    func end(_ owner: UUID) {
        guard owners.remove(owner) != nil, owners.isEmpty else { return }
        release?.cancel()
        release = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            guard let self, self.owners.isEmpty else { return }
            self.blocksGalleryActions = false; self.release = nil
        }
    }
}

/// Read the actual window edges, including landscape safe-area space.
struct EdgeTouchWindowProbe: UIViewRepresentable {
    let gate: EdgeTouchGate
    func makeUIView(context: Context) -> Probe { Probe() }
    func updateUIView(_ view: Probe, context: Context) { view.gate = gate; view.updateGate() }
    static func dismantleUIView(_ view: Probe, coordinator: ()) { view.detach() }
    final class Probe: UIView {
        weak var gate: EdgeTouchGate?
        private weak var installedWindow: UIWindow?
        private let observer = TouchObserver()
        override func didMoveToWindow() {
            super.didMoveToWindow()
            detach()
            installedWindow = window
            observer.gate = gate
            window?.addGestureRecognizer(observer)
            updateGate()
        }
        func updateGate() { observer.gate = gate }
        func detach() { observer.stopTracking(); installedWindow?.removeGestureRecognizer(observer); installedWindow = nil }
    }
    /// Watches the original window touch, including starts outside card bounds.
    /// It never recognizes/prevents another gesture; it only closes gallery actions.
    private final class TouchObserver: UIGestureRecognizer {
        init() {
            super.init(target: nil, action: nil)
            cancelsTouchesInView = false; delaysTouchesBegan = false; delaysTouchesEnded = false
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        weak var gate: EdgeTouchGate?
        private let owner = UUID()
        private var start: CGPoint?
        override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
        override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            guard touches.count == 1, let touch = touches.first, let window = touch.window else { state = .failed; return }
            let point = touch.location(in: window)
            guard PageEdgeGestureMetrics.contains(point.x, in: window, leading: true) || PageEdgeGestureMetrics.contains(point.x, in: window, leading: false) else { state = .failed; return }
            start = point
        }
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
            observeMovement(touches)
        }
        private func observeMovement(_ touches: Set<UITouch>) {
            guard let start, let touch = touches.first else { return }
            let point = touch.location(in: touch.window)
            if abs(point.x - start.x) >= 4 && abs(point.x - start.x) > abs(point.y - start.y) * 1.2 { gate?.begin(owner) }
        }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { observeMovement(touches); gate?.end(owner); state = .failed }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { stopTracking() }
        func stopTracking() { gate?.end(owner); if start != nil { state = .failed }; start = nil }
        override func reset() { gate?.end(owner); start = nil; super.reset() }
    }
}

extension View {
    /// A detail page owns its two edge gestures; fixed chrome stays outside the moving content.
    func detailEdgeBack(commitAllowed: Bool = true, action: @escaping () -> Void) -> some View {
        modifier(PageEdgeBackModifier(action: action, commitAllowed: commitAllowed))
    }
    func detailEdgeBack(commitAllowed: Bool, committing: @escaping () -> Bool,
                        onBlockedCommit: (() -> Void)? = nil) -> some View {
        modifier(PageEdgeBackModifier(action: {}, commitAllowed: commitAllowed, commitResult: committing,
                                      onBlockedCommit: onBlockedCommit))
    }
    func readerEdgeBack(enabled: Bool, requested: UUID?, preview: PageReturnPreview?, interaction: @escaping (Bool) -> Void, action: @escaping () -> Void) -> some View {
        modifier(PageEdgeBackModifier(action: action, enabled: enabled, reader: true, requested: requested, preview: preview, interaction: interaction))
    }
}

enum DetailEdgeBackPolicy {
    static func commits(distance: CGFloat, velocity: CGFloat, width: CGFloat, cancelled: Bool) -> Bool {
        guard !cancelled, width > 0, abs(distance) >= 24 else { return false }
        return abs(distance) + velocity * (distance >= 0 ? 1 : -1) * 0.12 >= width * 0.33
    }
}

private struct PageEdgeBackModifier: ViewModifier {
    let action: () -> Void
    var commitAllowed = true
    var commitResult: (() -> Bool)? = nil
    var onBlockedCommit: (() -> Void)? = nil
    var enabled = true
    var reader = false
    var requested: UUID? = nil
    var preview: PageReturnPreview? = nil
    var interaction: (Bool) -> Void = { _ in }
    @Environment(\.appMenuVisible) private var menuVisible
    @Environment(\.headerSectionSuspended) private var suspended
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.edgeReturnChromeHandoff) private var chromeHandoff
    @Environment(\.edgeTouchGate) private var touchGate
    @State private var touchOwner = UUID()
    @State private var diagnostic = "waiting"
    @State private var extent: CGFloat = 0
    @State private var offset: CGFloat = 0
    @State private var dragging = false
    @State private var settling = false
    @State private var revision = UUID()
    @State private var exitCommitted = false

    func body(content: Content) -> some View {
        content
            .background(reader ? Color.black : Color(uiColor: .systemBackground))
            .offset(x: offset)
            .background {
                if AppMode.qa {
                    ChromeMotionQA(clearance: offset, identifier: reader ? "reader.edge.motion" : "page.edge.motion")
                        .frame(width: 1, height: 1).allowsHitTesting(false)
                }
            }
            .background {
                DetailEdgeBackBridge(enabled: enabled && !menuVisible && !settling && (!suspended || reader) && scenePhase == .active, offset: offset,
                                     navigationPreview: !reader, widthChanged: { extent = $0 }, report: { value in if AppMode.qa { diagnostic = value } },
                                     changed: { value in
                                         if value != 0 && !dragging { dragging = true; interaction(true); touchGate?.begin(touchOwner) }
                                         offset = commitAllowed ? value : (value >= 0 ? 1 : -1) * min(abs(value) * 0.18, max(0, extent) * 0.1)
                                     }, ended: finish)
            }
            .background {
                if reader {
                    GeometryReader { geometry in
                        ZStack {
                            Color(uiColor: .systemGroupedBackground)
                            if let preview, abs(preview.size.width - geometry.size.width) < 2 {
                                Image(uiImage: preview.image).resizable().frame(width: geometry.size.width, height: geometry.size.height)
                            }
                            Color.black.opacity(1 - min(1, abs(offset) / max(1, geometry.size.width)))
                        }
                    }.ignoresSafeArea()
                }
            }
            .onChange(of: requested) { _, value in
                guard reader, value != nil, !settling, scenePhase == .active else { return }
                if extent > 0 { finish(extent * 0.5, 0, extent, false) }
                else { action() }
            }
            .onChange(of: enabled) { _, value in if !value { reset() } }
            .onChange(of: suspended) { _, suspended in if suspended && !reader { reset() } }
            .onChange(of: menuVisible) { _, visible in if visible { reset() } }
            .onChange(of: scenePhase) { _, phase in if phase != .active { reset() } }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { _ in reset() }
            .onAppear { exitCommitted = false; reset() }
            .onDisappear { reset() }
            .accessibilityAction(.escape) {
                if commitAllowed {
                    if let commitResult { _ = commitResult() } else { action() }
                }
            }
            .overlay(alignment: .bottomLeading) {
                if AppMode.qa {
                    Text("QA").font(.system(size: 1)).foregroundStyle(.clear).frame(width: 1, height: 1)
                        .accessibilityIdentifier(reader ? "reader.edge.qa" : "page.edge.qa").accessibilityValue(diagnostic + ";extent=\(Int(extent));allowed=\(commitAllowed);offset=\(Int(offset))").allowsHitTesting(false)
                }
            }
    }

    private func reset() {
        touchGate?.end(touchOwner)
        revision = UUID(); settling = false; dragging = false; interaction(false)
        var transaction = Transaction(); transaction.disablesAnimations = true
        if !exitCommitted { withTransaction(transaction) { offset = 0 } }
    }

    private func finish(_ distance: CGFloat, _ velocity: CGFloat, _ width: CGFloat, _ cancelled: Bool) {
        guard !settling, width > 0 else { return }
        let requestedCommit = DetailEdgeBackPolicy.commits(distance: distance, velocity: velocity, width: width, cancelled: cancelled)
        let commits = commitAllowed && requestedCommit
        if !commitAllowed && requestedCommit { onBlockedCommit?() }
        if !dragging && !cancelled { dragging = true; interaction(true) }
        let token = UUID(); revision = token; settling = true
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2), completionCriteria: .removed) {
            offset = commits ? (distance >= 0 ? width : -width) : 0
        } completion: {
            guard revision == token else { return }
            touchGate?.end(touchOwner)
            if commits {
                var transaction = Transaction(animation: nil); transaction.disablesAnimations = true
                exitCommitted = true
                if !reader { chromeHandoff?.begin() }
                let accepted = withTransaction(transaction) {
                    if let commitResult { return commitResult() }
                    action(); return true
                }
                if !accepted {
                    chromeHandoff?.cancel()
                    exitCommitted = false
                    // The destination rejected the action (for example an expired search target).
                    // Reuse the normal rollback path instead of leaving the page off-screen.
                    settling = false
                    finish(0, 0, width, true)
                }
            } else { settling = false; dragging = false; interaction(false) }
        }
    }
}

private struct DetailEdgeBackBridge: UIViewControllerRepresentable {
    let enabled: Bool
    let offset: CGFloat
    let navigationPreview: Bool
    let widthChanged: (CGFloat) -> Void
    let report: (String) -> Void
    let changed: (CGFloat) -> Void
    let ended: (CGFloat, CGFloat, CGFloat, Bool) -> Void

    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.widthChanged = widthChanged
        controller.report = report
        controller.navigationPreview = navigationPreview
        controller.renderedOffset = offset
        controller.setEnabled(enabled); controller.changed = changed; controller.ended = ended
        if offset == 0 { controller.clearPreviewIfIdle() }
    }
    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) { controller.detach() }

    final class Controller: UIViewController, UIGestureRecognizerDelegate {
        private final class DiagnosticView: UIView {
            var readState: (() -> String)?
            override var accessibilityValue: String? {
                get { readState?() }
                set { }
            }
        }
        var enabled = true
        var navigationPreview = true
        var renderedOffset: CGFloat = 0
        var widthChanged: (CGFloat) -> Void = { _ in }
        private var reportedWidth: CGFloat = 0
        private var travelWidth: CGFloat { navigationPreview ? view.bounds.width : (view.window?.bounds.width ?? view.bounds.width) }
        private func reportWidth() {
            let width = travelWidth
            guard width > 0, reportedWidth != width else { return }
            reportedWidth = width
            DispatchQueue.main.async { [weak self] in self?.widthChanged(width) }
        }
        var report: (String) -> Void = { _ in }
        private var previewDiagnostic = ""
        private func record(_ value: String) {
            if AppMode.qa { DispatchQueue.main.async { [weak self] in
                guard let self else { return }; self.report(value + self.previewDiagnostic)
            } }
        }
        var changed: (CGFloat) -> Void = { _ in }
        var ended: (CGFloat, CGFloat, CGFloat, Bool) -> Void = { _, _, _, _ in }
        private let left = UIPanGestureRecognizer()
        private let right = UIPanGestureRecognizer()
        private weak var installedWindow: UIWindow?
        private var visible = false
        private let identity = UUID()
        private var preview: UIView?
        private var previewFrameInNavigation: CGRect?
        private var previewClipInNavigation: CGRect?
        private var size: CGSize = .zero

        override func loadView() {
            view = UIView(); view.isUserInteractionEnabled = false; view.clipsToBounds = false
            if AppMode.qa {
                let probe = DiagnosticView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
                probe.isAccessibilityElement = true; probe.accessibilityIdentifier = "qa.edge.installation"
                probe.readState = { [weak self] in
                    guard let self else { return "released" }
                    let window = self.installedWindow
                    return "id=\(self.identity);visible=\(self.visible);enabled=\(self.enabled);key=\(window?.isKeyWindow ?? false);hidden=\(window?.isHidden ?? true);sameWindow=\(window === self.view.window);panEnabled=\(self.left.isEnabled),\(self.right.isEnabled);attached=\(self.left.view === window),\(self.right.view === window);states=\(self.left.state.rawValue),\(self.right.state.rawValue)"
                }
                view.addSubview(probe)
            }
        }
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard let window = view.window else { return }
            detach(); visible = true; installedWindow = window
            reportWidth()
            for pan in [left, right] {
                pan.delegate = self; pan.maximumNumberOfTouches = 1
                pan.cancelsTouchesInView = true
                pan.delaysTouchesBegan = true
                pan.delaysTouchesEnded = true
                pan.addTarget(self, action: #selector(dragged(_:))); window.addGestureRecognizer(pan)
            }
            record("ready id=\(identity) enabled=\(enabled) bounds=\(view.bounds) window=\(window.bounds) attached=\(left.view === window),\(right.view === window)")
        }
        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            if size != .zero, abs(size.width - view.bounds.width) > 0.5 {
                for pan in [left, right] { pan.isEnabled = false; pan.isEnabled = true }
                clearPreview(); changed(0)
            }
            size = view.bounds.size
            reportWidth()
        }
        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            holdCompletedPreviewThroughNativePop()
            detach(clearPreview: false)
        }
        override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); clearPreview() }
        func detach(clearPreview shouldClearPreview: Bool = true) {
            visible = false
            for pan in [left, right] {
                installedWindow?.removeGestureRecognizer(pan); pan.removeTarget(self, action: #selector(dragged(_:)))
            }
            installedWindow = nil
            if shouldClearPreview { clearPreview() }
            record("detached id=\(identity) visible=\(visible) viewWindow=\(viewIfLoaded?.window != nil)")
        }
        func setEnabled(_ value: Bool) {
            guard enabled != value else { return }
            enabled = value
            if !value {
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.enabled else { return }
                    for pan in [self.left, self.right] where pan.state == .began || pan.state == .changed {
                        pan.isEnabled = false; pan.isEnabled = true
                    }
                }
            }
        }
        func clearPreview() {
            preview?.removeFromSuperview(); preview = nil
            previewFrameInNavigation = nil; previewClipInNavigation = nil
        }

        private func holdCompletedPreviewThroughNativePop() {
            guard navigationPreview, abs(renderedOffset) >= travelWidth - 1,
                  let preview, let frame = previewFrameInNavigation, let clip = previewClipInNavigation,
                  let navigation = navigationController else { return }
            // The custom drag has already exposed the source at its final position.
            // UIKit can still apply a transient parallax/dimming frame during pop.
            // Keep that same source image above the navigation transition container
            // until the real source has completed layout; SwiftUI still owns the pop.
            // The navigation controller inserts/reorders its own transition
            // container after willDisappear. Use a stable sibling above it.
            let host = navigation.view.superview ?? navigation.view!
            let hostClip = navigation.view.convert(clip, to: host)
            let hostFrame = navigation.view.convert(frame, to: host)
            let cover = UIView(frame: hostClip)
            cover.clipsToBounds = true; cover.isUserInteractionEnabled = false; cover.accessibilityElementsHidden = true
            preview.removeFromSuperview()
            preview.frame = hostFrame.offsetBy(dx: -hostClip.minX, dy: -hostClip.minY)
            cover.addSubview(preview)
            host.addSubview(cover)
            self.preview = nil; previewFrameInNavigation = nil; previewClipInNavigation = nil
            let remove = { [weak navigation] in
                navigation?.topViewController?.viewIfLoaded?.layoutIfNeeded()
                cover.removeFromSuperview()
            }
            if let coordinator = navigation.transitionCoordinator,
               coordinator.animate(alongsideTransition: nil, completion: { _ in remove() }) { return }
            // An unanimated pop has no coordinator. Finish its next render commit.
            DispatchQueue.main.async {
                CATransaction.begin()
                CATransaction.setCompletionBlock(remove)
                navigation.view.layoutIfNeeded()
                CATransaction.commit()
            }
        }
        func clearPreviewIfIdle() {
            guard ![left, right].contains(where: { $0.state == .began || $0.state == .changed }) else { return }
            clearPreview()
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard visible, enabled else { record("reject visible=\(visible) enabled=\(enabled)"); return false }
            guard let window = installedWindow else { return false }
            let start = touch.location(in: window)
            record("candidate id=\(identity) edge=\(gestureRecognizer === left ? "left" : "right") start=\(start) window=\(window.bounds) attached=\(left.view === window),\(right.view === window)")
            guard PageEdgeGestureMetrics.contains(start.x, in: window, leading: gestureRecognizer === left) else { return false }
            let point = touch.location(in: view)
            let insets = view.safeAreaInsets
            record("touch point=\(point) bounds=\(view.bounds) insets=\(insets)")
            guard point.y >= insets.top, point.y <= view.bounds.height - insets.bottom else { return false }
            var ancestor: UIViewController? = self
            while let controller = ancestor {
                if controller.presentedViewController != nil { record("reject presented ancestor=\(type(of: controller))"); return false }
                ancestor = controller.parent
            }
            var hit = touch.view
            while let current = hit {
                if current is UISlider || current is UISwitch || current is UITextField || current is UITextView { record("reject control=\(type(of: current))"); return false }
                hit = current.superview
            }
            record("accept window=\(installedWindow?.bounds ?? .zero) hit=\(String(describing: touch.view.map { type(of: $0) }))")
            return true
        }
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard visible, enabled, let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: view)
            record("begin velocity=\(velocity)")
            return (pan === left ? velocity.x : -velocity.x) > abs(velocity.y) * 1.4
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            if navigationPreview { return otherGestureRecognizer is UIPanGestureRecognizer && otherGestureRecognizer.view is UIScrollView }
            if otherGestureRecognizer is UITapGestureRecognizer || otherGestureRecognizer is UILongPressGestureRecognizer { return false }
            // SwiftUI's paging DragGesture still observes touches; its edge path does no paging.
            // Only the actual continuous-scroll pan must remain mutually exclusive.
            return !(otherGestureRecognizer.view is UIScrollView && otherGestureRecognizer is UIPanGestureRecognizer)
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            // In the reader, the screen edge wins over continuous-page scrolling.
            if otherGestureRecognizer is UITapGestureRecognizer || otherGestureRecognizer is UILongPressGestureRecognizer { return true }
            return !navigationPreview && otherGestureRecognizer.view is UIScrollView && otherGestureRecognizer is UIPanGestureRecognizer
        }
        @objc private func dragged(_ pan: UIPanGestureRecognizer) {
            guard visible else { return }
            if !enabled {
                if pan.state == .ended || pan.state == .cancelled || pan.state == .failed {
                    ended(0, 0, view.bounds.width, true)
                }
                return
            }
            let width = travelWidth
            let sign: CGFloat = pan === left ? 1 : -1
            let distance = sign * min(width, max(0, pan.translation(in: view).x * sign))
            if pan.state != .changed { record("drag state=\(pan.state.rawValue) distance=\(Int(distance))") }
            switch pan.state {
            case .began:
                preparePreview(); changed(distance)
            case .changed: changed(distance)
            case .ended: ended(distance, pan.velocity(in: view).x, width, false)
            case .cancelled, .failed: ended(distance, 0, width, true)
            default: break
            }
        }
        private func preparePreview() {
            clearPreview()
            guard navigationPreview, let navigation = navigationController, navigation.viewControllers.count > 1,
                  let previous = navigation.viewControllers.dropLast().last, previous.isViewLoaded,
                  let window = view.window,
                  previous.view.bounds.width > 0, previous.view.bounds.height > 0,
                  abs(previous.view.bounds.width - view.bounds.width) < 2 else { return }
            // Capture only the already-loaded previous screen; never instantiate or navigate a preview.
            let sourceFrame: CGRect
            if previous.view.window === view.window {
                sourceFrame = previous.view.convert(previous.view.bounds, to: view)
            } else {
                // A covered hosting view can be detached. Only use the stable
                // navigation surface when its retained frame proves the same geometry.
                guard previous.view.transform.isIdentity,
                      abs(previous.view.frame.minX - navigation.view.bounds.minX) < 1,
                      abs(previous.view.frame.minY - navigation.view.bounds.minY) < 1,
                      abs(previous.view.bounds.width - navigation.view.bounds.width) < 1,
                      abs(previous.view.bounds.height - navigation.view.bounds.height) < 1 else { return }
                sourceFrame = navigation.view.convert(navigation.view.bounds, to: view)
            }
            // Scroll content deliberately paints behind both fixed bars. Capture
            // the whole window canvas rather than cropping to the bridge body:
            // otherwise the uncovered safe-area strips replay UIKit's pop.
            let coverage = window.convert(window.bounds, to: view)
            let captureOrigin = CGPoint(x: sourceFrame.minX - coverage.minX,
                                        y: sourceFrame.minY - coverage.minY)
            let image = UIGraphicsImageRenderer(size: coverage.size).image { context in
                context.cgContext.setFillColor(UIColor.systemGroupedBackground.resolvedColor(with: previous.view.traitCollection).cgColor)
                context.cgContext.fill(CGRect(origin: .zero, size: coverage.size))
                context.cgContext.translateBy(x: captureOrigin.x, y: captureOrigin.y)
                previous.view.layer.render(in: context.cgContext)
            }
            let imageView = UIImageView(image: image)
            imageView.frame = coverage
            imageView.contentMode = .topLeft
            if AppMode.qa {
                previewDiagnostic = String(format: ";previewScale=%.3f,%.3f;source=%.0fx%.0f;bridge=%.0fx%.0f;origin=%.0f,%.0f",
                    imageView.frame.width / image.size.width, imageView.frame.height / image.size.height,
                    image.size.width, image.size.height, view.bounds.width, view.bounds.height,
                    sourceFrame.minX, sourceFrame.minY)
            }
            imageView.isUserInteractionEnabled = false; imageView.accessibilityElementsHidden = true
            previewFrameInNavigation = view.convert(imageView.frame, to: navigation.view)
            previewClipInNavigation = view.convert(coverage, to: navigation.view)
            view.addSubview(imageView); preview = imageView
        }
    }
}

/// An in-memory image of the exact window before the reader covers it.
/// It is never persisted and is discarded with that reading presentation.
struct PageReturnPreview {
    let image: UIImage
    let size: CGSize
}

@MainActor final class PageReturnPreviewSource: ObservableObject {
    private weak var surface: UIView?
    var probe: some View { Probe(source: self).allowsHitTesting(false) }
    func capture() -> PageReturnPreview? {
        guard let window = surface?.window, window.bounds.width > 0 else { return nil }
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { window.layer.render(in: $0.cgContext) }
        return PageReturnPreview(image: image, size: window.bounds.size)
    }
    private struct Probe: UIViewRepresentable {
        let source: PageReturnPreviewSource
        func makeUIView(context: Context) -> UIView {
            let view = UIView(); view.isUserInteractionEnabled = false
            source.surface = view
            return view
        }
        func updateUIView(_ view: UIView, context: Context) { source.surface = view }
    }
}
