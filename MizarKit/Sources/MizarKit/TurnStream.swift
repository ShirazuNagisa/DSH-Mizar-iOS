//
//  TurnStream.swift
//  MizarKit
//
//  The data half of the live turn stream: state frames in, a list of drawable
//  blocks out. No SwiftUI in this file on purpose -- the view layer should be
//  able to say "draw these blocks" without knowing a single rule about
//  intervals, snapshots or text offsets.
//
//  Three things live here, in order:
//
//    StreamBlock   one status run or one body of text
//    StreamReplay  the whole stream as the host replays it on (re)connect
//    TurnStream    the reducer that turns frames into blocks
//
//  The rules are the state-channel spec's (protocol/state-channel-v1.md), with
//  one addition that only matters to the display: `streamFinal` is promoted onto
//  the last body when it repeats it word for word, so a turn that ended on a
//  narration is not printed twice.
//

import Foundation

/// One block of a turn's visible stream.
///
/// A turn reads top to bottom as status blocks ("思考推理中 → 调用工具中") and
/// body blocks (narration, then the final answer). Waiting states are not blocks;
/// they are a line of their own under the stream.
public struct StreamBlock: Identifiable, Equatable, Sendable, Codable {
    public enum Kind: String, Codable, Sendable {
        case status, body
    }

    /// Stable identity for `ForEach`.
    public let id: Int

    /// The interval the block opened on. A status block keeps the interval of its
    /// first state even after later states advance past it.
    public let interval: UInt32

    public var kind: Kind

    /// status only: the work states seen inside this run, in order, deduplicated
    /// adjacently. Waiting states and body states never appear here.
    public var states: [SessionState]

    /// body only: the text accumulated for this block.
    public var text: String

    /// body only: whether this block is confirmed to be the final answer.
    public var isFinal: Bool

    public init(
        id: Int,
        interval: UInt32,
        kind: Kind,
        states: [SessionState] = [],
        text: String = "",
        isFinal: Bool = false,
    ) {
        self.id = id
        self.interval = interval
        self.kind = kind
        self.states = states
        self.text = text
        self.isFinal = isFinal
    }
}

/// A whole turn stream as the host can hand it back on (re)connect.
///
/// `entries` is the frame log in order: the first entry of an interval is a
/// snapshot of that interval's text, later entries of the same interval are
/// deltas. `state` / `interval` / `textSeq` describe where the stream stands
/// *now*, so live frames can continue from the replay without a gap.
public struct StreamReplay: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public let interval: UInt32
        public let state: UInt8
        public let text: String
        public let final: Bool

        enum CodingKeys: String, CodingKey {
            case interval
            case state
            case text
            case final
        }

        public init(interval: UInt32, state: UInt8, text: String = "", final: Bool = false) {
            self.interval = interval
            self.state = state
            self.text = text
            self.final = final
        }

        /// A missing `text` or `final` means "no text, not ended", not "throw the
        /// whole journal away".
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            interval = try container.decode(UInt32.self, forKey: .interval)
            state = try container.decode(UInt8.self, forKey: .state)
            text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
            final = try container.decodeIfPresent(Bool.self, forKey: .final) ?? false
        }
    }

    public let sessionId: String?
    public let turn: Int?
    public let state: UInt8
    public let interval: UInt32
    public let textSeq: UInt32
    /// The host dropped earlier entries: draw "更早的过程已省略" above the blocks.
    public let truncated: Bool
    public let entries: [Entry]

    enum CodingKeys: String, CodingKey {
        case sessionId
        case turn
        case state
        case interval
        case textSeq
        case truncated
        case entries
    }

    public init(
        sessionId: String? = nil,
        turn: Int? = nil,
        state: UInt8,
        interval: UInt32,
        textSeq: UInt32 = 0,
        truncated: Bool = false,
        entries: [Entry] = [],
    ) {
        self.sessionId = sessionId
        self.turn = turn
        self.state = state
        self.interval = interval
        self.textSeq = textSeq
        self.truncated = truncated
        self.entries = entries
    }

    /// Only `state` and `interval` are required. A host that leaves out
    /// `textSeq` / `truncated` / `entries` is describing the same stream with less
    /// detail, and a replay is an improvement the screen falls back without -- not
    /// a reason to lose the turn's history.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId)
        turn = try container.decodeIfPresent(Int.self, forKey: .turn)
        state = try container.decode(UInt8.self, forKey: .state)
        interval = try container.decode(UInt32.self, forKey: .interval)
        textSeq = try container.decodeIfPresent(UInt32.self, forKey: .textSeq) ?? 0
        truncated = try container.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
        entries = try container.decodeIfPresent([Entry].self, forKey: .entries) ?? []
    }
}

