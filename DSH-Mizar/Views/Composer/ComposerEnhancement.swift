//
//  ComposerEnhancement.swift
//  DSH-Mizar
//
//  Rewriting the draft with the model that is already on this iPhone.
//
//  The feature is deliberately small: one session per request, no tools, no
//  transcript, and nothing sent anywhere. The draft goes in, one of three
//  intents names what "improve" means, and the rewritten draft comes back --
//  or the draft stays exactly as the operator wrote it.
//
//  What makes that safe is not the prompt: it is the check that runs before
//  anything is written. A rewrite that loses a path, invents a command, or
//  answers in another language is refused, and the operator keeps what they
//  had. The rewrite is a suggestion the code can verify, never a result that
//  is trusted because a model produced it.
//
//  Availability is read at runtime, never assumed: Apple Intelligence ships
//  by region, by device and by switch, and the entry must say which of those
//  applies rather than fail silently.
//

import Foundation
import FoundationModels
import SwiftUI

/// What the operator asked the rewriter to do.
///
/// Three intents, not a free-text instruction: a typed instruction would be a
/// second draft to get wrong, and the work worth offering is the work that is
/// the same every time. The instructions for each live in
/// ``ComposerEnhancement/instructions(for:)``.
enum ComposerEnhanceIntent: String, CaseIterable, Identifiable, Sendable {
    case moreDetail
    case bulletPoints
    case formal

    var id: String { rawValue }

    /// The row's title. A short label, no explanation: the three are told
    /// apart by what they say, and a sentence under each turned a small window
    /// into a page.
    var title: LocalizedStringKey {
        switch self {
        case .moreDetail: "More detail"
        case .bulletPoints: "Bullet points"
        case .formal: "More formal"
        }
    }

    var systemImage: String {
        switch self {
        case .moreDetail: "text.append"
        case .bulletPoints: "list.bullet"
        case .formal: "textformat"
        }
    }
}

/// Whether this iPhone can rewrite a draft right now, and if not, why.
enum ComposerEnhanceAvailability: Equatable, Sendable {
    /// Not asked yet.
    case unknown
    case available
    /// Apple Intelligence is not available on this device (unsupported
    /// hardware or a region that has no model yet). Not a permanent verdict:
    /// a system update can change it, so the entry stays and the panel explains.
    case deviceNotEligible
    /// The hardware can, but the operator has it off. The entry explains and
    /// offers Settings.
    case intelligenceNotEnabled
    /// The model is still being prepared. The entry waits.
    case modelNotReady
    /// The device language is outside what the on-device model speaks.
    case languageNotSupported

    var isAvailable: Bool { self == .available }

    /// Whether the reason is one the operator can act on.
    var isActionable: Bool {
        self == .intelligenceNotEnabled || self == .languageNotSupported
    }

    /// One sentence, in the operator's language, for the panel's explanation.
    var explanation: LocalizedStringKey? {
        switch self {
        case .unknown, .available: nil
        case .deviceNotEligible: "Apple Intelligence is not available on this device."
        case .intelligenceNotEnabled: "Turn on Apple Intelligence to rewrite a prompt."
        case .modelNotReady: "The on-device model is still getting ready."
        case .languageNotSupported: "The on-device model does not speak this language yet."
        }
    }
}

/// Why a rewrite did not reach the draft.
///
/// Every case is a refusal, and every refusal leaves the draft as it was. The
/// distinctions exist for the copy and for the tests: "the model lost a path"
/// and "the model answered in English" are different bugs in the prompt, not
/// two ways of saying "failed".
enum ComposerEnhanceFailure: Error, Equatable, Sendable {
    case unavailable(ComposerEnhanceAvailability)
    /// Nothing usable came back.
    case empty
    /// The same draft, so there is nothing to write, animate or undo.
    case unchanged
    /// A path or command from the original is missing.
    case lostAnchor(String)
    /// A path or command the original did not have.
    case inventedAnchor(String)
    /// The answer is in another writing system than the draft.
    case wrongLanguage
    /// Too long to rewrite within the model's budget.
    case tooLong
    /// The model refused, or a guardrail stopped it.
    case refused
}

