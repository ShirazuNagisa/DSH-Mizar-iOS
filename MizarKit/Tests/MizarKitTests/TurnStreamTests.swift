//
//  TurnStreamTests.swift
//  MizarKitTests
//
//  The rules the live turn stream follows, one test per rule. These are the
//  invariants the turn view draws from, so each one is pinned by name rather than
//  left to a "streams look right" smoke test.
//
//  Style note: `apply` is mutating, so the result is always stored in a local
//  before `#expect` sees it -- the expectation macro cannot call a mutating
//  member in place.
//

import Foundation
import Testing

@testable import MizarKit

/// Shorthand for building the frames the host sends.
private func frame(
    _ state: SessionState,
    interval: UInt32,
    _ flags: StateFrame.Flags = [],
    seq: UInt32 = 0,
    text: String = "",
) -> StateFrame {
    StateFrame(state: state, interval: interval, textSeq: seq, flags: flags, text: text)
}

/// Byte length of a string, which is what `textSeq` counts.
private func bytes(_ text: String) -> UInt32 {
    UInt32(text.utf8.count)
}

@Suite("Turn stream")
struct TurnStreamTests {
    // MARK: - Work states

    @Test("consecutive work states share one status block and dedupe adjacently")
    func workStatesMerge() {
        var stream = TurnStream()
        let c1 = stream.apply(frame(.thinking, interval: 1))
        let c2 = stream.apply(frame(.tool, interval: 2))
        let c3 = stream.apply(frame(.editing, interval: 3))
        // Going back to a state seen earlier is a *new* entry: only neighbours are
        // deduplicated, otherwise the run would read "思考 → 修改" when it did not.
        let c4 = stream.apply(frame(.tool, interval: 4))
        #expect(c1 && c2 && c3 && c4)

        #expect(stream.blocks.count == 1)
        #expect(stream.blocks[0].kind == .status)
        #expect(stream.blocks[0].states == [.thinking, .tool, .editing, .tool])
        // The block keeps the interval it opened on.
        #expect(stream.blocks[0].interval == 1)
        #expect(stream.current == .tool)
        #expect(stream.currentInterval == 4)
        #expect(stream.waiting == nil)
    }

    @Test("a repeated work state heartbeat is not a visible change")
    func workHeartbeatIsQuiet() {
        var stream = TurnStream()
        let first = stream.apply(frame(.tool, interval: 7))
        let beat = stream.apply(frame(.tool, interval: 7, [.heartbeat]))
        #expect(first)
        #expect(!beat)
        #expect(stream.blocks.count == 1)
        #expect(stream.blocks[0].states == [.tool])
        // The same state under a fresh interval is also nothing to draw.
        let again = stream.apply(frame(.tool, interval: 8, [.heartbeat]))
        #expect(!again)
        #expect(stream.currentInterval == 8)
    }

    @Test("a work state after a body opens a new status block")
    func workAfterBodyStartsANewBlock() {
        var stream = TurnStream()
        stream.apply(frame(.streamNarration, interval: 1, [.snapshot, .append], text: "先看看"))
        stream.apply(frame(.tool, interval: 2))
        #expect(stream.blocks.count == 2)
        #expect(stream.blocks[0].kind == .body)
        #expect(stream.blocks[1].kind == .status)
        #expect(stream.blocks[1].states == [.tool])
    }

    // MARK: - Waiting states

    @Test("waiting states are a line, never a block")
    func waitingNeverBecomesABlock() {
        var stream = TurnStream()
        stream.apply(frame(.tool, interval: 1))

        let asked = stream.apply(frame(.awaitingApproval, interval: 2))
        #expect(asked)
        #expect(stream.waiting == .awaitingApproval)
        #expect(stream.blocks.count == 1)
        #expect(stream.blocks[0].kind == .status)
        #expect(stream.blocks[0].states == [.tool])

        // The next work state clears it.
        let resumed = stream.apply(frame(.editing, interval: 3))
        #expect(resumed)
        #expect(stream.waiting == nil)
        #expect(stream.blocks.count == 1)
        #expect(stream.blocks[0].states == [.tool, .editing])
    }

