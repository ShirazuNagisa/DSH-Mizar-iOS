//
//  LiveActivity.swift
//  MizarKit
//
//  What the Live Activity shows, decided without a screen, a clock, or
//  ActivityKit.
//
//  The activity is drawn in another process. The widget extension is handed the
//  activity's `ContentState` and nothing else -- no model, no connection, no
//  cache -- so everything the two processes have to agree on is a value: the
//  rows, the elapsed times, and whether the activity should still be up at all.
//  That is this file, and it is why every type here is `Codable` and `Sendable`.
//
//  The clock belongs to the operator's arrangement rather than to the host: the
//  island counts the elapsed time of the session that has been running longest,
//  seeded from the last figure the app read off the host -- the
//  "深度求索中，用时 xx 分 xx 秒" of the running turn's own row -- and then
//  ticked by whoever is drawing it. **Nothing re-syncs it.** A clock that asked
//  the computer for the time every second would stop telling the time whenever the
//  link hiccuped, which on a phone is constant; the running row in the app
//  already makes that argument for itself.
//
//  Nothing here reads the clock either. `now` is a parameter to every function
//  that needs one, which is what lets the whole thing be tested at instants the
//  test chooses.
//
//  The title row the expanded card draws -- the app icon and the literal
//  "DSH-Mizar" -- is not here on purpose. It is the same on every activity this
//  app will ever post, so it is a fact about the widget rather than about any
//  session, and state that never varies is state that can only go stale.
//

import Foundation

/// One session that is running, as the app last saw it.
///
/// The app builds one of these per running turn in its conversation cache: the
/// instruction is that turn's most recent prompt, the title is what the host
/// calls the session when it has got round to naming it, and the two clock
/// fields are the figure the host last gave for the turn and the moment it
/// arrived.
public struct RunningSession: Codable, Sendable, Equatable, Identifiable {
    /// The session.
    ///
    /// Opaque here, and it becomes a row's identity: the widget keys its rows on
    /// it, so it has to be the same string every time the same session is
    /// passed.
    public let id: String
    /// The operator's most recent instruction to that session, whole.
    ///
    /// Cut to size when a row is built; see
    /// ``LiveActivityDecision/promptSnippetLength``.
    public let prompt: String
    /// What the host calls the session, when it has named it.
    ///
    /// A title exists only once the model has produced one, so `nil` is the
    /// ordinary case rather than a failure: a session that has not run yet has
    /// no title, and neither does one whose usage frame has not been read. The
    /// row then falls back to the operator's own instruction.
    public let title: String?
    /// How long the session had been running when the app last read the host.
    ///
    /// The figure behind "深度求索中，用时 xx 分 xx 秒", and the only measurement
    /// this clock ever gets. Not optional: a row on a card has to say something,
    /// so a session whose figure never arrived is seeded with zero and counts
    /// from the moment the app saw it.
    public let elapsedWhenSeeded: TimeInterval
    /// When that figure was read.
    public let seededAt: Date

    /// - Parameters:
    ///   - id: the session.
    ///   - prompt: the operator's most recent instruction to it.
    ///   - title: what the host calls it, when it has named it.
    ///   - elapsedWhenSeeded: how long it had been running at `seededAt`.
    ///   - seededAt: when that figure was read.
    public init(
        id: String,
        prompt: String,
        title: String? = nil,
        elapsedWhenSeeded: TimeInterval,
        seededAt: Date,
    ) {
        self.id = id
        self.prompt = prompt
        self.title = title
        self.elapsedWhenSeeded = elapsedWhenSeeded
        self.seededAt = seededAt
    }

    /// The instant this session's clock counts from.
    ///
    /// The host's figure and the moment it arrived say the same thing as an
    /// instant -- a session the host said had been running two minutes when the
    /// app read it at 10:00 began at 09:58 -- and the instant is what the
    /// ticking and the ordering both use.
    ///
    /// **Never after ``seededAt``.** The figure is measured against the host's
    /// clock and ``seededAt`` is the phone's, so a computer whose clock is ahead
    /// answers with a start the phone has not reached. Subtracting that would
    /// put the start in the future: the widget's `Text(_:style:.timer)` has no
    /// time to count *up* to, and the row would sort ahead of sessions that
    /// really began earlier. The phone cannot know how long work it never saw
    /// begin has been running; the honest start is the moment it read the
    /// figure.
    public var countingSince: Date {
        seededAt.addingTimeInterval(-max(0, elapsedWhenSeeded))
    }

