//
//  ComposerEnhancementTests.swift
//  DSH-MizarTests
//
//  The rewrite's promise, checked without a model.
//
//  Apple Intelligence is not in the simulator, so nothing here asks for a
//  rewrite. What is pinned instead is everything around the request: the
//  instructions a rewrite runs under, the anchors it may not lose, the anchors
//  it may not invent, the language it has to keep, and the size it has to fit.
//  Each of those is a way the operator's draft has to survive a model that is
//  trying to help, and each is a pure function on purpose, so this suite runs
//  in a second on every machine and in CI.
//
//  The drafts are realistic on both sides: Chinese with commands, English with
//  paths, and prose that only looks like a path (`and/or`, `UI/UX`). A rule
//  that only holds for one of the two languages is a rule that will fail for
//  the other one at run time, where nobody is reading.
//

import Foundation
import Testing
@testable import DSH_Mizar

struct ComposerEnhancementTests {
    // MARK: - Fixtures

    /// An English draft with both kinds of anchor: a path and a command.
    private let englishDraft = "Update docs/ios/plan.md so /goal explains the retry, then run the tests."

    /// The same draft turned into a bullet list, keeping both anchors.
    private let englishRewrite = """
        - Update docs/ios/plan.md so that /goal explains the retry.
        - Run the tests afterwards.
        """

    /// A Chinese draft carrying a command and a long English identifier: the
    /// shape that makes a naive language check call the draft English.
    private let chineseDraft = "把 ComposerEnhancement.swift 里的 /goal 逻辑补上测试，不要改行为，也不要新增依赖。"

    /// A faithful Chinese rewrite of the draft above.
    private let chineseRewrite = "在 ComposerEnhancement.swift 中为 /goal 逻辑补上测试，不改变现有行为，也不新增依赖。"

    // MARK: - Empty and unchanged

