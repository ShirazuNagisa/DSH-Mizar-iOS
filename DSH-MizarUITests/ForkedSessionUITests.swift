//
//  ForkedSessionUITests.swift
//  DSH-MizarUITests
//
//  A "branch in a new conversation" is a top-level session, and the sidebar has
//  to draw it.
//
//  DSH's fork creates a *new* session whose header keeps the source as its
//  parent -- `parentSession: <source session>` and `isSeeded: true`, with no
//  `origin` at all, read off a real header on this machine. A delegated child
//  is the different thing: the same parent, plus `origin: "subagent"`. The
//  phone's list used to treat any parent as the subagent mark, so every forked
//  conversation was filtered out of the sidebar forever -- and, because the
//  filter sits in `WorkspaceCatalog`, a refresh could not bring it back.
//
//  The fixture (`/forked?on=1` in `scripts/mock-host.mjs`) reports both rows
//  at once, in the same workspace, with nothing but `origin` to tell them
//  apart. That is what makes the assertions here about the host's
//  classification rather than about a directory or a list membership: the fork
//  must be drawn, the delegated child must not.
//
//  The test covers the whole report:
//
//  - the row is listed (the regression: before the fix it never appeared);
//  - the subagent row is not (a fork is not a subagent, and the fix must not
//    buy the fork by exposing delegated children);
//  - a pull-to-refresh keeps it (the report said refreshing did not help, so
//    "the row survived the list being re-read" is its own assertion);
//  - tapping it opens the branch's own history.
//
//  Focused run (the mock hosts are started by the script):
//    scripts/ios.sh test-fast "iPhone 18 Pro" -only-testing:DSH-MizarUITests/ForkedSessionUITests
//

import XCTest

final class ForkedSessionUITests: XCTestCase {
    /// This class's mock-host primary port; the table is `MockPorts`.
    private static let mockPort = MockPorts.port(for: "ForkedSessionUITests")
    /// The mock host this suite drives.
    private static let mockPairingURI =
        "mizar://pair?h=127.0.0.1%3A\(mockPort)&c=MOCK-CODE&n=Mock%20Mac&v=1"
    private static let mockBaseURL = "http://127.0.0.1:\(mockPort)"
    /// How long to wait for the host (or a screen) to answer.
    private static let patience: TimeInterval = 20
    /// A naming prompt appears only on the first pairing; waiting the full
    /// `patience` when it does not appear would add twenty seconds per launch.
    private static let namingPatience: TimeInterval = 3

    /// The title the mock gives the forked conversation, from `session.stats`.
    ///
    /// Host data, not interface copy -- it is the fixture's own name for the
    /// session and does not follow the device's language.
    private static let forkedTitle = "Forked session"

    /// The id prefix a row without a title is drawn with, in `demo · <prefix>`.
    ///
    /// `SessionRowButton` falls back to the directory and the first eight
    /// characters of the session id until `session.stats` has delivered a
    /// title, and the row has to be findable in both shapes: an assertion that
    /// only knew the pretty name would fail on a slow title rather than on the
    /// filter this suite is about. Eight characters of
    /// `mock-forked-session-0001`.
    private static let forkedIdPrefix = "mock-for"

    /// One page of conversation, and the answer under it.
    private static let branchPrompt = "A branch of the parser work."
    private static let branchAnswer = "The branch kept the parser tests."

    override func setUp() {
        continueAfterFailure = false
        // The default fixture first, then the extra rows: `/reset` puts the
        // fork fixture back off, so the order is what puts it on. Checked rather
        // than assumed, because a knob that did not take turns every assertion
        // below into an assertion about the default fixture.
        Self.resetMockHost()
        XCTAssertTrue(
            Self.setForkedFixture(true),
            "the mock host did not take the forked-session fixture switch",
        )
    }

