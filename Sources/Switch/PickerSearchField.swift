import AppKit
import SwiftUI

/// AppKit's real search control, including its field editor, selection, clipboard,
/// undo stack, and standard key bindings. SwiftUI only owns its placement.
struct PickerSearchField: NSViewRepresentable {
    let text: String
    var visualScale: CGFloat = 1
    let onTextChange: (String) -> Void
    let onFocusChange: (NSSearchField, Bool) -> Void
    let onRegister: (NSSearchField) -> Void
    let onUnregister: (NSSearchField) -> Void
    let onCommit: () -> Void
    let onCancel: () -> Void
    let onNavigate: (HotkeyManager.Direction) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NativeSearchField()
        field.identifier = .pickerSearchField
        field.delegate = context.coordinator
        field.onCommit = { [weak coordinator = context.coordinator, weak field] in
            guard let coordinator, let field else { return }
            coordinator.commit(from: field)
        }
        field.onCancel = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onCancel()
        }
        field.onNavigate = { [weak coordinator = context.coordinator, weak field] direction in
            guard let coordinator, let field else { return }
            coordinator.navigate(direction, from: field)
        }
        field.placeholderString = String(localized: "Type to filter")
        PickerSearchFieldAppearance.apply(to: field, visualScale: visualScale)
        field.maximumRecents = 0
        field.sendsSearchStringImmediately = true
        field.setAccessibilityLabel(String(localized: "Type to filter"))
        onRegister(field)
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        onRegister(field)
        if field.font?.pointSize != PickerSearchFieldAppearance.fontSize(for: visualScale) {
            PickerSearchFieldAppearance.apply(to: field, visualScale: visualScale)
        }
        let editor = field.currentEditor() as? NSTextView
        let currentText = editor?.string ?? field.stringValue
        guard currentText != text else { return }

        // This path is used by the hold-style fallback and by a new invocation.
        // Never rewrite an unchanged editor: doing so would destroy Cmd+A's
        // selection before the user's replacement keystroke arrives.
        field.stringValue = text
        if let editor {
            editor.string = text
            editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        }
    }

    static func dismantleNSView(_ field: NSSearchField, coordinator: Coordinator) {
        field.delegate = nil
        if let field = field as? NativeSearchField {
            field.onCommit = nil
            field.onCancel = nil
            field.onNavigate = nil
        }
        let onUnregister = coordinator.parent.onUnregister
        DispatchQueue.main.async {
            onUnregister(field)
        }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: PickerSearchField

        init(parent: PickerSearchField) {
            self.parent = parent
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            parent.onFocusChange(field, true)
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            // `stringValue` can lag the field editor while an input method owns
            // marked text. Publish the editor's current composition so Chinese
            // results update while the user is choosing a candidate.
            let current = (field.currentEditor() as? NSTextView)?.string ?? field.stringValue
            parent.onTextChange(current)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            parent.onFocusChange(field, false)
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            // The input method owns Return, Escape, arrows, and number keys while
            // it has marked text. Let NSTextInputContext consume the first key;
            // the same key becomes a picker command again after composition ends.
            guard !textView.hasMarkedText() else { return false }

            // While editing, AppKit sends key-binding commands to the shared
            // NSTextView field editor, not to NSSearchField.keyDown. Handle the
            // picker-reserved physical keys here so they remain ordered after
            // every preceding text mutation.
            if let event = NSApp.currentEvent, event.type == .keyDown {
                switch CGKeyCode(event.keyCode) {
                case 53:
                    parent.onCancel()
                    return true
                case 36, 76:
                    commit(from: control as? NSSearchField, textView: textView)
                    return true
                case 123:
                    navigate(.left, from: control as? NSSearchField, textView: textView)
                    return true
                case 124:
                    navigate(.right, from: control as? NSSearchField, textView: textView)
                    return true
                case 125:
                    navigate(.down, from: control as? NSSearchField, textView: textView)
                    return true
                case 126:
                    navigate(.up, from: control as? NSSearchField, textView: textView)
                    return true
                default:
                    break
                }
            }

            switch NSStringFromSelector(commandSelector) {
            case "cancelOperation:":
                parent.onCancel()
                return true
            case "insertNewline:", "insertNewlineIgnoringFieldEditor:":
                commit(from: control as? NSSearchField, textView: textView)
                return true
            case "moveUp:", "moveUpAndModifySelection:":
                navigate(.up, from: control as? NSSearchField, textView: textView)
                return true
            case "moveDown:", "moveDownAndModifySelection:":
                navigate(.down, from: control as? NSSearchField, textView: textView)
                return true
            case "moveLeft:", "moveLeftAndModifySelection:":
                navigate(.left, from: control as? NSSearchField, textView: textView)
                return true
            case "moveRight:", "moveRightAndModifySelection:":
                navigate(.right, from: control as? NSSearchField, textView: textView)
                return true
            default:
                return false
            }
        }

        func commit(from field: NSSearchField) {
            flushText(from: field)
            parent.onCommit()
        }

        private func commit(from field: NSSearchField?, textView: NSTextView) {
            flushText(from: field, textView: textView)
            parent.onCommit()
        }

        func navigate(_ direction: HotkeyManager.Direction, from field: NSSearchField) {
            flushText(from: field)
            parent.onNavigate(direction)
        }

        private func navigate(
            _ direction: HotkeyManager.Direction,
            from field: NSSearchField?,
            textView: NSTextView
        ) {
            flushText(from: field, textView: textView)
            parent.onNavigate(direction)
        }

        private func flushText(from field: NSSearchField) {
            let current = (field.currentEditor() as? NSTextView)?.string ?? field.stringValue
            parent.onTextChange(current)
        }

        private func flushText(from field: NSSearchField?, textView: NSTextView) {
            let current = textView.string
            if let field, field.stringValue != current {
                field.stringValue = current
            }
            parent.onTextChange(current)
        }
    }
}

private final class NativeSearchField: NSSearchField {
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?
    var onNavigate: ((HotkeyManager.Direction) -> Void)?

    override var needsPanelToBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        if let editor = currentEditor() as? NSTextView, editor.hasMarkedText() {
            super.keyDown(with: event)
            return
        }
        switch CGKeyCode(event.keyCode) {
        case 53:
            onCancel?()
        case 36, 76:
            onCommit?()
        case 123:
            onNavigate?(.left)
        case 124:
            onNavigate?(.right)
        case 125:
            onNavigate?(.down)
        case 126:
            onNavigate?(.up)
        default:
            super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard !UserDefaults.standard.bool(forKey: SwitchPreferences.disableMouseKey) else { return }
        super.mouseDown(with: event)
    }
}

extension NSUserInterfaceItemIdentifier {
    static let pickerSearchField = NSUserInterfaceItemIdentifier("pickerSearchField")
}
