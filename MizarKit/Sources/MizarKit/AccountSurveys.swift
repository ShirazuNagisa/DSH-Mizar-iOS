//
//  AccountSurveys.swift
//  MizarKit
//
//  The questionnaires the operator dispatches, as the account relay returns
//  them.
//
//  The origin relay (主力0) owns the definitions and the answers; the account
//  relay (主力1) is what the phone talks to, because it is the one that knows
//  who is asking and who has already been paid. A survey arrives with the
//  reward it carries and whether this account already finished it, and the
//  submission is a list of `(questionId, value)` pairs in the same order the
//  form drew them.
//
//  The answer value is the one shape the wire does not make easy: a single
//  choice is a string, a multi-select is an array, and a text answer is a
//  string again. ``SurveyAnswerValue`` encodes that union rather than making
//  every caller carry an `Any`.
//

import Foundation

/// What kind of control one question needs.
public enum SurveyQuestionType: String, Codable, Sendable {
    case single
    case multi
    case text

    /// Decode an unknown type as text: a question the phone cannot draw as a
    /// choice is better shown as a free-form answer than dropped from the form.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SurveyQuestionType(rawValue: raw) ?? .text
    }
}

/// One choice in a single- or multi-select question.
public struct SurveyOption: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let label: String
}

/// One question.
public struct SurveyQuestion: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let type: SurveyQuestionType
    public let prompt: String
    public let options: [SurveyOption]
    public let required: Bool
    public let maxLength: Int?

    private enum CodingKeys: String, CodingKey {
        case id, type, prompt, options, required, maxLength
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        type = try container.decodeIfPresent(SurveyQuestionType.self, forKey: .type) ?? .text
        prompt = try container.decodeIfPresent(String.self, forKey: .prompt) ?? ""
        options = try container.decodeIfPresent([SurveyOption].self, forKey: .options) ?? []
        required = try container.decodeIfPresent(Bool.self, forKey: .required) ?? false
        maxLength = try container.decodeIfPresent(Int.self, forKey: .maxLength)
    }
}

/// One questionnaire, plus this account's state.
public struct Survey: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let title: String
    public let summary: String
    public let rewardDays: Int
    public let questions: [SurveyQuestion]
    public let active: Bool
    public let expiresAt: Date?
    /// Whether this account has been paid for it.
    public let completed: Bool
    public let completedAt: Date?

    private enum CodingKeys: String, CodingKey {
        case id, title, summary, rewardDays, questions, active, expiresAt, completed, completedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        rewardDays = try container.decodeIfPresent(Int.self, forKey: .rewardDays) ?? 7
        questions = try container.decodeIfPresent([SurveyQuestion].self, forKey: .questions) ?? []
        active = try container.decodeIfPresent(Bool.self, forKey: .active) ?? true
        expiresAt = try container.decodeIfPresent(Date.self, forKey: .expiresAt)
        completed = try container.decodeIfPresent(Bool.self, forKey: .completed) ?? false
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
    }

    /// Whether the form can still be filled in.
    public var isOpen: Bool {
        active && !completed && (expiresAt == nil || expiresAt! > Date())
    }
}

/// One answer, in the wire's union shape.
public enum SurveyAnswerValue: Codable, Sendable, Equatable {
    /// A text answer, or the id of the one chosen option.
    case text(String)
    /// The chosen option ids of a multi-select question.
    case choices([String])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let list = try? container.decode([String].self) {
            self = .choices(list)
            return
        }
        self = .text(try container.decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let value): try container.encode(value)
        case .choices(let values): try container.encode(values)
        }
    }
}

/// One question's answer.
public struct SurveyAnswer: Codable, Sendable, Equatable {
    public let questionId: String
    public let value: SurveyAnswerValue

    public init(questionId: String, value: SurveyAnswerValue) {
        self.questionId = questionId
        self.value = value
    }
}

/// The answer to a successful submission.
public struct SurveySubmission: Codable, Sendable {
    public let user: AccountUser
    public let rewardDays: Int
}
