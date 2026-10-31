//
//  RunningDetailUITests.swift
//  DSH-MizarUITests
//
//  The paid running-turn detail as a growing feed, against
//  `scripts/mock-host.mjs`.
//
//  Two reports, one test each half:
//
//  - **A long turn's older details are reachable.** The area used to be one
//    host window and nothing more: there was no way back through a long turn.
//    It now pages by `beforeSeq`, so scrolling the detail to its top must ask
//    the host for the page before what it holds.
//  - **The feed accumulates instead of replaying.** Expanding re-waterfalls
//    the rows; collapsing and expanding again must not re-fetch what the phone
//    already has, and must not lose the older rows it was given. A request is
//    invisible from the screen -- the same rows come back -- so both claims are
//    read at the host: `/loads`'s `activityPages` counts the reads that carried
//    `beforeSeq`.
//
//  The fixture's long mode is asked for *before* launch (`/activity?count=120`)
//  because the first forward read after the app comes up is the window the rest
//  of the test pages away from. The default fixture (eight rows, growing three
//  per poll) is what `ActivityUITests` measures and is left exactly as it was.
//
//  Focused run (the mock hosts are started by the script):
//    scripts/ios.sh test-fast "iPhone 18 Pro" -only-testing:DSH-MizarUITests/RunningDetailUITests
//

import XCTest

final class RunningDetailUITests: XCTestCase {
    /// This class's mock-host primary port; the table is `MockPorts`.
    private static let mockPort = MockPorts.port(for: "RunningDetailUITests")
    /// The mock host this suite drives.
    private static let mockPairingURI =
        "mizar://pair?h=127.0.0.1%3A\(mockPort)&c=MOCK-CODE&n=Mock%20Mac&v=1"
    private static let mockBaseURL = "http://127.0.0.1:\(mockPort)"
    private static let patience: TimeInterval = 20
    private static let namingPatience: TimeInterval = 3

    /// How many distinct rows the long fixture exposes.
    ///
    /// The mock serves the newest twelve in a forward answer; the other 108 are
    /// one backwards page behind `beforeSeq`. Enough that the newest window
    /// cannot contain the marker row, small enough that a test scrolls through
    /// a window rather than a whole turn.
    private static let longActivityCount = 120

    /// A row that exists only in the older page.
    ///
    /// The newest of the older-only rows, immediately above the boundary the
    /// newest window ends on: after the page is folded in it is one short drag
    /// away, which keeps the test about paging rather than about scrolling a
    /// hundred rows.
    private static let olderRow = "Activity line 108 of 120"

    /// The newest row, which a forward read must have delivered.
    private static let newestRow = "Activity line 120 of 120"

    override func setUp() {
        continueAfterFailure = false
        // A clean fixture first, *then* the long one: `/reset` puts the default
        // eight-row feed back, so the order is what makes the first forward
        // read after launch the paging window this test measures.
        Self.resetMockHost()
        Self.setActivityCount(Self.longActivityCount)
    }

