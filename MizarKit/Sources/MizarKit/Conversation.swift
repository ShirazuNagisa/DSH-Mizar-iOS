//
//  Conversation.swift
//  MizarKit
//
//  Turning a session log into something a person can read.
//
//  The host hands back raw records, and that is deliberate on its side: event
//  names are merge-extensible, so the set of shapes is open and a bridge that
//  reshaped them would need redeploying whenever DSH added one. The consequence
//  lands here -- this file is where an open schema meets a closed UI, and its
//  whole job is to make an unrecognised record *visible* rather than dropped.
//
//  What each record means was read off a real session, and the *set* of records
//  has since changed on the host's side. It now sends a summary rather than a
//  transcript: for each finished turn, the operator's prompt, the turn's
//  `turn/start`, its `turn/end`, one `step/start` per step, and **only the last**
//  `assistant/message` of the turn -- the model's summary of it. Per-step
//  narration, tool calls, streaming attempts and the partial answer of a running
//  turn are not sent at all. The reason is bandwidth: the full history was too
//  heavy through the relay.
//
//    user/message        data.content[] of typed parts, data.source.kind
//    assistant/message   the turn's summary, the last one it produced
//    turn/start, turn/end, step/start   markers, and the shape of a turn
//    everything else     permission/preset, sandbox/mode, approval/policy, ...
//
//  The markers are kept rather than filtered out: "turn started, step started"
//  is the shape of a working agent, and a conversation that showed only messages
//  could not be told apart from one that was stuck. They are drawn as a count on
//  the turn's row, not as rows of their own -- measured on a live session the
//  ratio is sixteen bookkeeping records to two messages, and a screen where two
//  lines of dialogue sit in a list of sixteen bookkeeping rows is a screen
//  nobody can read. DSH's own desktop transcript makes the same call.
//

import Foundation

/// One page of a session's log.
public struct SessionMessagesResult: Decodable, Sendable, Equatable {
    public let sessionId: String    /// The log cut the page was taken at; `nil` when the session is unknown.
    public let asOfSeq: Int?
    public let records: [SessionRecord]
    public let hasMore: Bool
    /// The oldest *raw* log position on this page.
    ///
    /// The page can project to nothing the phone draws -- a long turn is mostly
    /// tool calls, which are not on the phone wire -- so the visible
    /// ``oldestSeq`` may be absent while the page still has a cursor. Paging
    /// backwards must use this, or the first tool-only page looks like the end
    /// of history.
    public let oldestRawSeq: Int?
    /// Context-window occupancy and its breakdown, as of this page's cut.
    ///
    /// Every page carries it -- the host derives it from the same projection
    /// baseline that names the cut, so a full refresh and a data-saving
    /// incremental refresh both bring it -- which is what keeps the composer's
    /// occupancy ring and its detail popover current while a turn runs. `nil`
    /// means the host did not send one (an older plugin, or a deployment with no
    /// token-meter projection): unknown, never zero.
    public let context: ContextPressure?
}

/// The answer to a `session.sync` batch.
///
/// A host new enough to answer it returns several conversation pages in one
/// frame -- the history sync's real cost was never the bytes, it was one public
/// round trip per session. A host that does not know the method answers
/// `NOT_IMPLEMENTED`, and the caller falls back to one request per session; the
/// type exists here rather than in the app so both sides of that decision are
/// testable against a scripted socket.
public struct SessionSyncResult: Decodable, Sendable, Equatable {
    /// The sessions this frame answers, in the order they were asked. A session
    /// the host read is here; one it had no room for is in ``remaining``.
    public let items: [SessionSyncItem]
    /// Sessions the host did not have room for, in the order they were asked.
    ///
    /// Absent means "nothing left" rather than "the host does not support this":
    /// a host that did not understand the request would have failed the call.
    public let remaining: [String]

    private enum CodingKeys: String, CodingKey {
        case items
        case remaining
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decodeIfPresent([SessionSyncItem].self, forKey: .items) ?? []
        remaining = try container.decodeIfPresent([String].self, forKey: .remaining) ?? []
    }
}

/// One session's entry in a `session.sync` answer.
public struct SessionSyncItem: Decodable, Sendable, Equatable {
    public let sessionId: String
    /// The host skipped the read: its row has not moved since `updatedAt`.
    public let unchanged: Bool?
    /// The page, when the host read one.
    public let messages: SessionMessagesResult?
    /// Why this item failed, when it did. The other items are unaffected.
    public let error: SessionSyncError?

    private enum CodingKeys: String, CodingKey {
        case sessionId
        case unchanged
        case messages
        case error
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        unchanged = try container.decodeIfPresent(Bool.self, forKey: .unchanged)
        messages = try container.decodeIfPresent(SessionMessagesResult.self, forKey: .messages)
        error = try container.decodeIfPresent(SessionSyncError.self, forKey: .error)
    }
}

/// One failed item in a `session.sync` answer.
public struct SessionSyncError: Decodable, Sendable, Equatable {
    public let code: String
    public let message: String
}

/// What the phone claims to hold when it asks for a page.
///
/// The three states are not interchangeable, and the host treats them
/// differently: `unstated` lets it answer from what it remembers delivering to
/// this device, `empty` says the phone lost its cache and needs a full page, and
/// `after` says everything through that log position is already on disk.
///
/// This exists because a refresh used to re-download the whole tail every time —
/// the phone already had every record and paid for them again on every pull,
/// reconnect and poll. ``CachedConversation/deliveredSeq`` is what makes the
/// claim, and a cache that is gone must not keep making it.
public enum SessionMessagesCursor: Sendable, Equatable {
    /// No claim: leave the field off the wire.
    case unstated
    /// The phone holds nothing: send `null`, which the host must not override
    /// with its own idea of what was delivered.
    case empty
    /// The phone holds everything through this position.
    case after(Int)

    /// Whether this is a delta read -- "what is new since a position".
    ///
    /// A delta is not the head of history: the older records a full load would
    /// page back through are already on disk, and a page that claimed otherwise
    /// made every incremental sync start a backfill it did not need.
    public var isDelta: Bool {
        if case .after = self { return true }
        return false
    }

    /// The `afterSeq` field's value, or `nil` when the key must be omitted.
    public var fieldValue: JSONValue? {
        switch self {
        case .unstated: nil
        case .empty: .null
        case .after(let seq): .number(Double(seq))
        }
    }
}

/// One record in the log.
///
/// `type` is `event` for a single event or `chunks` for a packed run of
/// assistant deltas. The payload is kept as ``JSONValue`` rather than decoded
/// into a fixed shape, for the same reason the host does not normalise it.
///
/// The whole record is kept, not just the `event` key, because the two places
/// these records come from disagree about shape. The gateway wraps them as
/// `{"type":"event","event":{…}}`; the same record written to a session log has
/// `type`, `seq`, `time` and `data` at the top level with no wrapper at all.
/// Decoding only `event` means a log-shaped record arrives with no payload and
/// renders as nothing, silently.
public struct SessionRecord: Decodable, Sendable, Equatable {
    /// The record type: `event`, `chunks`, or -- unwrapped -- the event's own
    /// name such as `assistant/message`.
    public let type: String
    /// The gateway's wrapper, when there is one.
    public let event: JSONValue?
    /// Everything the record held.
    private let raw: JSONValue

