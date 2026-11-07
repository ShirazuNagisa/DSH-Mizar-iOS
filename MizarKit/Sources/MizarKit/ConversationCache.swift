//
//  ConversationCache.swift
//  MizarKit
//
//  Conversations kept on the phone.
//
//  Two problems, one answer. A page can only be so large -- iOS refuses a
//  WebSocket frame over a mebibyte and closes the connection when one arrives --
//  so the host trims what it sends. And a phone loses its network constantly,
//  which used to mean losing the screen with it.
//
//  Caching locally means the conversation is there before the network answers,
//  survives the network not answering, and grows by paging backwards rather than
//  by asking for everything at once.
//
//  Stored as one JSON file per session under Application Support. Not a database:
//  the shape is a list of items with stable ids, the volume is a few hundred
//  kilobytes per session, and a file that can be read with `cat` is worth more
//  during a bug report than an index that cannot.
//

import Foundation

/// A conversation kept on disk.
public struct CachedConversation: Codable, Sendable, Equatable {
    /// The session it belongs to.
    public let sessionId: String
    /// Items, oldest first.
    public let items: [ConversationItem]
    /// The log cut this cache is complete through, or `nil` when unknown.
    public let throughSeq: Int?
    /// When it was last written.
    public let syncedAt: Date
    /// Whether the host said there was more history before this.
    public let hasMore: Bool
    /// The same conversation grouped into turns.
    ///
    /// Optional so a cache written before grouping existed still decodes -- a
    /// cache that fails to read is a conversation that looks lost, which is the
    /// thing this file exists to prevent.
    public let turns: [ConversationTurn]?
    /// The oldest log position this cache holds.
    ///
    /// Paging backwards needs it: `session.messages` takes a `beforeSeq`, and
    /// the newest position the page was taken at says nothing about where its
    /// first record sits. Without it there is no way to ask for what came
    /// before, which is why scrolling up did nothing.
    public let oldestSeq: Int?
    /// The oldest raw log position this cache has paged over.
    ///
    /// Separate from ``oldestSeq`` because a page can contain only tool calls
    /// and project to no visible item. That page still advances where the next
    /// backward request must start.
    public let historyCursor: Int?
    /// The last usage frame the host sent for this session.
    ///
    /// Stored beside the conversation rather than fetched when the screen opens.
    /// The figures above the composer are read from it, and without a copy the
    /// model name and the context percentage simply vanished whenever the read
    /// did not come back -- on a phone that is every time the app is suspended,
    /// which is constantly. Measured from the operator's side: "有时候退出会话
    /// 之后再进来就不见了，有时候又有".
    ///
    /// Optional so a cache written before this existed still decodes.
    public let stats: SessionStatsFrame?
    /// The highest log position this phone actually holds.
    ///
    /// Not the same as ``throughSeq``, which is the cut a page was taken at. The
    /// host's byte budget can trim older records out of that window, so a cutoff
    /// says what was asked for, while this says what arrived. It is what the
    /// phone claims when it asks for only new records — claiming more than it
    /// holds is how a conversation ends up with its middle missing.
    ///
    /// Optional so a cache written before it existed still decodes; a `nil` here
    /// makes the next request say nothing at all rather than make a claim nobody
    /// can stand behind.
    public let deliveredSeq: Int?

    /// The session row's `updatedAt` this conversation was synced against.
    ///
    /// The host's ledger makes a repeated read cheap in bytes, but not in round
    /// trips: a "sync all" pass still asks about every session. The row's
    /// `updatedAt` moves for exactly the things a history pass cares about (a
    /// new record, a rename, a model change), so a cache that already covers
    /// that value needs no request at all. Optional so caches written before
    /// this existed still decode, and so an older host's rows still sync.
    public let syncedUpdatedAt: Double?

