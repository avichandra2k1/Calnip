import AppKit
import SwiftUI

extension Notification.Name {
    static let calnipPanelDidShow = Notification.Name("com.avi.calnip.panelDidShow")
}

/// Single-line NSTextView with Todoist-style inline chip highlighting.
struct TokenField: NSViewRepresentable {
    @Binding var text: String
    var onSubmit: () -> Void
    var onCancel: () -> Void

    static let font = NSFont.systemFont(ofSize: 24, weight: .regular)

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSTextView {
        let textView = SingleLineTextView()
        textView.delegate = context.coordinator
        textView.font = Self.font
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.insertionPointColor = .controlAccentColor
        textView.typingAttributes = Coordinator.baseAttributes
        context.coordinator.textView = textView

        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.panelDidShow),
            name: .calnipPanelDidShow,
            object: nil
        )
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

        static let baseAttributes: [NSAttributedString.Key: Any] = [
            .font: TokenField.font,
            .foregroundColor: NSColor.labelColor,
        ]

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
            storage.setAttributes(Self.baseAttributes, range: full)
            for token in Parser.parse(textView.string).tokens {
                storage.addAttributes([
                    .foregroundColor: NSColor.controlAccentColor,
                    .backgroundColor: NSColor.controlAccentColor.withAlphaComponent(0.14),
                ], range: token.range)
            }
            storage.endEditing()
            textView.typingAttributes = Self.baseAttributes
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true
            default:
                return false
            }
        }
    }
}

/// Grows to fill width, single line tall.
final class SingleLineTextView: NSTextView {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: TokenField.font.boundingRectForFont.height + 4)
    }
}
