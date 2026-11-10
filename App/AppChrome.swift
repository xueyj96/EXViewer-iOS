import SwiftUI
import UIKit

enum AppShape {
    static let control = RoundedRectangle(cornerRadius: 8, style: .continuous)
    static let card = RoundedRectangle(cornerRadius: 12, style: .continuous)
    static let panelInset: CGFloat = 6
    static let panel = aligned(with: control, offset: panelInset)
    static let segmentInset: CGFloat = 3
    static let segment = aligned(with: control, offset: -segmentInset)

    // Offset the radius by the gap so nested corners follow the same curve.
    static func aligned(with shape: RoundedRectangle, offset: CGFloat) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: max(0, shape.cornerSize.width + offset), style: .continuous)
    }
}

enum FloatingChrome {
    static let surfaceOpacity = 0.90
    static let background = Color(uiColor: .systemBackground).opacity(surfaceOpacity)
    static let headerBackground = Color(uiColor: .secondarySystemGroupedBackground).opacity(surfaceOpacity)
    static let readerBackground = Color.black.opacity(surfaceOpacity)
}

struct AppControlSurface: ViewModifier {
    var selected = false
    var insets = EdgeInsets()
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        let shape = AppShape.control
        content
            .background {
                ZStack {
                    shape.fill(FloatingChrome.background)
                    if selected { shape.fill(Color.accentColor.opacity(0.08)) }
                }.padding(insets)
            }
            .overlay {
                shape.strokeBorder(selected ? Color.accentColor.opacity(0.30) : Color.primary.opacity(scheme == .dark ? 0.16 : 0.10), lineWidth: 0.5)
                    .padding(insets)
            }
    }
}

enum TagChipMetrics {
    static let faceHeight: CGFloat = 26
    static let targetHeight: CGFloat = 32
    static var verticalOverhang: CGFloat { (targetHeight - faceHeight) / 2 }
}

extension View {
    func formRowSurface(shape: RoundedRectangle = AppShape.card, outer: Bool = false) -> some View {
        background(outer ? Color.primary.opacity(0.035) : Color(uiColor: .secondarySystemGroupedBackground), in: shape)
            .overlay {
                shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                    .allowsHitTesting(false)
            }
    }

    func tagChipFaceLayout() -> some View {
        padding(.horizontal, 8)
            .padding(.vertical, 2)
            .frame(minHeight: TagChipMetrics.faceHeight)
    }

    func tagChipTargetLayout() -> some View {
        frame(minWidth: FeedChrome.rowHeight, minHeight: TagChipMetrics.targetHeight)
    }

    func appControlSurface(selected: Bool = false, verticalInset: CGFloat = 0) -> some View {
        appControlSurface(selected: selected, insets: EdgeInsets(top: verticalInset, leading: 0, bottom: verticalInset, trailing: 0))
    }

    func appControlSurface(selected: Bool = false, insets: EdgeInsets) -> some View {
        modifier(AppControlSurface(selected: selected, insets: insets))
    }
}

struct CompactFormSegmentPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [Value]
    let title: (Value) -> String
    let accessibilityLabel: String
    let identifier: String
    var body: some View {
        HStack(spacing: FeedChrome.panelSpacing) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                Button { selection = option } label: {
                    Text(title(option))
                        .font(.footnote.weight(selection == option ? .semibold : .regular))
                        .foregroundStyle(selection == option ? Color.accentColor : Color.primary)
                        .padding(.horizontal, FeedChrome.panelSpacing)
                        .frame(maxWidth: .infinity, minHeight: FeedChrome.compactFormRowHeight)
                        .background {
                            AppShape.segment
                                .fill(selection == option ? Color.accentColor.opacity(0.12) : Color.clear)
                                .padding(.vertical, AppShape.segmentInset)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == option ? .isSelected : [])
                .accessibilityIdentifier("\(identifier).\(index)")
            }
        }
        .padding(.horizontal, AppShape.segmentInset)
        .background(Color.primary.opacity(0.045), in: AppShape.control)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(identifier)
    }
}

struct TagChipButtonStyle: ButtonStyle {
    var selected = false
    var allowsMultiline = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.footnote)
            .lineLimit(allowsMultiline ? nil : 1)
            .tagChipFaceLayout()
            .background(selected ? Color.accentColor.opacity(0.12) : .clear, in: AppShape.control)
            .overlay {
                AppShape.control.strokeBorder(
                    selected ? Color.accentColor.opacity(0.40) : Color.primary.opacity(0.15), lineWidth: 0.5
                ).allowsHitTesting(false)
            }
            .tagChipTargetLayout()
            .contentShape(Rectangle())
            .opacity(enabled ? (configuration.isPressed ? 0.65 : 1) : 0.38)
    }
}

