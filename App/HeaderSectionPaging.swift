import SwiftUI
import Observation
import Combine
import UIKit

/// Gesture thresholds are independent of visible card spacing.
enum HeaderSectionSwipePolicy {
    static let edgeWidth = PageEdgeGestureMetrics.activationWidth
    static func target(selection: Int, count: Int, fromLeading: Bool) -> Int? {
        guard count > 1, (0..<count).contains(selection) else { return nil }
        return (selection + (fromLeading ? -1 : 1) + count) % count
    }
    static func commits(distance: CGFloat, velocity: CGFloat, width: CGFloat) -> Bool {
        width > 0 && distance >= 12 && distance + velocity * 0.12 >= width * 0.33
    }
}

@Observable @MainActor final class HeaderSectionPager {
    private(set) var selection = 0
    private(set) var count = 0
    private(set) var width: CGFloat = 0
    private(set) var offset: CGFloat = 0
    private(set) var target: Int?
    // Gestures advance one slot, including across the seam; explicit taps use their index delta.
    private(set) var transitionStep = 0
    private(set) var settling = false
    private(set) var mountRequest: UUID?
    @ObservationIgnored let currentSelectionTaps = PassthroughSubject<Int, Never>()
    @ObservationIgnored let willChangeSection = PassthroughSubject<Int, Never>()
    @ObservationIgnored private var pendingTap: Int?
    var enabled = true
    var locked = false { didSet { if locked { cancel() } } }
    var gestureLocked = false { didSet { if gestureLocked && !settling { cancel() } } }
    private var menuPresentations = Set<UUID>()
    private var layoutSettlements = Set<UUID>()
    var layoutSettlementCount: Int { layoutSettlements.count }
    @ObservationIgnored private var settlementRevision = UUID()
    @ObservationIgnored private var commit: (Int) -> Void = { _ in }
    @ObservationIgnored private var prepare: (Int) -> Void = { _ in }
    @ObservationIgnored var touchGate: EdgeTouchGate?
    @ObservationIgnored private let touchOwner = UUID()
    var moving: Bool { target != nil }
    var canBeginGesture: Bool { count > 1 && enabled && !locked && !gestureLocked && menuPresentations.isEmpty && layoutSettlements.isEmpty && !moving && !settling }
    var position: CGFloat {
        guard target != nil, width > 0 else { return CGFloat(selection) }
        return CGFloat(selection) + CGFloat(transitionStep) * min(1, abs(offset) / width)
    }
    var previewOffset: CGFloat { (transitionStep < 0 ? -1 : 1) * width }
    var canPageBack: Bool { count > 1 && enabled && !locked && !gestureLocked && menuPresentations.isEmpty }