    public init(
        sessionId: String,
        items: [ConversationItem],
        throughSeq: Int?,
        syncedAt: Date = Date(),
        hasMore: Bool = false,
        turns: [ConversationTurn]? = nil,
        oldestSeq: Int? = nil,
        historyCursor: Int? = nil,
        stats: SessionStatsFrame? = nil,
        deliveredSeq: Int? = nil,
        syncedUpdatedAt: Double? = nil,
    ) {
        self.turns = turns
        self.oldestSeq = oldestSeq
        self.historyCursor = historyCursor
        self.stats = stats
        self.deliveredSeq = deliveredSeq
        self.syncedUpdatedAt = syncedUpdatedAt
        self.sessionId = sessionId
        self.items = items
        self.throughSeq = throughSeq
        self.syncedAt = syncedAt
        self.hasMore = hasMore
    }
}

/// Whether a stored conversation already covers a session row.
///
/// Kept here rather than in the app so the rule is testable without a network:
/// the history pass may skip a session exactly when the cache was synced at or
/// after the row's last change.
public enum HistorySyncPolicy {
    /// Whether `cached` is at least as new as the row's `updatedAt`.
    public static func isCurrent(_ cached: CachedConversation?, updatedAt: Double) -> Bool {
        guard let synced = cached?.syncedUpdatedAt else { return false }
        return synced >= updatedAt
    }
}

/// Storage for cached conversations.
public protocol ConversationCache: Sendable {
    /// Read a cached conversation.
    /// - Parameter sessionId: the session.
    /// - Returns: the cache, or `nil` when nothing is stored.
    func load(sessionId: String) async -> CachedConversation?

    /// Replace a cached conversation.
    /// - Parameter conversation: what to store.
    func save(_ conversation: CachedConversation) async

    /// Read one session, change it, and write it back as one step.
    ///
    /// Load-then-save at the call site is two steps, and this file is written
    /// from four of them -- `syncConversation`, `loadOlder`, `storeStats` and a
    /// page arriving while the operator pulls to refresh. They genuinely overlap:
    /// the automatic paging at the top of a conversation runs against the reload
    /// that a returning-to-foreground triggers. Two overlapping read-modify-write
    /// cycles on one file lose one of them, and what is lost is whatever the
    /// other one had just fetched -- messages, or the cursor that paging needs.
    ///
    /// Implementations must not suspend between the read and the write. An actor
    /// gets that for free by doing both synchronously inside itself.
    ///
    /// - Parameters:
    ///   - sessionId: the session to change.
    ///   - transform: what the stored conversation should become, given what is
    ///     there now.
    /// - Returns: what was stored.
    @discardableResult
    func update(
        sessionId: String,
        _ transform: @Sendable (CachedConversation?) -> CachedConversation,
    ) async -> CachedConversation

    /// Forget one session.
    /// - Parameter sessionId: the session to forget.
    func remove(sessionId: String) async

    /// Forget everything.
    func clear() async

    /// How many sessions are cached.
    func count() async -> Int
}

extension ConversationItem: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, id, role, text, message, at
    }

    /// A flat shape, because the enum's associated values do not encode usefully
    /// through the synthesised conformance and a cache is a file format -- it has
    /// to keep working when the enum gains a case.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(String.self, forKey: .id)
        let at = try container.decode(Date.self, forKey: .at)
        switch try container.decode(String.self, forKey: .kind) {
        case "assistant":
            self = .message(
                id: id,
                role: .assistant,
                text: try container.decode(String.self, forKey: .text),
                at: at,
            )
        case "system":
            self = .message(
                id: id,
                role: .system,
                text: try container.decode(String.self, forKey: .text),
                at: at,
            )
        case "failure":
            self = .failure(
                id: id,
                message: try container.decode(String.self, forKey: .message),
                at: at,
            )
        case "notice":
            self = .notice(
                id: id,
                text: try container.decode(String.self, forKey: .text),
                at: at,
            )
        default:
            self = .message(
                id: id,
                role: .user,
                text: try container.decode(String.self, forKey: .text),
                at: at,
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        switch self {
        case .message(let id, let role, let text, let at):
            try container.encode(id, forKey: .id)
            try container.encode(text, forKey: .text)
            try container.encode(at, forKey: .at)
            switch role {
            case .user: try container.encode("user", forKey: .kind)
            case .assistant: try container.encode("assistant", forKey: .kind)
            case .system: try container.encode("system", forKey: .kind)
            }
        case .failure(let id, let message, let at):
            try container.encode(id, forKey: .id)
            try container.encode("failure", forKey: .kind)
            try container.encode(message, forKey: .message)
            try container.encode(at, forKey: .at)
        case .notice(let id, let text, let at):
            try container.encode(id, forKey: .id)
            try container.encode("notice", forKey: .kind)
            try container.encode(text, forKey: .text)
            try container.encode(at, forKey: .at)
        }
    }
}

