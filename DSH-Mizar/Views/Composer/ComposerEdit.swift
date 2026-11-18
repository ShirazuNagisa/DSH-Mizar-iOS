//
//  ComposerEdit.swift
//  DSH-Mizar
//
//  One programmatic replacement of the draft.
//
//  Two features write into the field without a keystroke: the on-device rewriter
//  and the hold-to-talk microphone. They are the same operation -- replace a
//  range with text -- and they have the same three obligations, which is why
//  they share this value rather than each owning a path into the editor:
//
//    * the draft is the truth: the range is measured in plain text (UTF-16
//      units, exactly what the binding holds), never in pill positions;
//    * the write is one edit, so one undo takes the draft back to what it was;
//    * the binding follows the editor, so the screen is told afterwards rather
//      than being written into underneath the field.
//
//  ``ComposerEditorView`` applies it. The view never applies one itself: an
//  edit that arrived while a Chinese input method was mid-composition is
//  discarded, not queued -- the operator is choosing between candidates, and a
//  replacement now takes the candidate away.
//

import Foundation

/// A replacement the editor should make once, when it next draws.
struct ComposerEdit: Identifiable, Equatable {
    /// Who asked for the edit. The two sources are gated, drawn and tested
    /// separately; the source is carried so a cancellation path can tell whose
    /// work it is dropping.
    enum Source: Equatable {
        /// The on-device prompt rewriter.
        case enhancement
        /// Hold-to-talk dictation.
        case dictation
    }

    /// Identity, not equality: the same text at the same range twice is two
    /// edits, and the editor must place each one once.
    let id = UUID()
    /// Where the replacement starts, in plain-text UTF-16 units.
    let range: NSRange
    /// What replaces ``range``. Already the draft's own spelling: pills are
    /// re-rendered from these characters, never carried alongside them.
    let text: String
    let source: Source

    init(range: NSRange, text: String, source: Source) {
        self.range = range
        self.text = text
        self.source = source
    }

    /// Whether the range is inside a draft of this length.
    func isInBounds(of plain: String) -> Bool {
        let length = (plain as NSString).length
        return range.location >= 0 && range.length >= 0 && NSMaxRange(range) <= length
    }

    /// Whether applying this edit would leave the draft as it already is.
    func isNoOp(in plain: String) -> Bool {
        guard isInBounds(of: plain) else { return false }
        return (plain as NSString).replacingCharacters(in: range, with: text) == plain
    }
}

/// What happened to a request the editor was handed.
enum ComposerEditOutcome: Equatable {
    /// The draft now holds the replacement, as one undoable edit.
    case applied
    /// An input method was mid-composition; nothing was written and nothing
    /// is queued.
    case discardedComposition
    /// The range no longer fits the draft -- someone edited it since the
    /// request was made.
    case rejected
}

/// What the screen saw happen, for the copy it may owe the operator.
extension ComposerEditOutcome {
    /// Whether the draft changed.
    var didApply: Bool { self == .applied }
}