/// Flat controls follow the same compact surface and hit area as CivitViewer.
struct AppActionButtonStyle: ButtonStyle {
    enum Tone { case neutral, accent, destructive }
    var tone: Tone = .neutral
    var singleLine = false
    var minSurfaceHeight: CGFloat = 32
    var labelFont = Font.subheadline.weight(.medium)
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let destructive = tone == .destructive || configuration.role == .destructive
        let ink: Color = destructive ? .red : (tone == .accent ? .accentColor : .primary)
        let fill = destructive ? Color.red.opacity(scheme == .dark ? 0.18 : 0.09)
            : (tone == .accent ? Color.accentColor.opacity(scheme == .dark ? 0.20 : 0.10)
               : Color.primary.opacity(scheme == .dark ? 0.10 : 0.06))
        configuration.label
            .lineLimit(singleLine ? 1 : nil)
            .fixedSize(horizontal: singleLine, vertical: false)
            .font(labelFont)
            .foregroundStyle(ink)
            .padding(.horizontal, 12)
            .frame(minHeight: minSurfaceHeight)
            .background(fill, in: AppShape.control)
            .overlay(AppShape.control.strokeBorder(ink.opacity(scheme == .dark ? 0.16 : 0.08), lineWidth: 0.5))
            .opacity(enabled ? (configuration.isPressed ? 0.65 : 1) : 0.38)
            .frame(minWidth: FeedChrome.rowHeight, minHeight: FeedChrome.rowHeight)
            .contentShape(Rectangle())
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct AppToolbarItem<Content: View>: ToolbarContent {
    var placement: ToolbarItemPlacement = .automatic
    var tone: AppActionButtonStyle.Tone = .neutral
    @ViewBuilder let content: () -> Content

    var body: some ToolbarContent {
        if #available(iOS 26.0, *) {
            ToolbarItem(placement: placement) {
                content().buttonStyle(AppActionButtonStyle(tone: tone, singleLine: true))
                    .fixedSize(horizontal: true, vertical: false)
            }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: placement) {
                content().buttonStyle(AppActionButtonStyle(tone: tone, singleLine: true))
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
    }
}

extension View {
    func appNavigationChrome(backButton: Bool = false, showsToolbarBackButton: Bool = true) -> some View {
        modifier(AppNavigationChromeModifier(backButton: backButton, showsToolbarBackButton: showsToolbarBackButton))
    }
}

private struct AppNavigationChromeModifier: ViewModifier {
    let backButton: Bool
    let showsToolbarBackButton: Bool
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        content
            .navigationBarBackButtonHidden(backButton)
            .toolbar {
                if backButton && showsToolbarBackButton {
                    AppToolbarItem(placement: .topBarLeading) {
                        Button { dismiss() } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 16, weight: .medium))
                        }
                        .accessibilityLabel("返回")
                        .accessibilityIdentifier("BackButton")
                    }
                }
            }
            .background(NavigationChrome(backButton: backButton).frame(width: AppMode.qa ? 1 : 0, height: AppMode.qa ? 1 : 0).allowsHitTesting(false))
    }
}

@MainActor
private struct NavigationChrome: UIViewControllerRepresentable {
    @Environment(\.colorScheme) private var scheme
    let backButton: Bool

