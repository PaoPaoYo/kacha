import AppKit
import Carbon.HIToolbox
import SwiftUI

@MainActor
enum TextAnnotationEditor {
    static func configure(_ textView: NSTextView) {
        textView.drawsBackground = false
        textView.isRichText = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainerInset = .zero
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.lineFragmentPadding = 0
    }
}

struct TextAnnotationEditorView: NSViewRepresentable {
    @Binding var text: String
    let fontSize: CGFloat
    let color: NSColor
    let onCommit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onCommit: onCommit)
    }

    func makeNSView(context: Context) -> EditorTextView {
        let textView = EditorTextView()
        TextAnnotationEditor.configure(textView)
        textView.delegate = context.coordinator
        textView.onCommit = onCommit
        return textView
    }

    func updateNSView(_ textView: EditorTextView, context: Context) {
        if textView.string != text {
            textView.string = text
        }
        textView.font = .systemFont(ofSize: fontSize)
        textView.textColor = color
        textView.onCommit = onCommit
        textView.textContainer?.containerSize = CGSize(
            width: max(textView.bounds.width, 1),
            height: .greatestFiniteMagnitude
        )
        if textView.window?.firstResponder !== textView {
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        let onCommit: () -> Void

        init(text: Binding<String>, onCommit: @escaping () -> Void) {
            _text = text
            self.onCommit = onCommit
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text = textView.string
        }
    }
}

final class EditorTextView: NSTextView {
    var onCommit: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Return), !event.modifierFlags.contains(.shift) {
            onCommit?()
            return
        }
        super.keyDown(with: event)
    }
}
