//
//  SelectableBubbleText.swift
//  DSH-Mizar
//
//  A user bubble's words, selectable in place.
//
//  SwiftUI's own `textSelection` does not let the bubble keep its shape while
//  the system selection UI is up, and the bubble is a coloured, padded surface
//  whose selection handles have to be white. So the words are handed to a real
//  `UITextView`: it brings the system selection menu and handles with it, and
//  the bubble around it does not change.
//

import SwiftUI
import UIKit

/// The words of a bubble, in an editor that is only ever read.
struct SelectableBubbleText: UIViewRepresentable {
    let text: String
    /// Called when the selection is gone -- the operator finished, or the
    /// bubble lost focus.
    let onEnd: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onEnd: onEnd)
    }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textColor = Theme.onAccentUI
        view.tintColor = Theme.onAccentUI
        view.text = text
        view.delegate = context.coordinator
        view.accessibilityIdentifier = "message.selectable"
        // Once it is in the hierarchy: take the selection whole, so the menu
        // and the handles are up the moment the operator asked to select.
        DispatchQueue.main.async {
            view.becomeFirstResponder()
            view.selectedTextRange = view.textRange(from: view.beginningOfDocument, to: view.endOfDocument)
        }
        return view
    }

    func updateUIView(_ uiView: UITextView, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 280
        let height = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        return CGSize(width: width, height: height)
    }

    /// Ends the selection when the operator collapses it or the bubble gives
    /// up focus.
    final class Coordinator: NSObject, UITextViewDelegate {
        private let onEnd: () -> Void
        /// Whether the opening select-all has landed. Before it does, an empty
        /// selection is the view's own first frame, not the operator's.
        private var didSelectAll = false

        init(onEnd: @escaping () -> Void) {
            self.onEnd = onEnd
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard didSelectAll else {
                if let range = textView.selectedTextRange, !range.isEmpty {
                    didSelectAll = true
                }
                return
            }
            if textView.selectedTextRange?.isEmpty ?? true {
                onEnd()
            }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            onEnd()
        }
    }
}