    /// The record's position in the log, when it names one.
    ///
    /// Read through ``payload`` so both record shapes answer: the gateway wraps
    /// events and puts `seq` inside, while a record read from the log carries it
    /// at the top level. Records without one cannot be placed in the incremental
    /// feed; the host sends them anyway and nothing here needs to guess.
    public var seq: Int? {
        payload["seq"]?.intValue
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case event
    }

    public init(from decoder: any Decoder) throws {
        let single = try decoder.singleValueContainer()
        self.raw = try single.decode(JSONValue.self)
        self.type = raw["type"]?.stringValue ?? ""
        self.event = raw["event"]
    }
}

/// Something worth showing in the conversation.
public enum ConversationItem: Sendable, Equatable, Identifiable {
    /// A message from the operator or the agent.
    case message(id: String, role: Role, text: String, at: Date)
    /// A turn that ended without producing a response.
    case failure(id: String, message: String, at: Date)
    /// The conversation talking about itself: a compaction, a summary that
    /// replaced older turns.
    ///
    /// Not a message from either side, so it is not drawn as one -- a centred
    /// line in the stream, the way the desktop draws it.
    case notice(id: String, text: String, at: Date)

    /// Who a message came from.
    public enum Role: Sendable, Equatable {
        case user
        case assistant
        case system
    }

    public var id: String {
        switch self {
        case .message(let id, _, _, _): id
        case .failure(let id, _, _): id
        case .notice(let id, _, _): id
        }
    }

    /// The log position this item came from, when it has one.
    ///
    /// Timestamps cannot order this log and were being asked to. `time` has
    /// millisecond resolution while one prompt emits about eighteen records, so
    /// runs of them share a millisecond exactly -- measured on a real session,
    /// the first three records all carry `time: …167121`. Sorting on that alone
    /// leaves ties, and the merge that produced the list went through a
    /// dictionary first, so which way the ties fell changed between runs. That
    /// is the scrambling: the same conversation, ordered differently each time
    /// it was loaded.
    ///
    /// `seq` is the log's own counter and is strictly increasing, so it breaks
    /// every tie the timestamp leaves. It is carried inside the identifier
    /// because ``SessionRecord/recordId`` builds it as `seq-<n>`; an item whose
    /// id does not have that shape has no position and sorts by time alone.
    public var seq: Int? {
        guard id.hasPrefix("seq-") else { return nil }
        return Int(id.dropFirst("seq-".count))
    }

    /// A total order over items, oldest first.
    ///
    /// Time first, because it is what a reader compares; `seq` second, because
    /// time does not distinguish everything.
    ///
    /// - Parameters:
    ///   - left: one item.
    ///   - right: the other.
    /// - Returns: whether `left` comes first.
    public static func precedes(_ left: ConversationItem, _ right: ConversationItem) -> Bool {
        // The log's own counter is the position; `time` only breaks records
        // that have no seq. It used to be the other way round, which let two
        // records stamped in the same millisecond (one turn emits many) swap
        // when a page arrived out of order.
        if let leftSeq = left.seq, let rightSeq = right.seq, leftSeq != rightSeq {
            return leftSeq < rightSeq
        }
        if left.at != right.at { return left.at < right.at }
        return (left.seq ?? .max) < (right.seq ?? .max)
    }

    /// When this item happened.
    public var at: Date {
        switch self {
        case .message(_, _, _, let at): at
        case .failure(_, _, let at): at
        case .notice(_, _, let at): at
        }
    }
}

extension SessionRecord {
    /// The payload, whether or not it arrived wrapped.
    ///
    /// The gateway hands back `{"type":"event","event":{…}}`. The same records
    /// written to a session log on disk have no wrapper -- `type`, `seq`, `time`
    /// and `data` sit at the top level. Reading both means a change on either
    /// side degrades to nothing rendered rather than to a parser crash or, worse,
    /// to a record that looks like it has no name.
    var payload: JSONValue {
        event ?? raw
    }

    /// The event's name, or `nil` when this record carries none.
    public var eventName: String? {
        payload["type"]?.stringValue ?? type
    }

    /// When the event happened.
    public var timestamp: Date? {
        guard let millis = payload["time"]?.numberValue else { return nil }
        return Date(timeIntervalSince1970: millis / 1000)
    }

    /// A stable identity for the record.
    public var recordId: String {
        if let seq = payload["seq"]?.intValue { return "seq-\(seq)" }
        return "unknown-\(eventName ?? type)"
    }
}

extension SessionMessagesResult {
    /// The highest log position this page carried, or `nil` when nothing does.
    ///
    /// This is what the phone may claim to hold after folding the page in — the
    /// highest position among the records that actually arrived. Deliberately
    /// not `asOfSeq`: that is the cut the page was taken at, and the host's byte
    /// budget can trim older records out of that window, so claiming the cut
    /// would claim records that were never sent.
    public var newestDeliveredSeq: Int? {
        records.compactMap(\.seq).max()
    }

    /// Flatten the log into something the conversation view can draw.
    ///
    /// One prompt arrives as *two* `user/message` events -- one carrying the RPC
    /// source and one from the inbox splice -- with identical text, and rendering
    /// both puts the same bubble on screen twice, so consecutive duplicates are
    /// collapsed.
    ///
    /// - Returns: the items, oldest first.
    public func conversationItems() -> [ConversationItem] {
        var out: [ConversationItem] = []
        // Ids already kept. A record's identity is its `seq`, and a host that
        // numbers nothing gives every record of a kind the same fallback id
        // (see ``SessionRecord/recordId``) -- two rows sharing one id in a
        // `ForEach` is a crash rather than a drawing mistake, so the second of
        // two colliding ids is dropped. With numbered records the set never
        // fires: every id is `seq-<n>` and distinct.
        var seen: Set<String> = []
        for item in records.compactMap({ $0.conversationItems() }).flatMap({ $0 }) {
            guard seen.insert(item.id).inserted else { continue }
            if case .message(_, let role, let text, _) = item,
               case .message(_, let priorRole, let priorText, _) = out.last,
               role == priorRole, text == priorText {
                continue
            }
            out.append(item)
        }
        return out
    }
}