/// The reducer: one turn's frames folded into drawable blocks.
///
/// Value type on purpose -- a view can hold one, apply a frame, and compare the
/// old value to the new one to decide whether to redraw.
public struct TurnStream: Sendable, Equatable {
    /// Longest history kept. Past this the oldest blocks fall off so a pathological
    /// stream cannot grow without bound; the view learns about it from `truncated`.
    static let maxBlocks = 200

    /// The turn number, when the engine numbers turns.
    public private(set) var turn: Int?

    /// Everything the stream has shown, oldest first.
    public private(set) var blocks: [StreamBlock]

    /// The state of the most recently applied frame.
    public private(set) var current: SessionState?

    /// The interval the most recently applied frame belonged to.
    public private(set) var currentInterval: UInt32?

    /// A waiting state (approval, question). Shown as the current line only; it
    /// never becomes a block and the next work state or body clears it.
    public private(set) var waiting: SessionState?

    /// Whether the turn has ended (`.completed` / `.failed` / `.paused`).
    public private(set) var finished: Bool

    /// How it ended, when it did.
    public private(set) var endState: SessionState?

    /// The connection went away. The view draws "远程连接失败" after the last block.
    public private(set) var disconnected: Bool

    /// Part of the stream is missing: the host truncated the replay, or blocks
    /// fell off the 200-block cap.
    public private(set) var truncated: Bool

    /// Body bytes already received in the interval being written. An append whose
    /// `textSeq` does not land exactly here came after a lost frame.
    private var bodyBytes: Int

    /// The body block currently accepting text, and the interval that text belongs
    /// to. Tracked by id rather than by interval because a promoted block keeps the
    /// interval it opened on while it takes over the next interval's deltas.
    private var bodyBlockId: Int?

    private var bodyInterval: UInt32?

    /// Source of `StreamBlock.id`.
    private var nextBlockId: Int

    public init() {
        turn = nil
        blocks = []
        current = nil
        currentInterval = nil
        waiting = nil
        finished = false
        endState = nil
        disconnected = false
        truncated = false
        bodyBytes = 0
        bodyBlockId = nil
        bodyInterval = nil
        nextBlockId = 1
    }

    /// Content equality. The bookkeeping counters (`bodyBytes`, `nextBlockId`) are
    /// deliberately left out: two streams that draw the same are the same stream.
    public static func == (lhs: TurnStream, rhs: TurnStream) -> Bool {
        lhs.turn == rhs.turn
            && lhs.blocks == rhs.blocks
            && lhs.current == rhs.current
            && lhs.currentInterval == rhs.currentInterval
            && lhs.waiting == rhs.waiting
            && lhs.finished == rhs.finished
            && lhs.endState == rhs.endState
            && lhs.disconnected == rhs.disconnected
            && lhs.truncated == rhs.truncated
    }

    /// The text of the body the agent is still writing, for the typewriter.
    ///
    /// Empty when the stream has ended or when the last block is a status run: in
    /// both cases nothing is being typed and the blocks should be drawn as stored.
    public var liveText: String {
        guard !finished, let last = blocks.last, last.kind == .body else { return "" }
        return last.text
    }

    // MARK: - Applying frames

    /// Apply one frame. Returns whether anything the person can see changed, so a
    /// view can skip redrawing on heartbeats.
    @discardableResult
    public mutating func apply(_ frame: StateFrame) -> Bool {
        let state = frame.state

        // "Idle" and unknown codes draw nothing special: no block, no line, no change.
        guard state != .idle, state != .unknown else { return false }

        // An older interval is a late frame. Whatever it says, the screen has moved on.
        if let currentInterval, frame.interval < currentInterval { return false }

        var changed = false

        // A non-terminal frame after an ending means the same stream carried on (the
        // agent answered the question it was waiting on, or a follow-up landed on the
        // same turn). Only the screen's ending is undone; the blocks stay, and a
        // genuinely new turn goes through `beginTurn`.
        if finished, !Self.isTerminal(state) {
            finished = false
            endState = nil
            changed = true
        }

        switch state {
        case .thinking, .tool, .editing, .subagent, .background, .compacting, .retrying, .queued:
            return applyWork(state, interval: frame.interval) || changed
        case .awaitingApproval, .awaitingUser:
            return applyWaiting(state, interval: frame.interval) || changed
        case .streamNarration, .streamFinal:
            return applyBody(frame) || changed
        case .completed, .failed, .paused:
            return applyEnd(state, interval: frame.interval) || changed
        case .idle, .unknown:
            return false
        }
    }

