import AppKit
import SwiftUI

extension Notification.Name {
    static let calnipPanelDidShow = Notification.Name("com.avi.calnip.panelDidShow")
    /// Refocus the main field without the "panel shown" side effects (scroll reset).
    static let calnipFocusField = Notification.Name("com.avi.calnip.focusField")
}

/// Single-line NSTextView with Todoist-style inline chip highlighting.
struct TokenField: NSViewRepresentable {
    @Binding var text: String
    var fontSize: CGFloat = 24
    /// Grab focus when created (the inline edit field).
    var focusOnAppear: Bool = false
    /// Refocus when the panel opens (the main field).
    var respondsToPanelShow: Bool = true
    var onSubmit: () -> Void
    var onCancel: () -> Void
    /// Return true to consume the key (selection/day browsing); false keeps caret behavior.
    var onArrow: (ArrowKey) -> Bool = { _ in false }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSTextView {
        let font = NSFont.systemFont(ofSize: fontSize)
        let textView = SingleLineTextView()
        textView.lineHeight = font.boundingRectForFont.height + 4
        textView.delegate = context.coordinator
        textView.font = font
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.insertionPointColor = .controlAccentColor
        textView.typingAttributes = context.coordinator.baseAttributes
        context.coordinator.textView = textView

        if respondsToPanelShow {
            for name in [Notification.Name.calnipPanelDidShow, .calnipFocusField] {
                NotificationCenter.default.addObserver(
                    context.coordinator,
                    selector: #selector(Coordinator.panelDidShow),
                    name: name,
                    object: nil
                )
            }
        }
        if focusOnAppear {
            DispatchQueue.main.async { [weak textView] in
                guard let textView else { return }
                textView.window?.makeFirstResponder(textView)
                textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
            }
        }
        return textView
    }

    func updateNSView(_ textView: NSTextView, context: Context) {
        context.coordinator.parent = self
        if textView.string != text {
            textView.string = text
            context.coordinator.applyHighlights()
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: TokenField
        weak var textView: NSTextView?

        var baseAttributes: [NSAttributedString.Key: Any] {
            [
                .font: NSFont.systemFont(ofSize: parent.fontSize),
                .foregroundColor: NSColor.labelColor,
            ]
        }

        init(_ parent: TokenField) {
            self.parent = parent
        }

        @objc func panelDidShow() {
            guard let textView else { return }
            textView.window?.makeFirstResponder(textView)
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            if textView.string.contains(where: \.isNewline) {
                textView.string = textView.string.filter { !$0.isNewline }
            }
            parent.text = textView.string
            applyHighlights()
        }

        func applyHighlights() {
            guard let textView, let storage = textView.textStorage else { return }
            let full = NSRange(location: 0, length: (textView.string as NSString).length)
            storage.beginEditing()
            storage.setAttributes(baseAttributes, range: full)
            for token in Parser.parse(textView.string).tokens {
                storage.addAttributes([
                    .foregroundColor: NSColor.controlAccentColor,
                    .backgroundColor: NSColor.controlAccentColor.withAlphaComponent(0.14),
                ], range: token.range)
            }
            storage.endEditing()
            textView.typingAttributes = baseAttributes
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true
            case #selector(NSResponder.moveDown(_:)):
                return parent.onArrow(.down)
            case #selector(NSResponder.moveUp(_:)):
                return parent.onArrow(.up)
            case #selector(NSResponder.moveLeft(_:)):
                return parent.onArrow(.left)
            case #selector(NSResponder.moveRight(_:)):
                return parent.onArrow(.right)
            default:
                return false
            }
        }
    }
}

/// Grows to fill width, single line tall.
final class SingleLineTextView: NSTextView {
    var lineHeight: CGFloat = 34

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: lineHeight)
    }
}
