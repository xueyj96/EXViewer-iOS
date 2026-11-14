import SwiftUI
import UIKit.UIGestureRecognizerSubclass

/// Observes the window's touch stream without competing with paging or scrolling.
struct ReaderGestureBridge: UIViewRepresentable {
    var tracksActivity: Bool
    var onActivity: (Bool) -> Void

    func makeUIView(context: Context) -> Surface { Surface() }
    func updateUIView(_ view: Surface, context: Context) {
        view.onActivity = onActivity
        view.update(tracksActivity: tracksActivity)
    }
    static func dismantleUIView(_ view: Surface, coordinator: ()) { view.detach() }

    final class Surface: UIView, UIGestureRecognizerDelegate {
        private weak var installedWindow: UIWindow?
        private let observation = TouchObservation()
        private var tracksActivity = false
        var onActivity: ((Bool) -> Void)?

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

        }
        required init?(coder: NSCoder) { nil }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard installedWindow !== window else { return }
            detach()
            installedWindow = window
            window?.addGestureRecognizer(observation)
        }

        func update(tracksActivity: Bool) {
            self.tracksActivity = tracksActivity
            if observation.isEnabled != tracksActivity { observation.isEnabled = tracksActivity }
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
        var onChange: ((Bool) -> Void)?

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            if self.touches.isEmpty {
                onChange?(true)
            }
            self.touches.formUnion(touches)
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
            end(touches)
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { end(touches) }
        override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
        override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

        override func reset() {
            super.reset()
            if !touches.isEmpty { touches.removeAll(); onChange?(false) }
        }

        private func end(_ ended: Set<UITouch>) {
            touches.subtract(ended)
            if touches.isEmpty { onChange?(false); state = .failed }
        }

    }
}