    @Test("a body clears the waiting line and a repeated wait is quiet")
    func waitingClearedByBody() {
        var stream = TurnStream()
        stream.apply(frame(.awaitingUser, interval: 1))
        #expect(stream.waiting == .awaitingUser)

        let beat = stream.apply(frame(.awaitingUser, interval: 1, [.heartbeat]))
        #expect(!beat)
        #expect(stream.waiting == .awaitingUser)

        let answered = stream.apply(frame(.streamFinal, interval: 2, [.snapshot, .append], text: "好"))
        #expect(answered)
        #expect(stream.waiting == nil)
        #expect(stream.blocks.count == 1)
        #expect(stream.blocks[0].kind == .body)
    }

    // MARK: - Body text

    @Test("a snapshot sets the body and appends extend it")
    func bodySnapshotThenAppend() {
        var stream = TurnStream()
        stream.apply(frame(.thinking, interval: 1))

        let opened = stream.apply(frame(.streamNarration, interval: 2, [.snapshot, .append], text: "第一段"))
        #expect(opened)
        #expect(stream.blocks.count == 2)
        #expect(stream.blocks[1].kind == .body)
        #expect(stream.blocks[1].text == "第一段")
        #expect(stream.blocks[1].isFinal == false)
        #expect(stream.liveText == "第一段")
        // The status block froze where it was.
        #expect(stream.blocks[0].states == [.thinking])

        let grew = stream.apply(
            frame(.streamNarration, interval: 2, [.append], seq: bytes("第一段"), text: "第二段")
        )
        #expect(grew)
        #expect(stream.blocks.count == 2)
        #expect(stream.blocks[1].text == "第一段第二段")
        #expect(stream.liveText == "第一段第二段")

        // A later snapshot replaces the buffer instead of appending to it.
        let replaced = stream.apply(frame(.streamNarration, interval: 2, [.snapshot, .append], text: "重来"))
        #expect(replaced)
        #expect(stream.blocks[1].text == "重来")
        #expect(stream.blocks.count == 2)
    }

    @Test("a final answer that repeats the last body is promoted, not duplicated")
    func finalPromotesIdenticalBody() {
        var stream = TurnStream()
        stream.apply(frame(.streamNarration, interval: 1, [.snapshot, .append], text: "结论：修好了"))

        let promoted = stream.apply(frame(.streamFinal, interval: 2, [.snapshot, .append], text: "结论：修好了"))
        #expect(promoted)
        #expect(stream.blocks.count == 1)
        #expect(stream.blocks[0].text == "结论：修好了")
        #expect(stream.blocks[0].isFinal)

        // Deltas of the new interval continue on the promoted block rather than
        // opening a second one.
        let grew = stream.apply(
            frame(.streamFinal, interval: 2, [.append], seq: bytes("结论：修好了"), text: "。")
        )
        #expect(grew)
        #expect(stream.blocks.count == 1)
        #expect(stream.blocks[0].text == "结论：修好了。")
    }

    @Test("a different final answer opens its own block and is marked final")
    func differentFinalStartsANewBlock() {
        var stream = TurnStream()
        stream.apply(frame(.streamNarration, interval: 1, [.snapshot, .append], text: "我先看看文件"))

        let answered = stream.apply(frame(.streamFinal, interval: 2, [.snapshot, .append], text: "改好了"))
        #expect(answered)
        #expect(stream.blocks.count == 2)
        #expect(stream.blocks[0].text == "我先看看文件")
        #expect(stream.blocks[0].isFinal == false)
        #expect(stream.blocks[1].kind == .body)
        #expect(stream.blocks[1].text == "改好了")
        #expect(stream.blocks[1].isFinal)
    }

    @Test("the FINAL flag closes the answer it points at")
    func finalFlagClosesTheAnswer() {
        var stream = TurnStream()
        stream.apply(frame(.streamFinal, interval: 1, [.snapshot, .append], text: "答案"))
        #expect(stream.blocks[0].isFinal)  // opened by streamFinal
        let closing = stream.apply(frame(.streamFinal, interval: 1, [.final]))
        #expect(!closing)

        var narration = TurnStream()
        narration.apply(frame(.streamNarration, interval: 1, [.snapshot, .append], text: "过程"))
        #expect(!narration.blocks[0].isFinal)
        // A FINAL that carries no text just closes the last body: no empty block.
        let closed = narration.apply(frame(.streamNarration, interval: 1, [.final]))
        #expect(closed)
        #expect(narration.blocks.count == 1)
        #expect(narration.blocks[0].isFinal)
        #expect(narration.blocks[0].text == "过程")
    }