    /// Scrolling the detail back reads older rows; collapsing and re-expanding
    /// keeps them without asking the host again.
    func testScrollingBackReadsOlderDetailAndReexpandingDoesNotRefetch() {
        let app = launch(session: "first", paid: true)
        openSessionIfNeeded(app)

        // The chevron only exists once the first detail read has landed, so
        // this is also the proof the long window was fetched.
        expectRunningRow(app)
        // A first window before the chevron: it waits on one `session.activity`
        // answer, and that is a round trip. If it has not arrived in ten
        // seconds, the process is suspect rather than slow -- a stale instance
        // can survive `launch()` without this launch's arguments, which is a
        // signed-out app wearing this test's name. Relaunch once rather than
        // measure the wrong configuration; the state probe below says which
        // happened if it is still wrong.
        if !activityToggle(in: app).waitForExistence(timeout: 10) {
            app.terminate()
            app.launch()
            dismissNamingIfPresented(app)
            openSessionIfNeeded(app)
            expectRunningRow(app)
        }
        expect(
            activityToggle(in: app),
            "a paid account's running row has no detail chevron. Diagnostics: \(toggleDiagnostics(app))",
        )
        let toggle = activityToggle(in: app)
        toggle.tap()

        let detail = element("turn.activity.detail", in: app)
        expect(detail, "tapping the chevron did not open the detail area")
        // Rows are built lazily, so the claim is "there are rows", never "there
        // are this many".
        let rows = app.descendants(matching: .any).matching(identifier: "turn.activity.row")
        XCTAssertGreaterThan(rows.count, 0, "the detail opened with no rows in it")
        XCTAssertTrue(
            row(containing: Self.newestRow, in: app).waitForExistence(timeout: Self.patience),
            "the newest window's rows never arrived",
        )

        // The older page has not been asked for yet, and the row that only
        // exists in it cannot be on screen.
        let older = row(containing: Self.olderRow, in: app)
        XCTAssertFalse(
            older.exists,
            "the older-only row was on screen before the host was asked for an older page",
        )
        XCTAssertEqual(Self.mockActivityPages(), 0, "the app paged before the operator scrolled back")

        // Scroll the detail to its top: the host must be asked for the page
        // before the one it holds, and the older-only row must be drawn.
        XCTAssertTrue(
            scrollBackToOlderRow(detail, marker: older),
            "scrolling the detail to its top never drew the older-only row. "
                + "Diagnostics: \(detailDiagnostics(app))",
        )
        let pagesAfterReadingBack = Self.mockActivityPages()
        XCTAssertGreaterThan(
            pagesAfterReadingBack,
            0,
            "the older row appeared without a session.activity read carrying beforeSeq",
        )

        // Collapse and expand again. The feed is the phone's copy and the walk
        // is at the turn's beginning, so nothing here is worth a request.
        toggle.tap()
        XCTAssertTrue(
            waitForDisappearance(detail, timeout: Self.patience),
            "tapping the chevron again did not collapse the detail area",
        )
        toggle.tap()
        expect(detail, "the detail area did not reopen")
        // A reopened window starts at the newest row again, so wait for that
        // to land before measuring: the assertion below is about what the
        // *phone* does on opening, not about the opening scroll still moving.
        XCTAssertTrue(
            row(containing: Self.newestRow, in: app).waitForExistence(timeout: Self.patience),
            "the reopened detail did not start at the newest rows",
        )
        // Given time for a wrong eager reload to arrive, because a re-read that
        // happens a moment later is still a re-read.
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertEqual(
            Self.mockActivityPages(),
            pagesAfterReadingBack,
            "re-expanding asked the host for the older page again",
        )

        // The older rows are still in the accumulated feed: back at the newest
        // end, scroll the detail up again and find one with no new request.
        XCTAssertTrue(
            scrollBackToOlderRow(detail, marker: row(containing: Self.olderRow, in: app)),
            "the older row was lost by collapsing and re-expanding. "
                + "Diagnostics: \(detailDiagnostics(app))",
        )
        XCTAssertEqual(
            Self.mockActivityPages(),
            pagesAfterReadingBack,
            "scrolling back through rows the phone already holds fetched a page again",
        )
    }

    // MARK: - Launching

