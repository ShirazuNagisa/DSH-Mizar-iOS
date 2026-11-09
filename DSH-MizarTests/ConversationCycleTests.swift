//
//  ConversationCycleTests.swift
//  DSH-MizarTests
//
//  The two rules the conversation's cycle rests on: which guide a phone has
//  walked, and which of a turn's items are its process.
//
//  Both are pure on purpose. The first decides whether an operator who
//  updates the app walks the guide again -- with the account and the
//  settings they already have -- and the second decides what a finished turn
//  folds away behind its own line.
//

import Foundation
import MizarKit
import Testing
@testable import DSH_Mizar

@Suite("The conversation cycle")
struct ConversationCycleTests {
    // MARK: - The guide

    @Test("a phone that never walked the guide walks it again")
    func noVersionWalksAgain() {
        #expect(!OnboardingKeys.isComplete(storedVersion: nil))
        #expect(!OnboardingKeys.isComplete(storedVersion: ""))
    }

    @Test("a phone that walked an older guide walks it again")
    func olderVersionWalksAgain() {
        #expect(!OnboardingKeys.isComplete(storedVersion: "0.9.7"))
        #expect(!OnboardingKeys.isComplete(storedVersion: "0.9.8"))
    }

    @Test("a phone that walked this guide does not walk it again")
    func currentVersionIsEnough() {
        #expect(OnboardingKeys.isComplete(storedVersion: OnboardingKeys.requiredVersion))
        #expect(OnboardingKeys.isComplete(storedVersion: "0.9.10"))
        #expect(OnboardingKeys.isComplete(storedVersion: "1.0.0"))
    }

    @Test("the guide this build wants is the one 0.9.9 asks for")
    func requiredVersion() {
        #expect(OnboardingKeys.requiredVersion == "0.9.9")
    }

    // MARK: - The process

    private func message(_ id: String, _ role: ConversationItem.Role, _ text: String) -> ConversationItem {
        .message(id: id, role: role, text: text, at: Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test("the last agent message is the summary and stays")
    func theLastAgentMessageIsTheSummary() {
        let items = [
            message("u1", .user, "run it"),
            message("a1", .assistant, "looking"),
            message("a2", .assistant, "done"),
        ]
        #expect(ConversationProcess.items(in: items) == ["a1"])
    }

    @Test("a turn with one agent message has no process")
    func oneAgentMessageHasNoProcess() {
        let items = [
            message("u1", .user, "run it"),
            message("a1", .assistant, "done"),
        ]
        #expect(ConversationProcess.items(in: items).isEmpty)
    }

    @Test("the operator's messages are never the process")
    func userMessagesAreNotTheProcess() {
        let items = [
            message("u1", .user, "run it"),
            message("u2", .user, "and again"),
            message("a1", .assistant, "done"),
        ]
        #expect(ConversationProcess.items(in: items).isEmpty)
    }

    @Test("a turn with no agent message has no process")
    func noAgentMessageHasNoProcess() {
        let items = [
            message("u1", .user, "run it"),
            .failure(id: "f1", message: "no model", at: Date(timeIntervalSince1970: 1_700_000_000)),
        ]
        #expect(ConversationProcess.items(in: items).isEmpty)
    }

    @Test("every agent message before the last one is the process")
    func allTheEarlierAgentMessages() {
        let items = [
            message("a1", .assistant, "one"),
            message("a2", .assistant, "two"),
            message("a3", .assistant, "three"),
            message("a4", .assistant, "the summary"),
        ]
        #expect(ConversationProcess.items(in: items) == ["a1", "a2", "a3"])
    }
}