    @Test("an empty snapshot waits for text instead of opening an empty body")
    func emptySnapshotWaits() {
        var stream = TurnStream()
        let opened = stream.apply(frame(.streamFinal, interval: 1, [.snapshot, .append], text: ""))
        #expect(!opened)
        #expect(stream.blocks.isEmpty)

        let filled = stream.apply(frame(.streamFinal, interval: 1, [.append], seq: 0, text: "答案"))
        #expect(filled)
        #expect(stream.blocks.count == 1)
        #expect(stream.blocks[0].text == "答案")
        #expect(stream.blocks[0].isFinal)
    }

    @Test("an empty begin before the final snapshot does not duplicate the answer")
    func emptyBeginThenFinalSnapshotPromotes() {
        var stream = TurnStream()
        stream.apply(frame(.thinking, interval: 1))
        stream.apply(frame(.streamNarration, interval: 2, [.snapshot, .append], text: "答案"))

        // The old kernel opened `stream_final` with an empty snapshot and then
        // sent the answer as a second snapshot in the same interval.
        stream.apply(frame(.streamFinal, interval: 3, [.snapshot, .append], text: ""))
        #expect(stream.blocks.filter { $0.kind == .body }.count == 1)

        stream.apply(frame(.streamFinal, interval: 3, [.snapshot, .append], text: "答案"))
        #expect(stream.blocks.filter { $0.kind == .body }.count == 1)
        #expect(stream.blocks.last?.isFinal == true)
    }

    @Test("an older host's concatenated final snapshot promotes the last body")
    func concatenatedFinalSnapshotPromotes() {
        var stream = TurnStream()
        stream.apply(frame(.streamNarration, interval: 1, [.snapshot, .append], text: "先看。"))
        stream.apply(frame(.tool, interval: 2))
        stream.apply(frame(.streamNarration, interval: 3, [.snapshot, .append], text: "改好了。"))

        // Before `last_text_run`, a completed turn re-sent every narration
        // message as one snapshot. The last body is still the answer.
        stream.apply(frame(.streamFinal, interval: 4, [.snapshot, .append], text: "先看。改好了。"))
        #expect(stream.blocks.filter { $0.kind == .body }.count == 2)
        #expect(stream.blocks.last?.isFinal == true)
        #expect(stream.blocks.last?.text == "改好了。")
    }

    // MARK: - Endings

    @Test("an ending ends the turn without erasing anything")
    func terminalStateEnds() {
        var stream = TurnStream()
        stream.apply(frame(.tool, interval: 1))
        stream.apply(frame(.streamFinal, interval: 2, [.snapshot, .append], text: "做完了"))

        stream.apply(frame(.awaitingApproval, interval: 3))
        let ended = stream.apply(frame(.completed, interval: 4))
        #expect(ended)
        #expect(stream.finished)
        #expect(stream.endState == .completed)
        #expect(stream.waiting == nil)
        #expect(stream.blocks.count == 2)
        #expect(stream.liveText == "")

        // A terminal state does not heartbeat, so the repeat is not a change.
        let beat = stream.apply(frame(.completed, interval: 4, [.heartbeat]))
        #expect(!beat)
        #expect(stream.finished)
    }

    @Test("a work state after an ending continues the same stream")
    func resumingAfterAnEnding() {
        var stream = TurnStream()
        stream.apply(frame(.streamFinal, interval: 1, [.snapshot, .append], text: "第一段交代"))
        stream.apply(frame(.completed, interval: 2))
        #expect(stream.finished)

        let resumed = stream.apply(frame(.thinking, interval: 3))
        #expect(resumed)
        #expect(!stream.finished)
        #expect(stream.endState == nil)
        // The blocks are not reset: whether this is a new turn is the view's call.
        #expect(stream.blocks.count == 2)
        #expect(stream.blocks[1].kind == .status)
    }