    func configure(selection: Int, count: Int, enabled: Bool, prepare: @escaping (Int) -> Void = { _ in }, commit: @escaping (Int) -> Void) {
        if selection != self.selection || count != self.count || !enabled { cancel() }
        self.selection = selection; self.count = count; self.enabled = enabled; self.prepare = prepare; self.commit = commit
    }
    func resize(_ width: CGFloat) {
        guard abs(width - self.width) > 0.5 else { return }
        cancel(); self.width = max(0, width)
    }
    func begin(fromLeading: Bool) -> Bool {
        guard enabled, !locked, !gestureLocked, menuPresentations.isEmpty, layoutSettlements.isEmpty, !moving, !settling, width > 0,
              let next = HeaderSectionSwipePolicy.target(selection: selection, count: count, fromLeading: fromLeading) else { return false }
        willChangeSection.send(next)
        prepare(next)
        touchGate?.begin(touchOwner)
        target = next; transitionStep = fromLeading ? -1 : 1; offset = 0; return true
    }
    func update(_ translation: CGFloat) {
        guard target != nil, !settling else { return }
        let sign: CGFloat = transitionStep < 0 ? 1 : -1
        offset = sign * min(width, max(0, translation * sign))
    }
    func end(velocity: CGFloat, cancelled: Bool, reducedMotion: Bool) {
        guard let target, !settling else { return }
        let sign: CGFloat = transitionStep < 0 ? 1 : -1
        let accepted = !cancelled && HeaderSectionSwipePolicy.commits(distance: offset * sign, velocity: velocity * sign, width: width)
        settle(to: target, accepted: accepted, reducedMotion: reducedMotion)
    }
    func select(_ next: Int, reducedMotion: Bool) {
        guard (0..<count).contains(next), enabled, !locked, menuPresentations.isEmpty, layoutSettlements.isEmpty, !moving, !settling, width > 0 else { return }
        if next == selection { currentSelectionTaps.send(next); return }
        willChangeSection.send(next)
        prepare(next)
        var transaction = Transaction(animation: nil); transaction.disablesAnimations = true
        withTransaction(transaction) {
            target = next; transitionStep = next - selection; offset = 0
            if !reducedMotion { pendingTap = next; mountRequest = UUID() }
        }
        if reducedMotion { settle(to: next, accepted: true, reducedMotion: true) }
    }
    func paneMounted(_ index: Int, request: UUID) {
        guard mountRequest == request, pendingTap == index, target == index,
              enabled, !locked, !settling else { return }
        pendingTap = nil; mountRequest = nil
        settle(to: index, accepted: true, reducedMotion: false)
    }
    private func settle(to next: Int, accepted: Bool, reducedMotion: Bool) {
        settling = true
        let sign: CGFloat = transitionStep < 0 ? 1 : -1
        let revision = UUID(); settlementRevision = revision
        withAnimation(reducedMotion ? nil : .spring(response: 0.28, dampingFraction: 0.92), completionCriteria: .removed) {
            offset = accepted ? sign * width : 0
        } completion: { [weak self] in
            // Completion can be synchronous for reduced motion or an unmounted view.
            // Hand off after this update and let rotation/owner changes invalidate it.
            Task { @MainActor [weak self] in
                guard let self, self.settlementRevision == revision, self.target == next else { return }
                var transaction = Transaction(animation: nil); transaction.disablesAnimations = true
                withTransaction(transaction) {
                    if accepted, self.enabled, !self.locked {
                        self.commit(next)
                        self.selection = next
                    }
                    self.target = nil; self.transitionStep = 0; self.offset = 0; self.settling = false
                    self.touchGate?.end(self.touchOwner)
                }
            }
        }
    }

    func setMenuPresentation(_ id: UUID, visible: Bool) {
        if visible { menuPresentations.insert(id); cancel() }
        else { menuPresentations.remove(id) }
    }
    func beginLayoutSettlement(_ owner: UUID) {
        layoutSettlements.insert(owner)
        touchGate?.begin(owner)
    }
    func finishLayoutSettlement(_ owner: UUID) {
        guard layoutSettlements.contains(owner) else { return }
        layoutSettlements.remove(owner)
        touchGate?.end(owner)
    }
    func cancel() {
        touchGate?.end(touchOwner)
        // UIKit can detach an already idle bridge during SwiftUI reconciliation.
        // Avoid publishing the same idle state from that teardown callback.
        guard target != nil || transitionStep != 0 || offset != 0 || settling else { return }
        settlementRevision = UUID(); mountRequest = nil; pendingTap = nil
        target = nil; transitionStep = 0; offset = 0; settling = false
    }
}

struct HeaderSectionContext {
    let pager: HeaderSectionPager
    let identifier: String
}
extension EnvironmentValues {
    @Entry var headerSectionContext: HeaderSectionContext? = nil
    @Entry var headerSectionCanPageBack = false
    @Entry var headerSectionPreview = false
    @Entry var headerSectionPreviewClearance: CGFloat? = nil
    @Entry var headerSectionSuspended = false
}
struct HeaderSectionLock: PreferenceKey {
    static var defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}
struct HeaderSectionGestureLock: PreferenceKey {
    static var defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}
