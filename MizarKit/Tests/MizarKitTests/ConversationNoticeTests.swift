//
//  ConversationNoticeTests.swift
//  MizarKitTests
//
//  The notice source kind is not on the wire, so the text is the only signal.
//  These are the shapes measured in real sessions; an unknown shape must stay
//  `.other` and be drawn unchanged.
//

import Foundation
import Testing
@testable import MizarKit

@Suite("Conversation notice classification")
struct ConversationNoticeTests {
    @Test("A compaction notice")
    func compaction() {
        #expect(ConversationNoticeClassifier.kind(of: "Context compacted") == .compaction)
        #expect(ConversationNoticeClassifier.kind(of: "Compacted 42 history items") == .other)
    }

    @Test("Background job lifecycle")
    func backgroundJob() {
        #expect(ConversationNoticeClassifier.kind(of: "background job bash-123 started") == .jobStarted)
        #expect(ConversationNoticeClassifier.kind(of: "background job bash-123 finished (exit code: 0)") == .jobFinished)
        #expect(ConversationNoticeClassifier.kind(of: "background job bash-123 stopped") == .jobStopped)
    }

    @Test("Subagent settlement and messages")
    func subagent() {
        #expect(ConversationNoticeClassifier.kind(
            of: "Background subagent obagen-1 finished and will do no further work unless you send it more.",
        ) == .subagentFinished)
        #expect(ConversationNoticeClassifier.kind(of: "Background subagent obagen-1 was stopped before it finished.") == .subagentFinished)
        #expect(ConversationNoticeClassifier.kind(of: "Agent obagent-1 sent a message: done") == .subagentMessage)
    }

    @Test("A bare settlement line is a finished subagent")
    func bareSettlement() {
        #expect(ConversationNoticeClassifier.kind(of: "Background subagent obagen-1") == .subagentFinished)
    }

    @Test("A bare job notice is a started job")
    func bareJob() {
        #expect(ConversationNoticeClassifier.kind(of: "background job bash-1") == .jobStarted)
    }

    @Test("An unrelated notice is left alone")
    func unrelated() {
        #expect(ConversationNoticeClassifier.kind(of: "Working directory changed to /tmp") == .other)
        #expect(ConversationNoticeClassifier.kind(of: "Working directory changed to /background job output") == .other)
        #expect(ConversationNoticeClassifier.kind(of: "subagent finished: the parser is done") == .other)
    }
}
