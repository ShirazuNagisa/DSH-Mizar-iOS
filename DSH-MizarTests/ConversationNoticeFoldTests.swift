//
//  ConversationNoticeFoldTests.swift
//  DSH-MizarTests
//
//  A burst of notices is one line; a message between them, a different family,
//  or a gap longer than the window keeps them apart. Unknown notices are never
//  rewritten.
//

import Foundation
import MizarKit
import Testing
@testable import DSH_Mizar

@Suite("Conversation notice folding")
struct ConversationNoticeFoldTests {
    private func notice(_ id: String, _ text: String, at seconds: TimeInterval) -> ConversationItem {
        .notice(id: id, text: text, at: Date(timeIntervalSince1970: seconds))
    }

    private func message(_ id: String, at seconds: TimeInterval) -> ConversationItem {
        .message(id: id, role: .user, text: "prompt", at: Date(timeIntervalSince1970: seconds))
    }

    @Test("Ten subagents starting together fold into one line")
    func subagentBurst() {
        let items = (0..<10).map { index in
            notice(
                "n\(index)",
                "Background subagent obagen-\(index) started",
                at: TimeInterval(index) * 0.2,
            )
        }
        let folded = ConversationNoticeFold.fold(items)
        #expect(folded.count == 1)
        #expect(folded.first?.id == "n0")
        if case .notice(_, let text, _) = folded.first {
            #expect(text == String(localized: "Multiple background subagents started"))
        } else {
            Issue.record("the folded item is not a notice")
        }
    }

    @Test("Mixed job actions in one burst fold into one updated line")
    func mixedJobBurst() {
        let items = [
            notice("n1", "background job bash-1 started", at: 0),
            notice("n2", "background job bash-2 finished (exit code: 0)", at: 1),
        ]
        let folded = ConversationNoticeFold.fold(items)
        #expect(folded.count == 1)
        if case .notice(_, let text, _) = folded.first {
            #expect(text == String(localized: "Background tasks updated"))
        } else {
            Issue.record("the folded item is not a notice")
        }
    }

    @Test("A compaction uses its fixed line")
    func compaction() {
        let folded = ConversationNoticeFold.fold([notice("n1", "Context compacted", at: 0)])
        #expect(folded.count == 1)
        if case .notice(_, let text, _) = folded.first {
            #expect(text == String(localized: "Conversation context compacted"))
        } else {
            Issue.record("the folded item is not a notice")
        }
    }

    @Test("A message between notices keeps them apart")
    func messageSeparates() {
        let items = [
            notice("n1", "background job bash-1 started", at: 0),
            message("m1", at: 0.5),
            notice("n2", "background job bash-2 started", at: 1),
        ]
        let folded = ConversationNoticeFold.fold(items)
        #expect(folded.count == 3)
    }

    @Test("Different families do not fold together")
    func familiesStayApart() {
        let items = [
            notice("n1", "background job bash-1 started", at: 0),
            notice("n2", "Background subagent obagen-1 started", at: 1),
        ]
        #expect(ConversationNoticeFold.fold(items).count == 2)
    }

    @Test("A gap longer than the window keeps notices apart")
    func windowExpires() {
        let items = [
            notice("n1", "background job bash-1 started", at: 0),
            notice("n2", "background job bash-2 started", at: 10),
        ]
        #expect(ConversationNoticeFold.fold(items).count == 2)
    }

    @Test("An unknown notice keeps the host's text")
    func unknownKept() {
        let original = "Working directory changed to /tmp"
        let folded = ConversationNoticeFold.fold([notice("n1", original, at: 0)])
        #expect(folded.count == 1)
        if case .notice(_, let text, _) = folded.first {
            #expect(text == original)
        } else {
            Issue.record("the item is not a notice")
        }
    }
}