    /// How long the session has been running at `now`.
    ///
    /// Clamped at zero: the figure is the host's and the clock is the phone's,
    /// and the two can disagree about an instant in the near future. A row
    /// reading "-2 s" would be worse than one reading "0 s".
    ///
    /// - Parameter now: the instant to measure to.
    /// - Returns: the elapsed time.
    public func elapsed(asOf now: Date) -> TimeInterval {
        max(0, now.timeIntervalSince(countingSince))
    }
}

extension RunningSession {
    /// The running sessions the island draws, from the session list and the
    /// phone's own cache.
    ///
    /// The one reading of "what is running", shared by the foreground refresh
    /// and the background one. It was the app's private method until the
    /// background sync needed the same answer: two readings of the same two
    /// sources are two readings that can disagree about which row is on the
    /// card, and the difference would only ever show up on a phone in a pocket.
    ///
    /// One per session whose row says it is running, with the operator's most
    /// recent instruction to it, its title when the host has named it, and the
    /// figure the running turn's own row is drawn from --
    /// `ConversationTurn.elapsed(asOf:)`, which is the clock behind
    /// "深度求索中，用时 xx 分 xx 秒".
    ///
    /// Two deliberate omissions, both of them things the app cannot answer:
    ///
    ///   - **Subagents are left out.** Their rows say `running` too, but the app
    ///     never syncs a subagent's conversation (`syncAllConversations` fetches
    ///     top-level sessions only), so a subagent has no prompt and no start
    ///     time here. It would arrive on the island as a row reading "0:03" for
    ///     work that has been going for ten minutes, and -- because the decision
    ///     layer keeps the two longest-running rows -- it could push the session
    ///     the operator is actually watching off the card. The test is
    ///     ``SessionRow/isLiveActivityCandidate``, the same one the background
    ///     refresh picks its reads with, and it keys on the host's `origin`
    ///     alone: a forked conversation carries a parent without that origin and
    ///     is a top-level session, so it belongs on the island like any other.
    ///   - **A session with nothing cached is seeded at zero.** The row says it is
    ///     running and the phone has not fetched its page yet, so there is no
    ///     figure to seed from; `RunningSession` says what to do about that, and
    ///     counting from the moment the app saw it is that answer.
    ///
    /// - Parameters:
    ///   - sessions: the session list as the host last gave it.
    ///   - conversations: the cache the prompts are read from.
    ///   - titles: the app's title list, keyed by session id. The list itself
    ///     does not carry titles -- they arrive with the usage frame -- so this
    ///     is the one place the two are joined. A session with no entry keeps
    ///     `nil` and the row falls back to its instruction.
    ///   - now: the instant the figures are measured to, and the instant they are
    ///     seeded from.
    /// - Returns: the sessions to hand to the decision layer, in the list's order.
    public static func running(
        in sessions: [SessionRow],
        conversations: any ConversationCache,
        titles: [String: String],
        now: Date,
    ) async -> [RunningSession] {
        var out: [RunningSession] = []
        for row in sessions where row.isLiveActivityCandidate {
            let cached = await conversations.load(sessionId: row.sessionId)
            // Settled first: a cache can hold a run a later turn has disproved,
            // and a card started from that would name the wrong turn's prompt
            // and count from the wrong start. The screen applies the same rule
            // before drawing, so card and screen agree about what is running.
            let turns = settlingStaleRuns(in: cached?.turns ?? [])
            let turn = turns.last { $0.isRunning }
            out.append(
                RunningSession(
                    id: row.sessionId,
                    prompt: prompt(of: turn, in: cached) ?? "",
                    title: titles[row.sessionId],
                    elapsedWhenSeeded: turn?.elapsed(asOf: now) ?? 0,
                    seededAt: now,
                ),
            )
        }
        return out
    }

    /// The operator's most recent instruction to a session.
    ///
    /// The running turn's last prompt, and when the cache holds no running turn
    /// -- a session that started since the last sync, whose `turn/start` is in a
    /// page the phone has not fetched -- the last thing the operator said in the
    /// conversation the phone does have. Both are their own words; nothing here
    /// makes one up. `nil` when the cache holds neither, and the row then draws a
    /// time and nothing else, which is true.
    ///
    /// - Parameters:
    ///   - turn: the running turn, when the cache has one.
    ///   - cached: the cached conversation.
    /// - Returns: the instruction, or `nil`.
    private static func prompt(of turn: ConversationTurn?, in cached: CachedConversation?) -> String? {
        if let asked = turn?.prompts.last?.words { return asked }
        return cached?.items.last { $0.role == .user }?.words
    }
}

