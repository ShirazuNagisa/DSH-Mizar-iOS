//
//  ComposerReceipt.swift
//  DSH-Mizar
//
//  One short receipt, in the composer's own voice.
//
//  The same capsule has two homes. It lands in the request dock after an
//  approval, where the card that asked for the decision used to be, and it
//  shares the composer's status row for a moment after a question is
//  answered. One shape for both is the point: it is one sentence, one tap's
//  worth of information, and it goes away by itself.
//

import SwiftUI

/// What a confirmed action says, for the 1.7 seconds it says it.
struct ComposerReceipt: Identifiable, Equatable {
    let id: UUID
    let text: String
    /// Whether the action was a grant. Failure and rejection share the mark.
    let allowed: Bool
    /// When it appeared, so a row that holds several can order them by the
    /// moment the operator saw them rather than by the kind of thing they are.
    let appearedAt: Date

    init(
        id: UUID = UUID(),
        text: String,
        allowed: Bool,
        appearedAt: Date = .now,
    ) {
        self.id = id
        self.text = text
        self.allowed = allowed
        self.appearedAt = appearedAt
    }
}

/// The glass one-line capsule every composer status item wears.
///
/// A single place for the measurements, because three items sitting in one
/// row must be the same height and share the same inner margin. The height is
/// a minimum rather than a fixed number: the default sizes land on the same 38
/// points the palette hint has always had, and an operator running a larger
/// text size gets a taller capsule instead of clipped words.
extension View {
    func composerStatusCapsule(interactive: Bool = false) -> some View {
        padding(.horizontal, 16)
            .padding(.vertical, 9)
            .frame(minHeight: 38)
            .contentShape(.capsule)
            .liquidCapsule(interactive: interactive)
    }
}

/// "Allowed write_file" or "Answer sent", for a moment, where it happened.
struct ReceiptCapsule: View {
    let receipt: ComposerReceipt

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: receipt.allowed ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(receipt.allowed ? Theme.running : Theme.failed)
                .symbolEffect(.bounce, value: receipt.id)
            Text(receipt.text)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .composerStatusCapsule()
        .mizarFeedback(receipt.allowed ? .success : .warning, trigger: receipt.id)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(receipt.text))
        .accessibilityIdentifier("composer.receipt")
    }
}
