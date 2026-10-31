//
//  LiveActivityTests.swift
//  MizarKitTests
//
//  The island's clock, and the state machine that decides whether the activity
//  is counting, showing a check, or gone.
//
//  Every test here fixes `now` and moves it by hand, because that is what the
//  layer is: the elapsed time on the island, the order of the rows and the
//  moment the activity is taken down are all answers to "given this instant".
//  Nothing waits for a second to pass, so the suite is instant and cannot go
//  flaky on a loaded machine.
//

import Foundation
import Testing
@testable import MizarKit

/// A fixed instant, so no test depends on the machine's clock.
private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

/// `t0` plus some seconds.
private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

/// A running session, seeded with a figure and the instant it arrived.
private func running(
    _ id: String,
    _ prompt: String = "run the tests",
    title: String? = nil,
    seed: TimeInterval,
    at seededAt: Date,
) -> RunningSession {
    RunningSession(
        id: id,
        prompt: prompt,
        title: title,
        elapsedWhenSeeded: seed,
        seededAt: seededAt,
    )
}

/// A session-list row, as the host's `session.list` sends it.
private func sessionRow(_ id: String) -> SessionRow {
    SessionRow(
        sessionId: id,
        updatedAt: t0.timeIntervalSince1970 * 1000,
        running: true,
        blank: false,
        agentAvailable: true,
        cwd: "/Users/you/projects/\(id)",
        parentSessionId: nil,
        origin: nil,
    )
}

@Suite("A running session's clock")
struct RunningSessionTests {
    @Test("counts on from the host's figure instead of asking for another one")
    func countsOnFromTheSeed() {
        // 134 seconds is the "深度求索中，用时 2 分 14 秒" the app last read. From
        // there the clock is local: nothing asks the host for the time again,
        // which is what keeps it telling the time when the link drops.
        let session = running("s-1", seed: 134, at: t0)

        #expect(session.elapsed(asOf: t0) == 134)
        #expect(session.elapsed(asOf: at(30)) == 164)
        #expect(session.elapsed(asOf: at(3_600)) == 3_734)
        // The seed stays where the host left it. It is the clock's starting
        // point, not a running total, and nothing writes back to it.
        #expect(session.elapsedWhenSeeded == 134)
    }

    @Test("counts from the instant the host's figure implies")
    func countsFromTheImpliedInstant() {
        // A session the host said had been running two minutes when the app read
        // it at `t0` began at `t0` minus two minutes, and that one instant is
        // what the ticking and the ordering both use.
        let session = running("s-1", seed: 134, at: t0)

        #expect(session.countingSince == at(-134))
        #expect(session.elapsed(asOf: session.countingSince) == 0)
    }

    @Test("never counts below zero")
    func neverCountsBackwards() {
        // The figure is the host's, the clock is the phone's, and the two can
        // disagree about an instant in the near future. A row reading "-2 s"
        // would be worse than one reading "0 s".
        let session = running("s-1", seed: 0, at: t0)

        #expect(session.elapsed(asOf: at(-5)) == 0)
    }

    @Test("never starts counting after the instant the host's figure was read")
    func neverStartsInTheFuture() {
        // A computer whose clock is ahead says the turn began two minutes from now.
        // Subtracting that figure put `countingSince` in the future, where the
        // island's count-up has nothing to count up from (and the ordering put
        // the session ahead of work that actually began earlier). The phone
        // cannot know how long a turn it has not seen begin has been running; the
        // honest start is the moment it read the figure.
        let session = running("s-1", seed: -120, at: t0)

        #expect(session.countingSince == t0)
        #expect(session.countingSince <= t0, "the clock starts after the instant it was seeded")
        #expect(session.elapsed(asOf: t0) == 0)
    }
}

@Suite("The Live Activity")
struct LiveActivityTests {
    /// One decision, with the arguments spelled out.
    private func decide(
        _ sessions: [RunningSession],
        approvals: [LiveActivityApproval] = [],
        opened: Bool = false,
        at now: Date,
    ) -> LiveActivityDecision {
        LiveActivityDecision.make(
            sessions: sessions,
            approvals: approvals,
            appOpenedSinceLastFinish: opened,
            now: now,
        )
    }