extension ComposerEnhanceFailure {
    /// What the operator is told. `unchanged` is deliberately silent: nothing
    /// happened because there was nothing left to do.
    var message: String? {
        switch self {
        case .unavailable(.deviceNotEligible):
            String(localized: "Apple Intelligence is not available on this device.")
        case .unavailable(.intelligenceNotEnabled):
            String(localized: "Turn on Apple Intelligence to rewrite a prompt.")
        case .unavailable(.modelNotReady):
            String(localized: "The on-device model is still getting ready.")
        case .unavailable(.languageNotSupported), .wrongLanguage:
            String(localized: "The on-device model does not speak this language yet.")
        case .unavailable(.unknown), .unavailable(.available):
            String(localized: "The rewrite is not available right now.")
        case .empty, .refused:
            String(localized: "The rewrite came back empty. Your draft is unchanged.")
        case .lostAnchor, .inventedAnchor:
            String(localized: "The rewrite changed a path or command. Your draft is unchanged.")
        case .tooLong:
            String(localized: "This draft is too long to rewrite. Your draft is unchanged.")
        case .unchanged:
            nil
        }
    }
}

// MARK: - The rewrite

enum ComposerEnhancement {
    /// The most tokens a rewrite may spend on its answer.
    ///
    /// The answer replaces a draft the operator already wrote, so it is short
    /// by construction; the cap also stops a model that starts restating the
    /// prompt instead of rewriting it. It is generous enough for a long draft
    /// turned into bullet points, and small enough that the draft itself still
    /// fits the same window on the smaller models.
    static let responseTokenBudget = 1024

    /// Whether the on-device model can be used now.
    ///
    /// Asked every time the entry appears or the scene comes back: Apple
    /// Intelligence can be switched on while the app is in the background, and
    /// a cached "no" would outlive the switch.
    static func availability() -> ComposerEnhanceAvailability {
        let model = SystemLanguageModel.default
        return resolve(
            availability: model.availability,
            supportsCurrentLocale: model.supportsLocale(Locale.current),
            supportedLanguages: model.supportedLanguages,
            locale: Locale.current,
        )
    }

    /// Resolve the model's state into the answer the panel shows.
    ///
    /// Split from the model so the mapping can be tested with fabricated
    /// states -- the states this feature has to explain are exactly the ones
    /// a simulator cannot produce.
    static func resolve(
        availability: SystemLanguageModel.Availability,
        supportsCurrentLocale: Bool,
        supportedLanguages: Set<Locale.Language>,
        locale: Locale,
    ) -> ComposerEnhanceAvailability {
        switch availability {
        case .available:
            // `supportsLocale` is the authority. It is not the only evidence:
            // a phone in mainland China reports `zh_CN` while the model's list
            // spells the language `zh-Hans`, and asking the language rather
            // than the whole locale is what keeps an eligible phone out of the
            // "does not speak this language" panel.
            let speaks = supportsCurrentLocale
                || Self.speaks(locale.language, in: supportedLanguages)
            return speaks ? .available : .languageNotSupported
        case .unavailable(.deviceNotEligible):
            return .deviceNotEligible
        case .unavailable(.appleIntelligenceNotEnabled):
            return .intelligenceNotEnabled
        case .unavailable(.modelNotReady):
            return .modelNotReady
        @unknown default:
            return .unknown
        }
    }

    /// Whether the model speaks this language, comparing language and script
    /// rather than the complete locale.
    static func speaks(_ language: Locale.Language, in supported: Set<Locale.Language>) -> Bool {
        guard let code = language.languageCode else { return false }
        return supported.contains { candidate in
            candidate.languageCode == code
                && (language.script == nil || candidate.script == language.script)
        }
    }

