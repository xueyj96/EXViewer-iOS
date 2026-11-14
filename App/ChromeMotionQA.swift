import SwiftUI
import UIKit

/// Records the incoming feed's vertical inset, including its presentation frames.
struct FeedClearanceMotionQA: AnimatableModifier {
    var clearance: CGFloat
    var animatableData: CGFloat { get { clearance } set { clearance = newValue } }
    func body(content: Content) -> some View {
        content.background(ChromeMotionQA(clearance: clearance, identifier: "feed.layout.clearance"))
    }
}

struct ChromeEdgeInteractionQA: UIViewRepresentable {
    let handoff: EdgeReturnChromeHandoff
    let gate: EdgeTouchGate
    func makeUIView(context: Context) -> Probe { Probe() }
    func updateUIView(_ view: Probe, context: Context) {
        view.handoff = handoff; view.gate = gate
        view.isAccessibilityElement = true; view.accessibilityIdentifier = "chrome.edge.interaction"
        view.accessibilityLabel = "边缘交接状态"
    }
    final class Probe: UIView {
        weak var handoff: EdgeReturnChromeHandoff?
        weak var gate: EdgeTouchGate?
        override var accessibilityLabel: String? {
            get { "边缘交接状态;rejected=\(gate?.rejectedGalleryActivations ?? 0)" }
            set { }
        }
        override var accessibilityValue: String? {
            get { "pending=\(handoff?.pending ?? false);blocked=\(gate?.blocksGalleryActions ?? false)" }
            set { }
        }
    }
}

/// Bounded readback of the actual values delivered by the shell's animatable pass.
/// No state is published back into production layout.
struct ChromeMotionQA: UIViewRepresentable {
    let clearance: CGFloat
    var identifier = "chrome.motion.samples"
    func makeUIView(context: Context) -> Probe { Probe(identifier: identifier) }
    func updateUIView(_ view: Probe, context: Context) { view.record(clearance) }
    final class Probe: UIView {
        private var samples: [CGFloat] = []
        init(identifier: String) {
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            isAccessibilityElement = true
            accessibilityIdentifier = identifier
            accessibilityLabel = "栏占位动画采样"
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        func record(_ value: CGFloat) {
            guard samples.last.map({ abs($0 - value) > 0.05 }) ?? true else { return }
            samples.append(value)
            if samples.count > 192 { samples.removeFirst(samples.count - 192) }
        }
        override var accessibilityValue: String? {
            get { samples.map { String(format: "%.2f", Double($0)) }.joined(separator: ",") }
            set { }
        }
    }
}

/// Presentation-layer position sampling catches the snapshot/live handoff, not just target heights.
/// Mounted only by QA fixtures; no timer or collection exists in installed production paths.
struct ChromePositionQA: UIViewRepresentable {
    let identifier: String
    func makeUIView(context: Context) -> Probe { Probe(identifier: identifier) }
    func updateUIView(_ view: Probe, context: Context) { }
    final class Probe: UIView {
        private var samples: [CGFloat] = []
        private var link: CADisplayLink?
        private final class Tick: NSObject {
            weak var probe: Probe?
            @objc func tick() { probe?.sample() }
        }
        init(identifier: String) {
            super.init(frame: .zero)
            isUserInteractionEnabled = false; isAccessibilityElement = true
            accessibilityIdentifier = identifier; accessibilityLabel = "内容位置采样"
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
        override func didMoveToWindow() {
            super.didMoveToWindow(); link?.invalidate(); link = nil
            guard window != nil else { return }
            let tick = Tick(); tick.probe = self
            let timer = CADisplayLink(target: tick, selector: #selector(Tick.tick))
            timer.add(to: .main, forMode: .common); link = timer
        }
        deinit { link?.invalidate() }
        private func sample() {
            guard let window else { return }
            let source = layer.presentation() ?? layer
            let y = source.convert(.zero, to: window.layer.presentation() ?? window.layer).y
            guard y.isFinite, samples.last.map({ abs($0 - y) > 0.1 }) ?? true else { return }
            samples.append(y)
            if samples.count > 192 { samples.removeFirst(samples.count - 192) }
        }
        override var accessibilityValue: String? {
            get { samples.map { String(format: "%.2f", Double($0)) }.joined(separator: ",") }
            set { }
        }
    }
}

/// QA-only identity readback; independent of layout and never published into SwiftUI state.
struct HeaderSectionPaneQA: UIViewRepresentable {
    let identifier: String
    static var instances: [String: [String]] = [:]
    func makeUIView(context: Context) -> UIView {
        Self.instances[identifier, default: []].append(UUID().uuidString)
        if Self.instances[identifier, default: []].count > 128 { Self.instances[identifier]?.removeFirst() }
        return UIView()
    }
    func updateUIView(_ view: UIView, context: Context) { }
}
struct HeaderSectionStateQA: UIViewRepresentable {
    let pager: HeaderSectionPager
    let identifier: String
    func makeUIView(context: Context) -> Probe { Probe() }
    func updateUIView(_ view: Probe, context: Context) {
        view.pager = pager; view.identifier = identifier
        view.isAccessibilityElement = true; view.accessibilityIdentifier = "\(identifier).paging"
        view.accessibilityLabel = "分栏转场状态"
    }
    final class Probe: UIView {
        weak var pager: HeaderSectionPager?
        var identifier = ""
        override var accessibilityLabel: String? {
            get {
                guard let window else { return "分栏转场状态" }
                return "分栏转场状态;left=\(window.safeAreaInsets.left);right=\(window.safeAreaInsets.right);width=\(window.bounds.width)"
            }
            set { }
        }
        override var accessibilityValue: String? {
            get {
                guard let pager else { return nil }
                let counts = (0..<pager.count).map { "\($0):\(HeaderSectionPaneQA.instances["\(identifier).pane.\($0)"]?.count ?? 0)" }.joined(separator: ",")
                return "selection=\(pager.selection);target=\(pager.target ?? -1);offset=\(Int(pager.offset));settling=\(pager.settling);locked=\(pager.locked);resizing=\(pager.layoutSettlementCount);instances=\(counts)"
            }
            set { }
        }
    }
}
