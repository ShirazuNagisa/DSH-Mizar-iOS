//
//  AppFlowSessionDetailTests.swift
//  DSH-MizarUITests
//
//  Methods moved verbatim from AppFlowTests.swift (session detail reads).
//

import XCTest

final class AppFlowSessionDetailTests: AppFlowTestBase {
    /// This class's own mock-host pair, from the MockPorts table.
    override class var mockPort: Int { MockPorts.port(for: String(describing: self)) }
    // MARK: - Session detail

    /// A turn with a live state channel opens at the stream's bottom, not in
    /// the empty space below it.
    func testALiveStreamOpensAtTheNewestMessage() {
        let app = launch(pending: false, running: true, states: true)
        expect(app.staticTexts["And run the whole suite."], "the running prompt is missing")

        // The header is the stream's stable bottom edge: the clock is a
        // transient, and by the time a query settles the turn may have ended.
        let header = app.descendants(matching: .any)["conversation.stream.header"]
        expect(header, "the stream header is missing")
        XCTAssertTrue(app.frame.contains(header.frame), "the conversation opened below the stream")

        expect(app.staticTexts["我先看一下现有的实现。"], "the narration is missing")
    }

    /// The turn settles into the header, and the answer stays on screen rather
    /// than being pushed out by a re-typed paragraph.
    func testALiveStreamSettlesTheAnswer() {
        let app = launch(pending: false, running: true, states: true)
        let answer = app.staticTexts["三处都改完了，测试全绿。"]
        expect(answer, "the final answer is missing")

        let header = app.descendants(matching: .any)["conversation.stream.header"]
        expect(header, "the settled header is missing")
        // A settled turn says how long it took; "Completed" alone means the
        // stream never bound to the turn the history recorded.
        let timed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "Completed in"),
            object: header,
        )
        XCTAssertEqual(XCTWaiter.wait(for: [timed], timeout: 10), .completed, "the header has no duration")
        XCTAssertTrue(app.frame.contains(answer.frame), "the settled answer is below the fold")
    }

    /// A long streaming turn survives repeated fast scrolling.
    ///
    /// The reported freeze happened while scrolling a conversation whose stream
    /// was being typed: the answer is large, every body was a Markdown parse,
    /// and the scroll geometry makes the screen re-evaluate. This test drives
    /// the same shape -- a dozen narration blocks, a long final answer, and the
    /// typewriter still running -- through eight up/down pairs. A hang fails the
    /// next query rather than passing silently.
    func testALongLiveStreamSurvivesRepeatedScrolling() {
        let app = launch(pending: false, running: true, states: true, longStates: true)

        // The long final answer is arriving; keep scrolling while it types.
        // The prompt may already be above the viewport by then, so the answer's
        // own element is the stable anchor.
        let answer = app.descendants(matching: .any)["conversation.stream.answer"]
        expect(answer, "the long answer is missing")

        for _ in 0..<8 {
            app.swipeUp(velocity: .fast)
            app.swipeDown(velocity: .fast)
        }

        XCTAssertTrue(app.textViews["composer.field"].isHittable, "the screen stopped responding after scrolling")
    }

    /// Jumping between a long conversation and another one must always land
    /// on the long one's newest turn -- no blank below it, no visible twitch.
    ///
    /// The fixture is the reader conversation (24 turns, long bodies) and the
    /// orphan session next to it. The test switches back and forth three times
    /// and checks the newest turn is on screen after each open. A screenshot
    /// per arrival is attached for visual inspection.
    func testSwitchingLongSessionsAlwaysLandsOnTheNewestTurn() {
        let app = launch(pending: false, running: false)

        let fixture = DispatchSemaphore(value: 0)
        let request = URLSession.shared.dataTask(
            with: URL(string: "http://127.0.0.1:\(Self.mockPort)/reader?long=1")!,
        ) { _, _, _ in fixture.signal() }
        request.resume()
        XCTAssertEqual(fixture.wait(timeout: .now() + 5), .success, "the reader fixture did not load")
        app.terminate()
        app.launch()
        expect(app.staticTexts["turn.24.usage"], "the long conversation did not open at its newest turn")

        let demo = app.buttons["workspace./Users/you/projects/demo"]
        let mock = sessionRow(in: app, titled: "Mock session", in: "demo")
        let orphanGroup = app.buttons["workspace.not-in-a-workspace"]
        let orphan = sessionRow(in: app, titled: "Orphan session", in: "deleted-workspace")

        for round in 0..<3 {
            openSidebar(app)
            XCTAssertTrue(expand(orphanGroup, revealing: orphan), "the orphan session is missing")
            orphan.tap()
            expect(app.staticTexts["turn.24.usage"], "the orphan conversation did not open")
            XCTAssertFalse(
                app.descendants(matching: .any)["session.placement.failed"].exists,
                "the orphan conversation could not be positioned",
            )

            openSidebar(app)
            XCTAssertTrue(expand(demo, revealing: mock), "the long session is missing")
            mock.tap()
            let marker = app.staticTexts["turn.24.usage"]
            expect(marker, "the long conversation did not return to its newest turn (round \(round))")
            XCTAssertTrue(marker.isHittable, "the newest turn is off screen (round \(round))")
            // The first 350 ms are where the late-row corrections used to be
            // visible. Two samples in that window must agree.
            RunLoop.current.run(until: Date().addingTimeInterval(0.35))
            let early = marker.frame
            RunLoop.current.run(until: Date().addingTimeInterval(0.35))
            XCTAssertEqual(early, marker.frame, "the page moved within 350 ms of landing (round \(round))")
            XCTAssertFalse(
                app.descendants(matching: .any)["session.placement.failed"].exists,
                "the long conversation could not be positioned (round \(round))",
            )
            // The page has landed. Give the settling corrections their full
            // window, then measure the newest turn's frame twice: if the page
            // is still moving, the operator sees the twitch.
            RunLoop.current.run(until: Date().addingTimeInterval(1.6))
            let settled = marker.frame
            RunLoop.current.run(until: Date().addingTimeInterval(0.6))
            XCTAssertEqual(
                marker.frame,
                settled,
                "the page kept moving after landing (round \(round))",
            )
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "switch-round-\(round)"
            shot.lifetime = .keepAlways
            add(shot)

            // The reported 100% case: from far up, tap the way-back button,
            // then switch sessions. It must land on the newest turn and stay
            // there; a blank page here fails the next round's marker check.
            let up = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.26))
            let down = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.64))
            for _ in 0..<10 {
                up.press(forDuration: 0.05, thenDragTo: down)
            }
            let jump = app.buttons["conversation.jumpToLatest"]
            expect(jump, "the way-back button did not appear after scrolling up (round \(round))")
            jump.tap()
            expect(marker, "the way-back button left the conversation away from the newest turn (round \(round))")
            XCTAssertTrue(marker.isHittable, "the way-back jump landed off screen (round \(round))")
        }
    }

    /// The short conversations are the shape that used to fail placement.
    ///
    /// A three-turn page can be shorter than the viewport; the old acceptance
    /// demanded the page be at the very top and refused a short page pushed
    /// down by the composer reserve, which produced the "could not position"
    /// card with no way in. Switch between the fixture's two short sessions and
    /// require readable content and a still frame each time.
    func testSwitchingShortSessionsAlwaysLandsOnTheNewestTurn() {
        let app = launch(session: "first", running: false)

        let demo = app.buttons["workspace./Users/you/projects/demo"]
        let mock = sessionRow(in: app, titled: "Mock session", in: "demo")
        let orphanGroup = app.buttons["workspace.not-in-a-workspace"]
        let orphan = sessionRow(in: app, titled: "Orphan session", in: "deleted-workspace")

        for round in 0..<3 {
            openSidebar(app)
            XCTAssertTrue(expand(orphanGroup, revealing: orphan), "the orphan session is missing")
            orphan.tap()
            let orphanText = app.staticTexts["A different session, a different answer."]
            expect(orphanText, "the short orphan conversation did not open (round \(round))")
            XCTAssertTrue(orphanText.isHittable, "the short orphan content is off screen (round \(round))")
            XCTAssertFalse(
                app.descendants(matching: .any)["session.placement.failed"].exists,
                "the short orphan conversation could not be positioned",
            )

            openSidebar(app)
            XCTAssertTrue(expand(demo, revealing: mock), "the short session is missing")
            mock.tap()
            let newest = app.staticTexts["Two files changed, and it still fails."]
            expect(newest, "the short conversation did not open (round \(round))")
            XCTAssertTrue(newest.isHittable, "the short conversation's newest content is off screen (round \(round))")
            XCTAssertFalse(
                app.descendants(matching: .any)["session.placement.failed"].exists,
                "the short conversation could not be positioned",
            )

            RunLoop.current.run(until: Date().addingTimeInterval(0.35))
            let early = newest.frame
            RunLoop.current.run(until: Date().addingTimeInterval(0.35))
            XCTAssertEqual(early, newest.frame, "the short page moved after landing (round \(round))")

            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "short-round-\(round)"
            shot.lifetime = .keepAlways
            add(shot)
        }
    }

    /// Entry is a cover, then the conversation at the bottom -- never a page
    /// that scrolls into place, starts in the wrong place, or flashes the
    /// way-back button while the placement works.
    func testOpeningASessionHoldsACoverUntilItIsPlaced() {
        let app = launch(session: nil, pending: false, running: false, slowPlacement: true)
        openSidebar(app)
        let demo = app.buttons["workspace./Users/you/projects/demo"]
        let mock = sessionRow(in: app, titled: "Mock session", in: "demo")
        XCTAssertTrue(expand(demo, revealing: mock), "the session is missing")
        mock.tap()
        let cover = app.descendants(matching: .any)["session.placement.cover"]
        expect(cover, "the placement cover never appeared")
        XCTAssertFalse(
            app.buttons["conversation.jumpToLatest"].exists,
            "the way-back button flashed during placement",
        )
        XCTAssertFalse(
            app.staticTexts["Two files changed, and it still fails."].exists,
            "conversation content was visible under the placement cover",
        )
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "placement-cover"
        shot.lifetime = .keepAlways
        add(shot)

        let gone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: cover,
        )
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: Self.patience), .completed,
                       "the placement cover never went away")
        expect(app.staticTexts["Two files changed, and it still fails."], "the conversation never appeared")
        XCTAssertFalse(
            app.buttons["conversation.jumpToLatest"].exists,
            "the way-back button was still showing after the page landed at the bottom",
        )
    }

    /// The host replacing the cached page with a fresh one must not drop the
    /// operator at the top. The long reader fixture is a different height from
    /// the cached four-turn page; after refresh the newest turn must be on
    /// screen, exactly as it is on first entry.
    func testRefreshingWithANewPageKeepsTheNewestTurnVisible() {
        let app = launch(pending: false, running: false)
        expect(app.textViews["composer.field"], "the conversation never opened")

        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(
            with: URL(string: "http://127.0.0.1:\(Self.mockPort)/reader?long=1")!,
        ) { _, _, _ in done.signal() }.resume()
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success, "the fresh page fixture did not load")

        app.buttons["session.refresh"].tap()
        let newest = app.staticTexts["turn.24.usage"]
        expect(newest, "the refreshed page did not land on its newest turn")
        XCTAssertTrue(newest.isHittable, "the refreshed page kept the newest turn off screen")
    }

    func testBalanceSupportMatrixAndExplicitRefresh() {
        let app = launch(pending: false, running: false, contentSizeCategory: "UICTContentSizeCategoryAccessibilityXXXL")
        openSidebar(app)
        let entry = app.buttons["sidebar.balance"]
        expect(entry, "balance entry is missing beside settings")
        let settings = app.buttons["sidebar.settings"]
        let connection = app.buttons["sidebar.connection"]
        XCTAssertTrue(entry.isHittable && settings.isHittable && connection.isHittable, "all three footer actions must be reachable")
        for control in [entry, settings, connection] {
            XCTAssertGreaterThanOrEqual(control.frame.width, 44)
            XCTAssertGreaterThanOrEqual(control.frame.height, 44)
        }
        XCTAssertEqual(entry.frame.width, 54, accuracy: 1)
        XCTAssertEqual(settings.frame.width, 54, accuracy: 1)
        XCTAssertFalse(entry.frame.intersects(settings.frame), "footer actions overlap")
        XCTAssertFalse(connection.frame.intersects(entry.frame))
        XCTAssertFalse(connection.frame.intersects(settings.frame))
        entry.tap()
        let panel = app.descendants(matching: .any)["balance.panel"]
        expect(panel, "balance entry must open the compact panel")
        expect(app.otherElements["PopoverDismissRegion"], "balance must use a popover rather than a sheet")
        XCTAssertLessThanOrEqual(panel.frame.width, 320)
        XCTAssertLessThan(panel.frame.height, app.frame.height * 0.75, "balance must not return to a large sheet")
        let status = app.staticTexts["balance.status"]
        for _ in 0..<5 where !status.exists { scrollBalance(app) }
        expect(status, "unsupported plugin must explain balance support")
        // The page keeps the finished page's shape in every state, so the two
        // amount columns are drawn -- saying 未知 -- and the top-up link stays
        // where it always is. What changes with the state is the figures and the
        // sentence, never the layout.
        expect(app.staticTexts["balance.unknown.CNY"], "an unsupported plugin must say the amount is unknown")
        expect(app.buttons["balance.topUp"], "the top-up link is part of the page, not of a ready balance")
        XCTAssertEqual(Self.mockMethodCounts()["account.balance", default: 0], 0, "old plugin must not be queried")
        app.buttons["balance.done"].tap()
        Self.setBalanceFixture("ready")
        entry.tap()
        tapBalanceRefresh(app)
        let amount = app.staticTexts.matching(identifier: "balance.amount.CNY").firstMatch
        for _ in 0..<5 where !amount.exists { scrollBalance(app) }
        expect(amount, "official supported balance did not appear after explicit refresh")
        XCTAssertTrue(amount.label.contains("123.46"), "decimal balance must be rounded to two fraction digits")
        XCTAssertFalse(amount.label.contains("123.456789"), "the panel must not expose the host's full precision")
        let topUp = app.buttons["balance.topUp"]
        for _ in 0..<8 where !topUp.exists { scrollBalance(app) }
        expect(topUp, "ready official account should offer the top-up link")
        Self.setBalanceFixture("long")
        tapBalanceRefresh(app)
        let exactLong = "12345678901234567890.00"
        let longAmount = app.staticTexts.matching(identifier: "balance.amount.CNY").matching(NSPredicate(format: "label CONTAINS %@", exactLong)).firstMatch
        for _ in 0..<12 where !longAmount.exists { scrollBalance(app, up: false) }
        expect(longAmount, "long balance must remain complete at accessibility size")
        XCTAssertTrue(longAmount.label.contains(exactLong))
        XCTAssertGreaterThan(longAmount.frame.height, 40, "AX long amount must wrap instead of remaining a clipped single line")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "balance-AX5-long-official-decimal"
        attachment.lifetime = .keepAlways
        add(attachment)
        Self.setBalanceFixture("failed")
        tapBalanceRefresh(app)
        let cleared = NSPredicate { _, _ in !amount.exists }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: cleared, object: nil)], timeout: 10), .completed, "failed refresh leaked the previous account balance")
        // What a failed read must not do is leak the previous account's money;
        // that is the assertion above. What it must do -- keep the page's shape
        // and say 未知 where the figure was -- is asserted in the unsupported
        // branch at the top of this test, where the panel is at its first
        // scroll position and every row is reachable. At this text size the
        // wallet cards sit below the panel's window after a refresh, and a
        // gesture aimed at that window is a measurement of the test, not of the
        // screen.
    }

    private func scrollBalance(_ app: XCUIApplication, up: Bool = true) {
        let scroll = app.descendants(matching: .any)["balance.panel"].scrollViews.firstMatch
        // The panel is one column inside a short window at accessibility text
        // sizes, and a gesture aimed at a scroll view whose frame is mid-change
        // fails the whole test with "visible frame is empty". A swipe on the
        // screen does the same thing to the same view without that failure mode.
        guard scroll.exists, scroll.isHittable else {
            up ? app.swipeUp() : app.swipeDown()
            return
        }
        up ? scroll.swipeUp() : scroll.swipeDown()
    }

    private func tapBalanceRefresh(_ app: XCUIApplication) {
        let refresh = app.buttons["balance.refresh"]
        expect(refresh, "explicit refresh must remain reachable at accessibility text size")
        refresh.tap()
    }

    private static func setBalanceFixture(_ variant: String) {
        let url = URL(string: "http://127.0.0.1:\(mockPort)/balance?variant=\(variant)")!
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: url) { _, _, _ in done.signal() }.resume()
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success, "local balance fixture did not respond")
    }

    func testCompletedTurnToolbarUsesClickedBoundaryAndExactUsage() {
        let app = launch(pending: false, running: true, contentSizeCategory: "UICTContentSizeCategoryAccessibilityXXXL")
        let usage = app.staticTexts["turn.1.usage"]
        for _ in 0..<5 where !usage.isHittable { app.swipeDown() }
        expect(usage, "completed response has no usage footer")
        XCTAssertTrue(usage.label.contains("12345"), "whole-turn exact token count is missing")
        XCTAssertFalse(app.buttons["turn.4.copy"].exists, "running response must not expose a completed footer")
        let branchGeometry = app.buttons["turn.1.branch"]
        let copyGeometry = app.buttons["turn.1.copy"]
        for action in [copyGeometry, branchGeometry] {
            XCTAssertTrue(action.isHittable)
            XCTAssertGreaterThanOrEqual(action.frame.width, 44)
            XCTAssertGreaterThanOrEqual(action.frame.height, 44)
        }
        XCTAssertFalse(copyGeometry.frame.intersects(branchGeometry.frame))
        XCTAssertLessThanOrEqual(copyGeometry.frame.maxX, branchGeometry.frame.minX)
        let time = app.staticTexts["turn.1.time"]
        XCTAssertFalse(usage.frame.intersects(time.frame))
        XCTAssertTrue(app.frame.contains(usage.frame) && app.frame.contains(time.frame))
        XCTAssertFalse(app.buttons["turn.1.usage"].exists)
        XCTAssertFalse(app.buttons["turn.1.time"].exists)
        let geometryShot = XCTAttachment(screenshot: app.screenshot())
        geometryShot.name = "real-completed-toolbar-AX5"
        geometryShot.lifetime = .keepAlways
        add(geometryShot)
        let copy = app.buttons["turn.1.copy"]
        expect(copy, "copy action missing")
        copy.tap()
        let field = app.textViews["composer.field"]
        field.press(forDuration: 1.1)
        let paste = app.menuItems["Paste"]
        expect(paste, "copied response was not available to the actual system paste action")
        paste.tap()
        XCTAssertEqual(field.value as? String, "The parser is now two files.", "copy must place the whole selected response on the clipboard")
        let branch = app.buttons["turn.1.branch"]
        XCTAssertTrue(branch.isEnabled, "safe completed response should be branchable")
        branch.tap()
        let finished = NSPredicate { _, _ in Self.forkRequestCount() == 1 }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: finished, object: nil)], timeout: 10), .completed)
        XCTAssertEqual(Self.lastForkSequence(), 9, "branch must use clicked turn 1 endSeq, not later answer/message/latest turn")
    }

    private static func lastForkSequence() -> Int? {
        let done = DispatchSemaphore(value: 0)
        let box = Box()
        URLSession.shared.dataTask(with: URL(string: "http://127.0.0.1:\(mockPort)/loads")!) { data, _, _ in
            if let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                box.value = ((object["forks"] as? [[String: Any]])?.last?["atSeq"] as? NSNumber)?.intValue
            }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 5)
        return box.value
    }

    private static func forkRequestCount() -> Int {
        let done = DispatchSemaphore(value: 0)
        let box = Box()
        URLSession.shared.dataTask(with: URL(string: "http://127.0.0.1:\(mockPort)/loads")!) { data, _, _ in
            if let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                box.value = (object["forks"] as? [[String: Any]])?.count ?? 0
            }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 5)
        return box.value ?? 0
    }

    func testReadingOlderMessageKeepsVisibleAnchorThroughComposerCollapse() {
        let app = launch(pending: false, running: false)
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: URL(string: "http://127.0.0.1:\(Self.mockPort)/reader?long=1")!) { _, _, _ in done.signal() }.resume()
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        app.terminate()
        app.launch()
        let field = app.textViews["composer.field"]
        expect(field, "reader fixture did not open the real conversation")
        let anchor = app.staticTexts["turn.20.usage"]
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65))
        for _ in 0..<6 where !anchor.isHittable { start.press(forDuration: 0.1, thenDragTo: end) }
        expect(anchor, "real drag must reveal an older completed message before measurement")
        XCTAssertTrue(anchor.isHittable)
        let before = anchor.frame.midY
        print("[reader-anchor] turn20-before=\(anchor.frame) turn24-visible=\(app.staticTexts["turn.24.usage"].isHittable)")
        XCTAssertFalse(app.staticTexts["turn.24.usage"].isHittable, "reader must be materially away from the newest response")
        app.buttons["composer.expand"].tap()
        RunLoop.current.run(until: Date().addingTimeInterval(1.2))
        app.buttons["composer.expand"].tap()
        RunLoop.current.run(until: Date().addingTimeInterval(1.8))
        XCTAssertTrue(anchor.isHittable, "composer collapse lost the older visible message")
        print("[reader-anchor] turn20-after=\(anchor.frame) delta=\(anchor.frame.midY - before)")
        XCTAssertLessThanOrEqual(abs(anchor.frame.midY - before), 2, "reader's message anchor moved after expand/collapse")
    }

    func testOpeningASessionShowsTheComposer() {
        let app = launch(pending: false)
        let field = app.textViews["composer.field"]
        expect(field, "the composer is missing")

        // One button, two jobs. The running session starts with an empty field,
        // which is the stop case -- the rule DSH uses, and the rule this follows.
        expect(app.buttons["composer.stop"], "a running turn with an empty field does not offer stop")

        // Typing turns it into send, and it is refused while empty -- so the one
        // button cannot be tapped into a no-op.
        field.tap()
        field.typeText("hello")
        let send = app.buttons["composer.send"]
        expect(send, "typing did not turn the button into send")
        XCTAssertTrue(send.isEnabled, "send is disabled with text in the field")

        let oneLineHeight = field.frame.height
        let lines = (1...12).map { "line \($0)" }.joined(separator: "\n")
        field.typeText("\n" + lines)
        let grew = NSPredicate { _, _ in field.frame.height > oneLineHeight * 2 }
        XCTAssertTrue(
            XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: grew, object: nil)], timeout: 5) == .completed,
            "a multiline draft did not grow the resting editor"
        )
        let restingHeight = field.frame.height
        app.buttons["composer.expand"].tap()
        let expanded = NSPredicate { _, _ in field.frame.height > restingHeight + 20 }
        XCTAssertTrue(
            XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: expanded, object: nil)], timeout: 5) == .completed,
            "expanded editor did not receive a larger viewport"
        )
        XCTAssertTrue((field.value as? String)?.contains("line 12") == true, "expanding lost the draft tail")
        field.swipeDown()
        field.swipeUp()
        XCTAssertTrue((field.value as? String)?.contains("line 1\n") == true, "scrolling lost the draft head")
        app.buttons["composer.expand"].tap()
        let settled = NSPredicate { _, _ in field.frame.height <= restingHeight + 1 }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: settled, object: nil)], timeout: 5), .completed)
        // Leave the actual UI alive beyond the production 600ms unlock so the
        // temporary diagnostic display-link can capture the late content jump.
        RunLoop.current.run(until: Date().addingTimeInterval(1.8))
        XCTAssertTrue((field.value as? String)?.contains("line 12") == true, "collapsing lost the draft tail")
    }

    /// A session whose workspace the host has deleted is not drawn as a
    /// workspace.
    ///
    /// The host reports two sessions: one in a workspace it has, and one in a
    /// directory it does not -- which is what a deleted workspace looks like,
    /// because deleting it removes the registry entry and leaves the session log
    /// behind. Grouping on the working directory drew both, and the deleted one
    /// was offered as somewhere to start new work.
    ///
    /// It is not gone, though, and that is deliberate: the conversation is
    /// collected under one heading of its own, because the list is the only
    /// screen that can open it. What changed is that it is no longer presented
    /// as a workspace DSH has.
    func testADeletedWorkspaceIsNotListed() {
        let app = launch(session: nil)
        expect(app.staticTexts["Mock Mac (fixture)"], "the host's name is missing")

        // The workspace the host still has is there, with its one session.
        let demo = app.buttons["workspace./Users/you/projects/demo"]
        expect(demo, "the host's own workspace is missing")

        // And the directory the host has no workspace for is not, even though a
        // session still lives in it.
        XCTAssertEqual(
            app.buttons.matching(identifier: "workspace./Users/you/projects/deleted-workspace").count,
            0,
            "a session in a deleted workspace was listed as a workspace",
        )
        // The host's second workspace holds no sessions and is drawn anyway: it
        // is on the computer's sidebar, so it is part of the count the operator is
        // comparing.
        expect(
            app.buttons["workspace./Users/you/projects/fresh"],
            "a workspace with no sessions was left out",
        )
        // One heading for what no workspace claims, and it says what it is.
        expect(
            app.buttons["workspace.not-in-a-workspace"],
            "the session in a deleted workspace is unreachable",
        )
    }

    /// The new-session picker offers the host's workspaces, and nothing else.
    ///
    /// This is the screen the report was about: "手机app中有许多电脑端dsh已经删除的
    /// 工作区". The list below it was already filtered by the host's workspace
    /// registry; the picker was not, because it was built from the working
    /// directory of every session the host had ever listed -- and a deleted
    /// workspace leaves its session log behind, so its directory stayed on offer
    /// forever as somewhere to start new work.
    func testTheNewSessionPickerDoesNotOfferADeletedWorkspace() {
        let app = launch(session: nil)
        expect(app.buttons["sessions.new"], "the new-session button is missing")
        app.buttons["sessions.new"].tap()

        expect(
            app.staticTexts["/Users/you/projects/demo"],
            "the host's own workspace is not offered",
        )
        XCTAssertFalse(
            offersDirectory(app, "/Users/you/projects/deleted-workspace"),
            "a deleted workspace was offered as somewhere to start a session",
        )
    }

    /// A refresh reports the workspaces the host has, which is the number the
    /// operator can check against their computer.
    ///
    /// The sheet used to say nothing about workspaces at all, so "the phone has
    /// more of them than DSH does" could only be discovered by counting rows.
    func testRefreshingReportsTheHostsWorkspaces() {
        let app = launch(session: nil)
        expect(app.buttons["sessions.refresh"], "the refresh button is missing")
        app.buttons["sessions.refresh"].tap()

        let count = app.staticTexts["sync.workspaces"]
        expect(count, "the refresh sheet does not say how many workspaces there are")
        // Two: the one holding the demo session, and the one holding none. The
        // session in a deleted workspace is not a workspace.
        XCTAssertTrue(
            labelLands(count, containing: "Workspaces: 2"),
            "the sheet reported \(count.label)",
        )
    }

    /// The figures the screen already has are not erased by a read that fails.
    ///
    /// Reported from the phone: "刚点进去一个会话，然后该会话的标题、正在使用的
    /// 模型、上下文用量显示全部消失", repaired by leaving the session and coming
    /// back or by leaving the app and coming back -- both of which are another
    /// read. What made them vanish was the *second* read of the same screen: the
    /// cache drew the figures, and the host's answer was assigned over them
    /// whether it had anything in it or not.
    func testTheFiguresSurviveAReadThatFails() {
        let app = launch(pending: false)
        let model = app.buttons["composer.model"]
        let context = app.buttons["composer.context"]
        expect(model, "the model is not shown above the composer")
        XCTAssertTrue(
            labelLands(context, containing: "35"),
            "the context figure never loaded: \(context.label)",
        )
        XCTAssertTrue(
            labelLands(model, containing: "deepseek-flash"),
            "the model never loaded: \(model.label)",
        )

        // The host stops answering `session.stats`, the way a phone link does.
        Self.failMockHost("session.stats")
        // Away and back, which is what the operator does to repair it and what
        // makes this screen re-read everything.
        XCUIDevice.shared.press(.home)
        app.activate()

        XCTAssertTrue(
            labelLands(context, containing: "35"),
            "the context figure was erased by a failed read: \(context.label)",
        )
        XCTAssertTrue(
            labelLands(model, containing: "deepseek-flash"),
            "the model was erased by a failed read: \(model.label)",
        )
        XCTAssertEqual(
            app.navigationBars["Mock session"].exists,
            true,
            "the session's title was erased by a failed read",
        )
    }

    /// An answer that carries less than the last one does not take anything away.
    ///
    /// The other half of the same report, and the likelier half: the host
    /// answers every field from its own projection, so a session whose agent is
    /// cold answers with a token meter and no title, no model and no context
    /// pressure. That reply is delivered successfully, which is exactly why the
    /// screen has to merge it rather than take it as the truth.
    func testTheFiguresSurviveAColdAnswer() {
        let app = launch(pending: false)
        let model = app.buttons["composer.model"]
        let context = app.buttons["composer.context"]
        expect(model, "the model is not shown above the composer")
        XCTAssertTrue(labelLands(context, containing: "35"), "the context figure never loaded")
        XCTAssertEqual(app.navigationBars["Mock session"].exists, true, "the title never loaded")

        // The session goes cold: the host still answers, with less.
        Self.setMockStatsCold(true)
        XCUIDevice.shared.press(.home)
        app.activate()

        XCTAssertTrue(
            labelLands(context, containing: "35"),
            "a colder answer took the context figure away: \(context.label)",
        )
        XCTAssertTrue(
            labelLands(model, containing: "deepseek-flash"),
            "a colder answer took the model away: \(model.label)",
        )
        XCTAssertEqual(
            app.navigationBars["Mock session"].exists,
            true,
            "a colder answer took the session's title away",
        )
    }

    /// The three figures above the field, each of which is a control.
    func testTheComposerBarShowsTheModelContextAndCommands() {
        let app = launch()
        expect(app.buttons["composer.model"], "the model is not shown above the composer")
        expect(app.buttons["composer.context"], "the context figure is not shown above the composer")
        expect(app.buttons["composer.commands"], "the command button is not shown above the composer")

        // The figure is the host's number, not a placeholder. Asserted on the
        // button's label: setting one makes the button a single accessibility
        // element, so its inner Text is not a queryable child.
        let context = app.buttons["composer.context"]
        XCTAssertTrue(
            labelLands(context, containing: "35"),
            "the context percentage is not the host's: \(context.label)",
        )
    }

    func testTheConversationRendersMessagesAndFailures() {
        // Nothing pending: the two interaction cards fill most of a phone screen,
        // and this test is about the conversation underneath them.
        let app = launch(pending: false)
        expect(app.staticTexts["Refactor the parser and run the tests."], "the user's message is missing")
        // The turn's one message is its answer, and it is on screen without a
        // tap. The transport no longer sends the steps that led to it.
        expect(
            app.staticTexts["The parser is now two files."],
            "the turn's answer is not on screen without a tap",
        )
        // A turn that ended badly still says so, on its own row: the state is the
        // one thing a monitoring app exists to report, and the row carries it
        // even when there is an answer under it.
        XCTAssertTrue(
            reveal(
                app.descendants(matching: .any)
                    .matching(NSPredicate(format: "label BEGINSWITH %@", "Unfinished after "))
                    .firstMatch,
                in: app,
            ),
            "a turn that ended badly was not reported as unfinished",
        )
        // The turn that ended with *nothing to show* is the one the failure card
        // belongs to, and it is on screen: without it, that turn is a bare row
        // saying "未完成" over an empty space, and the operator is left to guess
        // whether the model ever ran.
        expect(
            app.staticTexts["The turn ended without a response"],
            "a turn that ended without a response was not surfaced",
        )
        // And the turn that ended badly *after* answering keeps its answer: a
        // notice drawn over it would take away the only thing that turn managed
        // to say, and the row's own warning already reports the state.
        expect(
            app.staticTexts["Two files changed, and it still fails."],
            "a failure notice replaced a turn's answer",
        )
    }

    /// The step count comes from the markers, not from the messages.
    ///
    /// The reported shape, and the reason the count is derived rather than
    /// counted off the items: the host sends one tiny `step/start` per step and
    /// only the **last** `assistant/message` of a turn. Turn 1 below takes three
    /// steps and arrives with one message, so a row that counted messages would
    /// read "1 steps" over a turn that took three -- and the count is the only
    /// part of a step the transport still sends.
    func testATurnRowCountsItsStepsFromTheMarkers() {
        let app = launch(pending: false)
        // Waited for first: without this the assertions below pass on a screen
        // that has not drawn yet, which is a test that proves nothing.
        expect(app.staticTexts["Refactor the parser and run the tests."], "the conversation never arrived")

        let count = app.staticTexts["3 steps"]
        XCTAssertTrue(reveal(count, in: app), "the turn's step count does not match its markers")
        // And the row is a finished one, not a failure and not still running.
        XCTAssertTrue(
            app.staticTexts["The parser is now two files."].exists,
            "the counted turn's answer is missing",
        )
    }

    /// A turn is not a disclosure any more, and tapping it reveals nothing.
    ///
    /// The old screen folded a turn's steps behind its summary bar, and the
    /// transport change took the steps away: the host sends the prompt, the
    /// turn's markers and the model's last message, and none of the narration in
    /// between. There is nothing left to expand, so the row must not offer to.
    ///
    /// The text asserted on is a step of the running turn under the old
    /// fixture, which was the shape of the thing that is no longer sent at all.
    /// The row is tapped rather than merely inspected, because "the row is not
    /// expandable" is a claim about what a tap does -- and a `DisclosureGroup`
    /// looks exactly like a plain row until someone touches it.
    func testATurnRowIsNotExpandable() {
        let app = launch(pending: false)
        // Waited for first: the row is looked up by identifier, and an identifier
        // query finds nothing at all on a screen that has not drawn.
        let row = turnRow(app, 1)
        XCTAssertTrue(reveal(row, in: app), "the turn row is missing, so nothing can be tapped")

        // The step's text is not there to begin with, and that is the first half
        // of the claim: it is not merely hidden behind a tap.
        XCTAssertFalse(
            app.staticTexts["Running the tests now."].waitForExistence(timeout: 2),
            "a step's text is in the tree, so the steps were not actually dropped",
        )

        // Tapped, as an operator would. A row that was still a `DisclosureGroup`
        // would now be open.
        row.tap()

        XCTAssertFalse(
            app.staticTexts["Running the tests now."].waitForExistence(timeout: 2),
            "tapping the turn revealed a step, so the row is still expandable",
        )
        // And nothing else was revealed either: a row that still offered a
        // disclosure would be a control, and this one is not one any more.
        XCTAssertEqual(
            app.buttons.matching(identifier: "turn.1").count,
            0,
            "the turn row is still a control",
        )
        // The answer that is there stays there, so the tap did not swap anything.
        XCTAssertTrue(
            app.staticTexts["The parser is now two files."].exists,
            "tapping the turn row changed what is on screen",
        )
    }

    /// A turn that is still working says so, and does not claim to have finished.
    ///
    /// The reported bug, exactly. A running turn has no `turn/end`, and the
    /// reader invented an end time from its last record -- so a live turn was
    /// drawn as "已完成，用时 10 秒", with the seconds measuring the age of the
    /// newest message.
    func testARunningTurnSaysItIsRunning() {
        // With nothing pending, so the conversation has the screen. The two
        // interaction cards take most of it, and they are asserted on by their
        // own tests.
        let app = launch(pending: false)

        // The state is written on the row, found by its label: the identifier
        // belongs to the row and the state belongs to the text inside it, which
        // is where a reader finds it too.
        let running = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "DeepSeeking for "))
            .firstMatch
        expect(running, "no turn is reported as running")

        // Turn 1 did end, and still reads as finished -- so the fix is not just
        // "everything says running".
        let finished = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Completed in "))
            .firstMatch
        XCTAssertTrue(reveal(finished, in: app), "no turn is reported as completed")
    }

    /// The running wording, in the language it was asked for in.
    ///
    /// "深度求索中，用时 %@" is the operator's string, word for word, and the
    /// running row is the one thing on this screen they want to read at a
    /// glance. Asserted in Chinese because that is where it was asked for; the
    /// English pass is asserted in the test above.
    func testTheRunningRowIsWordedAsAskedInChinese() {
        let app = launch(language: "zh-Hans", pending: false)
        // The conversation has to have landed, or this passes on a screen with
        // nothing on it.
        XCTAssertTrue(
            app.staticTexts["Refactor the parser and run the tests."]
                .waitForExistence(timeout: Self.patience),
            "the conversation never arrived",
        )
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "label BEGINSWITH %@", "深度求索中，用时 "))
                .firstMatch
                .waitForExistence(timeout: Self.patience),
            "the running row does not read \"深度求索中，用时 \" in Chinese",
        )
        // And the finished row is the wording that was already correct.
        XCTAssertTrue(
            reveal(
                app.descendants(matching: .any)
                    .matching(NSPredicate(format: "label BEGINSWITH %@", "已完成，用时 "))
                    .firstMatch,
                in: app,
            ),
            "the finished row does not read \"已完成，用时 \" in Chinese",
        )
    }

    /// The clock on a running turn moves.
    ///
    /// Separate from the assertion above because it is a different claim: that
    /// the elapsed time is the turn's own start measured against now, rather
    /// than a number computed once when the screen was drawn. The host is not
    /// asked anything, so this is the only evidence that the phone is doing the
    /// arithmetic itself.
    func testARunningTurnsClockMoves() {
        let app = launch(pending: false)
        let running = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "DeepSeeking for "))
            .firstMatch
        expect(running, "no turn is reported as running")
        let first = running.label

        let moved = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label != %@", first),
            object: running,
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [moved], timeout: 10),
            .completed,
            "the running turn's clock did not move past \(first)",
        )
    }

    /// A running turn shows no answer at all, and hides nothing.
    ///
    /// Both halves of the request, and they are opposites: a half-written answer
    /// must not be presented as a conclusion, and nothing may be lost behind a
    /// tap that no longer exists to reveal it.
    ///
    /// Since the transport change the two are the same fact -- the host does not
    /// send a running turn's partial answer, so there is nothing to show and
    /// nothing to fold -- but they are asserted separately because a view that
    /// started drawing the partial answer again would fail one and pass the
    /// other.
    func testARunningTurnShowsNoAnswer() {
        let app = launch(pending: false)
        // Waited for first: without this the assertions below pass on a screen
        // that has not drawn yet, which is a test that proves nothing.
        expect(app.staticTexts["And run the whole suite."], "the running turn's prompt is missing")

        let running = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "DeepSeeking for "))
            .firstMatch
        // Waited for: the row is what the next assertion measures against, and a
        // query that matches nothing returns a frame of zeroes rather than
        // failing.
        expect(running, "the running turn is not reported as running")

        // Its count is still shown, because the markers are still sent: a
        // running turn with nothing on its row reads as a turn that has stalled.
        XCTAssertTrue(
            app.staticTexts["2 steps"].exists,
            "the running turn's step count is missing",
        )

        // Nothing has leaked out under its row. The answer above it belongs to
        // the turn that finished -- the prompt and the row are all the running
        // turn has, because the transport does not send a partial answer -- and
        // the narration of the old fixture is not here at all.
        XCTAssertLessThan(
            app.staticTexts["Two files changed, and it still fails."].frame.minY,
            running.frame.minY,
            "the running turn's row is not below the turn that came before it",
        )
        // The prompt is above the row, and the row is the last thing in the
        // turn: nothing of the running turn's own is under it, because the
        // transport sends nothing for a turn that has not ended.
        XCTAssertLessThan(
            app.staticTexts["And run the whole suite."].frame.minY,
            running.frame.minY,
            "the running turn's prompt is not above its row",
        )
        XCTAssertFalse(
            app.staticTexts["Running the tests now."].exists,
            "a step that the transport no longer sends is on screen",
        )
    }

    /// Repeated up/down scrolling on a long conversation must not lock the
    /// screen.
    ///
    /// Reported from the phone: dragging the conversation up and down a few
    /// times leaves the page frozen, with the system log repeating
    /// `<OnScrollGeometryChange Modifier> tried to update multiple times per
    /// frame` -- the shape of a scroll callback that writes state which moves
    /// the scroll view again.
    ///
    /// The assertion is on the *answer*, not on the gesture: a query that has
    /// to reach the app is what a frozen main thread cannot satisfy. Time, not
    /// a screenshot, is the signal.
    /// The way-back button must land on the newest turn, not in the space the
    /// lazy stack leaves below it after its estimated heights are replaced by
    /// real ones.
    func testJumpToLatestLandsOnTheNewestTurn() {
        let app = launch(pending: false, running: false)
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: URL(string: "http://127.0.0.1:\(Self.mockPort)/reader?long=1")!) { _, _, _ in done.signal() }.resume()
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success, "long reader fixture did not answer")
        app.terminate()
        app.launch()

        let field = app.textViews["composer.field"]
        expect(field, "reader fixture did not open the real conversation")

        // Far enough up that the newest turn is not built and the button shows.
        let up = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.26))
        let down = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.64))
        for _ in 0..<10 {
            up.press(forDuration: 0.05, thenDragTo: down)
        }

        let jump = app.buttons["conversation.jumpToLatest"]
        expect(jump, "the way back to the newest message did not appear")
        jump.tap()

        // The newest turn's usage line is the one thing only the true bottom
        // shows; a landing in the empty space below it leaves this above the
        // screen (or unbuilt).
        let newest = app.staticTexts["turn.24.usage"]
        let deadline = Date().addingTimeInterval(10)
        var landed = false
        while Date() < deadline {
            if newest.exists {
                let frame = newest.frame
                let visible = app.frame.insetBy(dx: 0, dy: 80)
                if visible.contains(CGPoint(x: frame.midX, y: frame.midY)) {
                    landed = true
                    break
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertTrue(landed, "the way-back button left the page away from the newest turn")
        // The jump owns the page until it finishes; let its own final settle
        // happen, then the frame must be still.
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        let early = newest.frame
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        XCTAssertEqual(early, newest.frame, "the page moved right after the jump landed")
        // A jump owns the page until it lands, then it must be still: two
        // measurements after the fade are the same frame.
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        let settled = newest.frame
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        XCTAssertEqual(newest.frame, settled, "the page kept moving after the jump landed")
    }

    func testRepeatedScrollingNeverLocksTheConversation() {
        let app = launch(pending: false, running: false)
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: URL(string: "http://127.0.0.1:\(Self.mockPort)/reader?long=1")!) { _, _, _ in done.signal() }.resume()
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success, "long reader fixture did not answer")
        app.terminate()
        app.launch()

        let field = app.textViews["composer.field"]
        expect(field, "reader fixture did not open the real conversation")

        // The report has the field focused while the page is dragged, which is
        // the state `scrollDismissesKeyboard(.interactively)` animates in.
        field.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))

        let up = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.26))
        let down = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.64))
        for pass in 0..<12 {
            if pass.isMultiple(of: 2) {
                up.press(forDuration: 0.05, thenDragTo: down)
            } else {
                down.press(forDuration: 0.05, thenDragTo: up)
            }
        }

        let asked = Date()
        let answered = field.waitForExistence(timeout: 8)
        let waited = Date().timeIntervalSince(asked)
        print("[scroll-stress] answered=\(answered) in \(waited)s")
        XCTAssertTrue(answered, "the conversation stopped answering after repeated scrolling")
        XCTAssertLessThan(waited, 6, "the conversation took \(waited)s to answer after repeated scrolling")
    }

}