extension SessionRow {
    /// Whether the island has anything to draw for this row.
    ///
    /// Running, and not a delegated child. The host's `origin` is the marker --
    /// a forked conversation has a parent but no subagent origin, and it is a
    /// top-level conversation the app syncs, so its clock belongs on the island.
    /// The app has never synced a subagent's page, which is what makes a row for
    /// one a clock started at zero rather than the work it is doing.
    var isLiveActivityCandidate: Bool { running && !isSubagent }
}

extension ConversationItem {
    /// The words of a message, and nothing for anything that is not one.
    var words: String? {
        if case .message(_, _, let text, _) = self { return text }
        return nil
    }

    /// Who said it, for the one question this file asks of the flat item list.
    var role: Role? {
        if case .message(_, let role, _, _) = self { return role }
        return nil
    }
}

/// One running session as a row of the expanded activity.
///
/// Both the elapsed time and the instant it counts from are carried, rather
/// than only one of them: the number is what the row reads at the moment the
/// app made it, and the instant is what the widget's own ticking text counts
/// from, so a second can pass on the lock screen without the app being asked
/// for anything.
/// `Hashable` as well as `Equatable`, and not for the widget's own use:
/// `ActivityAttributes.ContentState` is required to be `Hashable`, so the state
/// an activity carries has to be. The row is a value with no reference in it, so
/// this is a conformance the compiler writes and nothing here has to maintain.
public struct LiveActivityRow: Codable, Sendable, Hashable, Identifiable {
    /// The session this row is about.
    public let id: String
    /// The operator's instruction, already cut short.
    ///
    /// Still carried, and still cut, because it is what the row says when the
    /// host has not named the session: an unnamed row with no instruction is a
    /// clock about nothing.
    public let prompt: String
    /// The host's title for the session, when it has one.
    ///
    /// Optional, and optional on the wire as well: an activity posted by an
    /// older build carries no `title` key, and the system hands that stored
    /// state to the new widget. A required field would make the old row fail to
    /// decode and the card draw nothing.
    public let title: String?
    /// How long the session had been running when the row was built.
    public let elapsed: TimeInterval
    /// The instant ``elapsed`` was measured from.
    public let countingSince: Date

    /// - Parameters:
    ///   - id: the session.
    ///   - prompt: the instruction, cut short for the row.
    ///   - title: the host's title for the session, when it has one.
    ///   - elapsed: how long it has been running.
    ///   - countingSince: the instant that count started at.
    public init(
        id: String,
        prompt: String,
        title: String? = nil,
        elapsed: TimeInterval,
        countingSince: Date,
    ) {
        self.id = id
        self.prompt = prompt
        self.title = title
        self.elapsed = elapsed
        self.countingSince = countingSince
    }

    /// What the left side of the row says.
    ///
    /// The host's title first, because it is the name the operator gave the
    /// conversation and the one the session list already draws. A session the
    /// host has not named -- or one whose "title" is only space, which is what a
    /// projection mid-composition answers with -- falls back to the operator's
    /// own instruction, already cut. The title is not cut by
    /// ``LiveActivityDecision/promptSnippetLength``: that number is about a
    /// prompt on a lock-screen row, and a session's name is a name.
    public var displayTitle: String {
        if let title {
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return prompt
    }
}

/// What the activity is showing.
///
/// This is the value an activity's `ContentState` holds. The widget draws it and
/// decides nothing: whether it has rows is the difference between a clock and a
/// green check.
///
/// **A struct, and that is a wire decision.** This type is also what a push
/// notification carries as `content-state`, and Apple's rule for that field is
/// that its keys are the properties of the state type. It used to be an enum
/// with associated values, which encodes as `{"finished":{}}` or
/// `{"running":{"rows":[…]}}` -- a shape APNs accepts (every required key is
/// there) and the device then has nowhere to put, because there is no property
/// named `finished` or `running` for the keys to land on.
///
/// Measured on a real phone, 2026-10-26: three end pushes were delivered to the
/// same card over twelve minutes, the card kept counting, and the token was
/// never retired -- which is what a state the card cannot decode looks like
/// from outside. The rows are now a property, so the payload is
/// `{"rows":[…]}` and there is nothing left to invent.
public struct LiveActivityState: Codable, Sendable, Hashable {
    /// The rows to draw, longest-running first: one or two, and none when
    /// nothing is running.
    public var rows: [LiveActivityRow]
    /// The approvals waiting on the operator, oldest first.
    ///
    /// Additive on the wire: a card posted by a computer that has no approvals
    /// to report carries no `approvals` key at all, and the decoder supplies an
    /// empty list rather than failing the whole card. That tolerance is what
    /// lets the desktop start pushing these without a lockstep app release.
    public var approvals: [LiveActivityApproval]

