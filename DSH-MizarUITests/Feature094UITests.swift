//
//  Feature094UITests.swift
//  DSH-MizarUITests
//
//  Focused cover for the four 0.9.4 requests, against `scripts/mock-host.mjs`.
//
//  The requests, and what each is pinned to here:
//
//  - **The permission picker does not stick.** A preset chosen in the shield
//    was drawn as applied and then lost: the toolbar and the reopened picker
//    both read the host's last `session.stats`, which still said the old value.
//    The fixture now remembers an accepted `session.permission.set`, and the
//    test walks toolbar -> picker -> toolbar -> picker, which fails on 0.9.3
//    and passes only when the choice is both applied and re-read.
//  - **LAN first, and LAN unlocks paid features.** The mock is reached over
//    loopback, which the product rule deliberately does not count as a LAN --
//    so every other suite keeps the relay-era free-account assumptions. The
//    Debug-only `-mizarLocalNetwork` launch flag is how this suite asks for the
//    LAN state explicitly: footer and panel copy change, the running-turn poll
//    becomes three seconds, and a signed-out account gets attachments and the
//    full running-turn detail without paying.
//  - **Foreground recovery.** The app went back to the home screen and came
//    back Offline until somebody tapped Reconnect. A reconnection is invisible
//    from the app's own screen -- the data looks the same afterwards -- so the
//    evidence is read where it is a fact: the mock's connection counter.
//  - **Archive a session.** The sidebar's long-press menu gains an archive
//    action and keeps the copy action it already had. A host that refuses (the
//    fixture's `/fail?method=session.archive`) must leave the row where it was
//    and say so; a success must take it off the list.
//
//  Every helper here is a copy of the pattern the existing suites use rather
//  than a new convention: `AppFlowTests` is the long-term home of the launch
//  arguments, and this suite is kept self-contained so the two can move
//  without sharing state through a base class.
//

import XCTest

final class Feature094UITests: XCTestCase {
    /// This class's mock-host primary port; the table is `MockPorts`.
    private static let mockPort = MockPorts.port(for: "Feature094UITests")
    /// The mock host this suite drives.
    private static let mockPairingURI =
        "mizar://pair?h=127.0.0.1%3A\(mockPort)&c=MOCK-CODE&n=Mock%20Mac&v=1"
    private static let mockBaseURL = "http://127.0.0.1:\(mockPort)"
    /// How long to wait for the host (or a screen) to answer.
    private static let patience: TimeInterval = 20
    /// A naming prompt appears only on the first pairing; waiting the full
    /// `patience` when it does not appear would add twenty seconds per launch.
    private static let namingPatience: TimeInterval = 3

    override func setUp() {
        continueAfterFailure = false
        // Every test starts from the same fixture, whatever the last one left
        // behind -- including the preset switch and the archived set the new
        // endpoints change, which `/reset` puts back like everything else.
        Self.resetMockHost()
    }

    // MARK: - Request 1: the permission picker sticks