extension SessionRecord {
    /// The items this record contributes, if any.
    /// - Returns: zero or more items.
    func conversationItems() -> [ConversationItem] {
        // The payload, whether the gateway wrapped it or not.
        let event = payload
        let at = timestamp ?? Date(timeIntervalSince1970: 0)
        let id = recordId
        let name = eventName ?? type

        switch name {
        case "user/message":
            // Only what the operator actually typed. DSH sends its own context
            // through this same event, and `data.source.kind` is what tells them
            // apart. Measured on a live session with an eleven-character prompt:
            //
            //   source.kind = "user"             11 characters   <- the prompt
            //   source.kind = "runtime-context" 483 characters
            //   source.kind = "skill-catalog"  5921 characters
            //
            // 6393 characters of injected context for 11 characters of
            // conversation. Rendering them as user bubbles buries the
            // conversation completely, which is exactly what it did: the screen
            // looked like it had lost its history, and it had -- under text
            // nobody wrote.
            //
            // Blocklist, not allowlist. The first version kept only
            // `source.kind == "user"` and that turned out to hide anything typed
            // on the computer's own DSH window, which is half the history somebody
            // opens this app to read. Hiding the two known injections and
            // showing everything else is the right way round: an unrecognised
            // injection is noise, a hidden message is data loss.
            guard Self.isUserAuthored(event) else { return [] }
            guard let text = Self.messageText(in: event) else { return [] }
            return [.message(id: id, role: .user, text: text, at: at)]

        case "notice":
            // The host's own line about the conversation: a compaction, a
            // summary that replaced older turns. It is text it wrote, not a
            // message from anyone, so it keeps its own item rather than
            // borrowing a role it does not have.
            let text = payload["data"]?["text"]?.stringValue
                ?? Self.messageText(in: event)
            guard let text, !text.isEmpty else { return [] }
            return [.notice(id: id, text: text, at: at)]

        case "system/message":
            // Dropped. This is not a message between anyone -- it is the prompt
            // DSH hands the model: "You are an AI agent powered by DeepSeek
            // Harness. You are a coding agent powered by the deepseek-flash
            // model..." followed by the whole instruction set. Measured on a
            // real session it is several thousand characters at the top of every
            // conversation, and it is not something either party said.
            return []

        case "assistant/message":
            // The turn's summary. The host sends **one** of these per finished
            // turn -- the model's last message, standing for the turn -- so this
            // is the answer, not one step of several. A model that answered
            // perfectly used to produce nothing on the phone while the computer
            // showed the whole exchange, because this event type was the one the
            // parser did not know.
            //
            // A record with no readable text is a step that only called tools.
            // Its stop reason is still worth surfacing: a turn whose model never
            // ran is the single most important thing a monitoring app can tell
            // you.
            guard let text = Self.messageText(in: event) else {
                return Self.stopReasonItem(event: event, id: id, at: at)
            }
            return [.message(id: id, role: .assistant, text: text, at: at)]

        default:
            // Dropped on purpose, not by omission. See the note at the top of
            // this file: the markers outnumber the messages several times over,
            // and a conversation that lists them is not a conversation.
            return []
        }
    }

    /// Whether a `user/message` is context DSH assembled rather than words a
    /// person wrote.
    ///
    /// Measured on a live session with an eleven-character prompt:
    ///
    ///   source.kind = "user"             11 characters   <- the prompt
    ///   source.kind = "runtime-context" 483 characters
    ///   source.kind = "skill-catalog"  5921 characters
    ///
    /// 6393 characters of injected context for 11 characters of conversation,
    /// all arriving as `user/message`. Those two kinds are listed here; anything
    /// else is shown, because a source this build has not seen is far more
    /// likely to be a message from the computer's own window than a new injection.
    ///
    /// - Parameter event: the event payload.
    /// - Returns: whether to hide it.
    /// Whether a `user/message` was written by the operator.
    ///
    /// An allowlist, and the census that justifies it. Every `user/message` in a
    /// real session log, by `source.kind`:
    ///
    ///     13  user                the operator, typing
    ///      7  tool-jobs           a background job finished
    ///      6  runtime-context     injected context
    ///      4  subagent-settled    a subagent stopped
    ///      3  skill-catalog       injected skill list
    ///      3  goal                a goal round
    ///      2  user-approval       a notice *about* a user action
    ///      2  agent-message       another agent talking
    ///      2  compact-checkpoint  the conversation was compacted
    ///      1  model-selection     the model was changed
    ///      1  plan-mode           the mode was changed
    ///
    /// Nine of those eleven arrived as ordinary user messages, and a blocklist
    /// that named two of them let the other seven through -- which is the pile
    /// of things the operator never typed.
    ///
    /// A blocklist was chosen first, on the reasoning that an unrecognised
    /// injection is noise while a hidden message is data loss. The census says
    /// otherwise: an unrecognised kind is not a message, and the only kind that
    /// is one is `user`. A message typed in the computer's own DSH window carries it
    /// too, so nothing a person wrote is lost by asking for it by name.
    ///
    /// A missing `kind` is not treated as `user`. Guessing in that direction is
    /// how the pile got here.
    ///
    /// - Parameter event: the event payload.
    /// - Returns: whether the operator wrote it.
    private static func isUserAuthored(_ event: JSONValue?) -> Bool {
        let kind = event?["data"]?["source"]?["kind"]?.stringValue
            ?? event?["data"]?["message"]?["source"]?["kind"]?.stringValue
        return kind == "user"
    }

    /// Pull text out of a message event's typed content parts.
    ///
    /// There are two placements and both are real, read off a session log:
    ///
    ///   user/message       data.content[]
    ///   assistant/message  data.message.content[]
    ///   system/message     data.message.content[]
    ///
    /// Reading only the first is why the model's replies never appeared on the
    /// phone while the computer showed the whole exchange. The text was there, one
    /// key deeper, and the parser looked in the wrong one.
    ///
    /// - Parameter event: the event payload.
    /// - Returns: the joined text, or `nil` when there is none.
    private static func messageText(in event: JSONValue?) -> String? {
        let parts = event?["data"]?["message"]?["content"]?.arrayValue
            ?? event?["data"]?["content"]?.arrayValue
        guard let parts else { return nil }
        let text = parts.compactMap { part -> String? in
            guard part["type"]?.stringValue == "text" else { return nil }
            return part["text"]?.stringValue
        }
        return text.isEmpty ? nil : text.joined(separator: "\n")
    }

    /// Read a failed stop reason, when a reply carries one instead of text.
    ///
    /// The host's summary-only history sends the model's last message of a turn,
    /// and the shape of that message is the ordinary one: text parts. What is
    /// *not* ordinary -- and is the case this exists for -- is a reply with no
    /// text at all, which is what a turn whose model never ran looks like on a
    /// host with no provider credential. Rendering that as nothing would make a
    /// failure indistinguishable from a hang.
    ///
    /// - Parameters:
    ///   - event: the event payload.
    ///   - id: the record's identity.
    ///   - at: when it happened.
    /// - Returns: a failure item, or nothing when there is no reason to show.
    private static func stopReasonItem(event: JSONValue?, id: String, at: Date) -> [ConversationItem] {
        let message = event?["data"]?["stopReason"]?["message"]?.stringValue
            ?? event?["data"]?["error"]?["message"]?.stringValue
            ?? event?["data"]?["message"]?["stopReason"]?["message"]?.stringValue
        guard let message else { return [] }
        return [.failure(id: id, message: message, at: at)]
    }
}

