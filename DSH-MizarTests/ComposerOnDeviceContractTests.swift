//
//  ComposerOnDeviceContractTests.swift
//  DSH-MizarTests
//
//  What the on-device controls promise without a screen: the identifiers the
//  UI suite addresses, the copy the windows and the strip show, and the one
//  rule the controller must hold on its own -- nothing runs while the entry is
//  not available, and nothing is handed to the field without a draft to put it
//  in.
//
//  The engines themselves are pinned elsewhere: the edit surface in
//  `ComposerEditTests`, the rewrite's validation where it lives. What is
//  checked here is the wiring that survives a rebuild: identifiers and copy
//  live in source the snapshot suite cannot see.
//

import Foundation
import Testing
@testable import DSH_Mizar

struct ComposerOnDeviceContractTests {
    @Test("the composer and its controls declare the identifiers the UI suite queries")
    func identifiers() throws {
        try AppSourceContract.expectIdentifiers(
            ["composer.enhance"],
            in: "DSH-Mizar/Views/ComposerView.swift",
        )
        // Talking is a hold on the field, not a control on the row: the
        // contract names the recogniser and its gate, because those are what
        // the UI suite's long press reaches.
        try AppSourceContract.expectFragments(
            [
                "editor.dictationPressRecognizer = hold",
                "hold.delegate = context.coordinator",
                "!editor.isFirstResponder && !editor.isExpanded",
            ],
            in: "DSH-Mizar/Views/ComposerView.swift",
            describing: "hold-to-talk gesture",
        )
        try AppSourceContract.expectIdentifiers(
            [
                "composer.dictation.strip",
                "composer.onDevice.note",
            ],
            in: "DSH-Mizar/Views/Composer/ComposerOnDeviceControls.swift",
        )
        try AppSourceContract.expectFragments(
            [
                ".accessibilityIdentifier(\"composer.enhance.\\(intent.rawValue)\")",
                ".accessibilityIdentifier(\"composer.enhance.panel\")",
            ],
            in: "DSH-Mizar/Views/Composer/ComposerOnDeviceControls.swift",
            describing: "intent panel identifier",
        )
    }

    @Test("the copy the three intents and the microphone are named with is still there")
    func copy() throws {
        try AppSourceContract.expectFragments(
            [
                "case .moreDetail: \"More detail\"",
                "case .bulletPoints: \"Bullet points\"",
                "case .formal: \"More formal\"",
            ],
            in: "DSH-Mizar/Views/Composer/ComposerEnhancement.swift",
            describing: "intent title",
        )
        try AppSourceContract.expectFragments(
            [
                "String(localized: \"Hold to dictate\")",
            ],
            in: "DSH-Mizar/Views/ComposerView.swift",
            describing: "the hold's hint",
        )
        try AppSourceContract.expectFragments(
            [
                "\"Slide up to cancel\"",
                "\"Release to cancel\"",
                "String(localized: \"Allow microphone access to dictate.\")",
            ],
            in: "DSH-Mizar/Views/Composer/ComposerOnDeviceControls.swift",
            describing: "dictation copy",
        )
    }

    @Test("every name the controls ask for is in both catalogues")
    func catalogue() throws {
        let names = [
            "Improve prompt",
            "More detail",
            "Bullet points",
            "More formal",
            "Hold to dictate",
            "Listening…",
            "Slide up to cancel",
            "Release to cancel",
            "Rewriting the prompt…",
            "This iPhone cannot run Apple Intelligence.",
            "Open Settings",
        ]
        for relative in ["DSH-Mizar/en.lproj/Localizable.strings", "DSH-Mizar/zh-Hans.lproj/Localizable.strings"] {
            let source = try AppSourceContract.text(at: relative)
            let missing = names.filter { !source.contains("\"\($0)\" = ") }
            #expect(missing.isEmpty, "\(relative) is missing: \(missing)")
        }
    }

    @MainActor
    @Test("an unavailable entry does nothing, however it is asked")
    func unavailableDoesNothing() async {
        let input = ComposerOnDeviceInput()
        // No refresh: the initial state is "not asked yet", which is not
        // available, and must behave like an unavailable model rather than
        // firing a request that cannot be answered.
        #expect(!input.canEnhance)
        input.enhance(draft: "Rewrite me", intent: .moreDetail, revision: 0)
        #expect(input.enhancementPhase == .idle)
        #expect(input.pendingEdit == nil)
    }

    @MainActor
    @Test("a blank draft is refused before a request exists")
    func blankDraftIsRefused() {
        let input = ComposerOnDeviceInput()
        input.refreshAvailability()
        guard input.enhancementAvailability.isAvailable else { return }
        input.enhance(draft: "   \n", intent: .formal, revision: 3)
        #expect(input.enhancementPhase == .idle)
        #expect(input.pendingEdit == nil)
    }

    @MainActor
    @Test("a refused insertion leaves a note, and cancelling clears everything")
    func notesAndCancellation() {
        let input = ComposerOnDeviceInput()
        input.noteEditFinished(.discardedComposition)
        #expect(input.notice != nil)
        input.dismissNotice()
        #expect(input.notice == nil)

        input.cancelAll()
        #expect(input.enhancementPhase == .idle)
        #expect(input.dictation.phase == .idle)
        #expect(input.pendingEdit == nil)
    }
}