/// The real cache: one JSON file per session.
public actor FileConversationCache: ConversationCache {
    private let directory: URL

    /// - Parameter directory: where to keep the files. Defaults to Application
    ///   Support, which is backed up and not visible to the Files app -- a
    ///   conversation is the operator's data but not a document they manage.
    public init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.directory = base.appendingPathComponent("MizarConversations", isDirectory: true)
        }
    }

    private func url(for sessionId: String) -> URL {
        // The session id is a UUID from the host, but it arrives over the wire
        // and a path built from unvalidated input is how a cache becomes a
        // directory traversal. Anything outside a conservative set is escaped.
        let safe = sessionId.replacingOccurrences(
            of: "[^A-Za-z0-9._-]",
            with: "_",
            options: .regularExpression,
        )
        return directory.appendingPathComponent("\(safe).json")
    }

    public func load(sessionId: String) async -> CachedConversation? {
        read(sessionId: sessionId)
    }

    public func save(_ conversation: CachedConversation) async {
        write(conversation)
    }

    public func update(
        sessionId: String,
        _ transform: @Sendable (CachedConversation?) -> CachedConversation,
    ) async -> CachedConversation {
        // Synchronous from here to the return, so no other updater can interleave
        // between the read and the write. `read` and `write` are both synchronous
        // for exactly this reason; an `await` anywhere between them would put the
        // race back.
        let cached = read(sessionId: sessionId)
        let next = transform(cached)
        // A refresh that read a page the phone already had changes no byte, and
        // rewriting a whole conversation to say so is the cost a background
        // refresh cannot afford: the encode and the atomic write happen inside one
        // call, at the moment the system is asking for the background task back,
        // and cancellation cannot reach into them. What the caller asked for is
        // already on disk, so the answer is `next` either way -- only the write is
        // gone.
        if next != cached { write(next) }
        return next
    }

    /// Read one session from disk, synchronously.
    /// - Parameter sessionId: the session.
    /// - Returns: what is stored, or `nil`.
    private func read(sessionId: String) -> CachedConversation? {
        guard let data = try? Data(contentsOf: url(for: sessionId)) else { return nil }
        return try? JSONDecoder().decode(CachedConversation.self, from: data)
    }

    /// Write one session to disk, synchronously.
    /// - Parameter conversation: what to store.
    private func write(_ conversation: CachedConversation) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(conversation)
            // Written atomically: a cache that is half-written reads as absent,
            // and absent means the conversation looks lost, which is the thing
            // this file exists to prevent.
            try data.write(to: url(for: conversation.sessionId), options: .atomic)
        } catch {
            // A cache that cannot be written is a cache that does not exist, not
            // a failure the operator should see. The conversation still works.
        }
    }

    public func remove(sessionId: String) async {
        try? FileManager.default.removeItem(at: url(for: sessionId))
    }

    public func clear() async {
        try? FileManager.default.removeItem(at: directory)
    }

    public func count() async -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path).count) ?? 0
    }
}