/// One turn of the conversation: what the agent did in response to one prompt.
///
/// DSH groups by turn and this did not, so a single prompt that took eleven
/// steps arrived as eleven separate messages and read as the model talking to
/// itself. The grain is in the log -- every record from `turn/start` to
/// `turn/end` carries `data.turn`, and `step/start` and `step/end` bracket the
/// parts within it -- so the grouping is a reading of what is already there
/// rather than a guess at it.
public struct ConversationTurn: Sendable, Equatable, Identifiable, Codable {
    /// Which turn, or `nil` for anything outside one.
    public let turn: Int?
    /// The number of the last turn folded into this one, when it is a chain.
    ///
    /// DSH ends a turn before starting the next, and an agent that keeps working
    /// emits consecutive `turn/start`s with no prompt between them. Those are
    /// folded into the turn they continued, and the chain keeps its **first**
    /// number in ``turn`` as its identity. This is the number at the other end of
    /// that chain, so a record that names the *last* continuation -- which is
    /// what a `turn/end` does, and the ending is how the chain stops -- can still
    /// be joined to the copy the phone holds instead of arriving under a number
    /// no entry has. Equal to ``turn`` for a turn that is not a chain.
    ///
    /// Optional, because this is a cache format: a file written before it existed
    /// decodes with `nil`, and the sign-off that would have matched it is dropped
    /// as before.
    public let lastTurn: Int?
    /// What the operator said, oldest first. Always shown.
    public let prompts: [ConversationItem]
    /// What the agent produced, oldest first. The last assistant message is the
    /// turn's answer.
    ///
    /// Under the host's summary-only history this is the model's final message
    /// for a finished turn, and **nothing at all** for a running one: the
    /// per-step narration and the partial answer of a turn in progress are not
    /// sent any more.
    public let steps: [ConversationItem]
    /// How many steps the turn took, when the log says.
    ///
    /// Counted from `step/start`, not from ``steps``, and that is the point of
    /// it: the host sends one tiny marker per step but only the *last*
    /// `assistant/message` of a turn, so counting messages undercounts every
    /// turn that took more than one. Eleven steps used to arrive as eleven
    /// messages; they now arrive as eleven markers and one reply.
    ///
    /// `nil` means the log did not say -- a cache written before this existed,
    /// or a page whose markers were trimmed away. It is deliberately not zero:
    /// "this turn took no steps" is a claim, and a claim made out of a missing
    /// record is the kind of thing this file exists to avoid.
    public let stepCount: Int?
    /// When the turn began.
    ///
    /// `turn/start` when the page holds it. A page window can be cut *through* a
    /// turn, and then the oldest record of a running turn is a `step/start` --
    /// written one record after the turn opened, measured on a live host at seq
    /// 803 and 805 -- so the marker stands in for the start rather than the turn
    /// losing its clock. An approximation of one record is worth more than a
    /// running row that cannot say how long it has been running, and it is the
    /// same tolerance ``beganAt`` has always used for a page cut across a turn.
    public let startedAt: Date?
    /// When it ended.
    public let endedAt: Date?
    /// How it ended, when the host said.
    public let endedReason: String?
    /// Whether ``endedAt`` was inferred rather than read.
    ///
    /// The log is the only authority on an end: a turn is over when a
    /// `turn/end` for it arrives. This is `true` in the one case where the log
    /// cannot answer and the agent's own turn model still can -- this phone's
    /// copy never received the `turn/end`, but a later turn exists, and a turn
    /// ends before the next one begins. ``settlingStaleRuns(in:)`` is what
    /// writes it; every end read from the host leaves it `nil`.
    ///
    /// Optional, because this is a cache format: a file written before it
    /// existed must still decode, and a missing key is not a claim that the end
    /// was recorded.
    public let endInferred: Bool?
    /// The earliest log position any of the turn's records held.
    ///
    /// The turn's *markers* count, not only the records the screen draws, and
    /// that is the point of storing it. A running turn is `turn/start` and
    /// `step/start` and nothing else -- the host sends no answer for a turn that
    /// has not finished, and the prompt is written after the turn opens -- so
    /// derived from ``items`` alone its position was `nil`, and everything that
    /// reads a position then got it wrong: the turn sorted to the end of the
    /// conversation, so the prompt that began it (measured: turn/start at seq
    /// 803, the prompt at 806) sorted *before* its own turn, and the rule that
    /// gives a page-edge prompt back to the turn it began could not see that the
    /// turn followed it.
    ///
    /// `nil` for a turn built by hand or read from a cache written before this
    /// existed, which falls back to the positions of its items.
    public let firstSeq: Int?
    /// Exact inclusive durable boundary; never inferred from an answer's seq.
    public let endSeq: Int?
    /// Exact usage of the final durable turn represented by this summary.
    public let tokenUsage: TurnTokenUsage?
    /// Host found later tool/error content after the last text response.
    public let branchUnavailable: Bool?
    /// The files this turn declared as deliverables, when the host said.
    ///
    /// The computer draws them as cards under the turn, and they come from the
    /// model's `present` call — a `tool/call`, which `session.messages` never
    /// sends. The plugin lifts them onto the turn's `turn/end` instead, so this
    /// is what lets the phone draw the same cards.
    ///
    /// Optional, because this is a cache format and because most turns present
    /// nothing: `nil` is "no files", and it is also what a cache written before
    /// this field existed decodes to. Use ``files`` for the answer to draw.
    public let deliverables: [DeliveredFile]?

    /// The deliverables, with "the host said nothing" folded into "none".
    public var files: [DeliveredFile] { deliverables ?? [] }

    /// A stable identity, unique within a conversation.
    ///
    /// Unnumbered groups carry their position, not a shared word. Every group
    /// without a turn number used to be called `"unopened"`, and since the merge
    /// between pages is a dictionary keyed on this, they overwrote one another
    /// and only the last survived.
    public var id: String {
        if let turn { return String(turn) }
        return "unopened-\(orderSeq.map(String.init) ?? "head")"
    }

    /// Where this turn sits in the log: the earliest position it holds.
    ///
    /// This, not the turn number, is what orders a conversation. A page of the
    /// log can end immediately after a prompt, before the turn that prompt
    /// started, and that prompt then has no number at all -- so ordering by
    /// number sent it to the very end, below messages written hours later.
    /// Measured on a real session: a prompt sent at 09:57 was drawn beneath one
    /// sent at 12:01.
    ///
    /// ``firstSeq`` first, because a turn can hold nothing else: its markers are
    /// not items, so a running turn with no prompt in the page had no position
    /// at all and was ordered as though it were the newest thing in a
    /// conversation it might be the middle of.
    public var orderSeq: Int? { firstSeq ?? items.compactMap(\.seq).min() }

    /// A total order over turns, oldest first.
    ///
    /// - Parameters:
    ///   - left: one turn.
    ///   - right: the other.
    /// - Returns: whether `left` comes first.
    public static func precedes(_ left: ConversationTurn, _ right: ConversationTurn) -> Bool {
        let lhs = left.orderSeq ?? .max
        let rhs = right.orderSeq ?? .max
        if lhs != rhs { return lhs < rhs }
        return (left.turn ?? .max) < (right.turn ?? .max)
    }

    /// This turn, with prompts put in front of the ones it already has.
    ///
    /// - Parameter extra: the prompts to put first.
    /// - Returns: the combined turn.
    public func prepending(prompts extra: [ConversationItem]) -> ConversationTurn {
        ConversationTurn(
            turn: turn,
            prompts: extra + prompts,
            steps: steps,
            stepCount: stepCount,
            startedAt: startedAt,
            endedAt: endedAt,
            endedReason: endedReason,
            firstSeq: firstSeq,
            endInferred: endInferred,
            lastTurn: lastTurn,
            endSeq: endSeq,
            tokenUsage: tokenUsage,
            branchUnavailable: branchUnavailable,
            deliverables: deliverables,
        )
    }

    /// This turn, ended at an instant the log did not write down.
    ///
    /// The one settler of an end that is not in the log. It exists for the
    /// shape ``settlingStaleRuns(in:)`` describes: a turn this phone still holds
    /// as running while a later turn -- which the agent cannot start before this
    /// one ends -- has already arrived. The instant is an upper bound (the later
    /// turn's start), and ``endInferred`` is set so no screen reports it as a
    /// measured duration or a recorded outcome.
    ///
    /// - Parameter end: when the turn must have ended by.
    /// - Returns: the turn, settled.
    public func settling(at end: Date) -> ConversationTurn {
        ConversationTurn(
            turn: turn,
            prompts: prompts,
            steps: steps,
            stepCount: stepCount,
            startedAt: startedAt,
            endedAt: end,
            endedReason: endedReason,
            firstSeq: firstSeq,
            endInferred: true,
            lastTurn: lastTurn,
            endSeq: endSeq,
            tokenUsage: tokenUsage,
            branchUnavailable: branchUnavailable,
            deliverables: deliverables,
        )
    }