    /// Choose a preset, and see it applied and still in force afterwards.
    ///
    /// The report was two symptoms of one bug: the bar did not change, and
    /// reopening the picker showed the old preset ticked. So both are asserted,
    /// and the second one is the important one -- a screen can draw a switch it
    /// has not applied while reading the same old value back.
    func testPermissionPresetSticksAndTheToolbarFollows() {
        // The interaction cards are off: they fill the conversation and one of
        // them sits over the composer, and none of them has anything to do with
        // what is being measured.
        let app = launch(session: "first", pending: false)
        openSessionIfNeeded(app)

        let opener = app.buttons["session.permissions"]
        expect(opener, "there is no way to change the permission preset")
        // The fixture starts in workspace-write, so the bar has something to
        // hold before the switch and the change below is a change.
        XCTAssertTrue(
            labelLands(opener, containing: "Workspace write"),
            "the bar does not say which preset is in force: \(opener.label)",
        )

        // Pick read-only. The host accepts, so the window closes and the choice
        // must be what the bar says next.
        opener.tap()
        let readOnly = app.buttons["permission.row.read-only"]
        expect(readOnly, "the presets are missing")
        readOnly.tap()
        XCTAssertTrue(
            waitForDisappearance(readOnly, timeout: Self.patience),
            "the permission window stayed open over a switch the host accepted",
        )
        XCTAssertTrue(
            labelLands(opener, containing: "Read only"),
            "the bar went back to the host's old preset after an accepted switch: \(opener.label)",
        )

        // Reopening is the other half of the report. The picker has to resolve
        // to the preset in force rather than to the last stats frame the screen
        // happened to hold.
        opener.tap()
        expect(app.buttons["permission.row.workspace-write"], "the permission window did not reopen")
        XCTAssertTrue(
            element("permission.current.read-only", in: app).waitForExistence(timeout: Self.patience),
            "the reopened picker does not resolve to the preset in force",
        )

        // And it is live, not a frozen tick: the next choice applies and, when
        // the picker is opened again, it is what the picker resolves to. The
        // window is not asserted while it is closing -- an accepted switch
        // dismisses it by design, so the stable evidence is the window after
        // it has gone.
        app.buttons["permission.row.workspace-write"].tap()
        XCTAssertTrue(
            waitForDisappearance(app.buttons["permission.row.workspace-write"], timeout: Self.patience),
            "the permission window stayed open over the second switch",
        )
        XCTAssertTrue(
            labelLands(opener, containing: "Workspace write"),
            "the bar did not follow the second accepted switch: \(opener.label)",
        )
        opener.tap()
        expect(app.buttons["permission.row.read-only"], "the permission window did not reopen again")
        XCTAssertTrue(
            element("permission.current.workspace-write", in: app).waitForExistence(timeout: Self.patience),
            "the picker does not resolve to the second preset in force",
        )

        // The switches went to the host and were taken. A picker that only
        // remembered the tap would pass everything above and fail this.
        let methods = Self.mockMethodCounts()
        XCTAssertGreaterThanOrEqual(
            methods["session.permission.set"] ?? 0,
            2,
            "the host was not asked to change the preset twice: \(methods)",
        )
        XCTAssertEqual(
            Self.mockRefusedMethods()["session.permission.set"] ?? 0,
            0,
            "the fixture refused a switch the test expected it to take",
        )
    }

    // MARK: - Request 4: archive a session

    /// The long-press menu keeps what it had and gains the archive action, and
    /// archiving takes the row off the sidebar.
    ///
    /// Copy is asserted first, in the same menu, because "add an action" and
    /// "replace the menu" look identical from the new action alone -- and the
    /// older one working is part of the request.
    func testArchivingASessionRemovesItAndKeepsTheCopyAction() {
        let app = launch(session: nil)
        let row = expandFixtureWorkspace(in: app)

        // First menu: the action 0.9.3 already had, and the new one beside it.
        longPress(row)
        let copy = menuItem("Copy session ID", in: app)
        expect(copy, "the long-press menu no longer offers Copy session ID")
        expect(menuItem("Archive this session", in: app), "the long-press menu does not offer Archive this session")
        // Used rather than dismissed blindly: it puts the menu away and proves
        // the old action still does its job in the same breath.
        copy.tap()
        XCTAssertTrue(
            waitForDisappearance(copy, timeout: Self.patience),
            "choosing Copy session ID did not put the menu away",
        )

        // Second menu: the new action, on the row it belongs to.
        longPress(row)
        let archive = menuItem("Archive this session", in: app)
        expect(archive, "the long-press menu did not offer Archive this session the second time")
        archive.tap()

        XCTAssertTrue(
            row.waitForNonExistence(timeout: Self.patience),
            "the archived session is still drawn in the sidebar",
        )
        XCTAssertGreaterThanOrEqual(
            Self.mockMethodCounts()["session.archive"] ?? 0,
            1,
            "the row left the list without the host being asked to archive it",
        )
        XCTAssertEqual(
            Self.mockRefusedMethods()["session.archive"] ?? 0,
            0,
            "the fixture refused an archive the test expected it to take",
        )
    }