/// Fold a freshly fetched page into what is already known.
///
/// By id, not by concatenation: the page and the cache overlap on every refresh,
/// and appending one to the other duplicates every message they share. Sorting
/// by time keeps a page that arrives out of order readable.
///
/// Here rather than in the app because it is the rule that decides what a
/// conversation *is*, and a rule that decides is worth being able to test
/// without a screen.
///
/// - Parameters:
///   - cached: what the phone already had.
///   - fresh: what the host just sent.
/// - Returns: the union, oldest first.
public func mergeConversations(
    cached: [ConversationItem],
    fresh: [ConversationItem],
) -> [ConversationItem] {
    var byId: [String: ConversationItem] = [:]
    for item in cached { byId[item.id] = item }
    // Fresh wins on a collision: it is the host's current answer.
    for item in fresh { byId[item.id] = item }
    // Ordered by time and then by log position, which is a total order. The
    // values come back from a dictionary in no particular order, so a comparison
    // that leaves ties -- and sorting on the timestamp alone left one for every
    // run of records written in the same millisecond -- let unrelated messages
    // swap places between one load and the next.
    return byId.values.sorted(by: ConversationItem.precedes)
}

/// Fold a fresh page of turns into what is already stored.
///
/// By turn number, the same way items are merged and for the same reason:
/// consecutive pages overlap, and appending one to the other duplicates the
/// turns they share.
///
/// **Merged, not replaced.** "Fresh wins" is the obvious rule and it is wrong,
/// in both directions at once:
///
///   - A page fetched with `beforeSeq` is *older* than what is stored, and the
///     caller passes it as `fresh` -- so the older copy of a turn straddling the
///     page boundary used to replace the newer one, and the turn flipped back to
///     "still running" every time the operator scrolled up.
///   - A page is a *window*: the host trims it to the newest few hundred
///     messages, so the turn crossing the window's oldest edge arrives without
///     the prompt that began it. Replacing the stored copy with that one deleted
///     the operator's own message from the conversation -- permanently, because
///     the view draws turns and the turn no longer held the prompt.
///
/// So the turn is unioned by item id, and the end is kept if either copy has one.
/// An end is durable and append-only, which makes that safe in the only
/// direction that matters: a turn that has ended cannot be un-ended by a later
/// read, whichever page it came from.
///
/// One case is neither a turn nor a copy: a `turn/end` that arrived alone,
/// because the page window began between the turn's last record and its ending.
/// It is joined to the copy the phone holds -- which is how a turn that was
/// running when the phone last looked gets its ending -- and dropped when there
/// is no copy, because a row with no prompt and no answer is not a turn the
/// operator can read.
///
/// - Parameters:
///   - cached: turns the phone already had.
///   - fresh: turns from the page just fetched, older or newer than `cached`.
/// - Returns: the union, oldest first.
public func mergeTurns(
    cached: [ConversationTurn],
    fresh: [ConversationTurn],
) -> [ConversationTurn] {
    var byId: [String: ConversationTurn] = [:]
    for turn in cached { byId[turn.id] = turn }
    for turn in fresh {
        if let known = byId[turn.id] {
            byId[turn.id] = turn.merging(known)
            continue
        }
        // A page-edge ending for a turn this phone does not hold *under that
        // number*. There is one place it can still belong: a chain of
        // continuations keeps its first number as identity, so an ending that
        // names the chain's last continuation arrives under a number no entry
        // has. ``ConversationTurn/lastTurn`` is the other end of that chain.
        if turn.isEndOnly,
           let id = byId.first(where: { $0.value.lastTurn == turn.turn })?.key,
           let known = byId[id] {
            // `known` first: the ending is what the other copy brings, but the
            // identity and the prompt are the chain's and must stay so.
            byId[id] = known.merging(turn)
            continue
        }
        // Nothing to end, and drawing it would be a row with no prompt and no
        // answer: see ``ConversationTurn/isEndOnly``.
        if !turn.isEndOnly { byId[turn.id] = turn }
    }
    // Ordered by where each turn sits in the log, not by its number. A turn can
    // arrive without one -- see `reclaimStrandedPrompts` -- and ordering by
    // number put those at the end of the conversation regardless of when they
    // happened.
    return collapseContinuations(
        in: reclaimStrandedPrompts(in: byId.values.sorted(by: ConversationTurn.precedes)),
    )
}

