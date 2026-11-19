//
//  ComposerEditTests.swift
//  DSH-MizarTests
//
//  The shared edit surface, without a screen.
//
//  The rewriter and the microphone both hand the field a ``ComposerEdit``: a
//  plain range and the text that replaces it. What has to survive that handoff
//  is pinned here, because every one of these is a way the field has already
//  been broken once by a full-text write:
//
//    * only the named range moves, and a pill outside it stays a pill;
//    * the write is one edit, so one undo puts the draft back exactly and a
//      redo puts the replacement back;
//    * the caret lands after what was placed;
//    * a range that no longer fits the draft is refused rather than clamped.
//

import Foundation
import Testing
import UIKit
@testable import DSH_Mizar

@MainActor
struct ComposerEditTests {
    /// An editor with a width, so the pill pass has something to measure.
    private func makeEditor(_ text: String, names: [String] = ["goal"]) -> ComposerEditorView {
        let editor = ComposerEditorView()
        editor.frame = CGRect(x: 0, y: 0, width: 320, height: 200)
        editor.knownTokenNames = names
        editor.setPlainText(text, caret: nil)
        return editor
    }

    @Test("an edit replaces its range and leaves a pill outside it alone")
    func replacesOnlyItsRange() {
        let editor = makeEditor("Plan /goal for tonight")
        let range = ("Plan /goal for tonight" as NSString).range(of: "tonight")
        let outcome = editor.apply(ComposerEdit(range: range, text: "tomorrow", source: .enhancement))

        #expect(outcome == .applied)
        #expect(editor.plainText == "Plan /goal for tomorrow")
        // The pill is still one attachment, not four characters rebuilt.
        #expect(editor.renderedAttachmentCount == 1)
    }

    @Test("the caret lands after what was placed")
    func caretFollowsTheText() {
        let editor = makeEditor("Rewrite me")
        let outcome = editor.apply(
            ComposerEdit(range: NSRange(location: 0, length: 10), text: "Rewritten", source: .enhancement),
        )

        #expect(outcome == .applied)
        #expect(editor.plainText == "Rewritten")
        #expect(editor.plainSelectionRange == NSRange(location: 9, length: 0))
    }

    @Test("one undo takes the draft back, one redo puts it forward")
    func undoAndRedo() {
        let editor = makeEditor("Plan /goal for tonight")
        let undo = UndoManager()
        editor.editUndoManager = undo
        let before = editor.plainText
        let range = (before as NSString).range(of: "tonight")

        undo.beginUndoGrouping()
        let outcome = editor.apply(ComposerEdit(range: range, text: "tomorrow", source: .enhancement))
        undo.endUndoGrouping()

        #expect(outcome == .applied)
        #expect(editor.plainText == "Plan /goal for tomorrow")
        #expect(undo.canUndo)

        undo.undo()
        #expect(editor.plainText == before)
        #expect(editor.renderedAttachmentCount == 1)

        undo.redo()
        #expect(editor.plainText == "Plan /goal for tomorrow")
    }

    @Test("a range that no longer fits is refused, not clamped")
    func outOfBoundsIsRejected() {
        let editor = makeEditor("short")
        let outcome = editor.apply(
            ComposerEdit(range: NSRange(location: 3, length: 40), text: "…", source: .dictation),
        )

        #expect(outcome == .rejected)
        #expect(editor.plainText == "short")
    }

    @Test("an insertion at the caret lands before the text after it")
    func insertionAtCaret() {
        let editor = makeEditor("Hello world")
        editor.selectedRange = NSRange(location: 5, length: 0)
        let outcome = editor.apply(
            ComposerEdit(range: editor.plainSelectionRange, text: ", there", source: .dictation),
        )

        #expect(outcome == .applied)
        #expect(editor.plainText == "Hello, there world")
    }

    @Test("an identical replacement is a no-op the screen can refuse before writing")
    func noOpIsDetectable() {
        let edit = ComposerEdit(
            range: NSRange(location: 0, length: 4),
            text: "same",
            source: .enhancement,
        )
        #expect(edit.isNoOp(in: "same"))
        #expect(!edit.isNoOp(in: "diff"))
        #expect(edit.isInBounds(of: "same"))
        #expect(!edit.isInBounds(of: "sa"))
    }
}

private extension ComposerEditorView {
    /// How many pills the field currently draws.
    var renderedAttachmentCount: Int {
        var count = 0
        attributedText.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: attributedText.length),
            options: [],
        ) { value, _, _ in
            if value != nil { count += 1 }
        }
        return count
    }
}