    /// - Parameters:
    ///   - rows: the rows to draw; empty means nothing is running.
    ///   - approvals: the pending approvals to draw beside them.
    public init(rows: [LiveActivityRow] = [], approvals: [LiveActivityApproval] = []) {
        self.rows = rows
        self.approvals = approvals
    }

    private enum CodingKeys: String, CodingKey {
        case rows, approvals
    }

    /// Decode, tolerating a state from a computer that predates `approvals`.
    ///
    /// Synthesised conformance would require the key the moment the property
    /// exists, which would turn every card posted by an older host into a decode
    /// failure -- and a Live Activity that cannot decode its `content-state` is a
    /// card that draws nothing, with a 200 from Apple and no error anywhere.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rows = try container.decodeIfPresent([LiveActivityRow].self, forKey: .rows) ?? []
        approvals = try container.decodeIfPresent([LiveActivityApproval].self, forKey: .approvals) ?? []
    }

    /// Whether nothing is running and nothing is waiting, so nothing is counting.
    ///
    /// An approval alone keeps the card up: the operator has to be able to answer
    /// it, and a card that vanished because the turn is blocked rather than
    /// running is exactly the case this exists for.
    public var isFinished: Bool { rows.isEmpty && approvals.isEmpty }

    /// The time on the island's right side: the clock of the session that has
    /// been running longest, which is the first row's.
    ///
    /// Derived rather than stored, and `nil` once nothing is running. A second
    /// copy of a number is a second number that can disagree with the first.
    public var headline: TimeInterval? { rows.first?.elapsed }
}

/// One approval the card draws and the operator may answer from the island.
///
/// The id is the host's own `requestId`, passed through untouched: an answer
/// names it, and an id this app rewrote would answer nothing.
public struct LiveActivityApproval: Codable, Sendable, Hashable, Identifiable {
    /// The host's request id.
    public let requestId: String
    /// The session the turn belongs to, for the row it is about.
    public let sessionId: String
    /// The tool asking, e.g. `Bash`.
    public let tool: String
    /// The sentence the agent wrote about it.
    public let detail: String

    public var id: String { requestId }

    /// - Parameters:
    ///   - requestId: the host's request id.
    ///   - sessionId: the session the turn belongs to.
    ///   - tool: the tool asking.
    ///   - detail: the sentence the agent wrote.
    public init(requestId: String, sessionId: String, tool: String, detail: String) {
        self.requestId = requestId
        self.sessionId = sessionId
        self.tool = tool
        self.detail = detail
    }

    /// What the island says above the buttons.
    ///
    /// Both lines travel because the tool name is what the operator recognises
    /// and the detail is what they are deciding about; a card that showed only
    /// one of them is either a name with no context or a wall of text.
    public var headline: String {
        let name = tool.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Permission" : name
    }
}

/// What the activity should be showing, and whether it should still be up.
///
/// The contract the app is expected to keep, in full:
///
/// - ``phase`` `.running` means start an activity if there is none, and update
///   the one there is otherwise.
/// - ``phase`` `.finished` means nothing is running, so the activity comes down:
///   the app ends it with this state instead of leaving a check standing. No
///   activity may be *started* from it either -- a check for work that stopped
///   before the activity existed is not worth a second look.
/// - ``shouldDismiss`` means an activity that is still up must end now, because
///   the operator has been back in the app since the last finish. It is the
///   app-opened half of the same rule: `.finished` ends a card the app sees
///   finish, and this covers a card that outlived what the app knows.
public struct LiveActivityDecision: Codable, Sendable, Equatable {
    /// What to draw.
    public let phase: LiveActivityState
    /// Whether the activity should be ended.
    public let shouldDismiss: Bool

    /// - Parameters:
    ///   - phase: what to draw.
    ///   - shouldDismiss: whether to end the activity.
    public init(phase: LiveActivityState, shouldDismiss: Bool) {
        self.phase = phase
        self.shouldDismiss = shouldDismiss
    }

    /// How many rows the expanded activity shows.
    ///
    /// Two, and no more, however many sessions are running. They are the two
    /// that have been running longest, because that is where the attention is:
    /// the operator wants to know about the work that is taking a while.
    public static let maximumRows = 2

    /// How many approvals the expanded activity shows.
    ///
    /// Two, for the same reason the rows are two: a card with three questions on
    /// it is a card the operator reads twice and answers once.
    public static let maximumApprovals = 2