/// A turn this phone still holds as running, though a later turn exists.
///
/// The agent's turn model is serial: a turn ends before the next one begins, and
/// the log says so -- over every session log measured on this machine, no
/// `turn/start` is followed by another `turn/start` before its `turn/end`. So a
/// running turn with a finished turn after it is not a state the **agent** can be
/// in. What produces it is a copy of the log missing the `turn/end` that ended the
/// turn -- almost always this phone's, because its reads are incremental and a
/// page can step over records; a host that died mid-turn could leave the record
/// out of the log too, and the answer below is the same either way. The shape on
/// screen was the reported one: a row still counting "深度求索中" above rows that
/// say "已完成".
///
/// The missing record cannot be re-asked for by position alone -- the read that
/// skipped it did not know it had skipped anything -- so the repair is a page of
/// older records, the same `beforeSeq` paging the operator's scroll-up uses.
/// ``beforeSeq`` is where that page must stop: the earliest log position of any
/// turn after this one, which is the exclusive upper bound of the range the
/// missing end lives in. `nil` means no later turn named a position, and
/// nothing can be asked for.
public struct StaleRunningTurn: Sendable, Equatable {
    /// The turn that cannot still be running.
    public let turn: ConversationTurn
    /// The exclusive upper bound for the page holding the missing `turn/end`.
    public let beforeSeq: Int?

    public init(turn: ConversationTurn, beforeSeq: Int?) {
        self.turn = turn
        self.beforeSeq = beforeSeq
    }
}

/// The first turn the merge left running although a later turn exists.
///
/// A postcondition of ``mergeTurns(cached:fresh:)``, not a second reading of the
/// records: the agent cannot start a turn before the one before it ends, so any
/// held shape that says otherwise is a phone missing a record. See
/// ``StaleRunningTurn`` for what that costs and how the page is asked for.
///
/// Later is decided by turn number, not by array position. A continuation is
/// folded into the turn it continued and keeps that turn's number, so numbers
/// stay monotonic across the fold; positions do not, because a turn whose
/// `firstSeq` was never stored sorts by its items, and an item-less turn sorts
/// last regardless of when it happened.
///
/// - Parameter turns: merged turns, oldest first.
/// - Returns: the first stale run, or `nil` when the turns are serial.
public func staleRunningTurn(in turns: [ConversationTurn]) -> StaleRunningTurn? {
    for turn in turns where turn.isRunning {
        guard staleTurnIsSuperseded(turn, in: turns) else { continue }
        let beforeSeq = turns
            .filter { ($0.turn ?? .min) > (turn.turn ?? .max) }
            .compactMap(\.orderSeq)
            .min()
        return StaleRunningTurn(turn: turn, beforeSeq: beforeSeq)
    }
    return nil
}

/// Settle every turn a later turn proves has ended.
///
/// The display-side half of ``staleRunningTurn(in:)``, and the last resort when
/// the missing record cannot be fetched: a turn that is not the newest cannot be
/// running, so it is drawn as **ended** (``ConversationTurn/isEndInferred``) at
/// the instant the next turn began -- the latest it could have ended. No reason
/// is written and no duration is reported as measured, because the log never
/// said either. "Ended, and the record of how is missing" is true; "still
/// running" is not, and "completed" would be a claim the phone cannot make.
///
/// Idempotent, and it never touches the newest turn: that one may genuinely be
/// running, and is the one row the screen must keep counting.
///
/// - Parameter turns: merged turns, oldest first.
/// - Returns: the same turns, with every stale run settled.
public func settlingStaleRuns(in turns: [ConversationTurn]) -> [ConversationTurn] {
    var out = turns
    var settled = false
    for index in turns.indices where turns[index].isRunning {
        guard let next = nextTurn(after: turns[index], in: turns) else { continue }
        // The next turn by *number* bounds the ending. Only when it has no start
        // to give does the turn's own last known instant stand in -- never an
        // unrelated neighbour's, which array order can put on either side of a
        // turn whose position was not stored.
        let end = next.beganAt
            ?? turns[index].items.map(\.at).max()
            ?? turns[index].beganAt
            ?? Date(timeIntervalSince1970: 0)
        out[index] = turns[index].settling(at: end)
        settled = true
    }
    return settled ? out : turns
}