extension View {
    /// Place inside headerSectionPaging so taps and gestures share the same cleanup boundary.
    func headerSectionWillChange(_ action: @escaping () -> Void) -> some View {
        modifier(HeaderSectionWillChange(action: action))
    }
    func headerSectionGestureLocked(_ locked: Bool) -> some View { preference(key: HeaderSectionGestureLock.self, value: locked) }
    func headerSectionLocked(_ locked: Bool) -> some View { preference(key: HeaderSectionLock.self, value: locked) }
    func headerSectionPaging(selection: Binding<Int>, count: Int, identifier: String, enabled: Bool = true, identity: AnyHashable? = nil,
                             prepare: @escaping (Int) -> Void = { _ in }) -> some View {
        modifier(HeaderSectionPaging(selection: selection, count: count, identifier: identifier, enabled: enabled, identity: identity, prepare: prepare))
    }
}
private struct HeaderSectionWillChange: ViewModifier {
    let action: () -> Void
    @Environment(\.headerSectionContext) private var context
    func body(content: Content) -> some View {
        content.onReceive(context?.pager.willChangeSection.eraseToAnyPublisher() ?? Empty<Int, Never>().eraseToAnyPublisher()) { _ in action() }
    }
}

private struct HeaderSectionPaging: ViewModifier {
    @Binding var selection: Int
    let count: Int
    let identifier: String
    let enabled: Bool
    let identity: AnyHashable?
    let prepare: (Int) -> Void
    @Environment(\.headerSectionPreview) private var isPreview
    @Environment(\.headerSectionSuspended) private var suspended
    @Environment(\.edgeTouchGate) private var touchGate
    @State private var pager = HeaderSectionPager()
    func body(content: Content) -> some View {
        content
            .environment(\.headerSectionContext, isPreview ? nil : .init(pager: pager, identifier: identifier))
            .environment(\.headerSectionCanPageBack, !isPreview && !suspended && pager.canPageBack)
            .onPreferenceChange(HeaderSectionLock.self) { pager.locked = $0 }
            .onPreferenceChange(HeaderSectionGestureLock.self) { pager.gestureLocked = $0 }
            .onAppear(perform: configure)
            .onChange(of: selection) { _, _ in configure() }
            .onChange(of: enabled) { _, _ in configure() }
            .onChange(of: count) { _, _ in configure() }
            .onChange(of: suspended) { _, _ in configure() }
            .onChange(of: identity) { _, _ in pager.cancel(); configure() }
            .onDisappear { pager.cancel() }
    }
    private func configure() {
        pager.touchGate = touchGate
        pager.configure(selection: selection, count: count, enabled: enabled && !isPreview && !suspended, prepare: prepare) { selection = $0 }
    }
}
/// One real pane per section key. The incoming pane survives the selection commit;
/// there is no separately rendered preview to replace after the slide (HG's keyed-pane contract).
struct HeaderSectionPages<Page: View>: View {
    let selection: Int
    var topInset: CGFloat = 0
    @ViewBuilder let page: (Int, Bool) -> Page
    @Environment(\.headerSectionContext) private var context
    @Environment(\.accessibilityReduceMotion) private var reducedMotion

