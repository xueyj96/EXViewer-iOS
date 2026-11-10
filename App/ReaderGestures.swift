import SwiftUI
import UIKit.UIGestureRecognizerSubclass

/// Observes the window's touch stream without competing with paging or scrolling.
struct ReaderGestureBridge: UIViewRepresentable {
    var tracksActivity: Bool
    var allowsBack: Bool
    var onActivity: (Bool) -> Void
    var onBack: () -> Void

    func makeUIView(context: Context) -> Surface { Surface() }
    func updateUIView(_ view: Surface, context: Context) {
        view.onActivity = onActivity
        view.onBack = onBack
        view.update(tracksActivity: tracksActivity, allowsBack: allowsBack)
    }
    static func dismantleUIView(_ view: Surface, coordinator: ()) { view.detach() }

    final class Surface: UIView, UIGestureRecognizerDelegate {
        private weak var installedWindow: UIWindow?
        private let observation = TouchObservation()
        private var allowsBack = false
        private var tracksActivity = false
        var onActivity: ((Bool) -> Void)?
        var onBack: (() -> Void)?

        init() {
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            observation.delegate = self
            observation.isEnabled = false
            observation.cancelsTouchesInView = false
            observation.onChange = { [weak self] active in
                DispatchQueue.main.async { [weak self] in
                    if let self, self.tracksActivity { self.onActivity?(active) }
                }
            }
            observation.onEdgeSwipe = { [weak self] in
                DispatchQueue.main.async { [weak self] in
                    if let self, self.allowsBack, self.installedWindow != nil { self.onBack?() }
                }
            }
        }
        required init?(coder: NSCoder) { nil }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard installedWindow !== window else { return }
            detach()
            installedWindow = window
            window?.addGestureRecognizer(observation)
        }

        func update(tracksActivity: Bool, allowsBack: Bool) {
            self.tracksActivity = tracksActivity
            self.allowsBack = allowsBack
            if !allowsBack { observation.edgeStart = nil }
            observation.allowsBack = allowsBack
            let enabled = tracksActivity || allowsBack
            if observation.isEnabled != enabled { observation.isEnabled = enabled }
        }

        func detach() {
            installedWindow?.removeGestureRecognizer(observation)
            installedWindow = nil
        }

        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            bounds.contains(touch.location(in: self))
        }
    }

    private final class TouchObservation: UIGestureRecognizer {
        private var touches = Set<UITouch>()
        var allowsBack = false
        var edgeStart: CGPoint?
        var onChange: ((Bool) -> Void)?
        var onEdgeSwipe: (() -> Void)?

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            if self.touches.isEmpty {
                onChange?(true)
                if allowsBack, touches.count == 1, let touch = touches.first, let view,
                   !Self.isControl(touch.view) {
                    let start = touch.location(in: view)
                    if start.x <= ReaderEdgeBackPolicy.leadingInset { edgeStart = start }
                }
            } else {
                edgeStart = nil
            }
            self.touches.formUnion(touches)
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
            if let start = edgeStart, let touch = touches.first, let view {
                let end = touch.location(in: view)
                let translation = CGSize(width: end.x - start.x, height: end.y - start.y)
                if ReaderEdgeBackPolicy.completes(startX: start.x, translation: translation) { onEdgeSwipe?() }
            }
            end(touches)
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { end(touches) }
        override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
        override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

        override func reset() {
            super.reset()
            edgeStart = nil
            if !touches.isEmpty { touches.removeAll(); onChange?(false) }
        }

        private func end(_ ended: Set<UITouch>) {
            edgeStart = nil
            touches.subtract(ended)
            if touches.isEmpty { onChange?(false); state = .failed }
        }

        private static func isControl(_ view: UIView?) -> Bool {
            var ancestor = view
            while let current = ancestor {
                if current is UIControl { return true }
                ancestor = current.superview
            }
            return false
        }
    }
}
