//
//  AppFlowNavigationTests.swift
//  DSH-MizarUITests
//
//  Methods moved verbatim from AppFlowTests.swift (navigation / pickers / two computers / home).
//

import XCTest

final class AppFlowNavigationTests: AppFlowTestBase {
    /// This class's own mock-host pair, from the MockPorts table.
    override class var mockPort: Int { MockPorts.port(for: String(describing: self)) }
    /// The sidebar comes and goes: from the toggle, from a drag, from a tap on
    /// the conversation pushed aside, and by itself when a session is chosen.
    ///
    /// Opened by tapping, not by `-mizarSelectSession`. The launch argument sets
    /// the selection directly, so a test that used it would be measuring a
    /// screen the operator cannot reach that way.
    func testTheSidebarOpensAndCloses() {
        let app = launch(session: nil)
        // A launch opens on the app's own page; the list is one tap away.
        let newSession = app.buttons["sessions.new"]
        XCTAssertFalse(newSession.isHittable, "the sidebar opened on a launch with nothing selected")
        openSidebar(app)
        expect(newSession, "the sidebar did not open from its button")
        XCTAssertEqual(app.tabBars.count, 0, "a tab bar is still drawn")

        // Choosing a session puts the list away.
        let demo = app.buttons["workspace./Users/you/projects/demo"]
        let row = sessionRow(in: app, titled: "Mock session", in: "demo")
        XCTAssertTrue(expand(demo, revealing: row), "the session never appeared under its workspace")
        row.tap()
        // The one-time naming prompt is anchored to the sidebar button and is
        // offered when the drawer closes on the conversation -- after `launch`
        // already looked for it. Answer it here, or it covers the screen.
        dismissNamingIfPresented(app)
        // The conversation's own refresh button, not the composer field: a
        // pending approval docks over the composer, and this test is about the
        // drawer, not about that card.
        expect(app.buttons["session.refresh"], "the conversation never opened")
        XCTAssertFalse(
            app.descendants(matching: .any)["session.placement.failed"].exists,
            "the conversation could not be positioned",
        )
        XCTAssertTrue(sidebar(newSession, isOut: false), "the sidebar stayed out over the conversation")

        // The toggle brings it back, and a tap on the conversation beside it
        // puts it away again.
        openSidebar(app)
        let dismiss = app.buttons["shell.dismissSidebar"]
        expect(dismiss, "the conversation pushed aside cannot be tapped to come back")
        dismiss.tap()
        XCTAssertTrue(sidebar(newSession, isOut: false), "tapping the conversation did not bring it back")

        // A slow sideways drag across the conversation opens it too. Decided on
        // distance, not speed: a drag in a test is slow.
        //
        // One drag, not a retry. The retry this test used to have was hiding the
        // exact bug the deferred axis lock in SidebarPan.swift fixes: a drag
        // that started with a little vertical travel was failed for the whole
        // touch, and the second attempt is what made the test green.
        Thread.sleep(forTimeInterval: 0.4)
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.45))
        let finish = app.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.47))
        start.press(forDuration: 0.05, thenDragTo: finish)
        XCTAssertTrue(sidebar(newSession, isOut: true), "a sideways drag did not open the sidebar")
    }

    /// A drawer swipe still works when the finger travels diagonally, and the
    /// open drawer can be put away by the reverse swipe.
    ///
    /// The first drag deliberately moves 260 pt down while it moves 320 pt
    /// across. The old recognizer required the first movement to be horizontal
    /// by 1.5:1 and failed the touch otherwise; this one waits for the axis to
    /// become clear, so the diagonal still ends as a horizontal drawer drag.
    func testTheDrawersTakeDiagonalAndReverseSwipes() {
        // Select the fixture by tapping it, the way the other drawer test does:
        // `-mizarSelectSession` races the first session-list read on a loaded
        // simulator, and this test is about the drag, not about that race.
        let app = launch(session: nil, pending: false)
        let demo = app.buttons["workspace./Users/you/projects/demo"]
        let row = sessionRow(in: app, titled: "Mock session", in: "demo")
        XCTAssertTrue(expand(demo, revealing: row), "the session never appeared")
        row.tap()
        expect(app.textViews["composer.field"], "the conversation never opened")
        Thread.sleep(forTimeInterval: 0.5)

        let newSession = app.buttons["sessions.new"]
        let right = (start: CGVector(dx: 0.10, dy: 0.30), finish: CGVector(dx: 0.90, dy: 0.60))
        app.coordinate(withNormalizedOffset: right.start)
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: right.finish))
        expect(newSession, "a diagonal rightward drag did not open the sidebar")

        let left = (start: CGVector(dx: 0.90, dy: 0.55), finish: CGVector(dx: 0.10, dy: 0.35))
        app.coordinate(withNormalizedOffset: left.start)
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: left.finish))
        let gone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false OR hittable == false"),
            object: newSession,
        )
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: Self.patience), .completed,
                       "a diagonal leftward drag did not close the sidebar")

        // The mirror. The index is only available in a conversation.
        let indexStart = CGVector(dx: 0.90, dy: 0.30)
        let indexFinish = CGVector(dx: 0.10, dy: 0.55)
        app.coordinate(withNormalizedOffset: indexStart)
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: indexFinish))
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "turnIndex.entry."))
        expect(rows.firstMatch, "a diagonal leftward drag did not open the turn index")
    }

    /// Non-visual performance loop. Real XCUI drags exercise DrawerPanRecognizer;
    /// metric results are simulator observations, never a physical-device FPS claim.
    @available(iOS 26.0, *)
    func testDrawerGesturePerformanceOffline() {
        let app = launch(pending: false, running: false)
        let markdownFixture = ProcessInfo.processInfo.environment["MIZAR_PERF_MARKDOWN_FIXTURE"] == "1"
        let fixture = DispatchSemaphore(value: 0)
        let fixtureQuery = markdownFixture ? "long=1&markdown=1" : "long=1"
        final class FixtureResult: @unchecked Sendable {
            private let lock = NSLock()
            private var succeeded = false
            func set(_ value: Bool) { lock.withLock { succeeded = value } }
            func get() -> Bool { lock.withLock { succeeded } }
        }
        let fixtureResult = FixtureResult()
        let request = URLSession.shared.dataTask(with: URL(string: "http://127.0.0.1:\(Self.mockPort)/reader?\(fixtureQuery)")!) { _, response, error in
            fixtureResult.set(error == nil && (response as? HTTPURLResponse)?.statusCode == 200)
            fixture.signal()
        }
        request.resume()
        guard fixture.wait(timeout: .now() + 5) == .success, fixtureResult.get() else {
            request.cancel()
            XCTFail("Performance fixture request timed out or did not return HTTP 200")
            return
        }
        app.terminate()
        app.launch()
        let editor = app.textViews["composer.field"]
        let anchor = app.staticTexts["turn.24.usage"]
        let latest = app.buttons["conversation.jumpToLatest"]
        let sidebar = app.buttons["sessions.new"]
        let index = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "turnIndex.entry.")).firstMatch
        let drawerDismiss = app.buttons["shell.dismissSidebar"]
        let dismiss = app.buttons["composer.dismissKeyboard"]
        func diagnose(_ phase: String) {
            print("[sidebar-perf-invalid] phase=\(phase) keyboard=\(app.keyboards.firstMatch.exists) anchorExists=\(anchor.exists) jumpExists=\(latest.exists) drawerDismissExists=\(drawerDismiss.exists) drawerDismissHittable=\(drawerDismiss.isHittable) leftHittable=\(sidebar.isHittable) rightHittable=\(index.isHittable) dismissExists=\(dismiss.exists) dismissHittable=\(dismiss.isHittable) editorExists=\(editor.exists) editorHittable=\(editor.isHittable)")
            // One bounded textual tree, no screenshot; only this offline fixture.
            print(String(app.debugDescription.prefix(18000)))
        }
        func require(_ condition: Bool, _ phase: String) -> Bool {
            guard condition else {
                diagnose(phase)
                XCTFail("Invalid performance setup: \(phase)")
                return false
            }
            return true
        }
        func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 8) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            repeat {
                if condition() { return true }
                Thread.sleep(forTimeInterval: 0.25)
            } while Date() < deadline
            return false
        }
        func phase(_ name: String) {
            let frame = anchor.exists ? anchor.frame : .zero
            print("[sidebar-perf-phase] \(name) anchorExists=\(anchor.exists) hittable=\(anchor.isHittable) y=\(frame.midY) height=\(frame.height) jump=\(latest.exists) drawerDismissExists=\(drawerDismiss.exists) drawerDismissHittable=\(drawerDismiss.isHittable) leftHittable=\(sidebar.isHittable) rightHittable=\(index.isHittable) dismissExists=\(dismiss.exists) dismissHittable=\(dismiss.isHittable) editorExists=\(editor.exists) editorHittable=\(editor.isHittable)")
        }
        guard require(editor.waitForExistence(timeout: Self.patience), "composer-ready") else { return }
        phase("beforeDrawerNormalize")
        if drawerDismiss.exists, drawerDismiss.isHittable {
            drawerDismiss.tap()
        }
        // "Normalized" means no drawer can be tapped, not that its catcher was
        // removed from the tree: the catcher can exist while the drawer is shut.
        // The card's dismiss catcher can remain in the tree (and even hittable)
        // while the drawer is shut; what "normalized" means here is that neither
        // drawer is on screen.
        guard require(waitUntil {
            !sidebar.isHittable && !index.isHittable
        }, "drawers-normalized") else { return }
        phase("afterDrawerNormalize")
        phase("beforeDismiss")
        if app.keyboards.firstMatch.exists {
            if !dismiss.isHittable {
                phase("beforeComposerFocus")
                guard require(waitUntil({ editor.isHittable }, timeout: 5), "composer-focus-editor") else { return }
                editor.tap()
                phase("afterComposerFocus")
            }
            guard require(waitUntil({ dismiss.exists && dismiss.isHittable }, timeout: 5), "dismiss-button") else { return }
            dismiss.tap()
        }
        guard require(waitUntil {
            !app.keyboards.firstMatch.exists && !dismiss.exists
        }, "keyboard-and-dismiss-hidden") else { return }
        phase("afterDismiss")
        func positionLatest(_ name: String) -> CGRect? {
            // Collapse can change height. Allow the existing jump control to arrive,
            // but never scroll blindly or treat absence as proof of latest position.
            guard require(waitUntil {
                (anchor.exists && anchor.isHittable) || (latest.exists && latest.isHittable)
            }, "\(name)-latest-control-or-anchor") else { return nil }
            if latest.exists && latest.isHittable { latest.tap() }
            guard require(waitUntil {
                anchor.exists && anchor.isHittable && anchor.frame.height > 0 && app.frame.intersects(anchor.frame)
                    && !app.otherElements["session.placement.failed"].exists
            }, "\(name)-visible-anchor") else { return nil }
            let initial = anchor.frame
            for _ in 0..<3 {
                Thread.sleep(forTimeInterval: 0.5)
                guard require(anchor.exists && anchor.isHittable && abs(anchor.frame.midY - initial.midY) <= 0.5,
                              "\(name)-stable-anchor") else { return nil }
            }
            guard require(!app.keyboards.firstMatch.exists, "\(name)-keyboard-hidden") else { return nil }
            phase(name)
            return anchor.frame
        }
        guard positionLatest("afterLatest") != nil else { return }

        func drag(_ from: CGFloat, _ to: CGFloat) {
            app.coordinate(withNormalizedOffset: CGVector(dx: from, dy: 0.42))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: to, dy: 0.42)))
            // Identical settling allowance in every baseline/candidate. No AX polling
            // during the measured cycle: accessibility snapshots themselves cost CPU.
            // Long enough for the drawer spring to finish before the next drag; the
            // cold-launch shell starts closed and the first open/close pair runs
            // sooner than it used to.
            Thread.sleep(forTimeInterval: 1.0)
        }
        @discardableResult func cycle(prove: Bool) -> Bool {
            drag(0.10, 0.90)
            if prove && !require(sidebar.isHittable, "left-open") { return false }
            drag(0.90, 0.10)
            if prove && !require(!sidebar.isHittable, "left-close") { return false }
            drag(0.90, 0.10)
            if prove && !require(index.isHittable, "right-open") { return false }
            drag(0.10, 0.90)
            if prove && !require(!index.isHittable, "right-close") { return false }
            return true
        }
        phase("beforeWarmProof")
        guard cycle(prove: true) else { return }
        phase("afterWarmProof")
        guard let initialAnchor = positionLatest("preMeasure") else { return }
        print("[sidebar-perf-setup] latestAnchorY=\(initialAnchor.midY) height=\(initialAnchor.height) screenHeight=\(app.frame.height)")
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: [XCTHitchMetric(application: app), XCTCPUMetric(application: app), XCTClockMetric()], options: options) {
            cycle(prove: false)
        }
        phase("afterMeasure")
        guard require(anchor.exists && anchor.isHittable && abs(anchor.frame.midY - initialAnchor.midY) <= 2,
                      "measured-anchor-delta") else { return }
        phase("beforePostProof")
        guard cycle(prove: true) else { return }
        phase("afterPostProof")
        guard require(editor.exists && !app.keyboards.firstMatch.exists, "final-editor-and-keyboard") else { return }
        guard require(anchor.exists && anchor.isHittable && abs(anchor.frame.midY - initialAnchor.midY) <= 2,
                      "postproof-anchor-delta") else { return }
        print("[sidebar-perf] markdownFixture=\(markdownFixture) fixed24turns warmup=1 measuredCycles=3 dragsPerCycle=4 settleSeconds=0.65 finalAnchorDelta=\(anchor.frame.midY - initialAnchor.midY)")
    }

    // MARK: - Model and permission switching

    func testTheModelPickerListsTheHostsProviders() {
        let app = launch()
        let opener = app.buttons["composer.model"]
        expect(opener, "there is no way to change the model")
        opener.tap()

        // Rows are buttons, not static text: the row carries an identifier, and
        // an identifier makes the row one accessibility element with its label
        // and description merged, so the inner Text is not separately visible.
        expect(app.buttons["model.row.deepseek-flash"], "the first model is missing")
        expect(app.buttons["model.row.deepseek-v4-pro"], "the second model is missing")
        // The provider heading is a standalone element, so it is still text.
        expect(app.staticTexts["DeepSeek"], "the provider is missing from the picker")

        // A provider that could not be listed is shown rather than hidden: its
        // models being absent is information. It sits below the models.
        app.swipeUp()
        expect(app.staticTexts["OpenRouter"], "an unavailable provider was hidden")
    }

    func testChoosingAModelRevealsItsReasoningLevels() {
        let app = launch()
        app.buttons["composer.model"].tap()
        let model = app.buttons["model.row.deepseek-flash"]
        expect(model, "the model row is missing")
        model.tap()
        // The four levels the host actually offers. The picker must not invent
        // its own, and must not offer a level the model rejects.
        expect(app.buttons["Off"], "the reasoning levels were not revealed")
        expect(app.buttons["Max"], "the highest reasoning level is missing")
    }

    func testThePermissionPickerWarnsBeforeFullAccess() {
        let app = launch()
        let opener = app.buttons["session.permissions"]
        expect(opener, "there is no way to change the permission preset")
        opener.tap()
        expect(app.buttons["permission.row.workspace-write"], "the presets are missing")

        // Only full access asks twice. A preset that grants unrestricted access
        // to the machine should not be one tap away.
        app.buttons["permission.row.danger-full-access"].tap()
        expect(app.staticTexts["Allow full access?"], "full access was granted without confirmation")
    }

    /// A model switch the host refused does not stay on screen as applied.
    ///
    /// The choice was written down *before* the call and the call's failure was
    /// swallowed, and the host has no "what is this session using" read on this
    /// side of the protocol -- so the tick drawn for a refused switch was the
    /// only answer there was, and it was wrong for the life of the process. Every
    /// `session.model.set` on the fixture fails to decode, which is why nothing
    /// noticed.
    ///
    /// Both halves are asserted, because either one alone is a smaller bug than
    /// the one reported: the picker goes back to the model that is actually in
    /// force, and it says why the switch did not happen.
    func testARefusedModelSwitchGoesBackAndSaysSo() {
        // Opened by tapping rather than by `-mizarSelectSession`. That argument
        // selects the host's *first* session, which is a different session the
        // moment the fixture's list changes, and this test is about one named
        // session's model. Tapping the row is also the path an operator takes.
        let app = launch(session: nil, pending: false)
        let demo = app.buttons["workspace./Users/you/projects/demo"]
        expect(demo, "the host's first workspace is missing")
        var opened = false
        for _ in 0..<3 where !opened {
            let row = sessionRow(in: app, titled: "Mock session", in: "demo")
            _ = expand(demo, revealing: row)
            guard row.exists, row.isHittable else { continue }
            row.tap()
            opened = app.buttons["composer.model"].waitForExistence(timeout: 10)
        }
        XCTAssertTrue(opened, "the conversation never opened")

        // Re-queried rather than held in a `let`: a sheet coming and going
        // rebuilds the hierarchy under it, and an element captured before that is
        // a stale reference the second tap goes nowhere with.
        app.buttons["composer.model"].tap()
        XCTAssertTrue(
            app.buttons["model.row.deepseek-flash"].waitForExistence(timeout: Self.patience),
            "the picker did not open",
        )

        // A switch the host takes, so that the refusal below is a change from
        // something and the value it goes back to is one the app has agreed with
        // rather than one a test assumed. `deepseek-flash` has reasoning levels,
        // so this commits `Off`, and a taken switch closes the picker.
        app.buttons["model.row.deepseek-flash"].tap()
        expect(app.buttons["Off"], "the reasoning levels were not revealed")
        app.buttons["Off"].tap()
        XCTAssertTrue(
            waitForDisappearance(app.buttons["model.row.deepseek-flash"], timeout: Self.patience),
            "the picker stayed open over a switch the host accepted",
        )

        // Reopened: this is what is in force, said by the screen. It is also the
        // value the refusal below has to put back.
        app.buttons["composer.model"].tap()
        XCTAssertTrue(
            app.staticTexts["model.current.deepseek-flash"].waitForExistence(timeout: Self.patience),
            "the picker does not say which model is in force",
        )

        // From here the host refuses the switch, and answers everything else.
        XCTAssertTrue(Self.failMockHost("session.model.set"), "the mock did not take the refusal knob")

        // The refusal is driven through the reasoning-level control rather than
        // by tapping the model's own row, and that is about the test rather than
        // the app: a `List` row's button is not reliably hittable once the picker
        // has been closed and reopened under XCUITest, while the segmented
        // control is. What it exercises is the same `commit`, the same
        // `setModel`, and the same failure.
        // `Off`, not `High`: the second model already defaults to `High`, and a
        // segmented control whose selection does not change does not call its
        // binding -- so a tap on the level already in force commits nothing.
        app.buttons["model.row.deepseek-v4-pro"].tap()
        expect(app.buttons["Off"], "the second model's levels were not revealed")
        app.buttons["Off"].tap()

        XCTAssertTrue(
            labelled("model.error", in: app, contains: "failed on purpose")
                .waitForExistence(timeout: Self.patience),
            "a refused model switch was not reported at all",
        )
        // Back to the model that is actually in force. The picker did not close
        // over the refusal, so the operator is looking at the answer.
        XCTAssertTrue(
            app.staticTexts["model.current.deepseek-flash"].waitForExistence(timeout: 5),
            "the picker kept showing a model the host had refused, as though it were in force",
        )
        XCTAssertFalse(
            app.staticTexts["model.current.deepseek-v4-pro"].exists,
            "the refused model is still the one the picker says is in force",
        )
    }

    /// What belongs to one computer does not follow the operator to the next.
    ///
    /// The app keeps the model and permission catalogues, the pending
    /// interactions and the recent host events for the machine it is talking to,
    /// and none of them were dropped when the machine changed. The catalogues are
    /// the visible half: they are read once per *connection* and never re-read,
    /// so a phone that switches computers draws the first computer's models in the second
    /// computer's picker -- and the two mocks disagree about what they offer, which is
    /// the only way that is observable.
    ///
    /// Two hosts, deliberately: one mock answers every read with the same
    /// providers, the same sessions and the same host id, so a screen drawn from
    /// the wrong computer's answer looks exactly like a screen drawn from the right
    /// one. The shared second-machine mock (19396) is a different machine.
    func testSwitchingcomputersDoesNotCarryTheFirstcomputersCatalog() {
        Self.resetSecondMockHost()
        let app = launch(
            session: nil,
            pending: false,
            running: false,
            pairingURIs: [Self.mockPairingURI, Self.secondMockPairingURI],
        )
        // The second computer is the one open: the last pairing is the current one.
        // Its name lives in the sidebar, which a cold launch leaves closed.
        openSidebar(app)
        if !app.staticTexts["Mock Mac (second)"].waitForExistence(timeout: Self.patience) {
            let dump = app.staticTexts.allElementsBoundByIndex.prefix(25)
                .map { $0.identifier.isEmpty ? "<no id>" : $0.identifier }
            XCTFail("the second computer was not the one opened; screen says: \(dump)")
        }

        // The picker is inside a conversation, so one is opened first. Read the
        // second computer's catalogue into the app by opening the picker that asks for
        // it -- which is what makes the catalogue a *cached* value rather than
        // one fetched on demand, and the value the switch below must not carry.
        let demo = app.buttons["workspace./Users/you/projects/demo"]
        expect(demo, "the second computer's first workspace is missing")
        let secondRow = sessionRow(in: app, titled: "Mock session", in: "demo")
        XCTAssertTrue(expand(demo, revealing: secondRow), "the second computer's session never appeared")
        secondRow.tap()
        let opener = app.buttons["composer.model"]
        expect(opener, "the second computer's conversation never opened")
        opener.tap()
        XCTAssertTrue(
            app.buttons["model.row.kimi-k2"].waitForExistence(timeout: Self.patience),
            "the second computer's own catalogue is missing",
        )
        app.navigationBars.buttons["Done"].tap()
        expect(app.buttons["composer.model"], "the picker never closed")

        // Back to the list, and to the first computer.
        openSidebar(app)
        expect(app.buttons["sessions.hosts"], "the session list never came back")
        app.buttons["sessions.hosts"].tap()
        let first = app.buttons["host.row.mock-host-0000-4000-8000-000000000000"]
        expect(first, "the first computer is not in the list")
        first.tap()
        // Choosing a machine opens it, and the list of machines puts itself
        // away once the switch has landed.
        closeHosts(app)
        expect(app.buttons["sessions.hosts"], "the first computer's session list never arrived")

        // A conversation on the first computer, so its picker -- and therefore its
        // catalogue -- is reachable. Opening the picker is what asks for it.
        let firstDemo = app.buttons["workspace./Users/you/projects/demo"]
        expect(firstDemo, "the first computer's first workspace is missing")
        let firstRow = sessionRow(in: app, titled: "Mock session", in: "demo")
        XCTAssertTrue(expand(firstDemo, revealing: firstRow), "the first computer's session never appeared")
        firstRow.tap()
        expect(app.buttons["composer.model"], "the first computer's conversation never opened")
        app.buttons["composer.model"].tap()
        XCTAssertTrue(
            app.buttons["model.row.deepseek-flash"].waitForExistence(timeout: Self.patience),
            "the first computer's catalogue is missing",
        )
        XCTAssertFalse(
            app.buttons["model.row.kimi-k2"].exists,
            "the second computer's models are still offered under the first computer",
        )
    }

    /// The phone reopens the computer the operator last chose, not the one paired last.
    ///
    /// With two computers paired, the launch path used to open the most recently
    /// paired machine whatever the operator had been using: the app looked
    /// connected, but its session list, its approvals, its notifications and its
    /// Live Activity belonged to the other computer. Being paired is not the same as
    /// being chosen, and the difference is visible on the first screen.
    func testTheLastOpenedMacIsTheOneReopened() {
        Self.resetSecondMockHost()
        let app = launch(
            session: nil,
            pending: false,
            running: false,
            pairingURIs: [Self.mockPairingURI, Self.secondMockPairingURI],
        )
        // The second computer was paired last, so this first launch legitimately
        // opens it: with no choice recorded yet, "the machine given most
        // recently" is the only answer the phone has. Its name is in the
        // sidebar, which a cold launch leaves closed.
        openSidebar(app)
        XCTAssertTrue(
            app.staticTexts["Mock Mac (second)"].waitForExistence(timeout: Self.patience),
            "the launch did not open the most recently paired computer",
        )

        // Now choose the other one, exactly as the operator would.
        expect(app.buttons["sessions.hosts"], "the session list never came back")
        app.buttons["sessions.hosts"].tap()
        let first = app.buttons["host.row.mock-host-0000-4000-8000-000000000000"]
        expect(first, "the first computer is not in the list")
        first.tap()
        closeHosts(app)
        XCTAssertTrue(
            app.staticTexts["Mock Mac (fixture)"].waitForExistence(timeout: Self.patience),
            "choosing the first computer did not open it",
        )

        // A new process, no pairing arguments: what the app opens is what it
        // remembered, which is the whole question.
        app.terminate()
        let reopened = XCUIApplication()
        reopened.launchArguments = Self.arguments(
            pairing: false,
            session: nil,
            language: "en",
            freshStart: false,
        )
        reopened.launch()
        // A cold launch opens on the app's page; the chosen computer's name is
        // in the sidebar, which is one tap away.
        openSidebar(reopened)
        XCTAssertTrue(
            reopened.staticTexts["Mock Mac (fixture)"].waitForExistence(timeout: Self.patience),
            "the relaunch opened a computer other than the one the operator last chose",
        )
        XCTAssertFalse(
            reopened.staticTexts["Mock Mac (second)"].exists,
            "the relaunch kept the computer paired last instead of the one last chosen",
        )
    }

    /// A send during a reload is one load on the socket, not two.
    ///
    /// `reload()` is the screen's load-bearing gate: it documents that two
    /// overlapping loads interleave on one socket, each one's failed request
    /// reconnecting out from under the other. The poll after a send went around
    /// it, so a message sent while the screen was reloading made exactly that
    /// pair -- and produced a fresh WebSocket every few seconds on the machine
    /// this was reported from.
    ///
    /// Counted at the host rather than asserted on screen: both loads are
    /// answered correctly and the conversation that settles is the same one, so
    /// the overlap itself is the whole of the defect and only the host can see it.
    func testASendDuringAReloadDoesNotStartASecondLoad() {
        let app = launch(pending: false, running: false)
        let field = app.textViews["composer.field"]
        expect(field, "the conversation never opened")
        expect(app.staticTexts["The parser is now two files."], "the conversation never arrived")

        // Held rather than stalled, for both halves of the arrangement. The
        // reload's conversation read waits at the host until this test lets it
        // go, and the send's prompt is held long enough that the poll following
        // it starts *while* that read is still waiting -- which is the overlap
        // under test, arranged rather than raced for. A delay long enough to be
        // measured on a loaded machine is a delay long enough for the other half
        // to have finished first, and this suite has already been bitten by a
        // test that measured the clock instead of the app.
        Self.holdMockConversationReads(true)
        Self.stallMockHost(3_000, method: "session.prompt")
        // From here, whatever the host has already answered is not counted.
        XCTAssertEqual(Self.mockLoads()?.inFlight, 0, "a conversation read was already in flight")

        // The reload, stopped at the host on its conversation read.
        let refresh = app.buttons["session.refresh"]
        expect(refresh, "there is no way to refresh the conversation")
        refresh.tap()

        // Then the send, which is accepted immediately and whose own refresh
        // starts three seconds later -- with the reload still in flight, because
        // this read has not been released.
        field.tap()
        field.typeText("Count the loads")
        app.buttons["composer.send"].tap()

        // Long enough for the delayed answer to arrive and for the poll after it
        // to have made its first read, if it is going to make one. Nothing about
        // this wait is what the assertion measures: the reload's read is held
        // either way, and the send's has either happened by now or never will.
        Thread.sleep(forTimeInterval: 5)
        XCTAssertFalse(refresh.isEnabled, "the reload finished, so nothing overlapped after all")

        // Let the reload finish, and the screen settle on the conversation.
        XCTAssertNotNil(Self.holdMockConversationReads(false), "the host was not holding a read")
        XCTAssertTrue(
            reveal(app.staticTexts["Count the loads"], in: app),
            "the sent message never came back from the host",
        )

        XCTAssertEqual(
            Self.mockLoads()?.peak,
            1,
            "the host was answering two conversation reads at once: the send's poll went around the screen's reload gate",
        )
    }

    // MARK: - Localisation

    /// Composer titles and the failure card have zh/en goldens in snapshots;
    /// the TextField placeholder is UIKit-backed (it does not follow the render
    /// locale in ImageRenderer) so this test keeps asserting that half.
    func testInterfaceFollowsTheLanguageAndContentDoesNot() {
        let chinese = launch(language: "zh-Hans", pending: false)
        // Scrolled back to: the failure card belongs to the second turn, and the
        // conversation opens on its newest one.
        let failure = chinese.staticTexts["本轮没有产生回复"]
        XCTAssertTrue(reveal(failure, in: chinese), "the failure card did not translate")
        // The composer's placeholder, which is interface copy. This used to
        // assert on the "对话" segmented control; that control is gone, and the
        // placeholder is the localised string nearest the same place on screen.
        // Put the keyboard away first: a focused empty field reports an empty
        // value instead of its placeholder.
        if chinese.keyboards.firstMatch.exists {
            let dismissKeyboard = chinese.buttons["composer.dismissKeyboard"]
            if dismissKeyboard.exists, dismissKeyboard.isHittable { dismissKeyboard.tap() }
        }
        XCTAssertEqual(
            chinese.textViews["composer.field"].value as? String,
            "给 agent 发消息…",
            "the interface did not follow Chinese",
        )
        // Message content is data from the session, not interface copy.
        let prompt = chinese.staticTexts["Refactor the parser and run the tests."]
        XCTAssertTrue(reveal(prompt, in: chinese), "message content was translated")
        // The command sheet's names are the app's words; the slash forms beside
        // them are what the host parses and stay exactly as they are.
        chinese.buttons["composer.commands"].tap()
        let chineseGoal = chinese.buttons["command.goal"]
        expect(chineseGoal, "the command list did not open")
        XCTAssertTrue(
            chineseGoal.label.contains("目标"),
            "the command name did not translate: \(chineseGoal.label)",
        )
        chinese.terminate()

        let english = launch(language: "en", pending: false)
        let englishFailure = english.staticTexts["The turn ended without a response"]
        XCTAssertTrue(reveal(englishFailure, in: english), "the failure card did not translate")
        XCTAssertEqual(
            english.textViews["composer.field"].value as? String,
            "Ask your agent…",
            "the interface did not follow English",
        )
        english.buttons["composer.commands"].tap()
        let englishGoal = english.buttons["command.goal"]
        expect(englishGoal, "the command list did not open in English")
        XCTAssertTrue(
            englishGoal.label.contains("Goal"),
            "the command name is not English: \(englishGoal.label)",
        )
    }

    // MARK: - Redesign

    /// The requests dock above the composer and tuck into a pill while the
    /// operator types, so the field has the room; the pill brings them back.
    func testTheDockTucksAwayWhileTyping() {
        let app = launch()
        let allow = app.buttons["approval.allowOnce"]
        expect(allow, "the pending approval is not docked above the composer")
        let field = app.textViews["composer.field"]
        expect(field, "the composer is missing")
        // Docked means above the composer, on screen, without a scroll.
        XCTAssertLessThan(allow.frame.maxY, field.frame.minY, "the approval is not above the composer")
        XCTAssertTrue(allow.isHittable, "the docked approval is not on screen")

        field.tap()
        let tucked = app.buttons["interactions.tucked"]
        expect(tucked, "typing did not tuck the requests away")
        XCTAssertFalse(allow.exists && allow.isHittable, "the full card stayed up while typing")

        tucked.tap()
        expect(app.buttons["approval.allowOnce"], "the pill did not bring the requests back")
    }

    /// The workspace holding the session on screen opens by itself, so the
    /// sidebar always says where the operator is.
    func testTheOpenSessionsWorkspaceIsExpanded() {
        let app = launch(pending: false)
        expect(app.textViews["composer.field"], "the session never opened")
        openSidebar(app)
        let row = sessionRow(in: app, titled: "Mock session", in: "demo")
        XCTAssertTrue(row.waitForExistence(timeout: Self.patience), "the open session's workspace stayed folded")
        // And the others stay as they were: folded.
        XCTAssertFalse(
            sessionRow(in: app, titled: "Orphan session", in: "deleted-workspace").exists,
            "a workspace that holds nothing open was unfolded too",
        )
    }

    // MARK: - Turn index and small windows

    /// The turn index comes out on the right by a drag to the left, and a turn
    /// chosen there is shown in the conversation, with the index put away.
    func testTheTurnIndexOpensByADragAndJumps() {
        let app = launch(pending: false)
        let field = app.textViews["composer.field"]
        expect(field, "the conversation never opened")
        Thread.sleep(forTimeInterval: 1)

        // Mirrored from the sidebar's drag: right to left across the conversation.
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.45))
        let finish = app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.47))
        start.press(forDuration: 0.05, thenDragTo: finish)

        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "turnIndex.entry."))
        let first = rows.firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: Self.patience), "a leftward drag did not open the turn index")
        XCTAssertEqual(rows.count, 4, "the index does not list every turn of the session")
        // The sidebar is the other drawer, and it stays put away.
        XCTAssertFalse(app.buttons["sessions.new"].isHittable, "the sidebar came out instead of the index")

        first.tap()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false OR hittable == false"), object: first)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: Self.patience), .completed, "choosing a turn did not put the index away")
        // The first turn's prompt is on screen again, above the composer.
        let prompt = app.staticTexts["Refactor the parser and run the tests."]
        XCTAssertTrue(prompt.waitForExistence(timeout: Self.patience), "the chosen turn was not shown")
        XCTAssertTrue(prompt.isHittable, "the conversation did not scroll to the chosen turn")
    }

    /// A far turn chosen in the index arrives directly, without travelling the
    /// whole conversation first. The reader fixture has 24 turns; opening its
    /// index at the bottom and choosing turn 1 used to run the staged travel.
    func testTheTurnIndexJumpsDirectlyToAFarTurn() {
        let app = launch(pending: false, running: false)
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(
            with: URL(string: "http://127.0.0.1:\(Self.mockPort)/reader?long=1")!,
        ) { _, _, _ in done.signal() }.resume()
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success, "the reader fixture did not answer")
        app.terminate()
        app.launch()
        expect(app.staticTexts["turn.24.usage"], "the long conversation did not open at its newest turn")

        let title = app.buttons["session.turnIndex"]
        expect(title, "the turn index is not reachable")
        title.tap()
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "turnIndex.entry."))
        let first = rows.firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: Self.patience), "the turn index never opened")

        first.tap()
        let prompt = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Reader prompt 1."),
        ).firstMatch
        XCTAssertTrue(
            prompt.waitForExistence(timeout: 2.5),
            "choosing a far turn did not show it within 2.5 s (a travel, not a jump)",
        )
        XCTAssertTrue(prompt.isHittable, "the chosen turn is not on screen")
    }

    /// Jumping between turns, over and over, must never wedge the screen.
    ///
    /// Reported as "tapping a turn sometimes freezes the app". The jump goes
    /// through `ScrollViewReader` into a lazy stack, so the two ways it can go
    /// wrong are a scroll to a row that was never built and a re-entrant update
    /// between the jump and the visibility bookkeeping. Twenty jumps, both
    /// directions, with a deadline on each: a screen that is still answering
    /// after that has neither.
    func testJumpingBetweenTurnsNeverWedges() {
        let app = launch(pending: false)
        expect(app.textViews["composer.field"], "the conversation never opened")
        Thread.sleep(forTimeInterval: 1)

        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.45))
        let finish = app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.47))
        start.press(forDuration: 0.05, thenDragTo: finish)

        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "turnIndex.entry."))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: Self.patience), "the turn index never opened")
        let count = rows.count
        XCTAssertGreaterThan(count, 1, "the fixture has no turns to jump between")

        for round in 0..<20 {
            let index = round % count
            let row = rows.element(boundBy: index)
            guard row.waitForExistence(timeout: Self.patience) else {
                XCTFail("the index stopped answering at round \(round)")
                return
            }
            row.tap()
            // The jump is done when the index is away and the conversation is
            // back. Five seconds is generous for a scroll; a screen that misses
            // it twice in a row is the freeze that was reported.
            let gone = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == false OR hittable == false"),
                object: row,
            )
            XCTAssertEqual(
                XCTWaiter().wait(for: [gone], timeout: 5),
                .completed,
                "jumping to turn \(index) did not put the index away (round \(round))",
            )
            // Re-open it the way the operator does, from the title, which is
            // the route that does not depend on where the conversation landed.
            let title = app.buttons["session.turnIndex"]
            guard title.waitForExistence(timeout: 5) else {
                XCTFail("the title stopped answering at round \(round)")
                return
            }
            title.tap()
        }
    }

    /// The session's title is a button that opens the same index.
    func testTheTitleOpensTheTurnIndex() {
        let app = launch(pending: false)
        let title = app.buttons["session.turnIndex"]
        expect(title, "the title is not a way to the turns")
        XCTAssertTrue(labelLands(title, containing: "4"), "the title does not say how many turns there are")
        title.tap()
        let panel = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "turnIndex.entry.")).firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: Self.patience), "tapping the title did not open the turn index")
        let dismiss = app.buttons["shell.dismissSidebar"]
        expect(dismiss, "the conversation pushed aside cannot be tapped to come back")
        dismiss.tap()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false OR hittable == false"), object: panel)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: Self.patience), .completed, "the index did not go away")
    }

    /// The connection capsule opens a window that says how the link is, how
    /// fast it is -- measured -- and what keeps the phone current.
    func testTheConnectionWindowMeasuresLatency() {
        let app = launch(session: nil, pending: false)
        openSidebar(app)
        let capsule = app.buttons["sidebar.connection"]
        expect(capsule, "there is no connection control")
        capsule.tap()
        expect(app.descendants(matching: .any)["connection.panel"], "the connection window did not open")
        let latency = app.staticTexts["connection.latency"]
        expect(latency, "the window does not report latency")
        // A local mock answers in well under 80 ms: once measured, it says so.
        XCTAssertTrue(labelLands(latency, containing: "Excellent"), "the latency was never measured")
        expect(app.descendants(matching: .any)["connection.poll"], "the window does not say what the poll is doing")
    }

    /// The computer's name is the way to another computer, in a small window.
    func testTheComputersNameOpensTheComputerPicker() {
        let app = launch(session: nil, pending: false)
        openSidebar(app)
        let name = app.buttons["sessions.hosts"]
        expect(name, "the computer's name is not a button")
        XCTAssertTrue(name.staticTexts["Mock Mac (fixture)"].exists, "the button is not the computer's name")
        name.tap()
        // The window no longer offers a code to scan: the account's computers
        // are listed directly, and the on-device agent is the first row.
        expect(app.buttons["host.row.local"], "the window does not offer the on-device agent")
        expect(app.buttons["host.row.mock-host-0000-4000-8000-000000000000"], "the paired computer is not listed")
    }

}