    /// This turn and the one that carried on from it, as one turn.
    ///
    /// The *last* turn in the chain decides whether the whole thing has ended,
    /// which is why `endedAt` is taken from the continuation outright rather
    /// than falling back to this turn's own end. Folding a still-running
    /// continuation into a finished predecessor and keeping the predecessor's
    /// end time is what drew a working turn as "已完成，用时 2 分 14 秒": the end
    /// time was real, it just belonged to the turn before.
    ///
    /// A continuation with neither a start nor an end is not a real turn -- it
    /// is an unnumbered group of steps the pager dropped the envelope of -- and
    /// it supersedes nothing.
    ///
    /// Steps are unioned by id rather than concatenated, because this runs on
    /// every merge and not only once: a chain that was folded last time comes
    /// back unfurled from the host on the next page, so the same step arrives
    /// both inside the folded turn and beside it, and appending would show it
    /// twice.
    ///
    /// - Parameter next: the continuation, which has no prompt of its own.
    /// - Returns: the combined turn.
    public func absorbing(_ next: ConversationTurn) -> ConversationTurn {
        let continuation = next.startedAt != nil || next.endedAt != nil
        // Any reason that is not `completed` is unfinished, and the first one
        // wins. Only `error` counted before, so a turn the operator cancelled --
        // or the agent abandoned, or ran out of context in -- was continued by a
        // turn that completed and then reported "已完成" with the abort folded
        // away behind the bar.
        let unfinished = Self.unfinished(endedReason) ?? Self.unfinished(next.endedReason)
        return ConversationTurn(
            turn: turn,
            prompts: prompts,
            steps: Self.union(steps, next.steps),
            // Added, not unioned: a count is of a whole turn, and the two halves
            // of a continued turn each took their own steps. Only the items were
            // unioned, because a step that arrived beside the folded turn is the
            // same step -- its *marker* is a separate record with no identity to
            // union on, which is why the addition happens once here rather than
            // being re-derived from markers on every fold.
            stepCount: Self.adding(stepCount, next.stepCount ?? next.steps.count),
            startedAt: startedAt,
            endedAt: continuation ? next.endedAt : endedAt,
            endedReason: unfinished ?? (continuation ? next.endedReason : endedReason),
            firstSeq: Self.earliest(firstSeq, next.firstSeq),
            // The chain's end is the last continuation's, so whether that end
            // was inferred is the last continuation's too. Folding a settled
            // continuation in and keeping the predecessor's recorded end would
            // report a duration the log never measured.
            endInferred: continuation ? next.endInferred : endInferred,
            // The other end of the chain's identity, so a later `turn/end`
            // naming this continuation can find the folded copy it belongs to.
            lastTurn: Self.most(lastTurn, next.lastTurn ?? next.turn),
            endSeq: continuation ? next.endSeq : endSeq,
            tokenUsage: continuation ? next.tokenUsage : tokenUsage,
            branchUnavailable: continuation ? next.branchUnavailable : branchUnavailable,
            // The files belong to the turn's end, so the copy that carries the
            // end carries them; a continuation that ended the chain is that copy.
            deliverables: continuation ? next.deliverables : deliverables,
        )
    }

    /// This turn, with another copy of itself folded in.
    ///
    /// Two reads of one turn are both partial, and neither is a superset of the
    /// other. A page is a *window* -- the host trims it to the newest few hundred
    /// messages -- so the turn straddling the window's oldest edge comes back
    /// without the prompt that began it. Replacing the stored copy with the
    /// fetched one therefore deleted the operator's own message from the
    /// conversation, and nothing they could do on the phone brought it back: the
    /// view draws turns rather than the flat item list, and the turn no longer
    /// had the prompt in it.
    ///
    /// The end is taken from this copy where it has one, because this copy is the
    /// one just fetched and an end is durable -- a later read cannot un-end a
    /// turn. Everything else is unioned by item id, the same rule the flat item
    /// list has always used and for the same reason.
    ///
    /// - Parameter other: the other copy.
    /// - Returns: the two, as one turn.
    public func merging(_ other: ConversationTurn) -> ConversationTurn {
        // The end is one fact, not three. Its instant, the reason it carried and
        // whether it was inferred all belong to whichever copy has an end:
        // reading them field by field let a fresh copy with no end clear the
        // inferred mark off an end that came from the cached copy, which left a
        // settled turn reporting an end the host never sent.
        //
        // A **recorded** end beats an inferred one, whichever copy it is on. An
        // inferred end is a placeholder for exactly the record that just arrived;
        // keeping the placeholder because this copy has one would leave the
        // settled mark on a turn the host has since said how it ended.
        let ended: ConversationTurn
        if (lastTurn ?? turn ?? -1) != (other.lastTurn ?? other.turn ?? -1) {
            // A page of the older prefix may overlap a cached continuation.
            // Only the final durable turn owns the chain's end and footer.
            ended = (lastTurn ?? turn ?? -1) > (other.lastTurn ?? other.turn ?? -1) ? self : other
        } else if endedAt != nil, !isEndInferred {
            ended = self
        } else if other.endedAt != nil, !other.isEndInferred {
            ended = other
        } else {
            ended = endedAt != nil ? self : other
        }
        let sameFinalTurn = (lastTurn ?? turn) == (other.lastTurn ?? other.turn)
        let reason = ended.endedReason ?? (sameFinalTurn ? (endedAt != nil ? other.endedReason : endedReason) : nil)
        return ConversationTurn(
            turn: turn ?? other.turn,
            // `other` first, so this copy -- the one just fetched -- wins where
            // the two describe the same item.
            prompts: Self.union(other.prompts, prompts),
            steps: Self.union(other.steps, steps),
            // The count is of the *same* turn read twice, so the two are not
            // added -- the larger is the read that saw more markers. Adding them
            // would double every turn on every refresh, because a page and the
            // cache overlap on every one of them.
            stepCount: Self.most(stepCount, other.stepCount),
            startedAt: [startedAt, other.startedAt].compactMap { $0 }.min(),
            endedAt: ended.endedAt,
            endedReason: reason,
            firstSeq: Self.earliest(firstSeq, other.firstSeq),
            endInferred: ended.endInferred,
            lastTurn: Self.most(lastTurn, other.lastTurn),
            endSeq: ended.endSeq,
            tokenUsage: ended.tokenUsage ?? (endSeq == other.endSeq ? (tokenUsage ?? other.tokenUsage) : nil),
            branchUnavailable: ended.branchUnavailable ?? (endSeq == other.endSeq ? (branchUnavailable ?? other.branchUnavailable) : nil),
            // Same reasoning as the usage above: the list arrives with the end,
            // and the copy holding the end is the one that has it. Falling back
            // to the other copy keeps cards from disappearing when a refresh
            // returns a page that was cut before the turn ended.
            deliverables: ended.deliverables ?? deliverables ?? other.deliverables,
        )
    }

    /// The earlier of two log positions.
    ///
    /// Used where two reads of one turn are folded together: the one that saw
    /// further back is the one that knows where the turn begins.
    ///
    /// - Parameters:
    ///   - first: one position.
    ///   - second: the other.
    /// - Returns: the earlier, or `nil` when neither knows.
    private static func earliest(_ first: Int?, _ second: Int?) -> Int? {
        switch (first, second) {
        case (let first?, let second?): min(first, second)
        case (let first?, nil): first
        case (nil, let second?): second
        case (nil, nil): nil
        }
    }