    var body: some View {
        GeometryReader { geometry in
            if let context {
                let target = context.pager.target
                let indices = target.map { $0 == selection ? [selection] : [selection, $0] } ?? [selection]
                ZStack(alignment: .topLeading) {
                    ForEach(indices, id: \.self) { index in
                        let active = index == selection
                        page(index, active)
                            .environment(\.headerSectionPreviewClearance, !active && topInset > 0 ? topInset : nil)
                            .environment(\.headerSectionPreview, !active)
                            .suppressPinnedChromePreferences(!active)
                            .transformPreference(HeaderSectionLock.self) { if !active { $0 = false } }
                            .transformPreference(HeaderSectionGestureLock.self) { if !active { $0 = false } }
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .background(Palette.background)
                            .background {
                                if AppMode.qa {
                                    HeaderSectionPaneQA(identifier: "\(context.identifier).pane.\(index)")
                                        .frame(width: 1, height: 1)
                                }
                            }
                            .offset(x: target == nil ? 0 : context.pager.offset + (active ? 0 : context.pager.previewOffset))
                            .allowsHitTesting(active && !context.pager.moving)
                            .accessibilityHidden(!active)
                    }
                }
                .clipShape(SectionViewportClip(
                    top: max(geometry.safeAreaInsets.top, geometry.frame(in: .global).minY),
                    bottom: geometry.safeAreaInsets.bottom + FeedChrome.bottomBarReservedHeight))
                .background(Palette.background)
                .background {
                    if let target, let request = context.pager.mountRequest {
                        HeaderSectionMountBridge(pager: context.pager, index: target, request: request)
                            .allowsHitTesting(false)
                    }
                }
                .background {
                    HeaderSectionGestureBridge(pager: context.pager,
                        topInset: topInset + geometry.safeAreaInsets.top,
                        bottomInset: geometry.safeAreaInsets.bottom, reducedMotion: reducedMotion)
                }
                .onAppear { context.pager.resize(geometry.size.width) }
                .onChange(of: geometry.size.width) { _, width in context.pager.resize(width) }
                .overlay(alignment: .bottomLeading) {
                    if AppMode.qa {
                        HeaderSectionStateQA(pager: context.pager, identifier: context.identifier)
                            .frame(width: 1, height: 1).allowsHitTesting(false)
                    }
                }
            } else { page(selection, true) }
        }
    }
}

/// Page neighbours stay horizontally clipped; vertical scroll content can
/// continue behind the fixed bars and into their surrounding safe-area space.
private struct SectionViewportClip: Shape {
    var top: CGFloat
    var bottom: CGFloat
    func path(in rect: CGRect) -> Path {
        Path(CGRect(x: rect.minX, y: rect.minY - top, width: rect.width, height: rect.height + top + bottom))
    }
}

