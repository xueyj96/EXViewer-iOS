import SwiftUI
import UIKit

/// A native refresh still owns the pull threshold, held inset and return animation.
/// Its indicator is drawn below floating chrome instead of behind it.
@MainActor final class FeedPullRefresh: ObservableObject {
    @Published private(set) var distance: CGFloat = 0
    @Published private(set) var refreshing = false
    @Published private(set) var attached = false
    @Published private(set) var nativeReady = false
    @Published private(set) var refreshCount = 0
    @Published private(set) var greatestPull: CGFloat = 0
    @Published private(set) var indicatorFrame: CGRect = .zero
    @Published private(set) var indicatorShows = 0
    private var recordedPresentation = false
    private weak var scroll: UIScrollView?
    private weak var control: UIRefreshControl?
    private var originalTint: UIColor?
    private var originalEnabled = true
    private var originalAccessibilityHidden = false
    private var observer: NSKeyValueObservation?
    private var owner: ObjectIdentifier?
    private var enabled = true

    var diagnostic: String {
        "attached=\(attached);native=\(nativeReady);refreshing=\(refreshing);refreshes=\(refreshCount);maxPull=\(Int(greatestPull));pull=\(Int(distance));shows=\(indicatorShows);indicator=\(Int(indicatorFrame.minX)),\(Int(indicatorFrame.minY)),\(Int(indicatorFrame.width)),\(Int(indicatorFrame.height))"
    }
    var visible: Bool { refreshing || distance > 1 }
    // A long pull exposes more content space without carrying the spinner far down the page.
    var revealedHeight: CGFloat { refreshing ? FeedChrome.rowHeight : min(FeedChrome.rowHeight, distance) }
    func recordIndicatorFrame(_ frame: CGRect) {
        guard AppMode.qa, frame.width > 0, frame.height >= 18 else { return }
        if !recordedPresentation { recordedPresentation = true; indicatorShows += 1 }
        if frame != indicatorFrame { indicatorFrame = frame }
    }
    func endIndicatorPresentation() { recordedPresentation = false }

    func refresh(enabled: Bool, action: () async -> Void) async {
        guard enabled, !refreshing else { return }
        refreshCount += 1
        refreshing = true
        hideNativeIndicator()
        await action()
        refreshing = false
        updateDistance()
    }

    func attach(_ scroll: UIScrollView, owner: ObjectIdentifier, enabled: Bool) {
        self.enabled = enabled
        if self.scroll !== scroll || self.owner != owner {
            detach()
            self.scroll = scroll; self.owner = owner
            attached = true
            observer = scroll.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.updateDistance() }
            }
        }
        hideNativeIndicator()
        updateDistance()
    }

    func detach(owner: ObjectIdentifier? = nil) {
        guard owner == nil || owner == self.owner else { return }
        observer?.invalidate(); observer = nil
        if let control {
            control.tintColor = originalTint
            control.isEnabled = originalEnabled
            control.accessibilityElementsHidden = originalAccessibilityHidden
        }
        control = nil; scroll = nil; self.owner = nil
        if attached { attached = false }
        if nativeReady { nativeReady = false }
        if distance != 0 { distance = 0 }
    }

    private func hideNativeIndicator() {
        guard let native = scroll?.refreshControl else { return }
        if control !== native {
            control?.tintColor = originalTint
            control?.isEnabled = originalEnabled
            control?.accessibilityElementsHidden = originalAccessibilityHidden
            control = native; originalTint = native.tintColor; originalEnabled = native.isEnabled
            originalAccessibilityHidden = native.accessibilityElementsHidden
            nativeReady = true
        }
        native.tintColor = .clear
        native.accessibilityElementsHidden = true
        native.isEnabled = enabled
    }

    private func updateDistance() {
        hideNativeIndicator()
        let pull = scroll.map { max(0, -($0.contentOffset.y + $0.adjustedContentInset.top)) } ?? 0
        if pull > greatestPull { greatestPull = pull }
        if abs(pull - distance) > 0.25 || (pull == 0 && distance != 0) { distance = pull }
    }
}

extension View {
    /// Install on content inside its ScrollView so the probe cannot attach to a sibling feed.
    func feedRefreshProbe(_ refresh: FeedPullRefresh, enabled: Bool) -> some View {
        background(FeedRefreshProbe(refresh: refresh, enabled: enabled).allowsHitTesting(false))
    }

    func feedPullRefresh(_ refresh: FeedPullRefresh, topInset: CGFloat, enabled: Bool,
                         action: @escaping () async -> Void) -> some View {
        refreshable { await refresh.refresh(enabled: enabled, action: action) }
            .overlay(alignment: .top) {
                if enabled, refresh.visible {
                    VStack(spacing: 0) {
                        Color.clear.frame(height: topInset).accessibilityHidden(true)
                        ProgressView().controlSize(.small).tint(.secondary)
                            .frame(maxWidth: .infinity)
                            .frame(height: refresh.revealedHeight)
                            .clipped()
                            .accessibilityLabel("正在刷新")
                            .accessibilityIdentifier("feed.refresh.indicator")
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { refresh.recordIndicatorFrame($0) }
                            .onDisappear { refresh.endIndicatorPresentation() }
                    }
                    .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .topLeading) {
                if AppMode.qa {
                    Text(" ").font(.system(size: 1)).foregroundStyle(.clear)
                        .frame(width: 1, height: 1)
                        .accessibilityIdentifier("feed.refresh.state")
                        .accessibilityLabel("Pull refresh QA state")
                        .accessibilityValue(refresh.diagnostic)
                        .allowsHitTesting(false)
                }
            }
    }
}

private struct FeedRefreshProbe: UIViewRepresentable {
    let refresh: FeedPullRefresh
    let enabled: Bool
    func makeUIView(context: Context) -> Probe { Probe(refresh: refresh) }
    func updateUIView(_ view: Probe, context: Context) {
        view.enabled = enabled
        view.resolveScroll()
    }
    static func dismantleUIView(_ view: Probe, coordinator: ()) { view.detach() }

    final class Probe: UIView {
        let refresh: FeedPullRefresh
        var enabled = true
        init(refresh: FeedPullRefresh) {
            self.refresh = refresh
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { detach() }
            else { resolveScroll() }
        }
        override func layoutSubviews() { super.layoutSubviews(); resolveScroll() }
        func resolveScroll() {
            guard window != nil else { return }
            var ancestor = superview
            while let view = ancestor {
                if let scroll = view as? UIScrollView {
                    // Publishing geometry is deferred out of SwiftUI's update pass.
                    DispatchQueue.main.async { [weak self, weak scroll] in
                        guard let self, let scroll, self.window != nil else { return }
                        self.refresh.attach(scroll, owner: ObjectIdentifier(self), enabled: self.enabled)
                    }
                    return
                }
                ancestor = view.superview
            }
        }
        func detach() { refresh.detach(owner: ObjectIdentifier(self)) }
    }
}