/// Whether a turn with a greater number is among these turns.
///
/// - Parameters:
///   - turn: the running turn.
///   - turns: merged turns, oldest first.
/// - Returns: whether a recorded turn came after it.
private func staleTurnIsSuperseded(_ turn: ConversationTurn, in turns: [ConversationTurn]) -> Bool {
    nextTurn(after: turn, in: turns) != nil
}

/// The next recorded turn after this one, by turn number.
///
/// - Parameters:
///   - turn: the turn to look past.
///   - turns: merged turns, oldest first.
/// - Returns: the lowest-numbered turn with a greater number, or `nil`.
private func nextTurn(
    after turn: ConversationTurn,
    in turns: [ConversationTurn],
) -> ConversationTurn? {
    guard let number = turn.turn else { return nil }
    return turns
        .filter { ($0.turn ?? .min) > number }
        .min { ($0.turn ?? .max) < ($1.turn ?? .max) }
}

/// Fold the turns an agent continued on its own back into the turn they continued.
///
/// DSH does not emit one turn per prompt. Measured on a real session, the log
/// holds long runs of consecutive `turn/start` with **no `user/message` between
/// them at all** -- turn 2 into 3 into 4 into 5, and later 29 into 30 into 31
/// into 32. The agent kept working after the turn that answered the prompt had
/// ended, which is what it does when there is more to do.
///
/// The screen drew every one of those as its own "已完成" bar, so a single
/// instruction came back as two or three finished turns stacked under one
/// message: the reported "one turn split into two". A turn with no prompt is not
/// a turn the operator asked for -- it is the previous one still going -- so it
/// is absorbed into the turn above it.
///
/// - Parameter turns: merged turns, oldest first.
/// - Returns: the same turns, with continuations folded in.
public func collapseContinuations(in turns: [ConversationTurn]) -> [ConversationTurn] {
    var out: [ConversationTurn] = []
    for turn in turns {
        if turn.prompts.isEmpty, let previous = out.last, !previous.prompts.isEmpty {
            out[out.count - 1] = previous.absorbing(turn)
            continue
        }
        out.append(turn)
    }
    return out
}

