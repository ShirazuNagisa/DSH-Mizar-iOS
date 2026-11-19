//
//  PromptEnhancement.swift
//  MizarKit
//
//  The desktop's rewrite of a prompt draft.
//
//  `session.enhancePrompt` is the alternative to the on-device model: the
//  phone sends the draft and the intent's instructions to the paired desktop,
//  which answers with a rewritten draft using the session's own model. It is
//  used only when the operator turns the setting on -- the default keeps the
//  draft on the phone -- and the payload is exactly what the on-device path
//  would have read: the instructions and the draft.
//

import Foundation

/// The host's answer to `session.enhancePrompt`.
public struct SessionEnhancePromptResult: Decodable, Sendable, Equatable {
    /// The rewritten draft, trimmed by the host.
    public let text: String

    private enum CodingKeys: String, CodingKey {
        case text
    }
}

public extension MizarConnection {
    /// Ask the desktop to rewrite one draft with the session's model.
    ///
    /// - Parameters:
    ///   - sessionId: the session the model selection belongs to; the host
    ///     resolves the engine from it.
    ///   - provider: the model's provider route.
    ///   - model: the model id the session is using.
    ///   - system: the intent's instructions, exactly as the on-device path
    ///     would have passed them.
    ///   - draft: the operator's text.
    ///   - maxTokens: the answer's ceiling.
    /// - Returns: the rewritten draft.
    /// - Throws: ``MizarError`` when the host refuses. An older host answers
    ///   `NOT_IMPLEMENTED`, which callers render as "update the desktop".
    func sessionEnhancePrompt(
        sessionId: String,
        provider: String,
        model: String,
        system: String,
        draft: String,
        maxTokens: Int = 1024,
    ) async throws -> String {
        let result = try await call(
            "session.enhancePrompt",
            payload: .object([
                "sessionId": .string(sessionId),
                "provider": .string(provider),
                "model": .string(model),
                "system": .string(system),
                "draft": .string(draft),
                "maxTokens": .number(Double(maxTokens)),
            ]),
            as: SessionEnhancePromptResult.self,
        )
        return result.text
    }
}