    @Test("failed and paused also end the turn")
    func otherEndings() {
        var stream = TurnStream()
        stream.apply(frame(.failed, interval: 1))
        #expect(stream.finished)
        #expect(stream.endState == .failed)

        stream.apply(frame(.thinking, interval: 2))
        stream.apply(frame(.paused, interval: 3))
        #expect(stream.finished)
        #expect(stream.endState == .paused)
    }

    // MARK: - Intervals and offsets

    @Test("an older interval is dropped")
    func staleIntervalIsDropped() {
        var stream = TurnStream()
        stream.apply(frame(.tool, interval: 5))
        let before = stream

        let late = stream.apply(frame(.thinking, interval: 4))
        let older = stream.apply(frame(.streamFinal, interval: 0, [.snapshot, .append], text: "旧"))
        #expect(!late)
        #expect(!older)
        #expect(stream == before)
        #expect(stream.blocks[0].states == [.tool])
    }

    @Test("an append that skips bytes is dropped, and the next snapshot repairs it")
    func discontinuousAppendIsDropped() {
        var stream = TurnStream()
        stream.apply(frame(.streamFinal, interval: 1, [.snapshot, .append], text: "abc"))
        #expect(stream.blocks[0].text == "abc")

        // Text claiming to start at 10 when only 3 bytes arrived: a frame was lost.
        // Grafting it on would corrupt the answer, so nothing happens.
        let dropped = stream.apply(frame(.streamFinal, interval: 1, [.append], seq: 10, text: "X"))
        #expect(!dropped)
        #expect(stream.blocks[0].text == "abc")

        // The repair snapshot replaces the whole buffer, and offsets restart there.
        let repaired = stream.apply(frame(.streamFinal, interval: 1, [.snapshot, .append], text: "abcdef"))
        #expect(repaired)
        #expect(stream.blocks[0].text == "abcdef")
        let resumed = stream.apply(frame(.streamFinal, interval: 1, [.append], seq: 6, text: "g"))
        #expect(resumed)
        #expect(stream.blocks[0].text == "abcdefg")

        // A first delta of a fresh block has to start at zero, or its snapshot is lost.
        var fresh = TurnStream()
        let orphan = fresh.apply(frame(.streamNarration, interval: 1, [.append], seq: 5, text: "半句"))
        #expect(!orphan)
        #expect(fresh.blocks.isEmpty)
    }

    // MARK: - Ignored frames

    @Test("idle and unknown frames change nothing")
    func idleAndUnknownAreIgnored() {
        var stream = TurnStream()
        stream.apply(frame(.tool, interval: 1))
        let before = stream

        let idle = stream.apply(frame(.idle, interval: 2))
        let unknown = stream.apply(frame(.unknown, interval: 3))
        #expect(!idle)
        #expect(!unknown)
        #expect(stream == before)
    }

    // MARK: - Replay

    @Test("a replay rebuilds the stream through the same rules")
    func replaceWithReplay() {
        let replay = StreamReplay(
            sessionId: "s-1",
            turn: 4,
            state: SessionState.streamFinal.rawValue,
            interval: 3,
            textSeq: bytes("答案。"),
            truncated: true,
            entries: [
                .init(interval: 1, state: SessionState.thinking.rawValue),
                .init(interval: 2, state: SessionState.tool.rawValue),
                // First entry of interval 3 is that interval's snapshot.
                .init(interval: 3, state: SessionState.streamFinal.rawValue, text: "答案"),
                .init(interval: 3, state: SessionState.streamFinal.rawValue, text: "。", final: true),
            ]
        )

        var stream = TurnStream()
        stream.apply(frame(.tool, interval: 9))  // stale noise before the replay
        stream.markDisconnected()
        stream.replace(with: replay)

        #expect(stream.turn == 4)
        #expect(stream.truncated)
        #expect(!stream.disconnected)
        #expect(stream.current == .streamFinal)
        #expect(stream.currentInterval == 3)
        #expect(stream.blocks.count == 2)
        #expect(stream.blocks[0].kind == .status)
        #expect(stream.blocks[0].states == [.thinking, .tool])
        #expect(stream.blocks[1].kind == .body)
        #expect(stream.blocks[1].text == "答案。")
        #expect(stream.blocks[1].isFinal)
        #expect(stream.liveText == "答案。")
    }