    @Test("keeps the card up, and says what is blocked, while an approval waits")
    func anApprovalKeepsTheCardUp() {
        let approval = LiveActivityApproval(
            requestId: "r1",
            sessionId: "dsh:s-1",
            tool: "Bash",
            detail: "rm -rf build",
        )
        // A blocked turn is the one moment the operator must act: a card that
        // ended because nothing is "running" would take the button with it.
        let decision = decide([], approvals: [approval], at: t0)

        #expect(!decision.phase.isFinished)
        #expect(decision.phase.rows.isEmpty)
        #expect(decision.phase.approvals.map(\.requestId) == ["r1"])
        #expect(decision.phase.approvals.first?.headline == "Bash")
    }

    @Test("carries the approvals beside the running rows, and caps them at two")
    func approvalsSitBesideRows() {
        let approvals = (1...3).map { index in
            LiveActivityApproval(
                requestId: "r\(index)",
                sessionId: "dsh:s-1",
                tool: "Bash",
                detail: "",
            )
        }
        let decision = decide([running("s-1", seed: 0, at: t0)], approvals: approvals, at: t0)

        #expect(decision.phase.rows.count == 1, "the row is still there: the turn is blocked, not over")
        #expect(decision.phase.approvals.map(\.requestId) == ["r1", "r2"])
    }