    /// A host that refuses the archive keeps the session.
    ///
    /// Archiving is non-destructive on the host and can be refused -- a running
    /// session, an unknown id -- so the phone must not remove a row it was told
    /// did not go. The failure is armed *before* the menu is opened, because
    /// the refusal has to land on the tap being measured rather than on a read
    /// the test happens to make first.
    ///
    /// The refusal is no longer announced in a row of its own: request failures
    /// go to the log, and the sidebar's link bar reports the link. What this
    /// pins is the part that matters -- the row stays, the host was asked, and
    /// a request failure is not mistaken for a broken link.
    func testRefusedArchiveKeepsTheSession() {
        let app = launch(session: nil)
        let row = expandFixtureWorkspace(in: app)

        XCTAssertTrue(
            Self.failMockHost("session.archive"),
            "the mock did not take the archive-refusal knob",
        )

        longPress(row)
        let archive = menuItem("Archive this session", in: app)
        expect(archive, "the long-press menu does not offer Archive this session")
        archive.tap()

        // The row must survive its own failed archive. Waiting first, rather
        // than asserting immediately: a success removes it, and an immediate
        // assertion would pass against an app that removed it a frame later.
        // The query covers both names a row can be drawn under -- the host's
        // title, and the directory-and-id fallback before the title lands.
        Thread.sleep(forTimeInterval: 2)
        XCTAssertTrue(row.exists, "a refused archive removed the session anyway")
        // A refusal is a request failure, and request failures no longer have a
        // row of their own: the sidebar's link bar reports the link, not a
        // request's answer. The row above and the mock's own count are the
        // evidence -- and the link must not be marked broken by it.
        let link = app.descendants(matching: .any)["sidebar.link"]
        XCTAssertTrue(link.exists, "the sidebar's link bar is missing")
        XCTAssertEqual(
            link.label,
            "Link OK, direct",
            "a refused archive marked the link as broken",
        )
        XCTAssertGreaterThanOrEqual(
            Self.mockRefusedMethods()["session.archive"] ?? 0,
            1,
            "the app removed the row without the host ever refusing an archive",
        )
    }

    // MARK: - Request 2: LAN mode