    /// Rebuild the whole stream from a replay (reconnect, opening a session).
    ///
    /// Everything is cleared first; the entries are then folded through the same
    /// rules a live stream uses, so there is exactly one implementation of the
    /// merge/promotion/offset logic.
    public mutating func replace(with replay: StreamReplay) {
        self = TurnStream()
        turn = replay.turn
        truncated = replay.truncated

        var previousInterval: UInt32?
        var offset = 0

        for entry in replay.entries {
            let opensInterval = previousInterval != entry.interval
            var flags: StateFrame.Flags = []
            var textSeq: UInt32 = 0

            if opensInterval {
                // The first entry of an interval is that interval's snapshot.
                flags.insert(.snapshot)
                flags.insert(.append)
            } else {
                flags.insert(.append)
                textSeq = UInt32(clamping: offset)
            }
            if entry.final { flags.insert(.final) }

            let frame = StateFrame(
                state: SessionState(code: entry.state),
                interval: entry.interval,
                textSeq: textSeq,
                flags: flags,
                text: entry.text,
            )
            apply(frame)

            offset = opensInterval ? entry.text.utf8.count : offset + entry.text.utf8.count
            previousInterval = entry.interval
        }

        // Continue from where the replay says the stream stands, so the next live
        // append is accepted rather than judged a lost frame.
        current = SessionState(code: replay.state)
        currentInterval = max(currentInterval ?? replay.interval, replay.interval)
        bodyBytes = Int(clamping: replay.textSeq)

        // A replay may end without an entry for its own current state; honour the
        // ending either way rather than waiting for a frame that will never come.
        let landed = SessionState(code: replay.state)
        if Self.isTerminal(landed) {
            finished = true
            endState = landed
            waiting = nil
        }
    }

    /// The connection dropped. Content is kept: the failure is drawn after it.
    public mutating func markDisconnected() {
        disconnected = true
    }

    /// The connection is back. Content is rebuilt by `replace(with:)`, so this only
    /// takes the failure banner away.
    public mutating func markReconnected() {
        disconnected = false
    }

    /// Start the next turn on the same session: empty the stream, keep the turn
    /// number (pass `nil` to keep the one already known).
    public mutating func beginTurn(_ turn: Int?) {
        let carriedTurn = turn ?? self.turn
        self = TurnStream()
        self.turn = carriedTurn
    }

    // MARK: - Rule groups

    /// A work state. Consecutive work states are one status block: the block
    /// answers "what did it do", not "how many frames arrived".
    private mutating func applyWork(_ state: SessionState, interval: UInt32) -> Bool {
        var changed = false
        currentInterval = interval
        current = state

        if waiting != nil {
            waiting = nil
            changed = true
        }

        // A status run ends the moment text starts, so a body after it is a new
        // block even if another body block is still remembered.
        bodyBlockId = nil
        bodyInterval = nil

        if let index = blocks.indices.last, blocks[index].kind == .status {
            if blocks[index].states.last != state {
                blocks[index].states.append(state)
                changed = true
            }
        } else {
            blocks.append(StreamBlock(id: takeId(), interval: interval, kind: .status, states: [state]))
            trim()
            changed = true
        }
        return changed
    }

    /// A waiting state: a line under the stream, never a block.
    private mutating func applyWaiting(_ state: SessionState, interval: UInt32) -> Bool {
        currentInterval = interval
        current = state
        guard waiting != state else { return false }
        waiting = state
        return true
    }

    /// An ending. The blocks stay: what happened still happened.
    private mutating func applyEnd(_ state: SessionState, interval: UInt32) -> Bool {
        let changed = waiting != nil || !finished || endState != state
        currentInterval = interval
        current = state
        waiting = nil
        finished = true
        endState = state
        bodyBlockId = nil
        bodyInterval = nil
        return changed
    }

