//
//  InteractionCoverageTests.swift
//  MizarKitTests
//
//  When the host is allowed to leave the phone alone.
//
//  The host no longer excludes a phone that says it is on screen (that report
//  outlives the app on iOS), so the phone is the one that has to stay quiet when
//  the card is already in front of the operator. These are the cases that decide
//  it, tested here rather than on a device because a banner arriving or not
//  arriving is invisible to a UI test.
//

import Foundation
import Testing
@testable import MizarKit

private func question(callId: String, sessionId: String?) -> PendingQuestion {
    PendingQuestion(
        callId: callId,
        sessionId: sessionId,
        questions: [
            QuestionItem(
                id: "q1",
                question: "Which database?",
                detail: nil,
                header: nil,
                options: [QuestionOption(label: "Postgres", description: nil)],
                multiSelect: false,
                intent: nil,
            ),
        ],
        requestedAt: 1,
    )
}

private func approval(requestId: String, sessionId: String?) -> PendingApproval {
    PendingApproval(
        requestId: requestId,
        sessionId: sessionId,
        toolName: "bash",
        callId: nil,
        reason: nil,
        displayReason: nil,
        requestedAt: 1,
    )
}

@Suite("Interaction coverage")
struct InteractionCoverageTests {
    @Test("a question already on screen is not announced a second time")
    func coveredQuestion() {
        let pending = PendingInteractions(
            approvals: [],
            questions: [question(callId: "qs-1", sessionId: "dsh:s-1")],
        )
        #expect(
            InteractionCoverage.covers(.question, sessionId: "dsh:s-1", pending: pending),
        )
    }

    @Test("a question for another conversation still announces itself")
    func otherConversation() {
        let pending = PendingInteractions(
            approvals: [],
            questions: [question(callId: "qs-1", sessionId: "dsh:s-1")],
        )
        // The deck only draws the open conversation's card, so a request made in
        // session s-2 is not on screen anywhere while s-1 is open.
        #expect(
            !InteractionCoverage.covers(.question, sessionId: "dsh:s-2", pending: pending),
        )
    }

    @Test("a request with no session named is still announced")
    func sessionless() {
        // The deck draws the open conversation's card, and a sessionless request
        // is drawn nowhere but the home screen. Treating it as covered would
        // leave the operator with no card and no banner at all.
        let pending = PendingInteractions(
            approvals: [approval(requestId: "ap-1", sessionId: nil)],
            questions: [question(callId: "qs-1", sessionId: nil)],
        )
        #expect(!InteractionCoverage.covers(.question, sessionId: nil, pending: pending))
        #expect(!InteractionCoverage.covers(.approval, sessionId: "dsh:s-1", pending: pending))
        #expect(!InteractionCoverage.covers(.question, sessionId: "dsh:s-1", pending: pending))
    }

    @Test("the two kinds are not interchangeable")
    func kindsAreDistinct() {
        let pending = PendingInteractions(
            approvals: [],
            questions: [question(callId: "qs-1", sessionId: "dsh:s-1")],
        )
        #expect(!InteractionCoverage.covers(.approval, sessionId: "dsh:s-1", pending: pending))
    }

    @Test("a finished turn is never covered: its card has already gone")
    func turnEndIsNeverCovered() {
        let pending = PendingInteractions(
            approvals: [approval(requestId: "ap-1", sessionId: "dsh:s-1")],
            questions: [question(callId: "qs-1", sessionId: "dsh:s-1")],
        )
        #expect(!InteractionCoverage.covers(.turnFinished, sessionId: "dsh:s-1", pending: pending))
        #expect(!InteractionCoverage.covers(.turnInterrupted, sessionId: "dsh:s-1", pending: pending))
    }

    @Test("nothing held is nothing covered")
    func emptyPending() {
        #expect(!InteractionCoverage.covers(.question, sessionId: "dsh:s-1", pending: nil))
        #expect(
            !InteractionCoverage.covers(
                .question,
                sessionId: "dsh:s-1",
                pending: PendingInteractions(approvals: [], questions: []),
            ),
        )
    }
}