/// Give a page-edge prompt back to the turn it started.
///
/// A page can end in the gap between a prompt and the turn that prompt opens.
/// Measured on a real session: `turn/start` for turn 78 is at seq 9625 and the
/// prompt that began it at seq 9628, so a page cut at 9629 holds the prompt and
/// nothing that claims it. That prompt then formed its own group, which sorted
/// to the end -- a message sent at 09:57 drawn underneath one sent at 12:01.
///
/// Two cures, because the prompt can arrive on either side of its turn:
///
///   - a group that has prompts and no number belongs to the **next** turn, when
///     that turn is positioned after it and came out of its own page without a
///     prompt -- the turn's envelope is in the older page, the prompt in the
///     newer one;
///   - and it belongs to the **previous** turn when that turn is still open (no
///     `turn/end`) and sits before it. That is the shape the host actually
///     writes -- `turn/start` first, the prompt a couple of records later, both
///     inside the same turn -- so when the two arrive from different reads the
///     turn is above the prompt, not below it. Measured on the live wire:
///     `turn/start` at seq 803, `step/start` at 805, the prompt at 806, with the
///     turn still running. Without this the prompt stayed a group of its own and
///     the running turn lost the row the operator opens the app to read.
///
/// A prompt is identified by the log position it came from, so a record another
/// turn already carries is the same prompt read twice: the cache and the page
/// overlap on every refresh, and a build that grouped a running turn's prompt
/// into a group of its own left one of those groups behind for every turn that
/// was executing when the phone last looked. Drawing it twice is a message the
/// operator never sent twice, so the duplicate is dropped rather than merged.
///
/// - Parameter turns: merged turns, oldest first.
/// - Returns: the same turns, with page-edge prompts reattached.
public func reclaimStrandedPrompts(in turns: [ConversationTurn]) -> [ConversationTurn] {
    // Prompts a numbered turn already carries.
    let carried = Set(turns.filter { $0.turn != nil }.flatMap { $0.prompts.map(\.id) })
    // Every group that still holds something no turn has.
    let groups = turns.compactMap { turn -> ConversationTurn? in
        guard turn.turn == nil, !turn.prompts.isEmpty else { return turn }
        let unclaimed = turn.prompts.filter { !carried.contains($0.id) }
        guard !unclaimed.isEmpty else { return nil }
        return ConversationTurn(
            turn: nil,
            prompts: unclaimed,
            steps: turn.steps,
            stepCount: turn.stepCount,
            startedAt: turn.startedAt,
            endedAt: turn.endedAt,
            endedReason: turn.endedReason,
            firstSeq: turn.firstSeq,
            endInferred: turn.endInferred,
            lastTurn: turn.lastTurn,
        )
    }

    var out: [ConversationTurn] = []
    var held: ConversationTurn?
    for turn in groups {
        if turn.turn == nil, !turn.prompts.isEmpty {
            // The turn above it, still open: the prompt was written inside it.
            if let open = out.last, open.turn != nil, open.endedAt == nil,
               positioned(turn, atOrAfter: open) {
                out[out.count - 1] = open.prepending(prompts: turn.prompts)
                continue
            }
            // Two unnumbered prompt groups in a row: the first is genuinely on
            // its own, so it is released rather than held indefinitely.
            if let previous = held { out.append(previous) }
            held = turn
            continue
        }
        guard let previous = held else {
            out.append(turn)
            continue
        }
        held = nil
        let followsIt = previous.orderSeq.flatMap { before in
            turn.orderSeq.map { before < $0 }
        } ?? false
        if turn.prompts.isEmpty, followsIt {
            out.append(turn.prepending(prompts: previous.prompts))
        } else {
            out.append(previous)
            out.append(turn)
        }
    }
    if let held { out.append(held) }
    return out
}

/// Whether a group's known log position is at or after a turn's.
///
/// Unknown positions do not block it. A turn and the prompt that began it
/// frequently arrive one from the cache and one from the page, so one of the two
/// is often a copy written before positions were kept at all -- and a turn that
/// has not ended is the best evidence there is about where a prompt written
/// after it belongs.
///
/// - Parameters:
///   - group: the prompt group.
///   - turn: the turn being considered for it.
/// - Returns: whether the group can belong to that turn.
private func positioned(_ group: ConversationTurn, atOrAfter turn: ConversationTurn) -> Bool {
    guard let groupSeq = group.orderSeq, let turnSeq = turn.orderSeq else { return true }
    return turnSeq <= groupSeq
}

/// A cache that keeps nothing.
///
/// For tests and previews. Explicitly not a fallback: silently keeping
/// conversations in memory would look like caching worked and lose them on the
/// next launch.
public actor InMemoryConversationCache: ConversationCache {
    private var store: [String: CachedConversation] = [:]

    public init() {}

    public func load(sessionId: String) async -> CachedConversation? { store[sessionId] }
    public func save(_ conversation: CachedConversation) async { store[conversation.sessionId] = conversation }
    @discardableResult
    public func update(
        sessionId: String,
        _ transform: @Sendable (CachedConversation?) -> CachedConversation,
    ) async -> CachedConversation {
        let next = transform(store[sessionId])
        store[sessionId] = next
        return next
    }
    public func remove(sessionId: String) async { store[sessionId] = nil }
    public func clear() async { store.removeAll() }
    public func count() async -> Int { store.count }
}