    @Test("a live delta continues from where the replay stopped")
    func liveContinuesAfterReplay() {
        let replay = StreamReplay(
            state: SessionState.streamFinal.rawValue,
            interval: 5,
            textSeq: bytes("abc"),
            entries: [.init(interval: 5, state: SessionState.streamFinal.rawValue, text: "abc")],
        )
        var stream = TurnStream()
        stream.replace(with: replay)

        let continued = stream.apply(frame(.streamFinal, interval: 5, [.append], seq: bytes("abc"), text: "def"))
        #expect(continued)
        #expect(stream.blocks[0].text == "abcdef")
    }

    @Test("a replay whose last entry ended the turn restores the ending")
    func replayCarriesTheEnding() {
        let replay = StreamReplay(
            turn: 2,
            state: SessionState.failed.rawValue,
            interval: 2,
            entries: [
                .init(interval: 1, state: SessionState.tool.rawValue),
                .init(interval: 2, state: SessionState.failed.rawValue),
            ],
        )
        var stream = TurnStream()
        stream.replace(with: replay)

        #expect(stream.finished)
        #expect(stream.endState == .failed)
        #expect(stream.blocks.count == 1)
        #expect(stream.liveText == "")
        // An ending is not drawn as a waiting line.
        #expect(stream.waiting == nil)
    }

    @Test("an empty replay leaves an empty stream that still knows its turn")
    func emptyReplay() {
        var stream = TurnStream()
        stream.apply(frame(.tool, interval: 3))
        stream.replace(with: StreamReplay(sessionId: "s-9", turn: 7, state: SessionState.idle.rawValue, interval: 0))

        #expect(stream.blocks.isEmpty)
        #expect(stream.turn == 7)
        #expect(stream.current == .idle)
        #expect(!stream.finished)
        #expect(!stream.truncated)
    }

    // MARK: - Connection

    @Test("a disconnect keeps the content and a reconnect takes the banner away")
    func disconnectAndReconnect() {
        var stream = TurnStream()
        stream.apply(frame(.tool, interval: 1))
        stream.apply(frame(.streamFinal, interval: 2, [.snapshot, .append], text: "说完这句就断"))

        #expect(!stream.disconnected)
        stream.markDisconnected()
        #expect(stream.disconnected)
        // The failure is drawn after the last block; nothing else changes.
        #expect(stream.blocks.count == 2)
        #expect(stream.blocks[1].text == "说完这句就断")

        stream.markReconnected()
        #expect(!stream.disconnected)
        #expect(stream.blocks.count == 2)
    }

    // MARK: - Turns

    @Test("beginTurn empties the stream and keeps the turn number")
    func beginTurnClears() {
        var stream = TurnStream()
        stream.apply(frame(.tool, interval: 1))
        stream.apply(frame(.streamFinal, interval: 2, [.snapshot, .append], text: "上一轮"))
        stream.apply(frame(.completed, interval: 3))
        stream.markDisconnected()

        stream.beginTurn(7)
        #expect(stream.turn == 7)
        #expect(stream.blocks.isEmpty)
        #expect(stream.current == nil)
        #expect(stream.currentInterval == nil)
        #expect(stream.waiting == nil)
        #expect(!stream.finished)
        #expect(stream.endState == nil)
        #expect(!stream.truncated)
        #expect(stream.liveText == "")

        // The next turn starts from a clean interval ladder.
        let first = stream.apply(frame(.thinking, interval: 1))
        #expect(first)
        #expect(stream.blocks.count == 1)

        // Passing nil keeps the number already known.
        stream.beginTurn(nil)
        #expect(stream.turn == 7)
        stream.beginTurn(8)
        #expect(stream.turn == 8)
    }

    // MARK: - Caps and truncation