    /// How much of an instruction a row shows before it is cut short.
    ///
    /// Deliberately tiny. The rows are the identity of two sessions on a
    /// lock-screen card, and the width they have is a card's: an instruction
    /// long enough to read as a sentence wraps, and two wrapped rows push the
    /// clock off the card. A few characters are enough to tell "fix the parser"
    /// from "run the tests", which is all a row has to do.
    public static let promptSnippetLength = 8

    /// Read the running sessions and say what the activity should show.
    ///
    /// The whole state machine, and the only thing the app has to call: once
    /// when a session starts or ends, once when the app comes to the foreground,
    /// and once whenever it is about to touch the activity.
    ///
    /// The preference on the settings screen is not an input. Whether an
    /// activity may run at all is the app's question, asked before this one;
    /// this function answers what an activity would show if there were one.
    ///
    /// - Parameters:
    ///   - sessions: the paired sessions that are running right now, in any
    ///     order. A session that is not running is not passed: an activity has
    ///     nothing to say about one.
    ///   - appOpenedSinceLastFinish: whether the operator has opened the app
    ///     since the last running session ended, **and the activity has not been
    ///     taken down for it yet**. The app owns this flag -- set when it comes
    ///     to the foreground, cleared when it acts on a dismissal -- and the
    ///     clearing is what makes the dismissal happen once. Left set, it would
    ///     report the next session's finish as one the operator had already seen,
    ///     with nobody there to have seen it.
    ///   - now: the instant to measure the clocks to.
    /// - Returns: what to show, and whether to end the activity.
    public static func make(
        sessions: [RunningSession],
        approvals: [LiveActivityApproval] = [],
        appOpenedSinceLastFinish: Bool,
        now: Date,
    ) -> LiveActivityDecision {
        let rows = sessions
            .sorted(by: longestRunningFirst)
            .prefix(maximumRows)
            .map { session in
                // A clock never starts after the instant it is measured at.
                // ``RunningSession/countingSince`` already refuses a start after
                // its seed, but a session can have been seeded for an instant
                // this decision has since passed -- and the widget is another
                // process with no clock to clamp against. This is the last place
                // that knows `now`, so the invariant is enforced here as well:
                // a count-up handed a future instant has nothing to count up to.
                LiveActivityRow(
                    id: session.id,
                    prompt: snippet(session.prompt),
                    title: session.title,
                    elapsed: session.elapsed(asOf: now),
                    countingSince: min(session.countingSince, now),
                )
            }
        guard !rows.isEmpty || !approvals.isEmpty else {
            // Nothing is running and nothing is waiting: the island stops
            // counting, and the card comes down. A finished card is not left
            // standing for the app to be opened on: the app ends the activity
            // with this state as soon as it learns a session stopped -- which,
            // while the app is suspended, may be the relay's APNs end push and no
            // code of this app at all. The flag is the second, confirming half of
            // the same rule: the operator has been back since the last finish, so
            // a card still up is one whose moment has passed.
            return LiveActivityDecision(phase: LiveActivityState(), shouldDismiss: appOpenedSinceLastFinish)
        }
        // An approval with no running row is still a card: the turn is blocked
        // rather than working, and the button is the whole reason it is up.
        return LiveActivityDecision(
            phase: LiveActivityState(rows: rows, approvals: Array(approvals.prefix(maximumApprovals))),
            shouldDismiss: false,
        )
    }

    /// The session that has been running longest, first.
    ///
    /// Ordered by the instant each clock counts from rather than by the elapsed
    /// time at `now`. Every clock here advances at the same rate, so the two
    /// give the same order -- but the instant cannot move while the sessions do
    /// not, and that is the property the card needs: rows that swap places on
    /// their own are rows the operator cannot follow.
    ///
    /// Sessions that count from the very same instant fall back to their ids, so
    /// the order is a total one and two runs over the same sessions cannot
    /// disagree about it.
    private static func longestRunningFirst(_ left: RunningSession, _ right: RunningSession) -> Bool {
        if left.countingSince != right.countingSince {
            return left.countingSince < right.countingSince
        }
        return left.id < right.id
    }

    /// The first few characters of an instruction, with an ellipsis when it was
    /// cut.
    ///
    /// `prefix` counts what a reader counts -- one CJK character is one, one
    /// emoji is one -- so the cut falls on a boundary rather than inside a
    /// composed glyph.
    ///
    /// An instruction the app does not have comes back as nothing at all: a page
    /// can be cut across a turn, and a row that then says only how long is true,
    /// where the session id in the operator's place would be the app talking.
    private static func snippet(_ prompt: String) -> String {
        guard prompt.count > promptSnippetLength else { return prompt }
        return prompt.prefix(promptSnippetLength) + "…"
    }
}