    /// Two step counts for one turn, added.
    ///
    /// - Parameters:
    ///   - first: one count.
    ///   - second: the other.
    /// - Returns: their sum, or `nil` when neither knows.
    private static func adding(_ first: Int?, _ second: Int?) -> Int? {
        guard first != nil || second != nil else { return nil }
        return (first ?? 0) + (second ?? 0)
    }

    /// Two step counts for one turn, the larger of them.
    ///
    /// - Parameters:
    ///   - first: one count.
    ///   - second: the other.
    /// - Returns: the larger, or `nil` when neither knows.
    private static func most(_ first: Int?, _ second: Int?) -> Int? {
        switch (first, second) {
        case (let first?, let second?): max(first, second)
        case (let first?, nil): first
        case (nil, let second?): second
        case (nil, nil): nil
        }
    }

    /// Every item from both lists, once, in log order.
    ///
    /// - Parameters:
    ///   - first: one list.
    ///   - second: the other.
    /// - Returns: the union.
    private static func union(
        _ first: [ConversationItem],
        _ second: [ConversationItem],
    ) -> [ConversationItem] {
        var byId: [String: ConversationItem] = [:]
        for item in first { byId[item.id] = item }
        // The second list wins on a collision: it is the copy just fetched.
        for item in second { byId[item.id] = item }
        return byId.values.sorted(by: ConversationItem.precedes)
    }

    /// The reason a turn did not finish, when it is one.
    ///
    /// The vocabulary is merge-extensible -- plugins add their own `kind` -- so
    /// anything that is not `completed` counts. That is the safe direction: an
    /// unknown reason shown as done is a lie, and the same reason shown as
    /// unfinished is merely cautious.
    ///
    /// - Parameter reason: `turn/end.reason.kind`, as recorded.
    /// - Returns: the reason, or `nil` when the turn completed or has not ended.
    private static func unfinished(_ reason: String?) -> String? {
        guard let reason, reason != "completed" else { return nil }
        return reason
    }

    public init(
        turn: Int?,
        prompts: [ConversationItem],
        steps: [ConversationItem],
        stepCount: Int? = nil,
        startedAt: Date?,
        endedAt: Date?,
        endedReason: String?,
        firstSeq: Int? = nil,
        endInferred: Bool? = nil,
        lastTurn: Int? = nil,
        endSeq: Int? = nil,
        tokenUsage: TurnTokenUsage? = nil,
        branchUnavailable: Bool? = nil,
        deliverables: [DeliveredFile]? = nil,
    ) {
        self.turn = turn
        self.lastTurn = lastTurn
        self.prompts = prompts
        self.steps = steps
        self.stepCount = stepCount
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.endedReason = endedReason
        self.firstSeq = firstSeq
        self.endInferred = endInferred
        self.endSeq = endSeq
        self.tokenUsage = tokenUsage
        self.branchUnavailable = branchUnavailable
        self.deliverables = deliverables
    }

    /// How long the turn took, when both ends are known.
    ///
    /// `nil` while the turn is running, and that is the point: `turn/end` is the
    /// only record that ends a turn, and a duration invented from the last step
    /// is a duration for something that has not stopped.
    public var duration: TimeInterval? {
        guard let startedAt, let endedAt else { return nil }
        return max(0, endedAt.timeIntervalSince(startedAt))
    }

    /// Whether this is a turn that has started and has not ended.
    ///
    /// Both halves matter, and each was got wrong once:
    ///
    /// - `turn/end` is the only thing that ends a turn. A duration invented from
    ///   the last step made every unfinished turn look finished, which is the
    ///   bug this exists to fix.
    /// - A group with **no turn number is not a turn**. It is a prompt whose
    ///   `turn/start` is in the page on the other side of a window edge -- or,
    ///   rarely, a prompt from the end of a session that never started a turn.
    ///   Drawn as work in progress it would claim an agent was thinking about a
    ///   message nobody ever answered.
    ///
    ///   This used to say the cause was that `user/message` is logged before the
    ///   turn it begins. It is logged *after* it -- measured on the live wire,
    ///   `turn/start` at seq 92 and the prompt at 95 -- and reading the grouping
    ///   as though it were the other way round is what left a running turn with
    ///   no prompt, and its row reporting "已完成" while the host was executing.
    public var isRunning: Bool { turn != nil && endedAt == nil }

    /// Whether this turn's end was inferred rather than read. See ``endInferred``.
    ///
    /// A row that shows this one has to stop saying "deepseeking" -- the turn is
    /// over, a later turn proves it -- but it must not say "completed" either:
    /// the log never said how it ended.
    public var isEndInferred: Bool { endInferred == true }

    /// Whether this group holds nothing but a turn's ending.
    ///
    /// A page window is cut by log position, so it can begin between a turn's
    /// last record and its `turn/end`; the ending then arrives on its own. That
    /// is evidence about a turn, not a turn -- nothing this page can show
    /// happened in it -- and merging treats it as such: joined to the phone's
    /// copy it ends that copy, and on its own it is dropped rather than drawn as
    /// an empty row with no prompt. The failure item is allowed here because it
    /// is a detail *of* the ending, and merges into the held turn beside it.
    var isEndOnly: Bool {
        guard turn != nil, endedAt != nil, startedAt == nil, prompts.isEmpty else { return false }
        return steps.allSatisfy { item in
            if case .failure = item { return true }
            return false
        }
    }

    /// When the turn began, as well as the log can say.
    ///
    /// Normally `turn/start`. When a page was cut across a turn -- which happens
    /// at the boundary between two pages, and to whichever turn straddled it --
    /// the earliest thing the turn holds is the same instant to within a record,
    /// and a running turn with no start time would otherwise have no way to say
    /// how long it had been going.
    public var beganAt: Date? { startedAt ?? items.map(\.at).min() }

    /// How long the turn has been going, measured against a clock.
    ///
    /// A finished turn answers with its own duration; a running one counts up to
    /// `now`, which is what lets the screen tick without asking the host
    /// anything.
    ///
    /// - Parameter now: the instant to measure to.
    /// - Returns: the elapsed time, or `nil` when the turn has no start.
    public func elapsed(asOf now: Date) -> TimeInterval? {
        guard let beganAt else { return nil }
        return max(0, (endedAt ?? now).timeIntervalSince(beganAt))
    }

    /// Whether the turn ended without finishing.
    ///
    /// Two separate facts, because neither on its own is enough.
    ///
    /// **The log's own reason.** `turn/end.reason.kind` is `completed` when the
    /// agent finished, and one of `error`, `aborted`, `blocked`, `max-tokens`,
    /// `interrupted` or `forked` when it did not. Only `error` was treated as a
    /// failure here, so a turn the operator cancelled -- or the agent abandoned,
    /// or ran out of context in -- read as "已完成". The vocabulary is
    /// merge-extensible, so anything that is not `completed` counts as
    /// unfinished. That is the safe direction: an unknown reason shown as done
    /// is a lie, and the same reason shown as unfinished is merely cautious.
    ///
    /// **The answer.** A failure item among the turn's own records is the other
    /// half of the evidence, and it is what a turn whose message carries a stop
    /// reason instead of text produces. Measured on this machine, every turn
    /// ended `completed` while the model had never run -- the host has no
    /// provider credential -- and trusting the reason alone drew those as
    /// finished work.
    public var failed: Bool {
        if let endedReason, endedReason != "completed" { return true }
        return steps.contains { item in
            if case .failure = item { return true }
            return false
        }
    }