    /// Rewrite one draft, once, with no history and no tools.
    ///
    /// A fresh session per call is what makes the feature testable: what goes
    /// in is the draft and the intent, and nothing else can leak between two
    /// rewrites. The response is returned unvalidated; the caller runs
    /// ``validate(original:rewritten:)`` before it can reach the field.
    ///
    /// The draft is checked against the window *before* generation starts. The
    /// model would otherwise read as much of the draft as fits and quietly
    /// answer about the part it saw, which is worse than refusing: the operator
    /// would be handed a rewrite of a prompt they cannot recognise.
    static func rewrite(_ draft: String, intent: ComposerEnhanceIntent) async throws -> String {
        let availability = availability()
        guard availability.isAvailable else {
            throw ComposerEnhanceFailure.unavailable(availability)
        }

        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { throw ComposerEnhanceFailure.empty }

        let instructions = instructions(for: intent)
        let contextTokens = await contextTokenCount(prompt: prompt, instructions: instructions)
        guard contextTokens + responseTokenBudget <= SystemLanguageModel.default.contextSize else {
            throw ComposerEnhanceFailure.tooLong
        }

        let session = LanguageModelSession(model: .default, tools: [], instructions: instructions)
        // Nucleus sampling at 0.9 with a low temperature: "improve this" means
        // tightening what is already there, not inventing a variation, and a
        // nearly deterministic decode is what makes a refusal reproducible
        // enough to fix in the prompt.
        let options = GenerationOptions(
            samplingMode: .random(probabilityThreshold: 0.9),
            temperature: 0.2,
            maximumResponseTokens: responseTokenBudget,
        )

        let content: String
        do {
            content = try await session.respond(to: prompt, options: options).content
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw failure(for: error)
        }

        // A rewrite nobody is waiting for must not be handed to the field: the
        // screen cancels when the operator edits, sends or leaves, and a
        // result that arrives after that is a replacement of text they have
        // already moved past.
        try Task.checkCancellation()
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Refuse a rewrite that drifted from the draft.
    ///
    /// The rules are the promise made to the operator: same facts, same paths,
    /// same commands, same language. A model that follows them produces a
    /// better draft; a model that does not is stopped here rather than in the
    /// field, where the operator would have to notice by reading.
    ///
    /// The checks run in the order that produces the most useful refusal: an
    /// empty answer, then an answer identical to the draft (after trimming, so
    /// a stray newline at either end is still "no change"), then the anchors
    /// the draft cannot lose and the rewrite may not invent, then the language,
    /// then the size. The whole function is pure: it reads the two strings and
    /// nothing else, which is why it can be tested without a model.
    static func validate(original: String, rewritten: String) throws {
        let draft = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let answer = rewritten.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !answer.isEmpty else { throw ComposerEnhanceFailure.empty }
        guard answer != draft else { throw ComposerEnhanceFailure.unchanged }

        let draftAnchors = ComposerAnchors.tokens(in: draft)
        let answerAnchors = ComposerAnchors.tokens(in: answer)
        for anchor in draftAnchors where !answerAnchors.contains(anchor) {
            throw ComposerEnhanceFailure.lostAnchor(anchor)
        }
        let kept = Set(draftAnchors)
        for anchor in answerAnchors where !kept.contains(anchor) {
            throw ComposerEnhanceFailure.inventedAnchor(anchor)
        }

        guard !ComposerScript.answers(answer, inAnotherLanguageThan: draft) else {
            throw ComposerEnhanceFailure.wrongLanguage
        }

        guard answer.count <= answerCharacterLimit(for: draft) else {
            throw ComposerEnhanceFailure.tooLong
        }
    }

    /// The instructions a request runs under: the intent plus the contract.
    ///
    /// Written as short numbered rules rather than a paragraph, because each
    /// one is a check the code runs afterwards: a rule the model can count is
    /// a rule it can follow, and a rule this file can test is a rule the next
    /// edit to the prompt cannot silently drop.
    static func instructions(for intent: ComposerEnhanceIntent) -> String {
        """
        You rewrite one draft prompt for the DSH-Mizar app.

        The text you return replaces the operator's draft exactly as you write
        it, so follow every rule below. The app checks these rules after you
        answer: a draft that breaks one is thrown away and the operator keeps
        what they had.

        1. Keep the draft's language. Never translate. A Chinese draft stays
           Chinese, an English draft stays English, and a mixed draft keeps the
           same mix.
        2. Keep every fact, every intent and every constraint the draft states.
           Do not drop a requirement, a limitation, a number or a name.
        3. Never add a path, a command, a skill name, a number or a requirement
           the draft does not already contain.
        4. Keep every file path exactly as written, and keep every /command
           exactly as written, skill names included. Do not reformat,
           translate, expand or pluralise one.
        5. Output only the rewritten draft. No explanation of what you changed,
           no title, and no code fence around the answer.

        \(intentInstructions(for: intent))
        """
    }

    /// The one rule that makes the three intents different.
    ///
    /// Each intent says what it may touch, because "improve this prompt" is
    /// otherwise an invitation to add a goal the operator never asked for --
    /// the failure that reads as helpful and is the one nobody notices until
    /// the agent starts working on the wrong task.
    private static func intentInstructions(for intent: ComposerEnhanceIntent) -> String {
        switch intent {
        case .moreDetail:
            """
            Intent: more detail.
            Add detail inside what the draft already asks for. You may add steps
            and acceptance criteria that the draft's own intent implies. Do not
            add a new goal, a new subject or a requirement the operator did not
            ask for, and do not turn the draft into a different task.
            """
        case .bulletPoints:
            """
            Intent: bullet points.
            Reorder the draft into bullet points, one point per line, each line
            starting with "- ". Keep the draft's order and meaning: do not merge
            two points into one, do not drop a point, and keep the wording and
            the paths and commands as they are.
            """
        case .formal:
            """
            Intent: more formal.
            Make the wording more formal. Change only tone and word choice. Do
            not change a fact, do not remove a constraint, and do not make a
            requirement sound stronger or weaker than the draft does.
            """
        }
    }

    // MARK: - Budgets

    /// How much of the window the prompt and the instructions take.
    ///
    /// iOS 26.4 added a real tokenizer, so ask it; 26.0 to 26.3 only publish
    /// `contextSize`, and the estimate below stands in. The estimate is also
    /// the fallback when counting fails, which it can while the model's assets
    /// are still arriving.
    private static func contextTokenCount(prompt: String, instructions: String) async -> Int {
        if #available(iOS 26.4, *) {
            let model = SystemLanguageModel.default
            if let promptTokens = try? await model.tokenCount(for: prompt),
               let instructionTokens = try? await model.tokenCount(for: instructions) {
                return promptTokens + instructionTokens
            }
        }
        return ComposerScript.estimatedTokens(in: prompt) + ComposerScript.estimatedTokens(in: instructions)
    }

