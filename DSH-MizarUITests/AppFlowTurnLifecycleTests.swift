//
//  AppFlowTurnLifecycleTests.swift
//  DSH-MizarUITests
//
//  Methods moved verbatim from AppFlowTests.swift (send / refresh / approval / lifecycle).
//

import XCTest

final class AppFlowTurnLifecycleTests: AppFlowTestBase {
    /// This class's own mock-host pair, from the MockPorts table.
    override class var mockPort: Int { MockPorts.port(for: String(describing: self)) }
    /// The refresh control in the conversation, which is the way back to a
    /// session that has gone quiet without hunting for a pull gesture.
    ///
    /// It calls the same reload the pull-to-refresh does. The assertion is that
    /// it exists, that it is usable once the screen has landed, and that tapping
    /// it loads the conversation again rather than emptying it -- a reload that
    /// reported failure would draw the failure card over what was on screen.
    func testTheConversationCanBeRefreshed() {
        let app = launch(pending: false)
        // The screen has to have landed first: the button is disabled while a
        // reload is already in flight, and a disabled button that does nothing
        // would fail this for the wrong reason.
        expect(app.staticTexts["Refactor the parser and run the tests."], "the conversation never arrived")

        let refresh = app.buttons["session.refresh"]
        expect(refresh, "there is no way to refresh the conversation")
        XCTAssertTrue(refresh.isEnabled, "the refresh button is disabled on a landed screen")
        refresh.tap()

        // It comes back, and it comes back usable: the spinner it shows while it
        // works must not leave the control dead afterwards.
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isEnabled == true"),
            object: refresh,
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [ready], timeout: Self.patience),
            .completed,
            "the refresh button never became usable again",
        )
        XCTAssertTrue(
            app.buttons["session.refresh"].exists,
            "the refresh button vanished while it was working",
        )

        // And the conversation is still the conversation. A reload that lost it
        // is what "pull to refresh loses my history" was, in the same code path.
        XCTAssertTrue(
            reveal(app.staticTexts["Refactor the parser and run the tests."], in: app),
            "reloading the conversation emptied it",
        )
        XCTAssertFalse(
            app.staticTexts["Could not load the conversation"].exists,
            "reloading the conversation reported a failure",
        )
        XCTAssertFalse(
            app.otherElements["session.placement.failed"].exists || app.buttons["session.placement.retry"].exists,
            "reloading left loaded messages trapped behind positioning failure",
        )
    }

    /// A turn that ends while the conversation is open is noticed by itself.
    ///
    /// The report, in the operator's words: the phone sends an instruction, the
    /// session shows as running, the window is left open, the turn finishes and
    /// the phone still says it is running until somebody pulls to refresh. The
    /// only polls before this were the one after a send -- which gives up once
    /// the sent prompt has arrived -- and the pending-interactions one, which
    /// has nothing to say about a turn ending.
    ///
    /// The fixture's session is stopped at the control endpoint while the
    /// conversation is open. Its session list then reports nothing running and
    /// its conversation page carries the turn's end, so a phone that keeps
    /// asking sees the finished row; a phone that stopped asking does not. The
    /// assertion is made with no tap, no pull and no relaunch, because any of
    /// those would start a read of its own and prove the opposite thing.
    ///
    /// The timeout is longer than one tick (10 s) with room for the round trip
    /// and the view's own update, and short enough that a failure is about the
    /// poll rather than about the suite's patience.
    func testAFinishedTurnIsNoticedWithoutARefresh() {
        let app = launch(pending: false)
        // The conversation has landed before the clock starts: the row and the
        // prompt are what the assertion watches.
        expect(app.staticTexts["And run the whole suite."], "the running turn's prompt is missing")

        let running = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "DeepSeeking for "))
            .firstMatch
        expect(running, "no turn is reported as running to begin with")
        let row = turnRow(app, 4)
        expect(row, "turn 4 is missing, so there is no running row to watch")

        // The computer finishes the turn. Nothing on the phone is touched from here.
        Self.setMockSessionRunning(false)

        let stopped = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: running,
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [stopped], timeout: 15),
            .completed,
            "the running row is still on screen 15 s after the host stopped the session: \(running.label)",
        )
        // Finished rather than erased: the turn's row, prompt and markers are
        // still on screen, so the row changed state instead of leaving.
        XCTAssertTrue(row.exists, "turn 4 went away instead of finishing")
        XCTAssertTrue(
            app.staticTexts["And run the whole suite."].exists,
            "the finished turn's prompt went away",
        )
        XCTAssertTrue(
            app.staticTexts["2 steps"].exists,
            "the finished turn's step count went away",
        )
    }

    /// A send starts the running poll by itself, with no list read to wait for.
    ///
    /// The operator's report: the poll stopped once a real read said nothing was
    /// running, and the machine never went back to asking when a prompt was
    /// sent. `session.prompt` being accepted is direct evidence that a turn is
    /// executing; the session list is the stale one.
    ///
    /// The fixture is stopped at launch, so no poll exists, and is put back to
    /// running before the send. From the send onward nothing is tapped: the only
    /// thing that can make a `session.list` reach the host is the poll. Counted
    /// at the host, because a request that is never made has no screen symptom.
    func testASendStartsTheRunningPollWithoutATap() {
        let app = launch(pending: false, running: false)
        let field = app.textViews["composer.field"]
        expect(field, "the composer is missing")
        // The host records the prompt a moment later, and is left running from
        // here -- the app's list still says the session is stopped.
        Self.setMockSessionRunning(true)

        field.tap()
        field.typeText("Keep working while I watch")
        app.buttons["composer.send"].tap()

        // Accepted: the composer clears only on success.
        let cleared = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in (field.value as? String) == "Ask your agent…" },
            object: nil,
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [cleared], timeout: Self.patience),
            .completed,
            "the send never settled, so there is nothing to poll about",
        )

        // From here the host counts only what happens after the send. The
        // launch's own list reads are not the poll.
        _ = Self.mockLoads()

        // The tick is 10 s, so the first read belongs in the next sixteen.
        var counts: [String: Int] = [:]
        var firstTick: Date?
        let firstDeadline = Date().addingTimeInterval(16)
        while Date() < firstDeadline {
            counts = Self.mockMethodCounts()
            if (counts["session.list"] ?? 0) >= 1 {
                firstTick = Date()
                break
            }
            Thread.sleep(forTimeInterval: 0.4)
        }
        XCTAssertNotNil(
            firstTick,
            "no session.list read after a send: the running poll never started (methods: \(counts))",
        )

        // And it keeps asking, at the interval it shipped with. Two ticks are
        // what tells a start apart from one read that happened to land.
        var secondTick: Date?
        let secondDeadline = Date().addingTimeInterval(14)
        while Date() < secondDeadline {
            counts = Self.mockMethodCounts()
            if (counts["session.list"] ?? 0) >= 2 {
                secondTick = Date()
                break
            }
            Thread.sleep(forTimeInterval: 0.4)
        }
        XCTAssertNotNil(
            secondTick,
            "the poll asked once and stopped while the session was still running (methods: \(counts))",
        )
        if let firstTick, let secondTick {
            let interval = secondTick.timeIntervalSince(firstTick)
            XCTAssertGreaterThanOrEqual(interval, 5, "two session.list reads \(interval) s apart: not the 10 s poll")
            XCTAssertLessThanOrEqual(interval, 20, "the poll waited \(interval) s between reads")
        }
    }

    /// The operator's scenario end to end: send, the turn ends, nothing is tapped.
    ///
    /// The existing test for this starts from launch, which is exactly why it
    /// passed while the device failed: the launch list said a session was
    /// running, so the poll was already up before the send. On the phone the
    /// poll had read a list with nothing running and stopped; the send was the
    /// only evidence left, and nothing acted on it. Here the fixture is stopped
    /// at launch and put back to running before the prompt is sent, so the list
    /// the app holds says stopped and no poll exists. The host then stops the
    /// turn a few seconds after the send. The running row may only leave because
    /// something asked again.
    func testATurnThatEndsAfterASendIsNoticedWithoutATap() {
        let app = launch(pending: false, running: false)
        let field = app.textViews["composer.field"]
        expect(field, "the composer is missing")
        Self.setMockSessionRunning(true)

        field.tap()
        field.typeText("Finish this turn while I wait")
        app.buttons["composer.send"].tap()

        // The turn the send started is the row being watched. It comes from the
        // page the send's own refresh reads, so its arrival also says the send
        // settled -- which is what stops a late post-send retry from being
        // mistaken for the poll noticing the end.
        let running = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "DeepSeeking for "))
            .firstMatch
        expect(running, "the turn started by the send is not on screen")

        // The host finishes it, with nothing tapped on the phone. A few seconds
        // is the report's own timing: long enough that the post-send refresh has
        // settled, short enough that the first poll tick has not happened yet.
        Thread.sleep(forTimeInterval: 2)
        Self.setMockSessionRunning(false)

        let stopped = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: running,
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [stopped], timeout: 15),
            .completed,
            "the running row is still on screen 15 s after the turn ended: nothing asked the host again",
        )
    }

    /// The context figure opens the breakdown it is computed from.
    ///
    /// This replaces a test for a Usage *tab*. The tab is gone: the figure lives
    /// above the field now, so the detail is one tap from the conversation
    /// instead of a screen swap away from it.
    func testTheContextFigureOpensItsBreakdown() {
        let app = launch()
        let context = app.buttons["composer.context"]
        expect(context, "the context figure is missing")
        XCTAssertTrue(
            labelLands(context, containing: "35"),
            "the context percentage is not the host's: \(context.label)",
        )
        context.tap()

        // The window and the composition come from the host's frame, so their
        // being on screen is what proves the popover is wired to it.
        expect(app.staticTexts["Window"], "the window size is not in the breakdown")
        expect(app.staticTexts["Pressure"], "the pressure figure is not in the breakdown")
        expect(app.staticTexts["Messages"], "the token breakdown is not in the popover")
    }

    /// The command button puts a command in the field rather than sending it.
    func testTheCommandButtonDraftsACommand() {
        let app = launch()
        let commands = app.buttons["composer.commands"]
        expect(commands, "the command button is missing")
        commands.tap()

        let goal = app.buttons["command.goal"]
        expect(goal, "the command list did not open")
        goal.tap()

        // Did the action run at all? The list closes only from inside the
        // button, so a list still on screen means the tap never reached it --
        // which is a different fault from a command that ran and was lost.
        let closed = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in !goal.exists },
            object: nil,
        )
        let outcome = XCTWaiter().wait(for: [closed], timeout: 5)
        XCTAssertEqual(outcome, .completed, "the tap did not reach the command row")

        // Drafted, not sent: a goal needs text after the slash, and firing it
        // blank would send the agent an empty instruction.
        let field = app.textViews["composer.field"]
        expect(field, "the composer is missing")
        // Polled rather than read once: the sheet leaves with an animation and
        // the field is not updated until it has gone, so a single read races it
        // and reports the placeholder as if nothing had been drafted.
        let drafted = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in (field.value as? String) == "/goal " },
            object: nil,
        )
        _ = XCTWaiter().wait(for: [drafted], timeout: 10)
        XCTAssertEqual(field.value as? String, "/goal ", "the command was not drafted into the field")
    }

    // MARK: - Interactions

    func testAPendingApprovalOffersExactlyTwoOutcomes() {
        // Chinese, because the tool identifier is the thing on this card that
        // the app has to name: `write_file` is protocol data, and an operator
        // reading 请求执行 write_file is reading the host's vocabulary rather
        // than the app's.
        let app = launch(language: "zh-Hans")
        expect(app.buttons["approval.allowOnce"], "there is no way to allow")
        expect(app.buttons["approval.reject"], "there is no way to reject")
        XCTAssertTrue(
            app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "写入文件"))
                .firstMatch.waitForExistence(timeout: Self.patience),
            "the approval card still shows the raw tool identifier",
        )
        // There is deliberately no "always allow": a grant that outlives the
        // request it was given for is a permission change, and those belong in
        // the permission picker where they are visible and reversible.
        XCTAssertEqual(
            app.buttons.matching(identifier: "approval.allowAlways").count,
            0,
            "an unconditional grant appeared",
        )
    }

    func testAQuestionBatchIsRefusedUntilItIsComplete() {
        let app = launch()
        let submit = app.buttons["question.submit"]
        // The question sits behind the approval in the dock's deck.
        XCTAssertTrue(bringCardForward(submit, in: app), "the question never came to the front of the deck")
        // The batch has a single-option question, which is pre-selected, and a
        // multi-option one, which is not. Submitting half a batch would leave
        // the agent waiting on the rest.
        XCTAssertFalse(submit.isEnabled, "an incomplete batch could be submitted")
        // The option's button label includes its description, so the visible
        // text is the stable handle.
        app.staticTexts["Migrate in place"].tap()
        XCTAssertTrue(submit.isEnabled, "the batch could not be completed")
    }

    func testASentMessageAppearsInTheConversation() {
        // The half of the loop nothing checked: sending is not the same as the
        // message showing up. Before this, it did not -- the app never reloaded
        // the conversation after a send, so the operator's own words were absent
        // until a pull-to-refresh.
        //
        // Stopped, because this is about the send path alone. A send into a
        // *running* turn is held above the field now (guided send off, the
        // default), and that behaviour has its own tests below; measuring it
        // here would make this one fail for a reason that is not about the
        // message arriving.
        let app = launch(pending: false, running: false)
        let field = app.textViews["composer.field"]
        expect(field, "the composer is missing")
        field.tap()
        field.typeText("does this reach the agent")

        let send = app.buttons["composer.send"]
        expect(send, "there is no way to send")
        XCTAssertTrue(send.isEnabled, "send stayed disabled with text in the field")
        send.tap()

        // The composer must have emptied, or the text being found proves nothing:
        // a query for static text also matches a field still holding the words,
        // which is exactly how an earlier version of this test passed with the
        // reload removed.
        // Found is not enough, and a plain subscript is not even usable: SwiftUI
        // leaves the typed text in the accessibility tree after the field clears,
        // so several elements carry this label. The first two versions of this
        // test passed with the reload removed for exactly that reason -- the
        // words were real, they were just still sitting where they had been
        // typed. A conversation bubble is the one above the composer.
        // First: did the send succeed? The composer clears only on success and is
        // refilled on failure, so what the field holds says which branch ran --
        // and the two produce the same visible symptom ("the text is still
        // here"). Empty and the placeholder are the same answer: an empty
        // `UITextView` reports "" to XCUITest, and which of the two an empty
        // field reports depends on the OS, not on the send.
        let composerField = app.textViews["composer.field"]
        expect(composerField, "the composer vanished")
        XCTAssertFalse(
            fieldContains("does this reach the agent", in: app),
            "the composer still holds the text, so the send did not succeed",
        )

        // Scroll until it is actually on screen. The conversation is longer than
        // the display and a new message lands at the bottom of it, so its frame
        // sits below the composer until scrolled into view -- which reads
        // identically to the message being absent. A fixed number of swipes is a
        // guess about how long the conversation is.
        let composer = app.textViews["composer.field"]
        // By label, not by identifier. `matching(identifier:)` reads the
        // accessibility *identifier*, and a message bubble sets its text as the
        // accessibility *label* -- so this query matched nothing, ever, and the
        // failure said "0 elements carry the text" while the text was on screen.
        let candidates = app.staticTexts.matching(
            NSPredicate(format: "label == %@", "does this reach the agent"),
        )
        var inConversation: XCUIElement?
        for _ in 0..<8 {
            inConversation = (0..<candidates.count)
                .map { candidates.element(boundBy: $0) }
                .first { $0.frame.maxY < composer.frame.minY }
            if inConversation != nil { break }
            app.swipeUp()
        }
        XCTAssertNotNil(
            inConversation,
            "the message never reached the conversation (\(candidates.count) elements carry the text, none above the composer)\nHIERARCHY-START\n\(app.debugDescription)\nHIERARCHY-END",
        )
        XCTAssertFalse(
            fieldContains("does this reach the agent", in: app),
            "the composer never emptied",
        )
    }

    // MARK: - A prompt held for the end of a turn

    /// A message sent while the agent is working waits above the field.
    ///
    /// The default is guided send off, and the old behaviour was the host's
    /// queue: the message was gone the moment it was sent and could not be taken
    /// back. Now the phone holds it, so it can be put back or thrown away -- and
    /// the proof that nothing has been queued is the wire, where no prompt has
    /// arrived.
    func testASendIntoARunningTurnWaitsInTheBar() {
        let app = launch(pending: false)
        let field = app.textViews["composer.field"]
        expect(field, "the composer is missing")
        field.tap()
        field.typeText("hold this thought")
        app.buttons["composer.send"].tap()

        let bar = app.descendants(matching: .any).matching(identifier: "pending.bar").firstMatch
        expect(bar, "a send into a running turn did not appear above the field")
        let heldText = app.staticTexts["pending.text"]
        expect(heldText, "the bar draws no text")
        XCTAssertEqual(heldText.label, "hold this thought", "the bar is not showing what was sent")
        XCTAssertFalse(
            fieldContains("hold this thought", in: app),
            "the field still holds the text, so it was never taken",
        )
        XCTAssertEqual(
            Self.mockPrompts().texts,
            [],
            "the held prompt reached the host before the turn ended",
        )

        // Put it back: the words are the operator's again, and the bar goes.
        app.buttons["pending.return"].tap()
        XCTAssertTrue(
            waitForDisappearance(bar, timeout: 5),
            "the bar stayed after the prompt was put back",
        )
        XCTAssertTrue(
            waitForField("hold this thought", in: app),
            "the text never made it back to the field: \(app.textViews["composer.field"].value ?? "nil")",
        )

        // Hold it again and throw it away, without either send touching the wire.
        app.buttons["composer.send"].tap()
        expect(bar, "the second send did not put the bar back")
        app.buttons["pending.delete"].tap()
        XCTAssertTrue(
            waitForDisappearance(bar, timeout: 5),
            "the bar stayed after the prompt was deleted",
        )
        XCTAssertFalse(
            fieldContains("hold this thought", in: app),
            "deleting the held prompt left its text behind",
        )
        XCTAssertEqual(Self.mockPrompts().texts, [], "something was sent while no prompt was held")
    }

    /// The held prompt goes when the turn ends, with nothing tapped.
    ///
    /// It is sent as the next ordinary prompt, not as guidance: the turn it was
    /// waiting for is over. The mock host's session is stopped at the control
    /// endpoint; the app's running poll is what notices, and it asks faster while
    /// a prompt is held, which is why this can wait less than the usual tick.
    func testAHeldPromptGoesWhenTheTurnEnds() {
        let app = launch(pending: false)
        let field = app.textViews["composer.field"]
        expect(field, "the composer is missing")
        field.tap()
        field.typeText("and then run the suite")
        app.buttons["composer.send"].tap()

        let bar = app.descendants(matching: .any).matching(identifier: "pending.bar").firstMatch
        expect(bar, "the send into a running turn did not put a bar above the field")
        XCTAssertEqual(Self.mockPrompts().texts, [], "the held prompt left before its turn ended")

        // The turn the prompt was held for ends. Nothing is tapped from here.
        Self.setMockSessionRunning(false)

        XCTAssertTrue(
            waitForDisappearance(bar, timeout: 20),
            "the bar stayed after the turn ended",
        )
        let sent = Self.waitForMockPrompts(count: 1)
        XCTAssertEqual(
            sent.texts,
            ["and then run the suite"],
            "the held prompt never reached the host",
        )
        XCTAssertEqual(
            sent.modes,
            ["queue"],
            "the end-of-turn hand-over travelled as \(sent.modes) rather than as an ordinary prompt",
        )
    }

    /// The bar's send key is guidance: the running turn takes the message now.
    func testAHeldPromptCanBeSentAsGuidance() {
        let app = launch(pending: false)
        let field = app.textViews["composer.field"]
        expect(field, "the composer is missing")
        field.tap()
        field.typeText("do it this way instead")
        app.buttons["composer.send"].tap()

        let bar = app.descendants(matching: .any).matching(identifier: "pending.bar").firstMatch
        expect(bar, "the send into a running turn did not put a bar above the field")
        XCTAssertEqual(Self.mockPrompts().texts, [], "the held prompt left before it was asked to")

        app.buttons["pending.send"].tap()
        XCTAssertTrue(
            waitForDisappearance(bar, timeout: 10),
            "the bar stayed after its send key",
        )
        let sent = Self.waitForMockPrompts(count: 1)
        XCTAssertEqual(sent.texts, ["do it this way instead"], "the bar's send key sent nothing")
        XCTAssertEqual(
            sent.modes,
            ["steer"],
            "the bar's send key travelled as \(sent.modes), which would interrupt the turn",
        )
    }

    /// Guided send on: the message is handed to the running turn at once.
    ///
    /// The switch is the whole feature -- the bar only exists because it is off
    /// -- so this drives the screen rather than trusting the default, and reads
    /// the payload at the host, where guidance and a queue are indistinguishable
    /// from the screen's side.
    func testGuidedSendHandsTheMessageOverAtOnce() {
        let app = launch()
        openSettings(app)
        let identifier = "settings.send.guidedSend"
        let toggle = settingControl(identifier, in: app)
        XCTAssertTrue(revealInSettings(toggle, in: app), "there is no guided-send switch")

        // The simulator container outlives a test run, so "off" is established
        // rather than assumed: a suite that insisted on the default would pass on
        // a fresh machine and fail on the second run.
        if settingState(identifier, in: app) == true {
            flip(toggle, in: app)
            XCTAssertTrue(
                settingChanges(identifier, in: app, from: true),
                "the guided-send switch could not be put back to its default",
            )
        }
        XCTAssertEqual(
            settingState(identifier, in: app),
            false,
            "guided send should start off",
        )

        flip(toggle, in: app)
        XCTAssertTrue(
            settingChanges(identifier, in: app, from: false),
            "the guided-send switch did not move",
        )
        app.buttons["settings.done"].tap()
        let dismiss = app.buttons["shell.dismissSidebar"]
        if dismiss.waitForExistence(timeout: 3) { dismiss.tap() }
        XCTAssertTrue(
            sidebar(app.buttons["sessions.new"], isOut: false),
            "the sidebar stayed over the conversation after the settings closed",
        )

        let field = app.textViews["composer.field"]
        expect(field, "the conversation never came back from the settings")
        field.tap()
        field.typeText("guide me now")
        app.buttons["composer.send"].tap()

        let bar = app.descendants(matching: .any).matching(identifier: "pending.bar").firstMatch
        XCTAssertFalse(
            bar.waitForExistence(timeout: 2),
            "guided send still held the message in the bar",
        )
        let sent = Self.waitForMockPrompts(count: 1)
        XCTAssertEqual(sent.texts, ["guide me now"], "guided send sent nothing")
        XCTAssertEqual(
            sent.modes,
            ["steer"],
            "guided send travelled as \(sent.modes), which would interrupt the turn",
        )

        // And back to the default, so the rest of the suite measures what a
        // fresh install has rather than this test's choice.
        openSettings(app)
        let again = settingControl(identifier, in: app)
        XCTAssertTrue(revealInSettings(again, in: app), "the guided-send switch is gone")
        if settingState(identifier, in: app) == true {
            flip(again, in: app)
            _ = settingChanges(identifier, in: app, from: true)
        }
    }

    /// A running turn's clock, when the host's clock is ahead of the phone's.
    ///
    /// The start is the host's number and `now` is the phone's, so the two
    /// disagreeing is ordinary -- a computer whose clock drifted, a phone that has not
    /// synced. Subtracting them gave a negative duration, and the row read
    /// "DeepSeeking for -4 s", which is not a time anybody can act on. The
    /// clamp is the kit's own rule (``ConversationTurn/elapsed(asOf:)``), which
    /// the view was not using.
    func testARunningTurnsClockIsNotNegativeWhenTheHostsClockIsAhead() {
        // Ten minutes ahead: far enough that no part of the fixture can be in the
        // past by accident, and short enough that the turn is still running.
        let app = launch(pending: false, skew: 600_000)
        // The conversation has to have landed, or this passes on an empty screen.
        expect(app.staticTexts["And run the whole suite."], "the running turn's prompt is missing")

        let running = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "DeepSeeking for "))
            .firstMatch
        expect(running, "no turn is reported as running")
        XCTAssertFalse(
            running.label.contains("-"),
            "a running turn reports a negative duration: \(running.label)",
        )
        // And it says the honest thing rather than nothing: the phone cannot know
        // how long a turn started in the future has been running.
        XCTAssertEqual(
            running.label,
            "DeepSeeking for 0 s",
            "the running row does not clamp a start the phone has not reached",
        )
    }

    /// A page too large to deliver is asked for again smaller, not given up on.
    ///
    /// The host's `RESPONSE_TOO_LARGE` is the one failure whose answer is a
    /// different request: the page was real and the socket could not carry it.
    /// Before this the app reported it, so a conversation whose history is long
    /// enough -- which is exactly the conversation somebody opens the app to
    /// read -- showed "Could not load the conversation" and nothing else.
    func testAnAnswerTooLargeToDeliverIsAskedForAgainSmaller() {
        // The host refuses the app's usual 200-message page and answers a small
        // one, which is what the real host does at its own size limit.
        let app = launch(pending: false, pageLimit: 50)

        expect(
            app.staticTexts["Refactor the parser and run the tests."],
            "the conversation never arrived: a page too large to deliver was not re-asked for",
        )
        XCTAssertFalse(
            app.staticTexts["Could not load the conversation"].exists,
            "a too-large answer was reported as a failure instead of being re-asked",
        )
        // And asking for less is a *request*, not a new socket: tearing the
        // connection down over an answer the host already sent costs a handshake
        // and re-subscribes every listener.
        XCTAssertEqual(
            Self.mockConnections(),
            1,
            "a too-large answer cost a fresh connection",
        )
    }

    /// The Live Activity survives the moment everything finishes.
    ///
    /// The finished card draws the words "every session has finished" — and any
    /// `LocalizedStringKey` text (`Text("…")`) aborts the widget extension when
    /// WidgetKit archives the view to hand it to the process that draws a Live
    /// Activity, because stripping SwiftUI's localisable-segment attribute out of
    /// the archived string throws inside `NSAttributedString`. The file that
    /// documents this fixed it everywhere except these two strings, and the
    /// running card never draws them: the finished state is only ever reached by
    /// taking down an activity that was started for a session that was running,
    /// and that final state is archived on the way out.
    ///
    /// XCTest fails the test itself when the extension aborts — "Critical process
    /// DSH-Mizar-LiveActivity crashed" — which is the assertion here.
    func testTheLiveActivitySurvivesEverythingFinishing() {
        let app = launch(session: nil, pending: false)
        // A cold launch now lands on Home with the sidebar open; the session
        // list (and its refresh control) is one workspace tap behind it. The
        // old assumption -- that `session: nil` opens the list -- predates the
        // Home screen and made this test fail before the activity was ever
        // touched.
        if !app.buttons["sessions.refresh"].exists {
            if app.buttons["shell.sidebarToggle"].waitForExistence(timeout: 5) {
                app.buttons["shell.sidebarToggle"].tap()
            }
            let workspace = app.buttons["workspace./Users/you/projects/demo"]
            if workspace.waitForExistence(timeout: 10) {
                workspace.staticTexts.element(boundBy: 0).tap()
            }
        }
        expect(app.buttons["sessions.refresh"], "the session list never arrived")

        // Nothing is running any more, which is what the next refresh reports.
        Self.setMockSessionRunning(false)
        app.buttons["sessions.refresh"].tap()

        // A full pass over the sessions, which is where the app decides what the
        // activity should show. Waited for by the control it disables — first
        // disabled, then enabled again, because the refresh starts from a `Task`
        // and a single "is it enabled" read can beat it to the screen.
        let refresh = app.buttons["sessions.refresh"]
        let busy = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isEnabled == false"),
            object: refresh,
        )
        _ = XCTWaiter().wait(for: [busy], timeout: 5)
        let settle = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isEnabled == true"),
            object: refresh,
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [settle], timeout: Self.patience),
            .completed,
            "the refresh never finished",
        )
        let done = app.buttons["sync.done"]
        if done.exists { done.tap() }

        // The app is still here, with its list. A crashed widget takes the
        // activity down rather than the app, so this alone would not catch it —
        // XCTest's own "Critical process DSH-Mizar-LiveActivity crashed" is the
        // assertion this test is really making.
        XCTAssertTrue(
            app.buttons["workspace./Users/you/projects/demo"].waitForExistence(timeout: Self.patience),
            "the session list was lost",
        )
    }

    /// The refresh that runs once the app is off screen.
    ///
    /// Half of the Live Activity happens with no screen to look at: the app is
    /// backgrounded, and while it is off screen it has to re-read the session
    /// list and the running session's page, or the island only ever knows what
    /// was true when the app was last open. The assertion is the mock host's own
    /// count of what it was asked -- a request made with no screen cannot be
    /// seen on one, and the count is a fact about the wire rather than about
    /// either process's opinion of itself.
    ///
    /// It is the app's behaviour being measured, not the simulator's: the
    /// assertion the app takes on the way out is what keeps the process alive
    /// long enough to make the request at all. Measured by hand on this machine
    /// with `log stream` as well, where the app's own line names the state it was
    /// in when it updated the activity, and read "background".
    ///
    /// What is deliberately not asserted is that the activity's *content*
    /// changed. That needs the host to change its answer between the moment the
    /// app leaves the screen and the moment the refresh reads it, and the only
    /// hand on that dial is the test's own HTTP call -- made from the test
    /// runner, at a moment the app does not coordinate with. The content half is
    /// measured by hand in the report, not faked here.
    func testBackgroundingRefreshesTheSessionListAndTheRunningSession() {
        // The session list rather than a conversation: this is about what the
        // app does once it is off screen, and the screen it was on is beside the
        // point. The launch's first download is what puts the running turn in
        // the cache the refresh re-reads.
        let app = launch(session: nil, running: true)
        expect(app.buttons["sessions.refresh"], "the app never came up")
        // The launch's own reads are not what this measures. They finish in a
        // fraction of a second against this host, and the wait is long enough
        // that a straggler cannot be counted as the background refresh, while
        // still being far shorter than the test's patience.
        Thread.sleep(forTimeInterval: 3)
        _ = Self.mockLoads()

        XCUIDevice.shared.press(.home)

        // Polled rather than waited on once: the app is suspended in milliseconds
        // when it has nothing to do, and the assertion it takes on the way out
        // is what gives it the time. A single read of the counts after a fixed
        // sleep would be an assertion about the simulator's scheduler.
        var counts: [String: Int] = [:]
        let deadline = Date().addingTimeInterval(Self.patience)
        while Date() < deadline {
            counts = Self.mockMethodCounts()
            if (counts["session.list"] ?? 0) >= 1, (counts["session.messages"] ?? 0) >= 1 { break }
            Thread.sleep(forTimeInterval: 0.5)
        }
        // Reactivated before the assertions so a failure leaves the app on
        // screen for the next test rather than behind the home screen.
        app.activate()

        XCTAssertGreaterThanOrEqual(
            counts["session.list"] ?? 0,
            1,
            "the app was backgrounded and never re-read the session list",
        )
        XCTAssertGreaterThanOrEqual(
            counts["session.messages"] ?? 0,
            1,
            "the running session's page was not re-read off screen",
        )
    }

    /// A refusal the host chose to send does not rebuild the socket.
    ///
    /// `session.stats` is re-read on every reload, so a host-side failure there
    /// is the ordinary shape of "this one read did not work". Every failure used
    /// to reconnect -- a WebSocket, a handshake and a re-subscription -- and then
    /// ask the same question again, which the same host answered the same way.
    func testAHostSideRefusalDoesNotRebuildTheConnection() {
        let app = launch(pending: false)
        // The screen has to have landed: the reads the launch itself makes are
        // what the count below is measured from.
        expect(app.staticTexts["Refactor the parser and run the tests."], "the conversation never arrived")
        XCTAssertEqual(Self.mockConnections(), 1, "the launch opened more than one connection")

        // From here on the host refuses one method and answers everything else.
        Self.failMockHost("session.stats")
        let refresh = app.buttons["session.refresh"]
        expect(refresh, "there is no way to refresh the conversation")
        refresh.tap()

        // Wait for the reload to finish, so the count is not read mid-flight.
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isEnabled == true"),
            object: refresh,
        )
        XCTAssertEqual(XCTWaiter().wait(for: [ready], timeout: Self.patience), .completed)

        XCTAssertEqual(
            Self.mockConnections(),
            1,
            "a refusal the host sent over a working socket tore the connection down",
        )
        // The conversation is still the conversation: nothing about this failure
        // was the connection's business.
        XCTAssertTrue(
            reveal(app.staticTexts["Refactor the parser and run the tests."], in: app),
            "a refused usage read emptied the conversation",
        )
    }

    /// What belongs to one session does not follow the operator to the next.
    ///
    /// One view draws every session, and the parts of it that were not tagged
    /// with the session they were read for are drawn for whichever session is
    /// opened next: the composer kept the text typed for the last one — which
    /// could then be sent to the wrong agent — and the conversation kept "this
    /// history has been paged to its end", so the new session's older messages
    /// could not be asked for at all.
    ///
    /// Asserted where both columns are on screen at once, which is where the
    /// detail view survives a change of selection. On a phone the conversation is
    /// pushed over the list and popping it destroys the view — and the state with
    /// it — so there is nothing here to break, and a test that pretended
    /// otherwise would pass with the bug present.
    func testSwitchingSessionsDoesNotCarryTheOtherOnesState() throws {
        // Nothing running, so no Live Activity is posted: this is a test about
        // two conversations, and the widget extension is a second process that
        // has nothing to do with either of them.
        let app = launch(session: nil, pending: false, running: false)

        // The first session, opened the way an operator opens one: the workspace
        // it is filed under, then the row.
        // By identifier, never by label: the workspace's own title is interface
        // copy and follows the device's language, while a session's title is the
        // host's data and does not.
        let demo = app.buttons["workspace./Users/you/projects/demo"]
        expect(demo, "the host's first workspace is missing")
        let first = sessionRow(in: app, titled: "Mock session", in: "demo")
        XCTAssertTrue(
            expand(demo, revealing: first),
            "the first session never appeared under its workspace",
        )
        first.tap()
        let field = app.textViews["composer.field"]
        expect(field, "the first conversation never opened")

        // Something typed and never sent, and a history that has been paged to
        // its end, so the row that asks for older messages goes away by itself.
        field.tap()
        field.typeText("half a thought for the first session")
        XCTAssertEqual(field.value as? String, "half a thought for the first session")

        let loadOlder = app.buttons["conversation.loadOlder"]
        // The page asks for history when the row that asks is on screen, and
        // the conversation opens at its newest message -- the row is above the
        // fold until someone reads back. Scroll up the way that someone would,
        // and the row reports the end of the history by going away.
        // Drawn on the window rather than on `app.scrollViews.firstMatch`,
        // which matches the sidebar's own list -- off screen on a phone, and
        // still the first in the hierarchy. Downwards is towards older
        // messages.
        let window = app.windows.firstMatch
        for _ in 0..<3 {
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
                .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)))
        }
        let exhausted = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: loadOlder,
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [exhausted], timeout: Self.patience),
            .completed,
            "the first session never reported its history as paged to the end",
        )

        // Back to the list. On a phone it is under the conversation and comes
        // out from the toggle; on an iPad it never left. The conversation view
        // now survives the change of session on both -- only its identity
        // changes -- which is what makes this a real test of that identity.
        openSidebar(app)
        expect(demo, "the session list never came back")

        // The second session, which has a conversation of its own — different
        // prompt, different answer, and older history still to fetch.
        let orphanGroup = app.buttons["workspace.not-in-a-workspace"]
        let orphanRow = sessionRow(in: app, titled: "Orphan session", in: "deleted-workspace")
        XCTAssertTrue(
            expand(orphanGroup, revealing: orphanRow),
            "the second session never appeared under its heading",
        )
        orphanRow.tap()
        expect(app.textViews["composer.field"], "the second conversation never opened")

        XCTAssertEqual(
            app.textViews["composer.field"].value as? String,
            "",
            "the first session's draft followed the operator into the second",
        )
        XCTAssertTrue(
            app.staticTexts["Older history from the other session."]
                .waitForExistence(timeout: Self.patience),
            "the second session's older page was never asked for: its paging state belonged to the first session",
        )
    }

}