    @Test("decodes an approval the computer pushed, and a card that has none")
    func approvalPayloadDecodes() throws {
        let pushed = #"{"rows":[],"approvals":[{"requestId":"r1","sessionId":"dsh:s-1","tool":"Bash","detail":"rm"}]}"#
        let withApprovals = try JSONDecoder().decode(LiveActivityState.self, from: Data(pushed.utf8))
        #expect(withApprovals.approvals.first?.requestId == "r1")
        #expect(!withApprovals.isFinished, "an approval alone is still something to show")

        // The relay's older payloads have no `approvals` key at all, and a card
        // that cannot decode its content state draws nothing.
        let bare = try JSONDecoder().decode(LiveActivityState.self, from: Data(#"{"rows":[]}"#.utf8))
        #expect(bare.approvals.isEmpty)
        #expect(bare.isFinished)
    }

    @Test("is live and counting while a session is running")
    func oneSessionCounting() {
        let decision = decide([running("s-1", seed: 134, at: t0)], at: at(20))

        #expect(decision.phase.rows.map(\.id) == ["s-1"])
        #expect(decision.phase.rows.count == 1, "the one running session is not a row")
        #expect(decision.phase.headline == 154)
        #expect(!decision.shouldDismiss)
    }

    @Test("puts the session that has been running longest first")
    func longestFirst() {
        // Given the other way round, so the order is the sort's doing.
        let decision = decide(
            [running("s-short", seed: 60, at: t0), running("s-long", seed: 600, at: t0)],
            at: t0,
        )

        #expect(decision.phase.rows.map(\.id) == ["s-long", "s-short"])
        #expect(decision.phase.rows.map(\.elapsed) == [600, 60])
        #expect(decision.phase.headline == 600)
    }

    @Test("shows the two longest of three, and the one behind them moves up")
    func twoRowsOfThree() {
        let oldest = running("s-oldest", seed: 900, at: t0)
        let middle = running("s-middle", seed: 300, at: t0)
        let newest = running("s-newest", seed: 30, at: t0)

        let three = decide([newest, middle, oldest], at: at(10))
        #expect(three.phase.rows.map(\.id) == ["s-oldest", "s-middle"])
        #expect(three.phase.rows.map(\.elapsed) == [910, 310])

        // The third was never drawn. When the longest ends, the one behind it
        // takes the row the finished session was holding.
        let two = decide([newest, middle], at: at(10))
        #expect(two.phase.rows.map(\.id) == ["s-middle", "s-newest"])
        #expect(two.phase.headline == 310)
    }

    @Test("hands the island's clock to the next session when the longest ends")
    func headlineMovesOn() {
        let long = running("s-long", seed: 600, at: t0)
        let short = running("s-short", seed: 120, at: t0)

        #expect(decide([long, short], at: at(5)).phase.headline == 605)
        // The island's right side is now the other session's clock, and it is
        // still counting from its own seed rather than starting over.
        #expect(decide([short], at: at(5)).phase.headline == 125)
        #expect(decide([short], at: at(65)).phase.headline == 185)
    }

    @Test("holds the rows in place while only the clock moves")
    func rowsAreStable() {
        // Rows that swap places on their own are rows nobody can follow, so the
        // order is a property of the sessions and not of the instant.
        let sessions = [running("s-b", seed: 40, at: t0), running("s-a", seed: 300, at: t0)]

        for seconds in [0.0, 1.0, 7.0, 60.0, 3_600.0] {
            let decision = decide(sessions, at: at(seconds))
            #expect(decision.phase.rows.map(\.id) == ["s-a", "s-b"], "moved at +\(seconds)s")
            #expect(decision.phase.rows.map(\.elapsed) == [300 + seconds, 40 + seconds])
        }
    }

    @Test("falls back to the session ids when two clocks start at the same instant")
    func tiedSessionsAreDeterministic() {
        // Two sessions seeded in one read can carry the same figure, and the
        // card would then be drawn in whatever order the sort happened to leave
        // them in. A total order is what makes two runs agree.
        let first = running("s-1", seed: 60, at: t0)
        let second = running("s-2", seed: 60, at: t0)

        #expect(decide([first, second], at: t0).phase.rows.map(\.id) == ["s-1", "s-2"])
        #expect(decide([second, first], at: t0).phase.rows.map(\.id) == ["s-1", "s-2"])
    }

    @Test("is finished, and counting nothing, when the last session ends")
    func finishedWhenNothingRuns() {
        let decision = decide([], at: t0)

        #expect(decision.phase.isFinished)
        #expect(decision.phase.rows.isEmpty)
        // The island's right side is a green check from here: there is no
        // session left for a clock to belong to.
        #expect(decision.phase.headline == nil)
        #expect(!decision.shouldDismiss)
    }

    @Test("does not report a finish as witnessed while the app is closed")
    func finishIsNotWitnessedUntilTheAppIsOpened() {
        // `shouldDismiss` is the decision layer's only "the operator has seen
        // this" signal, and it stays false while the app is closed. The card no
        // longer waits on this flag -- the app ends a finished activity on the
        // spot -- but the answer to "was that ending witnessed" must not drift
        // with time.
        for minutes in [0.0, 1.0, 60.0, 1_440.0] {
            let decision = decide([], at: at(minutes * 60))
            #expect(decision.phase.isFinished)
            #expect(!decision.shouldDismiss, "the finish was called witnessed after \(minutes) minutes")
        }
    }

    @Test("asks for the finished activity to come down once, when the app is opened")
    func openingTheAppDismissesOnce() {
        // The app's own bookkeeping, kept the way the app keeps it: the flag
        // means "opened since the last session ended, and not yet acted on", and
        // the count of dismissals is what "once" is about. The card now comes
        // down on `.finished` whether or not this flag is set; what the flag
        // still decides is whether a finish is reported as one the operator saw,
        // and it must be consumed exactly once.
        var appOpenedSinceLastFinish = false
        var dismissals = 0

        func step(_ sessions: [RunningSession], opened: Bool? = nil, at now: Date) -> LiveActivityDecision {
            if let opened { appOpenedSinceLastFinish = opened }
            let decision = decide(sessions, opened: appOpenedSinceLastFinish, at: now)
            if decision.shouldDismiss {
                dismissals += 1
                // Consumed: left set, it would report the next session's finish
                // as one the operator had already seen.
                appOpenedSinceLastFinish = false
            }
            return decision
        }

        let first = running("s-1", seed: 0, at: t0)
        let second = running("s-2", seed: 0, at: t0)

        // A session running is never a dismissal, even after the app was opened:
        // the opening takes down a *finished* activity, never a live one.
        let runningAgain = step([first], opened: true, at: t0)
        #expect(runningAgain.phase.rows.map(\.id) == ["s-1"])
        #expect(!runningAgain.shouldDismiss)

        // It ends while the app is open, so the finish is one the operator saw --
        // and the dismissal is consumed with it.
        let endedWithTheAppOpen = step([], at: at(60))
        #expect(endedWithTheAppOpen.phase.isFinished)
        #expect(endedWithTheAppOpen.shouldDismiss)
        #expect(dismissals == 1)

        // A new session starts, and its finish arrives with the app in the
        // background: the decision layer says nothing about a witness, because
        // there was none.
        #expect(step([second], at: at(120)).phase.rows.map(\.id) == ["s-2"])
        let unwitnessed = step([], at: at(180))
        #expect(unwitnessed.phase.isFinished)
        #expect(!unwitnessed.shouldDismiss)
        #expect(dismissals == 1)

        // An hour later it is still unwitnessed, because the operator still has
        // not looked -- and then they open the app, and the answer flips once.
        #expect(!step([], at: at(3_600)).shouldDismiss)
        #expect(step([], opened: true, at: at(3_700)).shouldDismiss)
        #expect(dismissals == 2)

        // Nothing brings it back. There is no session to draw a clock for, so
        // nothing may start an activity again, and a finish already witnessed is
        // not reported as witnessed twice.
        let after = step([], at: at(4_000))
        #expect(after.phase.isFinished)
        #expect(!after.shouldDismiss)
        #expect(dismissals == 2)
    }

    @Test("shows the operator's instruction, cut to the first few characters")
    func instructionIsCutShort() throws {
        // The row's whole job is to say *which* session this is, and the width it
        // has is a lock-screen card's width shared with a second row.
        let cut = try #require(decide([running("s-1", "把登录页那个多余的转圈去掉", seed: 0, at: t0)], at: t0)
            .phase.rows.first)
        #expect(cut.prompt == "把登录页那个多余…")
        #expect("把登录页那个多余".count == LiveActivityDecision.promptSnippetLength)

        // Exactly the limit is not a cut, and an ellipsis there would claim one
        // that did not happen.
        let exact = try #require(decide([running("s-1", "把登录页那个多余", seed: 0, at: t0)], at: t0)
            .phase.rows.first)
        #expect(exact.prompt == "把登录页那个多余")

        // Shorter than the row is shown whole.
        let short = try #require(decide([running("s-1", "跑一下测试", seed: 0, at: t0)], at: t0)
            .phase.rows.first)
        #expect(short.prompt == "跑一下测试")
    }

    @Test("cuts a composed character at a boundary, not through the middle of one")
    func cutIsGraphemeSafe() {
        // One family emoji is one character to a reader and one to `count`, so
        // the cut cannot leave half a glyph on the card.
        let prompt = String(repeating: "👨‍👩‍👧‍👦", count: 12)
        let row = decide([running("s-1", prompt, seed: 0, at: t0)], at: t0).phase.rows.first

        #expect(row?.prompt == String(repeating: "👨‍👩‍👧‍👦", count: 8) + "…")
    }

    @Test("carries the session's title onto its row")
    func rowCarriesTheSessionTitle() throws {
        // The row used to be the prompt, and a prompt is not a name: two
        // sessions working on the same instruction read identically on the
        // Lock Screen. The title the session list already carries is.
        let row = try #require(
            decide(
                [running("s-1", "fix the parser", title: "Refactor the parser", seed: 30, at: t0)],
                at: t0,
            ).phase.rows.first,
        )

        #expect(row.title == "Refactor the parser")
        #expect(row.displayTitle == "Refactor the parser")
    }

    @Test("falls back to the prompt snippet when the host has not named the session")
    func rowFallsBackToThePrompt() throws {
        // A session gets a title only once the model has produced one, so an
        // unnamed session is the ordinary case rather than an error. The
        // operator's own words are the next best name -- and they are cut by
        // the same rule the row always used.
        let unnamed = try #require(
            decide(
                [running("s-1", "把登录页那个多余的转圈去掉", seed: 0, at: t0)],
                at: t0,
            ).phase.rows.first,
        )
        #expect(unnamed.title == nil)
        #expect(unnamed.displayTitle == "把登录页那个多余…")

        // A title that is only space is not a name, and must not turn the row
        // blank when the prompt is right there.
        let blank = try #require(
            decide(
                [running("s-2", "run the tests", title: "   ", seed: 0, at: t0)],
                at: t0,
            ).phase.rows.first,
        )
        #expect(blank.title == "   ")
        #expect(blank.displayTitle == "run the …")
    }

    @Test("orders by the clocks, not by the titles")
    func titlesDoNotAffectOrdering() {
        // The user is changing what a row says, not which rows are shown or in
        // what order. Titles are alphabetically the wrong way round here, so a
        // sort that picked them up would show it.
        let decision = decide(
            [
                running("s-short", "newer", title: "Zzz", seed: 60, at: t0),
                running("s-long", "older", title: "Aaa", seed: 600, at: t0),
            ],
            at: t0,
        )

        #expect(decision.phase.rows.map(\.id) == ["s-long", "s-short"])
        #expect(decision.phase.rows.map(\.title) == ["Aaa", "Zzz"])
    }

    @Test("reads each session's title from the app's title list, and leaves it absent")
    func runningSessionTakesItsTitleFromTheList() async {
        // The title does not come from `session.list`; it comes from the usage
        // frame the app keeps beside it. The mapping is the only place the two
        // meet, so it is the place a wrong row would start.
        let rows = await RunningSession.running(
            in: [sessionRow("s-1"), sessionRow("s-2")],
            conversations: InMemoryConversationCache(),
            titles: ["s-1": "Refactor the parser"],
            now: t0,
        )

        #expect(rows.map(\.id) == ["s-1", "s-2"])
        #expect(rows.map(\.title) == ["Refactor the parser", nil])
    }

    @Test("does not seed the card from a run a later turn disproved")
    func staleRunDoesNotSeedTheCard() async throws {
        // The session list says this session is running, and the cache holds a
        // turn the phone left counting plus a later turn that finished. Seeding
        // the card from the stale one would name the wrong instruction and count
        // from the wrong start; with the turn settled, the card falls back to
        // the last thing the operator said, exactly as it does for a session
        // whose page has not been read since it started.
        let older = ConversationItem.message(
            id: "seq-10",
            role: .user,
            text: "stale question",
            at: t0,
        )
        let later = ConversationItem.message(
            id: "seq-40",
            role: .user,
            text: "later question",
            at: t0,
        )
        let cache = InMemoryConversationCache()
        await cache.save(CachedConversation(
            sessionId: "s-1",
            items: [older, later],
            throughSeq: 50,
            turns: [
                ConversationTurn(
                    turn: 1,
                    prompts: [older],
                    steps: [],
                    startedAt: t0,
                    endedAt: nil,
                    endedReason: nil,
                ),
                ConversationTurn(
                    turn: 2,
                    prompts: [later],
                    steps: [],
                    startedAt: t0,
                    endedAt: at(2),
                    endedReason: "completed",
                ),
            ],
        ))

        let rows = await RunningSession.running(
            in: [sessionRow("s-1")],
            conversations: cache,
            titles: [:],
            now: at(5),
        )

        let row = try #require(rows.first)
        #expect(row.prompt == "later question")
        #expect(row.elapsedWhenSeeded == 0)
    }

    @Test("tells the widget which instant each row's clock counts from")
    func rowCarriesItsInstant() throws {
        // The widget draws its own ticking text rather than being handed a new
        // number every second, so a row says where its count starts: 2 分 14 秒
        // read at `t0` is a clock that has been going since t0 - 134.
        let row = try #require(
            decide([running("s-1", seed: 134, at: t0)], at: at(5)).phase.rows.first,
        )

        #expect(row.countingSince == at(-134))
        #expect(row.elapsed == 139)
        // And the two are the same clock, which is what lets the widget's timer
        // and the app's figure agree without either asking the host.
        #expect(row.countingSince.addingTimeInterval(row.elapsed) == at(5))
    }

    @Test("never hands the widget a clock that starts after the decision's now")
    func rowNeverStartsAfterNow() throws {
        // The last place that knows `now` is the decision layer, and the widget
        // is another process with no way to ask. A row seeded for an instant
        // this decision has already passed -- a session rebuilt with a new seed,
        // a clock that moved between the read and the decision -- must be
        // clamped here; the widget's count-up has no time to count up to.
        let row = try #require(
            decide([running("s-1", seed: 0, at: at(10))], at: t0).phase.rows.first,
        )

        #expect(row.countingSince == t0)
        #expect(row.elapsed == 0)
    }

    @Test("survives the trip to the widget as the activity's content state")
    func contentStateRoundTrips() throws {
        let decision = decide(
            [
                running(
                    "s-1",
                    "把登录页那个多余的转圈去掉",
                    title: "登录页的转圈",
                    seed: 134,
                    at: t0,
                ),
                running("s-2", seed: 60, at: t0),
            ],
            at: at(5),
        )
        let data = try JSONEncoder().encode(decision.phase)

        // Property names are a wire format between two processes that are
        // updated together but not at the same instant -- and, since the relay
        // builds this same JSON for a push, between three repositories. Pinned
        // here so a rename is a failing test rather than an activity that draws
        // nothing on somebody's phone.
        //
        // Read as an object rather than as a string: `JSONEncoder` has never
        // promised a key order, and a prefix assertion on two keys is a test that
        // fails on the day one of them is added.
        let text = String(decoding: data, as: UTF8.self)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["rows"] != nil)
        #expect(object?["approvals"] != nil)
        #expect(text.contains("\"title\""))
        let read = try JSONDecoder().decode(LiveActivityState.self, from: data)
        #expect(read == decision.phase)
        #expect(read.rows.first?.title == "登录页的转圈")
        #expect(read.rows.first?.displayTitle == "登录页的转圈")
        // The unnamed session still says the operator's words, on the widget's
        // side of the boundary as well.
        #expect(read.rows.last?.title == nil)
        #expect(read.rows.last?.displayTitle == "run the …")

        // The other case carries no rows at all, and the decision as a whole is
        // `Codable` like everything else here.
        //
        // `approvals` is always written by this side, even when empty: this is the
        // app's own encoder. The tolerance the other direction needs -- a relay
        // that has never heard of approvals -- lives in
        // `LiveActivityState.init(from:)` and is pinned by the end-push test
        // below.
        let finished = try JSONEncoder().encode(LiveActivityState())
        let empty = try JSONSerialization.jsonObject(with: finished) as? [String: Any]
        #expect(Set(empty?.keys ?? [:].keys) == ["rows", "approvals"])
        #expect((empty?["rows"] as? [Any])?.isEmpty == true)
        #expect(try JSONDecoder().decode(LiveActivityState.self, from: finished) == LiveActivityState())
        #expect(try JSONDecoder().decode(LiveActivityDecision.self, from: JSONEncoder().encode(decision)) == decision)
    }

    @Test("decodes the end push's content-state exactly as the relay sends it")
    func endPushContentStateDecodes() throws {
        // Cross-repo contract, pinned from this side: the relay's end push
        // carries `{"rows":[]}` as its `content-state` (see
        // `buildLiveActivityEndPayload` in dsh-relay). ActivityKit decodes it
        // with a plain JSONDecoder, and a literal that no longer matches this
        // state is an end event iOS accepts and then drops — the activity keeps
        // counting, which is the bug the payload exists to fix.
        //
        // The literal is the point. An enum with associated values used to
        // encode the same information as `{"finished":{}}`, which APNs accepts
        // (the required keys are all there) and the device cannot place: three
        // end pushes were delivered to one card on 2026-10-26 and the card kept
        // counting. Keys that are properties have nowhere to go wrong.
        let literal = Data(#"{"rows":[]}"#.utf8)
        #expect(try JSONDecoder().decode(LiveActivityState.self, from: literal) == LiveActivityState())
    }

    @Test("an activity written before rows carried titles still decodes")
    func oldRowWithoutATitleDecodes() throws {
        // A Live Activity outlives the build that posted it, and the system
        // hands the new widget the old row it stored. A required title would
        // make that row fail to decode and the card draw nothing, so the key
        // has to be optional on the wire.
        let row = LiveActivityRow(id: "s-1", prompt: "run", elapsed: 60, countingSince: t0)
        let encoded = try JSONEncoder().encode(row)
        var object = try #require(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any],
        )
        object.removeValue(forKey: "title")

        let old = try JSONSerialization.data(withJSONObject: object)
        let read = try JSONDecoder().decode(LiveActivityRow.self, from: old)

        #expect(read.id == "s-1")
        #expect(read.title == nil)
        #expect(read.displayTitle == "run")
    }
}
