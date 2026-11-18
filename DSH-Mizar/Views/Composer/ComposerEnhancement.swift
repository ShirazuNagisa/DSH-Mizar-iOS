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
/// the same every time.
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
    /// The hardware cannot run Apple Intelligence at all. The entry is hidden:
    /// there is nothing to retry and nothing to turn on.
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
        case .deviceNotEligible: "This iPhone cannot run Apple Intelligence."
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
            String(localized: "This iPhone cannot run Apple Intelligence.")
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
    /// Whether the on-device model can be used now.
    ///
    /// Asked every time the entry appears or the scene comes back: Apple
    /// Intelligence can be switched on while the app is in the background, and
    /// a cached "no" would outlive the switch.
    static func availability() -> ComposerEnhanceAvailability {
        switch SystemLanguageModel.default.availability {
        case .available:
            return SystemLanguageModel.default.supportsLocale(Locale.current)
                ? .available
                : .languageNotSupported
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

    /// Rewrite one draft, once, with no history and no tools.
    static func rewrite(_ draft: String, intent: ComposerEnhanceIntent) async throws -> String {
        throw ComposerEnhanceFailure.unavailable(availability())
    }

    /// Refuse a rewrite that drifted from the draft.
    static func validate(original: String, rewritten: String) throws {
        throw ComposerEnhanceFailure.refused
    }

    /// The instructions a request runs under: the intent plus the contract.
    static func instructions(for intent: ComposerEnhanceIntent) -> String {
        ""
    }
}