    /// On a local link the free account gets the paid surface, and the screens
    /// say which link it is.
    ///
    /// The mock is on loopback, so the LAN state is asked for with the Debug
    /// launch flag rather than produced by the fixture. What is asserted is the
    /// product rule: a direct link on the operator's own network costs the
    /// relay nothing, so attachments and the full running-turn detail are not
    /// paid features on it.
    func testLocalNetworkUnlocksPaidFeaturesAndSaysSo() {
        let app = launch(session: "first", pending: false, localNetwork: true)
        openSessionIfNeeded(app)

        // The paid feed's toggle only exists after the first detail read has
        // landed, so finding it is also proof the host was asked for the feed
        // by a free account -- which on a relay is not allowed.
        expectRunningRow(app)
        let detailToggle = app.buttons
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "turn details"))
            .firstMatch
        expect(detailToggle, "a LAN link did not unlock the running turn's detail for a free account")

        // Attachments: the commands window must not draw the paid lock at all.
        app.buttons["composer.commands"].tap()
        expect(app.buttons["composer.attach.photo"], "the commands window did not open")
        XCTAssertFalse(
            element("composer.attach.locked", in: app).exists,
            "a LAN link left attachments locked for a free account",
        )
        XCTAssertFalse(
            app.staticTexts["Paid accounts only"].exists,
            "the commands window still says attachments are paid-only on a LAN link",
        )
        // Put the window away before the sidebar: a popover in front of the
        // drawer is a second surface swallowing the taps meant for it.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
        XCTAssertTrue(
            waitForDisappearance(app.buttons["composer.attach.photo"], timeout: Self.patience),
            "the commands window did not close",
        )

        // The footer names the route, and the window behind it explains it and
        // says how often a running turn is re-read on this link.
        openSidebar(app)
        let footer = app.buttons["sidebar.connection"]
        expect(footer, "there is no connection control")
        XCTAssertTrue(
            labelLands(footer, containing: "LAN communication"),
            "the footer does not say the link is the local network: \(footer.label)",
        )
        footer.tap()
        expect(element("connection.panel", in: app), "the connection window did not open")
        expect(
            app.staticTexts["On the local network"],
            "the connection window does not say the link is on the local network",
        )
        let poll = element("connection.poll", in: app)
        expect(poll, "the connection window does not say what the poll is doing")
        XCTAssertTrue(
            labelLands(poll, containing: "3 s"),
            "the LAN running-turn poll is not three seconds: \(poll.label)",
        )
        XCTAssertFalse(
            poll.label.contains("10 s"),
            "the LAN poll is still on the relay's ten-second cadence: \(poll.label)",
        )
    }

    // MARK: - Request 3: foreground recovery

    /// Coming back from the home screen reconnects without anybody tapping
    /// Reconnect.
    ///
    /// The screen is a poor witness here: after a background return it settles
    /// on the same data whether or not it reconnected, and a footer that says
    /// Connected may be a stale snapshot. The socket count on the host is the
    /// fact, so the test reads it before and after and compares.
    func testReturningToTheForegroundReconnects() {
        // Nothing selected: the sidebar, and with it the footer, is the screen
        // that is out when the app comes back.
        let app = launch(session: nil, pending: false)
        let footer = app.buttons["sidebar.connection"]
        expect(footer, "there is no connection control")
        XCTAssertTrue(
            labelLands(footer, containing: "Connected"),
            "the app never came up connected: \(footer.label)",
        )
        // The launch's own reads and re-handshakes are not what this measures;
        // let them settle before the count is taken.
        Thread.sleep(forTimeInterval: 2)
        let before = Self.mockConnections()
        XCTAssertNotNil(before, "the mock host did not report its connection count")

        XCUIDevice.shared.press(.home)
        // Long enough that a phone would have suspended the app, short enough
        // that the test does not spend its patience behind the home screen.
        // What the reconnect costs is measured by polling below, not by this.
        Thread.sleep(forTimeInterval: 1.5)
        app.activate()

        XCTAssertTrue(
            labelLands(footer, containing: "Connected"),
            "the app came back without reconnecting: \(footer.label)",
        )

        // Polled, because the reconnect is a round trip that lands after the
        // screen is already back: a single count read after `activate()` would
        // be an assertion about the simulator's scheduler.
        var after = before
        let deadline = Date().addingTimeInterval(Self.patience)
        while Date() < deadline {
            after = Self.mockConnections()
            if let before, let after, after > before { break }
            Thread.sleep(forTimeInterval: 0.5)
        }
        if let before, let after {
            XCTAssertGreaterThan(
                after,
                before,
                "returning from the background did not open a new connection",
            )
        } else {
            XCTFail("the mock host stopped reporting its connection count")
        }
    }

    // MARK: - Launching

    /// Launch the app against the mock, optionally opening a session on the way
    /// in, with a clean fixture and a forced English interface.
    ///
    /// - Parameters:
    ///   - session: a session to open, or `nil` to stay on the list.
    ///   - pending: whether the mock should offer a pending approval and
    ///     question. Its cards fill a phone screen, which is correct and in the
    ///     way of a test about what is underneath them.
    ///   - running: whether the mock's session reports itself as running, which
    ///     is what puts the running row (and the detail feed) on screen.
    ///   - localNetwork: whether to force the Debug LAN state, so the LAN copy
    ///     and unlocks can be exercised against a loopback fixture.
    /// - Returns: the running application.
    private func launch(
        session: String? = nil,
        pending: Bool = true,
        running: Bool = true,
        localNetwork: Bool = false,
    ) -> XCUIApplication {
        Self.resetMockHost(pending: pending, running: running)
        var arguments: [String] = [
            "-mizarPairURI", Self.mockPairingURI,
            "-mizarFreshStart",
            "-mizarSkipPermissionPrompts", "-mizarSkipLoginGate", "-mizarCreditsFixture",
            // The fixture answers on a direct address; the transport switches
            // default to off, and without this the app lands on "The transport
            // switches are off" instead of a conversation.
            "-mizarDirectConnection", "-mizarSkipSplash",
            "-mizarAccountFreshStart",
            "-mizarAccountURL", Self.mockBaseURL,
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        if let session { arguments += ["-mizarSelectSession", session] }
        if localNetwork { arguments += ["-mizarLocalNetwork"] }
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
        dismissNamingIfPresented(app)
        return app
    }

    /// Make sure the requested conversation is on screen.
    ///
    /// `-mizarSelectSession` normally opens it on launch, but the selection is
    /// applied after the first session-list read; a test that starts before
    /// that read lands sits on the list and waits for a row that belongs to
    /// another screen. Tapping the fixture's row is the same thing a person
    /// would do and removes that race. Copied from `ActivityUITests`, which has
    /// been living with the same race.
    ///
    /// - Parameter app: the running app.
    private func openSessionIfNeeded(_ app: XCUIApplication) {
        if app.textViews["composer.field"].waitForExistence(timeout: 5) { return }
        if !app.buttons["sessions.new"].exists {
            app.buttons["shell.sidebarToggle"].tap()
        }
        let workspace = app.buttons["workspace./Users/you/projects/demo"]
        if workspace.waitForExistence(timeout: 5), workspace.exists {
            workspace.tap()
        }
        let row = sessionRowButton(in: app)
        if row.waitForExistence(timeout: 10), row.isHittable {
            row.tap()
        }
        _ = app.textViews["composer.field"].waitForExistence(timeout: 10)
    }

    /// Bring the sidebar out, if it is not out already.
    ///
    /// Idempotent: whether it is out depends on how the test launched -- a
    /// launch with nothing selected leaves it out, opening a session puts it
    /// away. The new-session row being hittable is the sidebar being in front.
    ///
    /// - Parameter app: the running app.
    private func openSidebar(_ app: XCUIApplication) {
        let marker = app.buttons["sessions.new"]
        if marker.exists, marker.isHittable { return }
        let toggle = app.buttons["shell.sidebarToggle"]
        expect(toggle, "there is no way to open the sidebar")
        toggle.tap()
        let shown = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true"),
            object: marker,
        )
        XCTAssertEqual(XCTWaiter().wait(for: [shown], timeout: Self.patience), .completed, "the sidebar did not open")
    }

    // MARK: - The session list

    /// Expand the fixture's workspace and hand back the "Mock session" row.
    ///
    /// - Parameter app: the running app.
    /// - Returns: the row, once it is in the tree.
    private func expandFixtureWorkspace(in app: XCUIApplication) -> XCUIElement {
        openSidebar(app)
        let heading = app.buttons["workspace./Users/you/projects/demo"]
        let row = sessionRow(in: app, titled: "Mock session", in: "demo")
        XCTAssertTrue(
            expand(heading, revealing: row),
            "the fixture's session never appeared under its workspace",
        )
        return row
    }

    /// The button for the fixture's session, under either name it can be drawn
    /// with.
    ///
    /// The button, not the static text, is what a long press is meant for: the
    /// menu belongs to the row, and a press aimed at the text is a press aimed
    /// at the row by accident.
    ///
    /// - Parameter app: the running app.
    /// - Returns: the row's button.
    private func sessionRowButton(in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Mock session")).firstMatch
    }

    /// The row for one session, under either name it can be drawn with.
    ///
    /// The host's title once it has given one, and otherwise the working
    /// directory and the session's id -- so a query for the pretty name alone
    /// finds nothing on a phone whose host has not named the session yet.
    ///
    /// - Parameters:
    ///   - app: the running app.
    ///   - title: the host's title for the session.
    ///   - directory: the last path component of its working directory.
    /// - Returns: the element to tap or press.
    private func sessionRow(in app: XCUIApplication, titled title: String, in directory: String) -> XCUIElement {
        app.staticTexts.matching(
            NSPredicate(format: "label == %@ OR label BEGINSWITH %@", title, "\(directory) · "),
        ).firstMatch
    }

    /// Open a workspace and wait for a row inside it.
    ///
    /// Copied from `AppFlowTests`, comments and all: the heading's own title is
    /// what a person taps, and a tap at the centre of the button lands in the
    /// empty space between the title and the count and toggles nothing.
    ///
    /// - Parameters:
    ///   - heading: the workspace's heading, found by its identifier.
    ///   - row: a row that only exists inside the workspace.
    ///   - attempts: how many times to try.
    /// - Returns: whether the row turned up.
    @discardableResult
    private func expand(_ heading: XCUIElement, revealing row: XCUIElement, attempts: Int = 3) -> Bool {
        for _ in 0..<attempts {
            if row.exists { return true }
            guard heading.waitForExistence(timeout: 5), heading.isHittable else { continue }
            let title = heading.staticTexts.element(boundBy: 0)
            guard title.exists else { continue }
            title.tap()
            if row.waitForExistence(timeout: 3) { return true }
        }
        return row.exists
    }

    // MARK: - The long-press menu

    /// Long-press a row until its menu is offered.
    ///
    /// - Parameter element: the row to press.
    private func longPress(_ element: XCUIElement) {
        expect(element, "the row to long-press is not on screen")
        element.press(forDuration: 1.2)
    }

    /// One action in the long-press menu, wherever the OS put it.
    ///
    /// A context menu is a system surface, and how its actions appear has moved
    /// between OS versions: buttons here, menu items there. An exact-label
    /// search across every type is what keeps a menu that rendered correctly
    /// from reading as missing -- the same reason `AppFlowTests` tries several
    /// element types for its settings switches.
    ///
    /// - Parameters:
    ///   - title: the action's label in the forced English interface.
    ///   - app: the running app.
    /// - Returns: the element to tap.
    private func menuItem(_ title: String, in app: XCUIApplication) -> XCUIElement {
        let button = app.buttons[title]
        if button.waitForExistence(timeout: 3) { return button }
        return app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", title))
            .firstMatch
    }

    // MARK: - Expectations

    /// Wait for an element to exist.
    /// - Parameters:
    ///   - element: the element.
    ///   - message: what to say when it never appears.
    private func expect(_ element: XCUIElement, _ message: String) {
        XCTAssertTrue(
            element.waitForExistence(timeout: Self.patience),
            "\(message) (waited \(Self.patience)s)",
        )
    }

    /// Wait until an element's label says something.
    ///
    /// The labels here come from reads that land after the screen does, so a
    /// plain `label.contains` is an assertion about a snapshot taken at an
    /// arbitrary moment. Polling is what the rest of the suite does for the
    /// same reason.
    ///
    /// - Parameters:
    ///   - element: what to watch.
    ///   - text: what its label should contain.
    /// - Returns: whether it got there.
    private func labelLands(_ element: XCUIElement, containing text: String) -> Bool {
        let arrived = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", text),
            object: element,
        )
        return XCTWaiter().wait(for: [arrived], timeout: Self.patience) == .completed
    }

    /// Wait until an element is gone.
    /// - Parameters:
    ///   - element: what to watch.
    ///   - timeout: how long to wait.
    /// - Returns: whether it went away.
    private func waitForDisappearance(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }

    /// Wait until the conversation has drawn a running turn.
    /// - Parameter app: the running app.
    private func expectRunningRow(_ app: XCUIApplication) {
        let running = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "DeepSeeking for "))
            .firstMatch
        expect(running, "the conversation has no running turn to watch")
    }

    /// Find an element by accessibility identifier, whatever its type.
    ///
    /// - Parameters:
    ///   - identifier: the identifier.
    ///   - app: the running app.
    /// - Returns: the first matching descendant.
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Skip the naming prompt, which pairing offers once.
    /// - Parameter app: the launched app.
    private func dismissNamingIfPresented(_ app: XCUIApplication) {
        for _ in 0..<2 {
            let skip = app.buttons["rename.skip"]
            guard skip.waitForExistence(timeout: Self.namingPatience) else { return }
            guard skip.isHittable else {
                Thread.sleep(forTimeInterval: 0.4)
                continue
            }
            skip.tap()
            if !skip.waitForExistence(timeout: 2) { return }
            Thread.sleep(forTimeInterval: 0.4)
        }
    }

    // MARK: - The mock host

    /// Put the mock host's fixtures back, accounts and the new 0.9.4 state
    /// included.
    ///
    /// - Parameters:
    ///   - pending: whether the mock should offer a pending approval and
    ///     question.
    ///   - running: whether the fixture's session reports itself as running.
    private static func resetMockHost(pending: Bool = true, running: Bool = true) {
        var query: [String] = []
        if !pending { query.append("pending=0") }
        if !running { query.append("running=0") }
        _ = mockJSON("/reset" + (query.isEmpty ? "" : "?" + query.joined(separator: "&")))
    }

    /// Make the mock host fail every answer to one method, from now on.
    ///
    /// Cleared by the next `/reset`, like the rest of the mock's state. Checked
    /// rather than assumed: a knob that did not take turns every assertion after
    /// it into an assertion about something else.
    ///
    /// - Parameter method: the wire method to refuse.
    /// - Returns: whether the mock confirmed it is refusing that method.
    @discardableResult
    private static func failMockHost(_ method: String) -> Bool {
        guard let json = mockJSON("/fail?method=\(method)") else { return false }
        return (json["failMethod"] as? String) == method
    }

    /// What the mock host has been asked, by method, since the last reset.
    /// - Returns: method name to count.
    private static func mockMethodCounts() -> [String: Int] {
        guard let json = mockJSON("/loads"),
              let methods = json["methods"] as? [String: Any] else { return [:] }
        return methods.compactMapValues { ($0 as? NSNumber)?.intValue }
    }

    /// How many answers the mock host refused, by method, since the last reset.
    /// - Returns: method name to count.
    private static func mockRefusedMethods() -> [String: Int] {
        guard let json = mockJSON("/loads"),
              let methods = json["refusedMethods"] as? [String: Any] else { return [:] }
        return methods.compactMapValues { ($0 as? NSNumber)?.intValue }
    }

    /// How many sockets the mock host has accepted since the last reset.
    ///
    /// The one piece of evidence a reconnect leaves where a test can read it:
    /// the app's own screen looks the same after a reconnect as it did before.
    ///
    /// - Returns: the count, or `nil` when the mock is not answering.
    private static func mockConnections() -> Int? {
        guard let json = mockJSON("/connections") else { return nil }
        return json["connections"] as? Int
    }

    /// GET one mock-host endpoint and decode its JSON.
    /// - Parameter path: the path, starting with `/`.
    /// - Returns: the decoded object, or `nil`.
    private static func mockJSON(_ path: String) -> [String: Any]? {
        guard let url = URL(string: "\(mockBaseURL)\(path)") else { return nil }
        let done = DispatchSemaphore(value: 0)
        let box = Box()
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        URLSession.shared.dataTask(with: request) { data, _, _ in
            defer { done.signal() }
            guard let data else { return }
            box.value = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }.resume()
        // Bounded, because a mock host that is not running is a suite that is
        // about to fail on its own terms -- not one to hang on here.
        _ = done.wait(timeout: .now() + 6)
        return box.value
    }

    /// A value written on URLSession's queue and read after the semaphore.
    /// `@unchecked Sendable` with the semaphore as the synchronisation: the
    /// write happens before `signal()` and the read after `wait()`.
    private final class Box: @unchecked Sendable {
        var value: [String: Any]?
    }
}