    func makeUIViewController(context: Context) -> Controller { Controller(scheme: scheme, backButton: backButton) }
    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.scheme = scheme; controller.backButton = backButton
        controller.applyChrome(); controller.updateInteractivePop()
    }
    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) { controller.deactivate() }

    final class Binding {
        weak var gesture: UIGestureRecognizer?
        let proxy: PopDelegate
        init(_ gesture: UIGestureRecognizer, proxy: PopDelegate) { self.gesture = gesture; self.proxy = proxy }
    }

    final class DiagnosticView: UIView {
        var readState: (() -> String)?
        override var accessibilityValue: String? {
            get { readState?() }
            set { }
        }
    }

    final class Controller: UIViewController {
        var scheme: ColorScheme
        var backButton: Bool
        private weak var styledNavigation: UINavigationController?
        private var styledScheme: ColorScheme?
        private var bindings: [ObjectIdentifier: Binding] = [:]
        private var ownershipLost: Set<ObjectIdentifier> = []
        private var visible = false
        private var lifecycle = UUID()
        private var appearanceCount = 0
        private var decisionCount = 0

        init(scheme: ColorScheme, backButton: Bool) {
            self.scheme = scheme; self.backButton = backButton
            super.init(nibName: nil, bundle: nil)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
        override func loadView() {
            if AppMode.qa {
                let diagnostic = DiagnosticView()
                diagnostic.isAccessibilityElement = true; diagnostic.accessibilityIdentifier = "qa.navigation.flat"
                diagnostic.readState = { [weak self] in
                    guard let self, let navigation = self.navigationController else { return "navigation=none" }
                    return self.diagnosticValue(navigation)
                }
                view = diagnostic
            } else { view = UIView() }
            view.isUserInteractionEnabled = false
        }
        override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); applyChrome() }
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            appearanceCount += 1
            visible = true; lifecycle = UUID(); ownershipLost.removeAll()
            updateInteractivePop()
            DispatchQueue.main.async { [weak self] in self?.updateInteractivePop() }
        }
        override func viewWillDisappear(_ animated: Bool) { super.viewWillDisappear(animated); deactivate() }
        override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); deactivate() }
        func deactivate() { visible = false; lifecycle = UUID(); restoreBindings() }

        func applyChrome() {
            guard let navigation = navigationController,
                  styledNavigation !== navigation || styledScheme != scheme else { return }
            styledNavigation = navigation; styledScheme = scheme
            let traits = UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light)
            let ink = UIColor.label.resolvedColor(with: traits)
            let appearance = UINavigationBarAppearance()
            appearance.configureWithTransparentBackground()
            appearance.backgroundColor = UIColor.systemBackground.resolvedColor(with: traits)
                .withAlphaComponent(CGFloat(FloatingChrome.surfaceOpacity))
            appearance.backgroundEffect = nil; appearance.shadowColor = .clear
            appearance.titleTextAttributes = [.foregroundColor: ink]
            navigation.navigationBar.standardAppearance = appearance
            navigation.navigationBar.scrollEdgeAppearance = appearance
            navigation.navigationBar.compactAppearance = appearance
            navigation.navigationBar.tintColor = ink
        }

        func updateInteractivePop() {
            guard let navigation = navigationController else { return }
            defer { updateDiagnostic(navigation) }
            guard backButton, visible, isViewLoaded, view.window != nil,
                  navigation.viewControllers.count > 1 else { restoreBindings(); return }
            guard navigation.transitionCoordinator == nil else { return }
            var gestures = [navigation.interactivePopGestureRecognizer].compactMap { $0 }
            if #available(iOS 26.0, *), let content = navigation.interactiveContentPopGestureRecognizer,
               !gestures.contains(where: { $0 === content }) { gestures.append(content) }
            for gesture in gestures {
                let key = ObjectIdentifier(gesture)
                if let binding = bindings[key] {
                    guard gesture.delegate === binding.proxy else {
                        binding.proxy.isActive = false; bindings[key] = nil; ownershipLost.insert(key); continue
                    }
                    binding.proxy.isActive = true
                } else if !ownershipLost.contains(key) {
                    let proxy = PopDelegate(original: gesture.delegate, enabled: gesture.isEnabled, navigation: navigation)
                    proxy.isActive = true
                    proxy.onDecision = { [weak self, weak navigation] in
                        self?.decisionCount += 1
                        if let navigation { self?.updateDiagnostic(navigation) }
                    }
                    bindings[key] = Binding(gesture, proxy: proxy)
                    gesture.delegate = proxy; gesture.isEnabled = true
                }
            }
        }

        private func restoreBindings() {
            let revision = lifecycle
            for (key, binding) in bindings {
                guard let gesture = binding.gesture else { bindings[key] = nil; continue }
                if gesture.state != .began && gesture.state != .changed { binding.proxy.isActive = false }
                let restore = { [weak self] in
                    // A cancelled interactive pop can make this page visible
                    // again before its old transition completion is delivered.
                    if let self, self.visible || self.lifecycle != revision { return }
                    if let gesture = binding.gesture, gesture.delegate === binding.proxy {
                        guard gesture.state != .began && gesture.state != .changed else { return }
                        binding.proxy.isActive = false
                        gesture.delegate = binding.proxy.originalDelegate
                        gesture.isEnabled = binding.proxy.originalEnabled
                    }
                    if self?.bindings[key] === binding { self?.bindings[key] = nil }
                }
                if (gesture.state == .began || gesture.state == .changed), let transition = navigationController?.transitionCoordinator {
                    if !transition.animate(alongsideTransition: nil, completion: { _ in restore() }) { restore() }
                } else { restore() }
            }
        }

        private func updateDiagnostic(_ navigation: UINavigationController) {
            guard AppMode.qa else { return }
            view.accessibilityValue = diagnosticValue(navigation)
        }

        private func diagnosticValue(_ navigation: UINavigationController) -> String {
            let values = bindings.values.map { b in
                "enabled=\(b.gesture?.isEnabled ?? false),owned=\(b.gesture?.delegate === b.proxy),active=\(b.proxy.isActive),begin=\(b.proxy.beginCount),receive=\(b.proxy.receiveCount),events=\(b.proxy.eventCount),state=\(b.gesture?.state.rawValue ?? -1)"
            }.sorted().joined(separator: "|")
            return "stack=\(navigation.viewControllers.count);visible=\(visible);appearances=\(appearanceCount);decisions=\(decisionCount);transition=\(navigation.transitionCoordinator != nil);gestures=\(values)"
        }
    }

    @MainActor final class PopDelegate: NSObject, UIGestureRecognizerDelegate {
        // Retain the original only for restoration. Forwarding its additional
        // selectors also forwards the native hidden-back rejection on iOS 26.
        weak var originalDelegate: (any UIGestureRecognizerDelegate)?
        weak var navigation: UINavigationController?
        let originalEnabled: Bool
        var isActive = false
        var beginCount = 0
        var receiveCount = 0
        var eventCount = 0
        var onDecision: (() -> Void)?
        init(original: UIGestureRecognizerDelegate?, enabled: Bool, navigation: UINavigationController) {
            if let proxy = original as? PopDelegate { originalDelegate = proxy.originalDelegate }
            else { originalDelegate = original }
            originalEnabled = enabled; self.navigation = navigation
            super.init()
        }
        @objc(gestureRecognizer:shouldReceiveTouch:)
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            receiveCount += 1; defer { onDecision?() }
            if gestureRecognizer.state == .began || gestureRecognizer.state == .changed { return true }
            if #available(iOS 26.0, *), gestureRecognizer === navigation?.interactiveContentPopGestureRecognizer {
                var hit = touch.view
                while let view = hit {
                    if view is UIControl { return false }
                    if let scroll = view as? UIScrollView, scroll.isScrollEnabled, scroll.contentSize.width > scroll.bounds.width + 1 { return false }
                    hit = view.superview
                }
            }
            return isActive && (navigation?.viewControllers.count ?? 0) > 1 && navigation?.transitionCoordinator == nil
        }
        @objc(gestureRecognizer:shouldReceiveEvent:)
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive event: UIEvent) -> Bool {
            eventCount += 1; defer { onDecision?() }
            if gestureRecognizer.state == .began || gestureRecognizer.state == .changed { return true }
            return isActive && (navigation?.viewControllers.count ?? 0) > 1 && navigation?.transitionCoordinator == nil
        }
        @objc(gestureRecognizerShouldBegin:)
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            beginCount += 1; defer { onDecision?() }
            guard isActive, let navigation, navigation.viewControllers.count > 1,
                  navigation.transitionCoordinator == nil else { return false }
            if let pan = gestureRecognizer as? UIPanGestureRecognizer {
                let velocity = pan.velocity(in: navigation.view)
                let translation = pan.translation(in: navigation.view)
                let movement = abs(velocity.x) + abs(velocity.y) > 0.1 ? velocity : translation
                let sign: CGFloat = navigation.view.effectiveUserInterfaceLayoutDirection == .rightToLeft ? -1 : 1
                guard movement.x * sign > 0, abs(movement.x) > abs(movement.y) else { return false }
            }
            return true
        }
    }
}

struct TagWrapLayout: Layout {
    var spacing: CGFloat
    var keepsFirstPairTogether = false
    var rowSpacing: CGFloat = 0
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        return CGSize(width: width, height: rows(width: width, subviews: subviews).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, rows(width: bounds.width, subviews: subviews).frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          anchor: .topLeading, proposal: .init(width: frame.width, height: frame.height))
        }
    }

    private func rows(width: CGFloat, subviews: Subviews) -> (frames: [CGRect], height: CGFloat) {
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var frames: [CGRect] = []
        let joinsFirstPair = keepsFirstPairTogether && subviews.count > 1 && width >= 88 + spacing
        for (index, subview) in subviews.enumerated() {
            let rowBudget: CGFloat
            switch (joinsFirstPair, index) {
            case (true, 0): rowBudget = width - 44 - spacing
            case (true, 1): rowBudget = width - x
            default: rowBudget = width
            }
            let available = min(rowBudget, subview.sizeThatFits(.unspecified).width)
            let size = subview.sizeThatFits(.init(width: available, height: nil))
            if x > 0 && x + size.width > width {
                x = 0
                y += rowHeight + rowSpacing
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (frames, y + rowHeight)
    }
}