    /// Everything in the turn, for a caller that wants a flat list.
    public var items: [ConversationItem] { prompts + steps }

    /// Everything the turn contains, in the order the log wrote it.
    ///
    /// ``prompts`` and ``steps`` are storage buckets, not a running order. DSH
    /// writes a steer message and an injected notice *inside* the turn, between
    /// two assistant messages, and the desktop draws them there; drawing every
    /// prompt first moved those rows above an answer that came before them.
    /// `seq` is the only stable position, and it is already on the item.
    public var orderedItems: [ConversationItem] {
        items.sorted(by: ConversationItem.precedes)
    }
}

extension SessionMessagesResult {
    /// Read the page as turns, in order.
    ///
    /// Grouping rules, each from the log rather than from taste:
    ///
    /// - `data.turn` on a record says which turn it belongs to.
    /// - **A prompt carries no turn number, and is written inside the turn it
    ///   opened.** The order was measured twice over -- in the durable log of a
    ///   real session (`turn/start` at seq 4, `step/start` at 6, the operator's
    ///   `user/message` at 8, the injected context after it) and on the live wire
    ///   (`turn/start` 803, `step/start` 805, the prompt 806) -- and it is the
    ///   opposite of what this reader assumed: the prompt comes *after* the
    ///   `turn/start`, not before it. So a prompt belongs to the turn that is
    ///   open when it arrives, and is held for a later `turn/start` only when
    ///   nothing is open -- which is what a page cut across a turn looks like.
    ///   Holding it in every case lost the newest turn: the host sends one
    ///   `assistant/message` per *finished* turn, so a running turn has no
    ///   message to claim its prompt, and the prompt became a group of its own
    ///   while the turn that was executing held none -- measured, `prompts.count
    ///   == 0` on the turn whose row was supposed to read "深度求索中，用时
    ///   xx分xx秒".
    /// - A prompt with no turn after it keeps its own unopened group rather than
    ///   being dropped.
    /// - Within a turn, the prompt is what the operator typed and stays visible;
    ///   the answer is the model's last message of the turn.
    /// - `step/start` is counted rather than rendered. The host still sends one
    ///   per step -- they are tiny -- but it sends nothing for the steps
    ///   themselves, so the count is the only part of a step that survives. Its
    ///   position and its time are kept even though the marker is not drawn: a
    ///   turn whose window was cut before its `turn/start` has nothing else to
    ///   place it by, and a running turn has nothing else at all.
    /// - `turn/end.reason.kind` distinguishes a turn that finished from one that
    ///   ran into something, and a turn that ran into something **before it
    ///   answered** is drawn as a failure. Under summary-only history there is no
    ///   streaming attempt left to carry the reason, so a turn that ends
    ///   `error`/`aborted`/`blocked` with no message of its own would otherwise
    ///   read as a bar saying "未完成" over an empty screen. "The turn ended
    ///   without a response" is exactly what happened, and it is the one state a
    ///   monitoring app must not show as a hang.
    /// - A `turn/end` whose turn has **no other record in this page** is a
    ///   **sign-off**, not a turn: the window is cut at a log position, not at a
    ///   turn boundary, so the ending can arrive alone. It is kept so
    ///   ``mergeTurns(cached:fresh:)`` can end the copy the phone holds -- how a
    ///   turn that was running when the phone last looked finishes without a
    ///   page that repeats its `turn/start` -- and dropped when there is no copy
    ///   to end.
    ///
    /// - Returns: the turns, oldest first.
    public func conversationTurns() -> [ConversationTurn] {
        var order: [Int?] = []
        var prompts: [Int?: [ConversationItem]] = [:]
        var steps: [Int?: [ConversationItem]] = [:]
        var stepCounts: [Int?: Int] = [:]
        var started: [Int?: Date] = [:]
        var ended: [Int?: Date] = [:]
        var reason: [Int?: String] = [:]
        var endSeqs: [Int?: Int] = [:]
        var usages: [Int?: TurnTokenUsage] = [:]
        var branchFlags: [Int?: Bool] = [:]
        /// The earliest log position each turn is known to hold.
        var firstSeq: [Int?: Int] = [:]
        /// The earliest time a turn-naming record carried, for a turn whose
        /// `turn/start` the page window cut away. Markers only: a `step/start`
        /// stands in for the start it follows by one record, and a `turn/end`
        /// does not stand in for anything.
        var firstAt: [Int?: Date] = [:]
        /// Prompts seen before the turn they started.
        var pendingPrompts: [ConversationItem] = []
        /// Notices seen before the turn they belong to. They are steps, never
        /// prompts: a notice drawn as a user bubble is the wrong voice.
        var pendingNotices: [ConversationItem] = []
        /// The turn that is open: a `turn/start` has been read and no
        /// `turn/end` for it has. This is the turn a prompt written now began.
        var open: Int?
        var openIsSet = false

        /// Remember where a turn sits, and (for a marker) roughly when it began.
        ///
        /// - Parameters:
        ///   - turn: the turn the record names.
        ///   - seq: its log position.
        ///   - at: when it happened, for the records that can stand in for a
        ///     start.
        func note(_ turn: Int?, seq: Int?, at: Date?) {
            if let seq, seq < (firstSeq[turn] ?? .max) { firstSeq[turn] = seq }
            if let at, at < (firstAt[turn] ?? .distantFuture) { firstAt[turn] = at }
        }

        /// Item ids each turn has already been given, prompts and steps apart.
        ///
        /// A record's identity is its `seq` (``SessionRecord/recordId``), and a
        /// host that numbers nothing gives every record of a kind the same
        /// fallback id -- one prompt can even arrive as two `user/message`
        /// records, the RPC source and the inbox splice. Prompts and steps are
        /// two separate `ForEach` lists on screen, so an id repeated *within*
        /// one list is a crash while the same id on two different turns is not:
        /// the scopes here are exactly the lists the screen keys on, which
        /// drops the duplicate without ever dropping a second turn's prompt.
        /// Numbered records are untouched -- every id is `seq-<n>` and
        /// distinct, so neither set ever fires on a host that numbers its log.
        /// Files each turn declared as deliverables, keyed by turn.
        var deliverables: [Int?: [DeliveredFile]] = [:]
        var placedIds: [Int?: Set<String>] = [:]
        var placedStepIds: [Int?: Set<String>] = [:]

        /// The turn whose seq range contains a record, when one has closed
        /// around it. Used for notices whose wire `turn` is missing (DSH's
        /// `user/message` has no turn field) and for a page cut mid-turn.
        func containingTurn(seq: Int) -> Int? {
            for candidate in order.reversed() {
                guard let candidate else { continue }
                guard let start = firstSeq[candidate], start <= seq else { continue }
                if let end = endSeqs[candidate] {
                    if seq <= end { return candidate }
                } else if candidate == open {
                    return candidate
                }
            }
            return nil
        }

        /// Put a record's items on its turn, keeping the first of any repeated id.
        ///
        /// - Parameters:
        ///   - items: what the record contributed.
        ///   - turn: the turn it belongs to, or `nil` for the group a prompt
        ///     with no turn after it keeps.
        ///   - step: whether these are steps -- an answer or a failure card --
        ///     rather than prompts.
        func place(_ items: [ConversationItem], for turn: Int?, as step: Bool) {
            var kept: [ConversationItem] = []
            for item in items {
                let isNew = step
                    ? placedStepIds[turn, default: []].insert(item.id).inserted
                    : placedIds[turn, default: []].insert(item.id).inserted
                if isNew { kept.append(item) }
            }
            guard !kept.isEmpty else { return }
            if step {
                steps[turn, default: []].append(contentsOf: kept)
            } else {
                prompts[turn, default: []].append(contentsOf: kept)
            }
        }

        for record in records {
            let payload = record.payload
            let name = payload["type"]?.stringValue ?? record.type
            let turn = payload["data"]?["turn"]?.intValue
            let seq = payload["seq"]?.intValue
            let at = payload["time"]?.numberValue.map { Date(timeIntervalSince1970: $0 / 1000) }

            switch name {
            case "turn/start":
                if !order.contains(turn) { order.append(turn) }
                started[turn] = at
                note(turn, seq: seq, at: at)
                open = turn
                openIsSet = true
                if !pendingPrompts.isEmpty {
                    place(pendingPrompts, for: turn, as: false)
                    pendingPrompts.removeAll()
                }
                if !pendingNotices.isEmpty {
                    place(pendingNotices, for: turn, as: true)
                    pendingNotices.removeAll()
                }
            case "step/start":
                // A marker, not content. It still names its turn -- unlike a
                // prompt, which names none -- but a page can be cut mid-turn, so
                // a marker for a turn no record has opened yet puts that turn in
                // the order rather than dropping the step it counts.
                if !order.contains(turn) { order.append(turn) }
                note(turn, seq: seq, at: at)
                stepCounts[turn, default: 0] += 1
            case "turn/end":
                // A page can begin between a turn's last record and this one --
                // a window is cut at a log position, not at a turn boundary --
                // and then the ending arrives on its own. It used to be skipped
                // unless the turn's own `turn/start` happened to be in the same
                // page, which is how a turn this phone held as running could
                // finish without the phone ever hearing it: the next page held
                // only the later turns. The group is a sign-off rather than a
                // turn (see `ConversationTurn/isEndOnly`); ``mergeTurns`` joins
                // it to the copy the phone holds, and drops it when there is no
                // copy to join.
                if let turn, !order.contains(turn) { order.append(turn) }
                ended[turn] = at
                endSeqs[turn] = seq
                if let count = payload["data"]?["mizarTokenUsage"]?["totalTokens"]?.intValue {
                    usages[turn] = TurnTokenUsage(totalTokens: count)
                }
                branchFlags[turn] = payload["data"]?["mizarBranchUnavailable"]?.boolValue
                // The files the model declared with `present`. Read from the
                // same record as the usage above and for the same reason: the
                // host attaches both to `turn/end`, and an empty list is stored
                // as `nil` so "nothing presented" and "the host said nothing"
                // draw the same screen without a distinction nobody can act on.
                let declared = DeliverablePayload.parse(payload["data"])
                deliverables[turn] = declared.isEmpty ? nil : declared
                note(turn, seq: seq, at: nil)
                // Closed, so a prompt written after it belongs to a later turn
                // rather than to this one.
                if openIsSet, open == turn { openIsSet = false }
                let kind = payload["data"]?["reason"]?["kind"]?.stringValue
                reason[turn] = kind
                // A turn that ended badly and produced **nothing**. The
                // answer's absence is what makes the card the operator's
                // business: a turn that failed after answering has said
                // something, and a notice drawn over its answer would replace
                // what the model managed to say with a notice that it did not
                // finish. That turn keeps its row's own warning and its answer.
                if let kind, kind != "completed", steps[turn]?.isEmpty ?? true {
                    let detail = payload["data"]?["reason"]?["error"]?["message"]?.stringValue
                    place(
                        [.failure(id: record.recordId, message: detail ?? kind, at: at ?? .distantPast)],
                        for: turn, as: true,
                    )
                }
            case "notice":
                let items = record.conversationItems()
                guard !items.isEmpty else { continue }
                if let turn, order.contains(turn) {
                    place(items, for: turn, as: true)
                } else if let seq, let containing = containingTurn(seq: seq) {
                    place(items, for: containing, as: true)
                } else if openIsSet {
                    place(items, for: open, as: true)
                } else {
                    // A notice is not a prompt. Holding it separately keeps a
                    // settlement notice from waking as a user bubble.
                    pendingNotices.append(contentsOf: items)
                }
            case "user/message", "assistant/message":
                let items = record.conversationItems()
                guard !items.isEmpty else { continue }
                if name == "user/message" {
                    // A prompt belongs to the turn it opened, and the host
                    // writes it *inside* that turn -- see the note above. Only
                    // when nothing is open is it held for a turn that has not
                    // been read yet.
                    if let turn, order.contains(turn) {
                        place(items, for: turn, as: false)
                    } else if let seq, let containing = containingTurn(seq: seq) {
                        place(items, for: containing, as: false)
                    } else if openIsSet {
                        place(items, for: open, as: false)
                    } else {
                        pendingPrompts.append(contentsOf: items)
                    }
                    continue
                }
                if !order.contains(turn) { order.append(turn) }
                note(turn, seq: seq, at: nil)
                // A prompt can also arrive before its `turn/start` -- a page
                // whose oldest record is the prompt, with the turn's envelope in
                // the page before it -- so it is claimed by whichever of the two
                // is read first.
                if !pendingPrompts.isEmpty {
                    place(pendingPrompts, for: turn, as: false)
                    pendingPrompts.removeAll()
                }
                if !pendingNotices.isEmpty {
                    place(pendingNotices, for: turn, as: true)
                    pendingNotices.removeAll()
                }
                place(items, for: turn, as: true)
            default:
                continue
            }
        }

        // A record with nothing after it still has to be on screen. Prompts
        // stay prompts; notices stay notices -- the trailing group is a
        // transcript, not a user message.
        if !pendingPrompts.isEmpty || !pendingNotices.isEmpty {
            order.append(nil)
            if !pendingPrompts.isEmpty { place(pendingPrompts, for: nil, as: false) }
            if !pendingNotices.isEmpty { place(pendingNotices, for: nil, as: true) }
        }

        return order.map { turn in
            ConversationTurn(
                turn: turn,
                prompts: prompts[turn] ?? [],
                steps: steps[turn] ?? [],
                stepCount: stepCounts[turn],
                startedAt: started[turn] ?? firstAt[turn],
                // Only a `turn/end` ends a turn. This used to fall back to the
                // time of the last step, which made every unfinished turn look
                // finished: the screen drew "已完成，用时 1 分 12 秒" for a turn
                // that was still working, and the number was just the age of the
                // newest message in it.
                endedAt: ended[turn],
                endedReason: reason[turn],
                firstSeq: firstSeq[turn],
                lastTurn: turn,
                endSeq: endSeqs[turn],
                tokenUsage: usages[turn],
                branchUnavailable: branchFlags[turn],
                deliverables: deliverables[turn],
            )
        }
    }

    /// The oldest log position among these records, or `nil` when there are none.
    ///
    /// `session.messages` pages by `beforeSeq`, so this is what a caller asks
    /// for next when it wants what came before the page it holds.
    public var oldestSeq: Int? {
        records.compactMap { $0.payload["seq"]?.intValue }.min()
    }
}