    /// The report, end to end: the forked conversation is listed, a refresh
    /// keeps it, and opening it shows the history it was branched with.
    func testAForkedSessionIsListedAndOpensItsBranchHistory() {
        // Nothing selected, so the sidebar is the screen -- which is where the
        // row was missing. The interaction cards are off: they fill the
        // conversation, and none of them has anything to do with the list.
        let app = launch()
        openSidebar(app)

        // The fixture's workspace holds both extra rows, but they start folded
        // and the title is fetched only for a drawn row, so opening it is also
        // what asks for the fork's name.
        let demo = app.buttons["workspace./Users/you/projects/demo"]
        expect(demo, "the fixture's workspace is missing")
        let row = forkedRow(in: app)
        XCTAssertTrue(
            expand(demo, revealing: row),
            "the forked session was not drawn under its workspace. "
                + "Diagnostics: \(sidebarDiagnostics(app))",
        )

        // The name, not just the fallback: titles land after the row does, one
        // `session.stats` request per drawn session. This is the assertion the
        // report fails -- with the parent mistaken for a subagent mark, neither
        // shape was ever drawn.
        XCTAssertTrue(
            app.staticTexts[Self.forkedTitle].waitForExistence(timeout: Self.patience),
            "the forked session never got its title. "
                + "Diagnostics: \(sidebarDiagnostics(app))",
        )

        // The delegated child shares the parent and the working directory, and
        // must stay out of the list. Given a moment for every asynchronous
        // title to land first, so this is an assertion about the settled list
        // rather than about a frame before the reads answered.
        Thread.sleep(forTimeInterval: 2)
        let leakedSubagent = app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS %@", "mock-sub"))
            .firstMatch
        XCTAssertFalse(
            leakedSubagent.exists,
            "a delegated child was drawn in the sidebar; the host's `origin` is what has to be honoured, "
                + "not the parent that a fork shares. Diagnostics: \(sidebarDiagnostics(app))",
        )

        // A refresh is the report's second sentence ("refresh did not help"):
        // the list is re-read from the host, and the forked row has to be there
        // afterwards. The read is asserted at the host before the row is, so
        // this cannot pass on a pull the scroll view ignored.
        let readsBefore = Self.mockSessionListReads()
        pullToRefresh(app)
        XCTAssertTrue(
            Self.waitForSessionListRead(above: readsBefore),
            "the pull-to-refresh never asked the host for the session list",
        )
        XCTAssertTrue(
            app.staticTexts[Self.forkedTitle].waitForExistence(timeout: Self.patience),
            "the forked session left the sidebar after the list was re-read. "
                + "Diagnostics: \(sidebarDiagnostics(app))",
        )

        // And the row is a conversation, not a dead one: opening it has to show
        // the history the branch was copied with. The mock answers the fork's
        // `session.messages` with one finished turn whose prompt and answer are
        // unlike the fixture session's, so the text on screen also says whose
        // conversation was opened.
        row.tap()
        expect(app.textViews["composer.field"], "tapping the forked session did not open its conversation")
        XCTAssertTrue(
            app.staticTexts[Self.branchPrompt].waitForExistence(timeout: Self.patience),
            "the forked conversation has no prompt: its history did not sync",
        )
        XCTAssertTrue(
            app.staticTexts[Self.branchAnswer].waitForExistence(timeout: Self.patience),
            "the forked conversation has no answer: its history did not sync",
        )
    }

    // MARK: - The subagent census

    /// The drawer's Subagents tab says how many children this session has.
    ///
    /// The count and the page come from the same session-list filter, so the
    /// test checks both halves: a tab that says "Subagents 1" over a page that
    /// lists the child, not a number invented for the control. `/forked?on=1`
    /// in `setUp` is what puts one delegated child in the list next to the
    /// forked session, which must not be counted.
    func testTheSubagentsTabCountsTheDelegatedChildren() {
        let app = launch(extra: [
            "-mizarSelectSession", "first",
            "-mizarOpenTurnIndex",
        ])

        let control = app.descendants(matching: .any)["side.tab.bar"]
        XCTAssertTrue(control.waitForExistence(timeout: Self.patience), "the drawer's page control never arrived")
        let segment = control.buttons
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Subagents"))
            .firstMatch
        XCTAssertTrue(segment.waitForExistence(timeout: Self.patience), "there is no Subagents segment")
        XCTAssertTrue(
            segment.label.contains("1"),
            "the Subagents segment does not count the fixture's child: \(segment.label)",
        )
        // Tap the segment rather than asking the launch argument for the page:
        // the argument is applied when the plane has a measured width, which is
        // not guaranteed before the drawer opens. A tap is also the thing the
        // operator does.
        segment.tap()

        // The page it opens is the same census: one row, for the child the
        // fixture delegated. A count with no row under it would be a number
        // about nothing.
        let child = app.descendants(matching: .any)["subagent.row.mock-subagent-session-0001"]
        XCTAssertTrue(
            child.waitForExistence(timeout: Self.patience),
            "the Subagents page did not list the delegated child. \(app.debugDescription)",
        )
    }

    // MARK: - Launching

    /// Launch the app against the mock, with a clean install and a forced
    /// English interface.
    ///
    /// The fixture is prepared in `setUp`, before the first list read.
    ///
    /// - Returns: the running application.
    private func launch(extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        // Terminate anything left from an earlier run before launching. A
        // suspended instance can make `launch()` attach to the old process
        // instead of starting one with these arguments.
        app.terminate()
        app.launchArguments = [
            "-mizarPairURI", Self.mockPairingURI,
            "-mizarFreshStart",
            "-mizarSkipPermissionPrompts", "-mizarSkipLoginGate", "-mizarSkipOnboarding", "-mizarCreditsFixture",
            // The fixture answers on a direct address; the transport switches
            // default to off, and without this the app lands on "The transport
            // switches are off" instead of a conversation.
            "-mizarDirectConnection", "-mizarLocalNetworkRoute", "-mizarSkipSplash",
            "-mizarAccountFreshStart",
            "-mizarAccountURL", Self.mockBaseURL,
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ] + extra
        app.launch()
        dismissNamingIfPresented(app)
        return app
    }