    @Test("the block list stops growing at the cap and says it is truncated")
    func blockCap() {
        var stream = TurnStream()
        var interval: UInt32 = 1
        for index in 0 ..< 130 {
            stream.apply(frame(.thinking, interval: interval))
            interval += 1
            stream.apply(
                frame(.streamNarration, interval: interval, [.snapshot, .append], text: "第\(index)段")
            )
            interval += 1
        }

        #expect(stream.blocks.count == TurnStream.maxBlocks)
        #expect(stream.truncated)
        // The newest block is the one kept; the oldest are the ones dropped.
        #expect(stream.blocks.last?.kind == .body)
        #expect(stream.blocks.last?.text == "第129段")
        #expect(stream.liveText == "第129段")
        #expect(stream.blocks.first?.kind == .status)
    }

    @Test("a long stream without overflow is not marked truncated")
    func belowTheCap() {
        var stream = TurnStream()
        var interval: UInt32 = 1
        for index in 0 ..< 3 {
            stream.apply(frame(.thinking, interval: interval))
            interval += 1
            stream.apply(frame(.streamNarration, interval: interval, [.snapshot, .append], text: "第\(index)段"))
            interval += 1
        }
        #expect(stream.blocks.count == 6)
        #expect(!stream.truncated)
    }

    // MARK: - liveText

    @Test("liveText is the body being written, and nothing else")
    func liveTextRules() {
        var stream = TurnStream()
        #expect(stream.liveText == "")

        stream.apply(frame(.thinking, interval: 1))
        #expect(stream.liveText == "")  // last block is a status run

        stream.apply(frame(.streamNarration, interval: 2, [.snapshot, .append], text: "写着"))
        #expect(stream.liveText == "写着")

        stream.apply(frame(.tool, interval: 3))
        #expect(stream.liveText == "")  // the body is no longer the last block

        stream.apply(frame(.completed, interval: 4))
        #expect(stream.liveText == "")
    }

    // MARK: - Value semantics

    @Test("blocks and replays survive a JSON round trip")
    func codableRoundTrip() throws {
        let block = StreamBlock(
            id: 3,
            interval: 12,
            kind: .status,
            states: [.thinking, .tool],
            text: "说明",
            isFinal: true,
        )
        let decoded = try JSONDecoder().decode(StreamBlock.self, from: JSONEncoder().encode(block))
        #expect(decoded == block)
        #expect(decoded.states == [.thinking, .tool])

        let replay = StreamReplay(
            sessionId: "s",
            turn: 1,
            state: 6,
            interval: 2,
            textSeq: 4,
            truncated: true,
            entries: [.init(interval: 2, state: 6, text: "x", final: true)],
        )
        let replayJSON = try JSONEncoder().encode(replay)
        let replayBack = try JSONDecoder().decode(StreamReplay.self, from: replayJSON)
        #expect(replayBack == replay)
    }

    @Test("a replay decodes with the optional fields left out")
    func lenientReplayDecoding() throws {
        // `state` and `interval` are the minimum a replay means anything with; the
        // rest is detail, and a host that omits it must not cost the turn its history.
        let json = Data(#"{"state": 6, "interval": 4}"#.utf8)
        let replay = try JSONDecoder().decode(StreamReplay.self, from: json)
        #expect(replay.sessionId == nil)
        #expect(replay.turn == nil)
        #expect(replay.textSeq == 0)
        #expect(!replay.truncated)
        #expect(replay.entries.isEmpty)

        // An entry may drop `text` and `final` the same way.
        let entriesJSON = Data(#"{"state": 6, "interval": 4, "entries": [{"interval": 4, "state": 1}]}"#.utf8)
        let withEntries = try JSONDecoder().decode(StreamReplay.self, from: entriesJSON)
        #expect(withEntries.entries == [.init(interval: 4, state: 1)])
    }

    @Test("equal content compares equal even when a different path built it")
    func equalityIsAboutContent() {
        var live = TurnStream()
        live.apply(frame(.thinking, interval: 1))
        live.apply(frame(.streamFinal, interval: 2, [.snapshot, .append], text: "答案"))

        var replayed = TurnStream()
        replayed.replace(
            with: StreamReplay(
                state: SessionState.streamFinal.rawValue,
                interval: 2,
                textSeq: bytes("答案"),
                entries: [
                    .init(interval: 1, state: SessionState.thinking.rawValue),
                    .init(interval: 2, state: SessionState.streamFinal.rawValue, text: "答案"),
                ],
            )
        )
        #expect(live == replayed)
    }
}
