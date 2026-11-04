import SwiftUI
import UIKit

/// Keep these settings as one native control with explicit value-change
/// handling, including inside a Form with interactive navigation gestures.
struct LoadingConcurrencyPicker: UIViewRepresentable {
    let title: String
    let choices: [Int]
    @Binding var selection: Int
    let identifier: String

    func makeUIView(context: Context) -> UISegmentedControl {
        let control = UISegmentedControl(items: choices.map(String.init))
        control.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        control.accessibilityIdentifier = identifier
        control.accessibilityLabel = title
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return control
    }
    func updateUIView(_ control: UISegmentedControl, context: Context) {
        context.coordinator.picker = self
        control.selectedSegmentIndex = choices.firstIndex(of: selection) ?? UISegmentedControl.noSegment
        control.accessibilityValue = String(selection)
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    final class Coordinator: NSObject {
        var picker: LoadingConcurrencyPicker
        init(_ picker: LoadingConcurrencyPicker) { self.picker = picker }
        @objc func changed(_ control: UISegmentedControl) {
            guard picker.choices.indices.contains(control.selectedSegmentIndex) else { return }
            let value = picker.choices[control.selectedSegmentIndex]
            picker.selection = value
            control.accessibilityValue = String(value)
        }
    }
}