    /// Launch the app against the mock with a clean install, optionally as a
    /// paid account. The fixture itself is prepared in `setUp`, before the
    /// first forward read.
    ///
    /// - Parameters:
    ///   - session: a session to open, or `nil` to stay on the list.
    ///   - paid: whether to use the Debug paid-account flag, which is what makes
    ///     the running-turn detail available without walking the account
    ///     screens first.
    /// - Returns: the running application.
    private func launch(session: String? = nil, paid: Bool = false) -> XCUIApplication {
        var arguments: [String] = [
            "-mizarPairURI", Self.mockPairingURI,
            "-mizarFreshStart",
            "-mizarSkipPermissionPrompts", "-mizarSkipLoginGate", "-mizarCreditsFixture",
            // The fixture answers on a direct address; the transport switches
            // default to off, and without this the app lands on "The transport
            // switches are off" instead of a conversation.
            "-mizarDirectConnection", "-mizarLocalNetworkRoute", "-mizarSkipSplash",
            "-mizarAccountFreshStart",
            "-mizarAccountURL", Self.mockBaseURL,
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        if paid { arguments += ["-mizarMockPaid"] }
        if let session { arguments += ["-mizarSelectSession", session] }
        let app = XCUIApplication()
        // Terminate anything left from an earlier run before launching. A
        // suspended instance can make `launch()` attach to the old process
        // instead of starting one with these arguments, and an app without the
        // Debug paid flag is not the app this suite means to measure.
        app.terminate()
        app.launchArguments = arguments
        app.launch()
        dismissNamingIfPresented(app)
        return app
    }

    /// Make sure the requested conversation is on screen.
    ///
    /// `-mizarSelectSession` normally opens it on launch, but the selection is
    /// applied after the first session-list read; tapping the fixture's row is
    /// the same thing a person would do and removes that race. Copied from
    /// `ActivityUITests`, which has been living with the same race.
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
        let session = app.buttons
            .matching(NSPredicate(format: "label CONTAINS %@", "Mock session"))
            .firstMatch
        if session.waitForExistence(timeout: 10), session.isHittable {
            session.tap()
        }
        _ = app.textViews["composer.field"].waitForExistence(timeout: 10)
    }

    // MARK: - The detail area