    /// How long an answer may be, in characters.
    ///
    /// Three times the draft plus a paragraph's worth of markers: bullet points
    /// add a dash and a newline per line and more detail adds steps, and
    /// neither triples the text. The ceiling is the model's own answer window,
    /// so a runaway generation is refused instead of written over the draft.
    private static func answerCharacterLimit(for draft: String) -> Int {
        min(draft.count * 3 + 400, responseTokenBudget * 4)
    }

    /// Turn a framework error into the refusal the screen knows how to explain.
    ///
    /// Mapped by cause, not by wording: `.tooLong` sends the operator to the
    /// length of the draft, `.unavailable` sends them to a switch, and
    /// everything else is a refusal the draft survives untouched. Cancellation
    /// is not routed through here: the caller has to tell "the operator stopped
    /// it" from "the model stopped it", and only one of those is worth a note.
    static func failure(for error: Error) -> ComposerEnhanceFailure {
        if #available(iOS 27.0, *), let modelError = error as? LanguageModelError {
            return failure(for: modelError)
        }
        if let generationError = error as? LanguageModelSession.GenerationError {
            return failure(for: generationError)
        }
        return .refused
    }

    @available(iOS 27.0, *)
    private static func failure(for error: LanguageModelError) -> ComposerEnhanceFailure {
        switch error {
        case .contextSizeExceeded: .tooLong
        case .guardrailViolation, .refusal: .refused
        case .unsupportedLanguageOrLocale: .unavailable(.languageNotSupported)
        case .rateLimited: .refused
        default: .refused
        }
    }

    @available(iOS, introduced: 26.0, deprecated: 27.0,
               message: "FoundationModels reports LanguageModelError from iOS 27 on.")
    private static func failure(for error: LanguageModelSession.GenerationError) -> ComposerEnhanceFailure {
        switch error {
        case .exceededContextWindowSize: .tooLong
        case .guardrailViolation, .refusal: .refused
        case .unsupportedLanguageOrLocale: .unavailable(.languageNotSupported)
        case .assetsUnavailable: .unavailable(.modelNotReady)
        case .rateLimited, .concurrentRequests: .refused
        default: .refused
        }
    }
}

// MARK: - Anchors

/// The strings a rewrite is not allowed to lose or invent.
///
/// A draft is full of text whose exact spelling is the request: a path the
/// next tool will open, a `/command` capsule the composer draws as a pill, a
/// skill name typed by hand. A model that "improves" `/goal` into `/goals`, or
/// turns `ComposerView.swift` into "the composer view", has not improved the
/// draft; it has changed what the operator asked for. Catching that is a pure
/// string question, so it is answered here, once, and tested directly instead
/// of through a model that the simulator does not have.
///
/// The rules, and why each one is narrow:
///
///   * a token is an anchor when it starts with `/`, `~/`, `./`, `../` or a
///     drive letter, or when it contains `/` or `\` and looks like a path:
///     two components where one carries a dot, or three components;
///   * surrounding punctuation is dropped before comparing, so a path in
///     parentheses or a command at the end of a sentence matches its bare
///     spelling, and a trailing separator is not a different directory;
///   * a URL with a scheme, or a bare `www.` host, is a link and not a path: a
///     rewrite must not be refused because it moved a link to the end of a
///     sentence;
///   * `and/or`, `UI/UX` and `18/11` contain a slash but no path, and are not
///     anchors; treating them as anchors would refuse edits over ordinary
///     prose;
///   * anchors compare as whole tokens, never as substrings, so `/goal` is
///     not satisfied by `/goals`.
enum ComposerAnchors {
    /// Every anchor in `text`, in the order they appear, without duplicates.
    ///
    /// Deduplicated because the question is "is this token in the answer",
    /// not "how often"; keeping duplicates would only make a failing rewrite
    /// report the same anchor twice.
    static func tokens(in text: String) -> [String] {
        var anchors: [String] = []
        var seen: Set<String> = []
        for run in runs(in: text) {
            let token = canonical(run)
            guard isAnchor(token), seen.insert(token).inserted else { continue }
            anchors.append(token)
        }
        return anchors
    }