    /// Body text: narration or the final answer.
    private mutating func applyBody(_ frame: StateFrame) -> Bool {
        let state = frame.state
        let isSnapshot = frame.flags.contains(.snapshot)
        let carriesText = frame.flags.contains(.append)
        let endsHere = frame.flags.contains(.final)
        let opensInterval = frame.interval != currentInterval

        var changed = false
        currentInterval = frame.interval
        current = state

        if waiting != nil {
            waiting = nil
            changed = true
        }

        // A heartbeat on a stream interval: liveness only, nothing to draw.
        guard isSnapshot || endsHere || !frame.text.isEmpty else { return changed }

        // Promotion. A final answer that says exactly what the last body already
        // says is that body, now confirmed. Printing it a second time would read
        // like the model repeated itself.
        //
        // "Exactly" means the whole text, byte for byte, so this can only fire on a
        // snapshot or a FINAL -- never on a delta, which is a fragment by nature.
        // `opensInterval` lets a replayed answer re-confirm a block that is already
        // final instead of duplicating it on reconnect.
        if state == .streamFinal, isSnapshot || endsHere, !frame.text.isEmpty,
            let index = blocks.indices.last, blocks[index].kind == .body,
            blocks[index].text == frame.text,
            !blocks[index].isFinal || opensInterval
        {
            if !blocks[index].isFinal {
                blocks[index].isFinal = true
                changed = true
            }
            bodyBlockId = blocks[index].id
            bodyInterval = frame.interval
            bodyBytes = blocks[index].text.utf8.count
            return changed
        }

        // An older host re-announces the whole turn's text as the final snapshot
        // (before this build the kernel concatenated every narration message).
        // The last body is still the answer; the prefix is narration already on
        // screen, so promoting it is the whole update. Exact concatenation only --
        // a suffix test would promote "好了" over a real answer "改好了".
        if state == .streamFinal, isSnapshot, !frame.text.isEmpty,
            let index = blocks.indices.last, blocks[index].kind == .body,
            !blocks[index].text.isEmpty
        {
            let narration = blocks
                .filter { $0.kind == .body && !$0.isFinal }
                .map(\.text)
                .joined()
            if narration == frame.text {
                if !blocks[index].isFinal {
                    blocks[index].isFinal = true
                    changed = true
                }
                bodyBlockId = blocks[index].id
                bodyInterval = frame.interval
                bodyBytes = blocks[index].text.utf8.count
                return changed
            }
        }

        // A FINAL with no text (the usual shape) only closes the answer already
        // there. Opening an empty block for it would draw an empty bubble.
        if endsHere, !carriesText, frame.text.isEmpty, !isSnapshot,
            let index = blocks.lastIndex(where: { $0.kind == .body }),
            !blocks[index].isFinal
        {
            blocks[index].isFinal = true
            return true
        }

        // Where does the text go? The body block this interval has been writing to,
        // if any. A new interval opens a new block; a status run never takes text,
        // it freezes and the body starts a block of its own.
        let target: Int? = bodyBlockId.flatMap { id in
            guard bodyInterval == frame.interval else { return nil }
            return blocks.firstIndex { $0.id == id }
        }

        // A delta must land exactly where the body ended. Text at any other offset
        // means a frame was lost; gluing it on would silently corrupt the answer,
        // so it is dropped and the next snapshot repairs the block. A block that is
        // about to be created starts at zero, hence the `?? 0`.
        if carriesText, !isSnapshot, Int(frame.textSeq) != (target.map { _ in bodyBytes } ?? 0) {
            return changed
        }

        // An interval's first frame is an empty snapshot -- `begin` of a
        // text-carrying state. It is not a body yet: drawing it would open an
        // empty block, and the snapshot that follows would fill that block with
        // text the previous block already shows. Wait for the text.
        if isSnapshot, frame.text.isEmpty {
            return changed
        }

        var index: Int
        if let existing = target {
            index = existing
        } else {
            let block = StreamBlock(
                id: takeId(),
                interval: frame.interval,
                kind: .body,
                // A body opened by `streamFinal` *is* the answer; it does not have
                // to wait for the FINAL flag to be styled as one.
                isFinal: state == .streamFinal,
            )
            blocks.append(block)
            index = blocks.count - 1
            bodyBytes = 0
            bodyBlockId = block.id
            bodyInterval = frame.interval
            trim()
            // `trim` drops from the front, so the new block is no longer at the
            // index it was appended at.
            index = blocks.firstIndex { $0.id == block.id } ?? (blocks.count - 1)
            changed = true
        }

        if isSnapshot {
            if blocks[index].text != frame.text {
                blocks[index].text = frame.text
                changed = true
            }
            bodyBytes = frame.text.utf8.count
        } else if carriesText, !frame.text.isEmpty {
            blocks[index].text += frame.text
            bodyBytes += frame.text.utf8.count
            changed = true
        }

        if endsHere, !blocks[index].isFinal {
            blocks[index].isFinal = true
            changed = true
        }
        return changed
    }

    // MARK: - Housekeeping

    private static func isTerminal(_ state: SessionState) -> Bool {
        switch state {
        case .completed, .failed, .paused: return true
        default: return false
        }
    }

    private mutating func takeId() -> Int {
        defer { nextBlockId += 1 }
        return nextBlockId
    }

    /// Keep the block list bounded, oldest first. The newest block (the one being
    /// written) is never the one dropped.
    private mutating func trim() {
        while blocks.count > Self.maxBlocks {
            blocks.removeFirst()
            truncated = true
        }
        if let id = bodyBlockId, !blocks.contains(where: { $0.id == id }) {
            bodyBlockId = nil
            bodyInterval = nil
        }
    }
}