    /// Wait until the conversation has drawn a running turn.
    ///
    /// - Parameter app: the running app.
    private func expectRunningRow(_ app: XCUIApplication) {
        let running = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "DeepSeeking for "))
            .firstMatch
        expect(running, "the conversation has no running turn to watch")
    }

    /// The running row's detail toggle, found by the label it carries.
    ///
    /// The row keeps its `turn.<number>` identifier for the other suites; the
    /// paid-only affordance is its "Show/Hide turn details" label.
    ///
    /// - Parameter app: the running app.
    /// - Returns: the toggle.
    private func activityToggle(in app: XCUIApplication) -> XCUIElement {
        app.buttons
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "turn details"))
            .firstMatch
    }

    /// A detail row whose accessibility label contains some text.
    ///
    /// A row is one combined accessibility element (`turn.activity.row`), so
    /// its label carries the category and the one-line detail; the entry's own
    /// text is matched there rather than on an inner `staticText`.
    ///
    /// - Parameters:
    ///   - text: what the row says.
    ///   - app: the running app.
    /// - Returns: the row.
    private func row(containing text: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", text))
            .firstMatch
    }

    /// Scroll the detail area towards older rows until one of them is drawn.
    ///
    /// The finger travels downwards, which moves the content down and so reveals
    /// rows above: the detail opens anchored to the newest line, and the older
    /// history is behind it. Repeated rather than done once because the first
    /// drag reaches the top of what is held and asks for a page; the rows that
    /// arrive are inserted above and a further drag is what reveals them.
    ///
    /// - Parameters:
    ///   - detail: the detail area's element.
    ///   - marker: the row to wait for.
    /// - Returns: whether the row turned up.
    private func scrollBackToOlderRow(_ detail: XCUIElement, marker: XCUIElement) -> Bool {
        expect(detail, "the detail area is not on screen")
        for _ in 0..<12 {
            if marker.exists { return true }
            let start = detail.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
            let end = detail.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9))
            start.press(forDuration: 0.05, thenDragTo: end)
            if marker.waitForExistence(timeout: 1) { return true }
        }
        return marker.exists
    }

    /// Why the running row stopped short of its detail chevron.
    ///
    /// The chevron needs a paid (or LAN-unlocked) account *and* at least one
    /// detail row, so the two conditions are probed separately: the row labels
    /// say whether the turn is running, and the commands window draws its paid
    /// lock only when the account is locked -- the cheapest honest read of the
    /// Debug paid flag from a UI test.
    ///
    /// - Parameter app: the running app.
    /// - Returns: a one-line description.
    private func toggleDiagnostics(_ app: XCUIApplication) -> String {
        let running = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "DeepSeeking"))
            .allElementsBoundByIndex
            .prefix(4)
            .map { $0.label }
        var attach = "not probed"
        let commands = app.buttons["composer.commands"]
        if commands.exists, commands.isHittable {
            commands.tap()
            if app.buttons["composer.attach.photo"].waitForExistence(timeout: 5) {
                attach = element("composer.attach.locked", in: app).exists ? "locked" : "unlocked"
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
            }
        }
        return detailDiagnostics(app)
            + " runningRows=\(running)"
            + " attach=\(attach)"
            + " link=\(app.descendants(matching: .any)["sidebar.link"].label)"
            + " sidebar=\(app.buttons["sessions.new"].exists)"
    }

    /// What the detail area looks like right now: the rows it has built, where
    /// it is scrolled to, and what the host has been asked.
    ///
    /// Diagnostics are part of the failure message on purpose: a UI test that
    /// fails on a scrolling list has to say which rows were on screen, because
    /// "the row is missing" and "the row is a hundred rows away" are different
    /// bugs and the assertion alone cannot tell them apart.
    ///
    /// - Parameter app: the running app.
    /// - Returns: a one-line description.
    private func detailDiagnostics(_ app: XCUIApplication) -> String {
        let rows = app.descendants(matching: .any).matching(identifier: "turn.activity.row")
        let labels = (0..<min(rows.count, 24)).map { index in
            rows.element(boundBy: index).label
        }
        let detail = element("turn.activity.detail", in: app)
        let toggle = activityToggle(in: app)
        return "detail=\(detail.exists)"
            + " frame=\(detail.exists ? "\(detail.frame)" : "none")"
            + " composer=\(app.textViews["composer.field"].exists)"
            + " rows=\(rows.count)"
            + " labels=\(labels)"
            + " olderRow=\(element("turn.activity.older", in: app).exists)"
            + " toggle=\(toggle.exists ? toggle.label : "missing")"
            + " pages=\(Self.mockActivityPages())"
            + " methods=\(Self.mockMethodCounts())"
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

    /// Wait until an element is gone.
    /// - Parameters:
    ///   - element: what to watch.
    ///   - timeout: how long to wait.
    /// - Returns: whether it went away.
    private func waitForDisappearance(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
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

    /// Put the mock host's fixtures back. The interaction cards are off: this
    /// screen is about the detail area under the running row.
    private static func resetMockHost() {
        _ = mockJSON("/reset?pending=0")
    }

    /// Expose a long activity fixture of `count` distinct rows.
    ///
    /// - Parameter count: how many rows the fixture's running turn has.
    private static func setActivityCount(_ count: Int) {
        _ = mockJSON("/activity?count=\(count)")
    }

    /// How many `session.activity` reads carried `beforeSeq` since the last
    /// reset: the host's count of the lazy pages the phone asked for.
    /// - Returns: the count, or zero when the mock is not answering.
    private static func mockActivityPages() -> Int {
        guard let json = mockJSON("/loads") else { return 0 }
        return json["activityPages"] as? Int ?? 0
    }

    /// What the mock host has been asked, by method, since the last reset.
    ///
    /// Diagnostic only: the failure this suite exists to catch is about *not*
    /// asking again, and the total count distinguishes "no page was ever
    /// requested" from "the request did not produce rows".
    ///
    /// - Returns: method name to count.
    private static func mockMethodCounts() -> [String: Int] {
        guard let json = mockJSON("/loads"),
              let methods = json["methods"] as? [String: Any] else { return [:] }
        return methods.compactMapValues { ($0 as? NSNumber)?.intValue }
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
    /// `@unchecked Sendable` with the semaphore as the synchronisation.
    private final class Box: @unchecked Sendable {
        var value: [String: Any]?
    }
}