    /// Whether a canonical token names a file path or a `/command`.
    ///
    /// Exposed for the tests: the rules above are the whole contract, and a
    /// rule that cannot be exercised on its own is a rule that drifts.
    static func isAnchor(_ token: String) -> Bool {
        // Two characters is never a path or a command worth protecting.
        guard token.count >= 3 else { return false }
        if token.contains("://") { return false }
        if token.lowercased().hasPrefix("www.") { return false }
        if token.hasPrefix("/") || token.hasPrefix("~/") || token.hasPrefix("./")
            || token.hasPrefix("../") {
            return true
        }
        if isDriveQualified(token) { return true }

        let components = token.split(whereSeparator: { $0 == "/" || $0 == "\\" })
        guard components.count >= 2 else { return false }
        // Three components or more is a path even without a file name, and two
        // components need a dotted name in them: that is what separates
        // `Views/Composer` from `and/or`.
        if components.count >= 3 { return true }
        return components.contains { $0.contains(".") && $0 != "." && $0 != ".." }
    }

    /// Splits on what cannot be inside a path.
    ///
    /// Whitespace ends a token, and so does a CJK character or CJK punctuation:
    /// Chinese prose does not put spaces around a path, and `修改src/foo.swift的调用`
    /// has to yield `src/foo.swift` rather than a token glued to the verbs on
    /// both sides of it.
    ///
    /// Brackets, quotes, backticks and asterisks also end a token, so a path
    /// inside parentheses, a link written as `[plan](docs/ios/plan.md)`, or a
    /// bold `**src/foo.swift**` keeps its bare spelling on both sides of the
    /// comparison. A path that itself contains one of those characters loses
    /// it on both sides equally, which is a smaller loss than refusing a
    /// rewrite because the model added emphasis.
    private static func runs(in text: String) -> [String] {
        var runs: [String] = []
        var current = ""
        for character in text {
            if isSeparator(character) {
                if !current.isEmpty {
                    runs.append(current)
                    current = ""
                }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }

    private static func isSeparator(_ character: Character) -> Bool {
        if character.isWhitespace { return true }
        if asciiSeparators.contains(character) { return true }
        guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first else {
            return false
        }
        // A CJK letter is a separator for the same reason a space is: the run
        // around a path is what has to be compared, and the prose on either
        // side of it is not part of the path.
        if ComposerScript.isCJK(scalar) { return true }
        switch scalar.value {
        case 0x2010...0x2015, 0x2018...0x2019, 0x201C...0x201D, 0x2026,
             0x3000...0x303F, 0xFE10...0xFE1F, 0xFF01...0xFF0F, 0xFF1A...0xFF20:
            return true
        default:
            return false
        }
    }

    /// Wrappers that are never part of a path and are common in prompts:
    /// markdown links, emphasis, quotations and the commas of a list.
    private static let asciiSeparators: Set<Character> = [
        "(", ")", "[", "]", "{", "}", "<", ">",
        "\"", "'", "`", "*", ",", ";",
    ]

    /// Strips what a sentence wraps a token in, and the separator a directory
    /// may or may not end with.
    private static func canonical(_ raw: String) -> String {
        var token = raw
        while let first = token.first, edgePunctuation.contains(first) {
            token.removeFirst()
        }
        while let last = token.last, edgePunctuation.contains(last) {
            token.removeLast()
        }

        guard token.contains("/") || token.contains("\\") else { return token }
        // A sentence's full stop is not part of a file name.
        while token.count > 1, token.hasSuffix(".") {
            token.removeLast()
        }
        // A directory written with and without its trailing separator is the
        // same directory; refusing a rewrite over that would be pedantry.
        while token.count > 2, token.hasSuffix("/") || token.hasSuffix("\\") {
            token.removeLast()
        }
        return token
    }

    private static func isDriveQualified(_ token: String) -> Bool {
        let head = Array(token.prefix(3))
        guard head.count == 3, head[0].isLetter, head[1] == ":" else { return false }
        return head[2] == "/" || head[2] == "\\"
    }

    /// Punctuation a path or a command may be wrapped in. `/`, `\`, `.`, `~`
    /// and `-` are deliberately absent: each of them can be part of the token,
    /// and stripping one would turn `./scripts` into `/scripts`.
    private static let edgePunctuation: Set<Character> = [
        "(", ")", "[", "]", "{", "}", "<", ">",
        "\"", "'", "`", "*", ",", ";", ":", "!", "?",
        "…", "。", "，", "、", "；", "：", "！", "？",
        "（", "）", "「", "」", "『", "』", "《", "》", "【", "】",
        "“", "”", "‘", "’", "—", "–",
    ]
}

// MARK: - Writing system

/// Which writing system a draft is written in, by letter count.
///
/// The check exists for one failure: a model that answers a Chinese draft in
/// English. It is not a locale check -- the draft does not carry one and the
/// operator may switch language mid-sentence -- so it counts letters and
/// compares the answer with the draft.
///
/// A CJK character is weighted three times a Latin letter because one
/// character carries roughly what three letters do. Without that weight a
/// Chinese draft containing a long English identifier would count as English,
/// and a wholesale translation into English would pass the check that exists
/// to stop exactly that.
enum ComposerScript {
    struct Counts: Equatable {
        var cjk = 0
        var latin = 0
        /// Digits, punctuation and symbols: neither script, but they still
        /// take room in the model's window.
        var other = 0
    }

    enum Family: Equatable {
        case cjk
        case latin
        /// Both scripts, or neither. Only a draft with a decided script has an
        /// opinion about what the answer must be written in.
        case undecided
    }

    /// How many Latin letters one CJK character is worth.
    private static let cjkWeight = 3

    static func counts(in text: String) -> Counts {
        var counts = Counts()
        for scalar in text.unicodeScalars where !CharacterSet.whitespacesAndNewlines.contains(scalar) {
            if isCJK(scalar) {
                counts.cjk += 1
            } else if isLatin(scalar) {
                counts.latin += 1
            } else {
                counts.other += 1
            }
        }
        return counts
    }

    static func family(of text: String) -> Family {
        let counts = counts(in: text)
        let cjk = counts.cjk * cjkWeight
        if cjk > counts.latin { return .cjk }
        if counts.latin > cjk { return .latin }
        return .undecided
    }

    /// Whether the answer moved the draft into another writing system.
    ///
    /// Symmetric on purpose: an English draft answered in Chinese is the same
    /// bug as a Chinese draft answered in English, and both leave the operator
    /// with text they did not ask for.
    static func answers(_ rewritten: String, inAnotherLanguageThan original: String) -> Bool {
        let draft = family(of: original)
        guard draft != .undecided else { return false }
        let answer = family(of: rewritten)
        return answer != .undecided && answer != draft
    }

    /// A pessimistic token estimate for text the real tokenizer has not seen.
    ///
    /// One token per CJK character, one per three Latin letters, one per four
    /// remaining symbols, plus a tenth. The estimate is used to refuse a draft
    /// before it reaches the model, so being wrong in the safe direction costs
    /// a retry on a draft that might have fitted; being wrong in the other
    /// direction costs a generation that fails after the operator has waited.
    static func estimatedTokens(in text: String) -> Int {
        let counts = counts(in: text)
        let base = counts.cjk + (counts.latin + 2) / 3 + (counts.other + 2) / 4
        return base + base / 10
    }

    /// Whether a scalar is a CJK letter: Han, kana or hangul.
    static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF,       // hiragana and katakana
             0x3400...0x4DBF,       // CJK unified ideographs, extension A
             0x4E00...0x9FFF,       // CJK unified ideographs
             0xAC00...0xD7AF,       // hangul syllables
             0xF900...0xFAFF,       // CJK compatibility ideographs
             0x20000...0x2FA1F:     // supplementary ideographic plane
            return true
        default:
            return false
        }
    }

    private static func isLatin(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x41...0x5A, 0x61...0x7A,     // basic Latin
             0xC0...0x24F,                 // Latin-1 supplement and extended A/B
             0x1E00...0x1EFF:              // Latin extended additional
            return true
        default:
            return false
        }
    }
}