    /// Bring the sidebar out, if it is not out already.
    ///
    /// Idempotent: whether it is out depends on how the test launched, and the
    /// new-session row being hittable is the sidebar being in front.
    ///
    /// - Parameter app: the running app.
    private func openSidebar(_ app: XCUIApplication) {
        let marker = app.buttons["sessions.new"]
        // A launch with nothing selected leaves the list out, so this is
        // normally already true; it is checked rather than assumed because the
        // suite must not depend on which screen the launch happened to land on.
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

    /// The row that opens the fork's conversation, under either name it can be
    /// drawn with.
    ///
    /// The host's title once it has given one, and otherwise the directory and
    /// the id prefix -- so a query for the pretty name alone finds nothing on a
    /// phone whose host has not named the session yet, and a deep link into the
    /// list would race a request rather than measure the filter.
    ///
    /// - Parameter app: the running app.
    /// - Returns: the row's title text, which is the thing a tap lands on.
    private func forkedRow(in app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(
            NSPredicate(
                format: "label == %@ OR label BEGINSWITH %@",
                Self.forkedTitle,
                "demo · \(Self.forkedIdPrefix)",
            ),
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
            if row.waitForExistence(timeout: 5) { return true }
        }
        return row.exists
    }

    /// Pull the sidebar down, which is `ScrollView.refreshable`'s route into the
    /// same `session.list` read the report tried.
    ///
    /// Copied from `AppFlowTests`: a press and a drag, because `swipeDown()`
    /// gives the scroll view a different gesture than a finger does, and the
    /// refresh control is the thing being asked for.
    ///
    /// - Parameter app: the running app.
    private func pullToRefresh(_ app: XCUIApplication) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.28))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.88))
        start.press(forDuration: 0.1, thenDragTo: end)
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

    /// What the sidebar looks like right now.
    ///
    /// Diagnostics are part of the failure message on purpose: "the row is
    /// missing", "the row is there under its fallback", and "the sidebar never
    /// opened" are different bugs, and the assertion alone cannot tell them
    /// apart.
    ///
    /// - Parameter app: the running app.
    /// - Returns: a one-line description.
    private func sidebarDiagnostics(_ app: XCUIApplication) -> String {
        let texts = app.staticTexts.allElementsBoundByIndex.prefix(20).map { $0.label }
        return "sidebar=\(app.buttons["sessions.new"].exists)"
            + " staticTexts=\(texts)"
            + " forkFallback=\(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "demo · ")).count)"
            + " methods=\(Self.mockMethodCounts())"
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

    /// Put the mock host's default fixture back, interaction cards off.
    ///
    /// `/reset` also switches the fork fixture off, which is why `setUp` calls
    /// this first and asks for the fork rows second.
    private static func resetMockHost() {
        _ = mockJSON("/reset?pending=0")
    }

    /// Ask the mock host to list the forked conversation and the delegated
    /// child, or not to.
    ///
    /// Checked rather than assumed: a knob that did not take turns every
    /// assertion after it into an assertion about the default fixture, which is
    /// the one shape this suite exists to show is *not* being measured.
    ///
    /// - Parameter on: whether the two extra rows belong in the fixture.
    /// - Returns: whether the mock confirmed the state.
    @discardableResult
    private static func setForkedFixture(_ on: Bool) -> Bool {
        guard let json = mockJSON("/forked?on=\(on ? 1 : 0)") else { return false }
        return (json["forked"] as? Bool) == on
    }

    /// How many times the app has asked the host for the session list since the
    /// last reset.
    ///
    /// A refresh that the scroll view ignored and a refresh that ran look the
    /// same on screen, so "the list was re-read" is read at the host, where it
    /// is a fact.
    ///
    /// - Returns: the count, or zero when the mock is not answering.
    private static func mockSessionListReads() -> Int {
        mockMethodCounts()["session.list"] ?? 0
    }

    /// Wait for the app to ask the host for the session list again.
    ///
    /// Polled: the pull starts a LAN probe first, then the read, so the answer
    /// lands a few seconds after the gesture.
    ///
    /// - Parameter count: the read count taken before the refresh was asked for.
    /// - Returns: whether a newer read reached the host.
    private static func waitForSessionListRead(above count: Int) -> Bool {
        let deadline = Date().addingTimeInterval(Self.patience)
        while Date() < deadline {
            if mockSessionListReads() > count { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return mockSessionListReads() > count
    }

    /// What the mock host has been asked, by method, since the last reset.
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
    /// `@unchecked Sendable` with the semaphore as the synchronisation: the
    /// write happens before `signal()` and the read after `wait()`.
    private final class Box: @unchecked Sendable {
        var value: [String: Any]?
    }
}