    @Test("a blank answer is refused, in either language")
    func blankIsRefused() {
        #expect(throws: ComposerEnhanceFailure.empty) {
            try ComposerEnhancement.validate(original: englishDraft, rewritten: "   \n\t ")
        }
        #expect(throws: ComposerEnhanceFailure.empty) {
            try ComposerEnhancement.validate(original: chineseDraft, rewritten: "")
        }
    }

    @Test("an answer identical to the draft, or only different at the margins, is no change")
    func identicalIsUnchanged() {
        #expect(throws: ComposerEnhanceFailure.unchanged) {
            try ComposerEnhancement.validate(original: englishDraft, rewritten: englishDraft)
        }
        // A model that only re-wrapped the edges has changed nothing the
        // operator can see, and writing it would cost an undo step for no
        // difference.
        #expect(throws: ComposerEnhanceFailure.unchanged) {
            try ComposerEnhancement.validate(
                original: englishDraft,
                rewritten: "\n  \(englishDraft)  \n",
            )
        }
        #expect(throws: ComposerEnhanceFailure.unchanged) {
            try ComposerEnhancement.validate(original: chineseDraft, rewritten: chineseDraft + "\n")
        }
    }

    // MARK: - Anchors

    @Test("a rewrite that keeps every anchor is accepted, in either language")
    func faithfulRewriteIsAccepted() throws {
        try ComposerEnhancement.validate(original: englishDraft, rewritten: englishRewrite)
        try ComposerEnhancement.validate(original: chineseDraft, rewritten: chineseRewrite)
    }

    @Test("a rewrite that lost a path names the path it lost")
    func lostPathIsNamed() {
        #expect(throws: ComposerEnhanceFailure.lostAnchor("docs/ios/plan.md")) {
            try ComposerEnhancement.validate(
                original: englishDraft,
                rewritten: "Update the plan so /goal explains the retry, then run the tests.",
            )
        }
    }

    @Test("a command is matched whole, so /goals does not stand in for /goal")
    func commandIsMatchedWhole() {
        #expect(throws: ComposerEnhanceFailure.lostAnchor("/goal")) {
            try ComposerEnhancement.validate(
                original: "把 /goal 里的验收标准补全。",
                rewritten: "把 /goals 里的验收标准补全。",
            )
        }
    }

    @Test("a rewrite that invented a path is refused, in either language")
    func inventedPathIsRefused() {
        #expect(throws: ComposerEnhanceFailure.inventedAnchor("docs/ios/next.md")) {
            try ComposerEnhancement.validate(
                original: englishDraft,
                rewritten: """
                    - Update docs/ios/plan.md so that /goal explains the retry in docs/ios/next.md.
                    - Run the tests afterwards.
                    """,
            )
        }
        #expect(throws: ComposerEnhanceFailure.inventedAnchor("docs/ios/next.md")) {
            try ComposerEnhancement.validate(
                original: "把 /goal 的计划补全。",
                rewritten: "把 /goal 的计划补全，并参考 docs/ios/next.md。",
            )
        }
    }

    @Test("a rewrite that invented a command is refused")
    func inventedCommandIsRefused() {
        let rewritten = """
            Update docs/ios/plan.md so /goal explains the retry, then /compact and run the tests.
            """
        #expect(throws: ComposerEnhanceFailure.inventedAnchor("/compact")) {
            try ComposerEnhancement.validate(original: englishDraft, rewritten: rewritten)
        }
    }

    // MARK: - Language

    @Test("a Chinese draft answered in English is refused")
    func chineseAnsweredInEnglish() {
        #expect(throws: ComposerEnhanceFailure.wrongLanguage) {
            try ComposerEnhancement.validate(
                original: chineseDraft,
                rewritten: """
                    Add tests for the /goal logic in ComposerEnhancement.swift, without changing \
                    behaviour or adding dependencies.
                    """,
            )
        }
    }

    @Test("an English draft answered in Chinese is refused the same way")
    func englishAnsweredInChinese() {
        #expect(throws: ComposerEnhanceFailure.wrongLanguage) {
            try ComposerEnhancement.validate(
                original: englishDraft,
                rewritten: "请更新 docs/ios/plan.md，让 /goal 说明重试的步骤，然后运行测试。",
            )
        }
    }

    // MARK: - Size

    @Test("an answer far longer than the draft is refused instead of written")
    func runawayAnswerIsRefused() {
        #expect(throws: ComposerEnhanceFailure.tooLong) {
            try ComposerEnhancement.validate(
                original: englishDraft,
                rewritten: englishRewrite + "\n" + String(repeating: "more detail. ", count: 400),
            )
        }
    }

    // MARK: - Anchor extraction

    @Test("a command and its plural are two different anchors")
    func commandAndPluralAreDistinct() {
        #expect(ComposerAnchors.tokens(in: "Run /goal, not /goals.") == ["/goal", "/goals"])
    }

    @Test("punctuation around a path is stripped before comparing")
    func punctuationIsStripped() {
        #expect(
            ComposerAnchors.tokens(in: "See (docs/ios/plan.md), `src/foo.swift`, and ./scripts/ios.sh.")
                == ["docs/ios/plan.md", "src/foo.swift", "./scripts/ios.sh"],
        )
        #expect(ComposerAnchors.tokens(in: "Read [the plan](docs/ios/plan.md) again.") == ["docs/ios/plan.md"])
        #expect(ComposerAnchors.tokens(in: "Bold **src/foo.swift** here.") == ["src/foo.swift"])
    }

    @Test("a URL is a link, not a path")
    func urlsAreNotAnchors() {
        #expect(
            ComposerAnchors.tokens(in: "Open https://example.com/a/b and www.example.com/a/b, not a path.")
                .isEmpty,
        )
        #expect(ComposerAnchors.tokens(in: "See https://example.com/docs/plan.md for the rule.").isEmpty)
    }

    @Test("prose with a slash is not a path")
    func proseSlashesAreNotAnchors() {
        #expect(ComposerAnchors.tokens(in: "Pick and/or UI/UX for 18/11, whichever reads better.").isEmpty)
        #expect(ComposerAnchors.tokens(in: "open src/views next").isEmpty)
    }

    @Test("a path written against Chinese prose is still found")
    func pathInsideChineseProse() {
        #expect(ComposerAnchors.tokens(in: "修改src/foo.swift的调用，再跑一遍。") == ["src/foo.swift"])
        #expect(ComposerAnchors.tokens(in: "参考文档（docs/ios/plan.md）里的结论。") == ["docs/ios/plan.md"])
    }

    @Test("home-relative paths and drive-qualified paths are anchors")
    func homeAndDrivePaths() {
        #expect(
            ComposerAnchors.tokens(in: #"Clear ~/Library/Logs then copy C:\Users\me\draft.txt."#)
                == ["~/Library/Logs", #"C:\Users\me\draft.txt"#],
        )
        #expect(ComposerAnchors.tokens(in: "Run /usr/local/bin/tool now") == ["/usr/local/bin/tool"])
    }

    @Test("each anchor is reported once, in the order it appears")
    func anchorsAreDeduplicated() {
        #expect(
            ComposerAnchors.tokens(
                in: "/goal again /goal, and docs/ios/plan.md twice docs/ios/plan.md",
            ) == ["/goal", "docs/ios/plan.md"],
        )
    }

    @Test("a trailing separator does not make a different directory")
    func trailingSeparatorIsNormalised() {
        #expect(
            ComposerAnchors.tokens(in: "See docs/ios/plans/ and docs/ios/plans.")
                == ["docs/ios/plans"],
        )
    }

    // MARK: - Instructions

    @Test("every intent carries the shared contract", arguments: ComposerEnhanceIntent.allCases)
    func instructionsCarryTheContract(intent: ComposerEnhanceIntent) {
        let instructions = ComposerEnhancement.instructions(for: intent)
        let clauses = [
            "Keep the draft's language",
            "Never translate",
            "Keep every fact, every intent and every constraint",
            "Never add a path, a command, a skill name, a number or a requirement",
            "Keep every file path exactly as written",
            "/command",
            "skill names included",
            "Output only the rewritten draft",
            "no code fence",
        ]
        for clause in clauses {
            #expect(instructions.contains(clause), "\(intent.rawValue) dropped the clause: \(clause)")
        }
    }

    @Test("each intent says what it may and may not change")
    func intentRulesAreDistinct() {
        let detail = ComposerEnhancement.instructions(for: .moreDetail)
        #expect(detail.contains("Intent: more detail"))
        #expect(detail.contains("acceptance criteria"))
        #expect(detail.contains("add a new goal"))

        let bullets = ComposerEnhancement.instructions(for: .bulletPoints)
        #expect(bullets.contains("Intent: bullet points"))
        #expect(bullets.contains("bullet points"))
        #expect(bullets.contains("Keep the draft's order and meaning"))
        #expect(bullets.contains("do not drop a point"))

        let formal = ComposerEnhancement.instructions(for: .formal)
        #expect(formal.contains("Intent: more formal"))
        #expect(formal.contains("Change only tone and word choice"))
        #expect(formal.contains("do not remove a constraint"))
        // The other intents' permissions must not leak into this one: "more
        // formal" may not add a step, so it may not be told it can.
        #expect(!formal.contains("acceptance criteria"))
        #expect(!formal.contains("bullet points"))
    }

    // MARK: - Availability and copy

    @Test("availability reports a case the panel can draw, without a model behind it")
    func availabilityIsDeclared() {
        switch ComposerEnhancement.availability() {
        case .unknown, .available, .deviceNotEligible, .intelligenceNotEnabled, .modelNotReady,
             .languageNotSupported:
            break
        @unknown default:
            Issue.record("availability returned a case neither the panel nor this suite knows")
        }
        // Asking twice is free, and the answer does not depend on the call
        // site: the entry asks again every time it appears.
        #expect(ComposerEnhancement.availability() == ComposerEnhancement.availability())
    }

    @Test("only one case counts as available, and two as actionable")
    func availabilitySemantics() {
        #expect(ComposerEnhanceAvailability.available.isAvailable)
        let unavailable: [ComposerEnhanceAvailability] = [
            .unknown, .deviceNotEligible, .intelligenceNotEnabled, .modelNotReady, .languageNotSupported,
        ]
        #expect(unavailable.allSatisfy { !$0.isAvailable })
        #expect(ComposerEnhanceAvailability.intelligenceNotEnabled.isActionable)
        #expect(ComposerEnhanceAvailability.languageNotSupported.isActionable)
        #expect(!ComposerEnhanceAvailability.deviceNotEligible.isActionable)
        #expect(!ComposerEnhanceAvailability.modelNotReady.isActionable)
        #expect(!ComposerEnhanceAvailability.unknown.isActionable)
    }

    @Test("every refusal that kept the draft explains itself, and the no-op stays silent")
    func refusalCopy() {
        #expect(ComposerEnhanceFailure.unchanged.message == nil)
        #expect(ComposerEnhanceFailure.empty.message != nil)
        #expect(ComposerEnhanceFailure.lostAnchor("/goal").message != nil)
        #expect(ComposerEnhanceFailure.inventedAnchor("docs/ios/plan.md").message != nil)
        #expect(ComposerEnhanceFailure.wrongLanguage.message != nil)
        #expect(ComposerEnhanceFailure.tooLong.message != nil)
        #expect(ComposerEnhanceFailure.refused.message != nil)
        #expect(ComposerEnhanceFailure.unavailable(.modelNotReady).message != nil)
        #expect(ComposerEnhanceFailure.unavailable(.available).message != nil)
    }

    @Test("the panel's three rows keep the names and symbols it draws")
    func intentRows() {
        #expect(ComposerEnhanceIntent.allCases.map(\.rawValue) == ["moreDetail", "bulletPoints", "formal"])
        #expect(ComposerEnhanceIntent.moreDetail.systemImage == "text.append")
        #expect(ComposerEnhanceIntent.bulletPoints.systemImage == "list.bullet")
        #expect(ComposerEnhanceIntent.formal.systemImage == "textformat")
    }
}
