import AppKit

/// Visual configuration kept separate from input routing so native AppKit cell
/// geometry can be regression-tested without constructing the picker model.
enum PickerSearchFieldAppearance {
    static let baseFontSize: CGFloat = 14

    static func fontSize(for visualScale: CGFloat) -> CGFloat {
        baseFontSize * max(visualScale, 0.1)
    }

    static func apply(to field: NSSearchField, visualScale: CGFloat) {
        field.font = .systemFont(ofSize: fontSize(for: visualScale), weight: .regular)
        field.textColor = .labelColor
        field.controlSize = .large
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.focusRingType = .default
    }
}
