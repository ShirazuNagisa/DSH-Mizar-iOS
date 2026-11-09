//
//  ConversationStreamSnapshotTests.swift
//  DSH-MizarTests
//
//  The live stream's three shapes, and the two ways it can stop: the clock
//  alone before anything has arrived, the status lines and narration while the
//  turn works, the settled header over the transcript -- folded to the answer,
//  or unfolded to the whole turn -- and the interruption and disconnect lines
//  under it.
//
//  Time is passed in rather than read: the clock is a `TimelineView` in the app,
//  and a snapshot of a ticking view is a snapshot of whenever it was taken.
//

import MizarKit
import SwiftUI
import Testing
@testable import DSH_Mizar

@MainActor
struct ConversationStreamSnapshotTests {
    enum Variant: String, CaseIterable, Sendable {
        case justSent
        case working
        case settled
        case settledExpanded
        case interrupted
        case disconnected
    }

    private static let start = Date(timeIntervalSince1970: 1_700_000_000)
    private static let now = start.addingTimeInterval(76)

    private func stream(_ variant: Variant) -> TurnStream {
        var stream = TurnStream()
        switch variant {
        case .justSent:
            return stream
        case .settled, .settledExpanded, .interrupted, .disconnected:
            stream.apply(StateFrame(state: .thinking, interval: 1, flags: [.snapshot], text: ""))
            stream.apply(StateFrame(state: .tool, interval: 2, flags: [.snapshot], text: ""))
            stream.apply(StateFrame(state: .streamNarration, interval: 3, textSeq: 0, flags: [.snapshot, .append], text: "我先看一下现有的实现。"))
            stream.apply(StateFrame(state: .streamNarration, interval: 4, textSeq: 0, flags: [.snapshot, .append], text: "三处都改完了，测试全绿。"))
        case .working:
            stream.apply(StateFrame(state: .thinking, interval: 1, flags: [.snapshot], text: ""))
            stream.apply(StateFrame(state: .tool, interval: 2, flags: [.snapshot], text: ""))
            stream.apply(StateFrame(state: .streamNarration, interval: 3, textSeq: 0, flags: [.snapshot, .append], text: "我先看一下现有的实现，再把三处改掉。"))
        }

        switch variant {
        case .settled, .settledExpanded:
            stream.apply(StateFrame(state: .streamFinal, interval: 5, textSeq: 0, flags: [.snapshot, .append], text: "三处都改完了，测试全绿。"))
            stream.apply(StateFrame(state: .streamFinal, interval: 5, textSeq: 0, flags: [.final], text: ""))
            stream.apply(StateFrame(state: .completed, interval: 6, flags: [], text: ""))
        case .interrupted:
            stream.apply(StateFrame(state: .failed, interval: 5, flags: [], text: ""))
        case .disconnected:
            stream.markDisconnected()
        default:
            break
        }
        return stream
    }

    private func view(_ variant: Variant) -> some View {
        ZStack(alignment: .topLeading) {
            Color(.systemBackground)
            ConversationStreamView(
                sessionId: "session",
                stream: stream(variant),
                turn: nil,
                startedAt: Self.start,
                endedAt: variant == .settled || variant == .settledExpanded || variant == .interrupted ? Self.now : nil,
                running: variant == .working || variant == .justSent || variant == .disconnected,
                typing: false,
                onTypingStarted: {},
                onTypingStopped: {},
                now: Self.now,
                startsExpanded: variant == .settledExpanded,
            )
            .padding(18)
        }
        .frame(width: 360, height: height(variant))
    }

    private func height(_ variant: Variant) -> CGFloat {
        switch variant {
        case .justSent: return 80
        case .working: return 260
        // A settled turn is folded: the header, the divider, and the answer.
        case .settled: return 140
        // Unfolded, it is the whole transcript again.
        case .settledExpanded: return 320
        case .interrupted, .disconnected: return 300
        }
    }

    @Test(arguments: Variant.allCases)
    func conversationStream(_ variant: Variant) throws {
        try SnapshotHarness.assertSnapshot(
            of: view(variant),
            named: "conversation-stream-\(variant.rawValue)",
            size: CGSize(width: 360, height: height(variant)),
        )
    }
}