/// Like HG's requestAnimationFrame after mounting its keyed neighbour: start a tap
/// slide only after the new pane has a real layout/frame. No guessed sleep duration.
private struct HeaderSectionMountBridge: UIViewRepresentable {
    let pager: HeaderSectionPager
    let index: Int
    let request: UUID
    func makeUIView(context: Context) -> Probe { Probe() }
    func updateUIView(_ view: Probe, context: Context) {
        view.ready = { [weak pager] in pager?.paneMounted(index, request: request) }
    }
    static func dismantleUIView(_ view: Probe, coordinator: ()) { view.stop() }
    final class Probe: UIView {
        var ready: (@MainActor () -> Void)?
        private var link: CADisplayLink?
        private final class Tick: NSObject {
            weak var probe: Probe?
            @objc func tick() { probe?.tick() }
        }
        override func didMoveToWindow() {
            super.didMoveToWindow(); stop()
            guard window != nil else { return }
            let target = Tick(); target.probe = self
            let timer = CADisplayLink(target: target, selector: #selector(Tick.tick))
            timer.add(to: .main, forMode: .common); link = timer
        }
        private func tick() {
            guard window != nil, bounds.width > 0, bounds.height > 0 else { return }
            stop()
            DispatchQueue.main.async { [weak self] in self?.ready?() }
        }
        func stop() { link?.invalidate(); link = nil }
        deinit { link?.invalidate() }
    }
}

private struct HeaderSectionGestureBridge: UIViewControllerRepresentable {
    let pager: HeaderSectionPager
    let topInset: CGFloat
    let bottomInset: CGFloat
    let reducedMotion: Bool
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.pager = pager; controller.topInset = topInset; controller.bottomInset = bottomInset; controller.reducedMotion = reducedMotion
    }
    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) { controller.detach() }
    final class Controller: UIViewController, UIGestureRecognizerDelegate {
        var pager: HeaderSectionPager?
        var topInset: CGFloat = 0
        var bottomInset: CGFloat = 0
        var reducedMotion = false
        private var visible = false
        private weak var installedWindow: UIWindow?
        private let leading = UIPanGestureRecognizer()
        private let trailing = UIPanGestureRecognizer()
        override func loadView() { view = UIView(); view.isUserInteractionEnabled = false }
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated); visible = true
            guard let window = view.window, installedWindow !== window else { return }
            detach(); visible = true; installedWindow = window
            for gesture in [leading, trailing] {
                gesture.delegate = self; gesture.maximumNumberOfTouches = 1
                gesture.cancelsTouchesInView = true
                gesture.delaysTouchesBegan = true
                gesture.delaysTouchesEnded = true
                gesture.addTarget(self, action: #selector(changed(_:))); window.addGestureRecognizer(gesture)
            }
        }
        override func viewWillDisappear(_ animated: Bool) { super.viewWillDisappear(animated); detach() }
        func detach() {
            visible = false; pager?.cancel()
            for gesture in [leading, trailing] { installedWindow?.removeGestureRecognizer(gesture); gesture.removeTarget(self, action: #selector(changed(_:))) }
            installedWindow = nil
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let window = installedWindow else { return false }
            let start = touch.location(in: window)
            guard PageEdgeGestureMetrics.contains(start.x, in: window, leading: gestureRecognizer === leading) else { return false }
            let point = touch.location(in: view)
            guard visible, point.y > topInset, point.y < view.bounds.height - bottomInset else { return false }
            var hit = touch.view
            while let current = hit {
                if current is UITextField || current is UITextView || current is UISlider || current is UISwitch { return false }
                hit = current.superview
            }
            return true
        }
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard visible, let pager, pager.canBeginGesture,
                  HeaderSectionSwipePolicy.target(selection: pager.selection, count: pager.count, fromLeading: gestureRecognizer === leading) != nil,
                  let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: view)
            return (gestureRecognizer === leading ? velocity.x : -velocity.x) > abs(velocity.y) * 1.2
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            otherGestureRecognizer is UIPanGestureRecognizer && otherGestureRecognizer.view is UIScrollView
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            otherGestureRecognizer is UITapGestureRecognizer || otherGestureRecognizer is UILongPressGestureRecognizer
        }
        @objc private func changed(_ pan: UIPanGestureRecognizer) {
            guard let pager else { return }
            switch pan.state {
            case .began:
                guard pager.begin(fromLeading: pan === leading) else { return }
                pager.update(pan.translation(in: view).x)
            case .changed: pager.update(pan.translation(in: view).x)
            case .ended: pager.end(velocity: pan.velocity(in: view).x, cancelled: false, reducedMotion: reducedMotion)
            case .cancelled, .failed: pager.end(velocity: 0, cancelled: true, reducedMotion: reducedMotion)
            default: break
            }
        }
    }
}


/// A current-tab tap is an event, not saved navigation state: it must never
/// replay merely because a covered page reappears or a neighbouring pane mounts.
private struct HeaderReselectionAction: ViewModifier {
    let action: @MainActor () async -> Void
    @Environment(\.headerSectionContext) private var context
    @Environment(\.headerSectionPreview) private var isPreview
    @State private var task: Task<Void, Never>?
    @State private var request: UUID?
    func body(content: Content) -> some View {
        content.onReceive(context?.pager.currentSelectionTaps.eraseToAnyPublisher() ?? Empty<Int, Never>().eraseToAnyPublisher()) { index in
            guard !isPreview, context?.pager.selection == index, task == nil else { return }
            let token = UUID(); request = token
            task = Task { @MainActor in
                guard !Task.isCancelled, !isPreview, context?.pager.selection == index else { return }
                await action()
                if request == token { task = nil; request = nil }
            }
        }
        .onDisappear { request = nil; task?.cancel(); task = nil }
    }
}
extension View {
    func onHeaderReselection(_ action: @escaping @MainActor () async -> Void) -> some View {
        modifier(HeaderReselectionAction(action: action))
    }
}
