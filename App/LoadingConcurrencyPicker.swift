import SwiftUI
import UIKit

struct LoadingValueSlider: UIViewRepresentable {
    enum Scale {
        case range(ClosedRange<Int>)
        case choices([Int])

        var positions: ClosedRange<Int> {
            switch self {
            case .range(let range): range
            case .choices(let choices): 0...(choices.count - 1)
            }
        }

        func position(for value: Int) -> Int {
            switch self {
            case .range: value
            case .choices(let choices): choices.firstIndex(of: value) ?? 0
            }
        }

        func value(at position: Int) -> Int {
            let position = min(max(position, positions.lowerBound), positions.upperBound)
            switch self {
            case .range: return position
            case .choices(let choices): return choices[position]
            }
        }
    }

    let title: String
    let identifier: String
    let unit: String
    let scale: Scale
    @Binding var value: Int
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .caption) private var scaledNumberSize: CGFloat = 13

    func makeUIView(context: Context) -> UISlider {
        let slider = NumberedSlider()
        if case .choices = scale { slider.usesDiscreteAccessibilitySteps = true }
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        slider.accessibilityIdentifier = identifier
        slider.accessibilityLabel = title
        slider.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        slider.addTarget(context.coordinator, action: #selector(Coordinator.finished(_:)),
                         for: [.touchUpInside, .touchUpOutside, .touchCancel])
        return slider
    }

    func updateUIView(_ slider: UISlider, context: Context) {
        context.coordinator.view = self
        if !slider.isTracking {
            slider.minimumValue = Float(scale.positions.lowerBound)
            slider.maximumValue = Float(scale.positions.upperBound)
            slider.value = Float(scale.position(for: value))
        }
        context.coordinator.updateThumb(slider, count: value)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UISlider, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        return CGSize(width: width, height: FeedChrome.rowHeight)
    }

    func makeCoordinator() -> Coordinator { Coordinator(view: self) }

    private final class NumberedSlider: UISlider {
        override var intrinsicContentSize: CGSize {
            CGSize(width: super.intrinsicContentSize.width, height: FeedChrome.rowHeight)
        }
        var usesDiscreteAccessibilitySteps = false

        override func accessibilityIncrement() {
            if usesDiscreteAccessibilitySteps { moveOneStep(1) } else { super.accessibilityIncrement() }
        }

        override func accessibilityDecrement() {
            if usesDiscreteAccessibilitySteps { moveOneStep(-1) } else { super.accessibilityDecrement() }
        }

        private func moveOneStep(_ step: Float) {
            value = min(max(value.rounded() + step, minimumValue), maximumValue)
            sendActions(for: .valueChanged)
        }
    }

    @MainActor final class Coordinator: NSObject {
        var view: LoadingValueSlider

        private struct Thumb: Equatable {
            let count: Int
            let numberSize: CGFloat
            let dark: Bool
        }

        private var thumb: Thumb?

        init(view: LoadingValueSlider) { self.view = view }

        @objc func changed(_ slider: UISlider) {
            let count = view.scale.value(at: Int(slider.value.rounded()))
            if view.value != count { view.value = count }
            updateThumb(slider, count: count)
        }

        @objc func finished(_ slider: UISlider) {
            changed(slider)
            slider.value = Float(view.scale.position(for: view.value))
        }

        func updateThumb(_ slider: UISlider, count: Int) {
            let next = Thumb(count: count, numberSize: min(22, view.scaledNumberSize), dark: view.colorScheme == .dark)
            guard thumb != next else { return }
            thumb = next
            let image = makeThumb(next)
            slider.setThumbImage(image, for: .normal)
            slider.setThumbImage(image, for: .highlighted)
            slider.accessibilityValue = "\(count) \(view.unit)"
        }

        private func makeThumb(_ thumb: Thumb) -> UIImage {
            let faceHeight = max(30, thumb.numberSize + 16)
            let size = CGSize(width: max(40, thumb.numberSize * 2 + 16), height: max(FeedChrome.rowHeight, faceHeight))
            let shape = CGRect(x: 3, y: (size.height - faceHeight) / 2 + 4,
                               width: size.width - 6, height: faceHeight - 8)
            let traits = UITraitCollection(userInterfaceStyle: thumb.dark ? .dark : .light)
            let fill = thumb.dark ? UIColor.tertiarySystemBackground.resolvedColor(with: traits) : .white
            let text = NSAttributedString(string: String(thumb.count), attributes: [
                .font: UIFont.monospacedDigitSystemFont(ofSize: thumb.numberSize, weight: .semibold),
                .foregroundColor: UIColor.label.resolvedColor(with: traits)
            ])
            return UIGraphicsImageRenderer(size: size).image { context in
                let outline = UIBezierPath(roundedRect: shape, cornerRadius: shape.height / 2)
                context.cgContext.saveGState()
                context.cgContext.setShadow(offset: CGSize(width: 0, height: 1), blur: 3,
                                            color: UIColor.black.withAlphaComponent(0.20).cgColor)
                fill.setFill()
                outline.fill()
                context.cgContext.restoreGState()
                UIColor.separator.resolvedColor(with: traits).withAlphaComponent(0.24).setStroke()
                outline.lineWidth = 0.5
                outline.stroke()
                let textSize = text.size()
                text.draw(at: CGPoint(x: shape.midX - textSize.width / 2, y: shape.midY - textSize.height / 2))
            }.withRenderingMode(.alwaysOriginal)
        }
    }
}
