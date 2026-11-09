//
//  ActivityUITests.swift
//  DSH-MizarUITests
//
//  The paid full-detail feed for a running turn, against `scripts/mock-host.mjs`.
//
//  Two claims, and the first is the important one:
//
//  - a **free** account never calls `session.activity`. The feed is paid by
//    product decision, and a UI test cannot see a request that was not made --
//    so the assertion is read at the host, from the per-method counters the mock
//    exposes on `/loads`. A screen that hid the detail but kept polling would
//    pass every on-screen assertion and fail this one.
//  - a **paid** account gets a chevron on the running row, and tapping it opens
//    the bounded detail area with rows in it -- fed by the same method, which the
//    host can see being called.
//
//  The paid test launches with the Debug-only `-mizarMockPaid` flag. The real
//  paid flow through the account screen and invite redemption is covered by
//  AccountUITests; this suite isolates the feed and its presentation.
//
//  Focused run (the mock host must be up):
//    node scripts/mock-host.mjs 19420 &
//    scripts/ios.sh test "iPhone 18 Pro" -only-testing:DSH-MizarUITests/ActivityUITests
//

import XCTest

final class ActivityUITests: XCTestCase {
    /// This class's mock-host primary port; the table is `MockPorts`.
    private static let mockPort = MockPorts.port(for: "ActivityUITests")
    /// The mock host this suite drives.
    private static let mockPairingURI =
        "mizar://pair?h=127.0.0.1%3A\(mockPort)&c=MOCK-CODE&n=Mock%20Mac&v=1"
    private static let mockAccountURL = "http://127.0.0.1:\(mockPort)"
    private static let patience: TimeInterval = 20

    override func setUp() {
        continueAfterFailure = false
        Self.resetMockHost()
    }

    // MARK: - Free accounts

    /// A free account's running row has no chevron, and the host is never asked
    /// for the detail.
    func testFreeAccountNeverCallsSessionActivity() {
        let app = launch(session: "first")
        expectRunningRow(app)

        // Let the screen settle, then zero the host's counters and watch a full
        // poll interval with nothing to do. If the app were polling for a free
        // account -- even with the detail hidden -- the method would show up.
        Self.resetMockMethodCounts()
        Thread.sleep(forTimeInterval: 4.5)

        let methods = Self.mockMethodCounts()
        XCTAssertEqual(
            methods["session.activity"] ?? 0,
            0,
            "a free account called session.activity \(methods["session.activity"] ?? 0) time(s)",
        )
        XCTAssertFalse(
            activityToggle(in: app).exists,
            "a free account's running row offers the paid detail",
        )
    }

    // MARK: - Paid accounts

    /// A paid account's running row grows a chevron, and the detail opens under
    /// it and collapses again.
    func testPaidAccountExpandsRunningTurnDetail() {
        // The account/invite UI is covered by AccountUITests; here the paid
        // launch flag isolates the paid-only activity feed and its animation.
        let app = launch(session: "first", paid: true)
        expectRunningRow(app)

        // The chevron only exists once the first detail read has landed, so this
        // wait is also the proof that the paid feed was fetched.
        let toggle = activityToggle(in: app)
        expect(toggle, "a paid account's running row has no detail chevron")

        toggle.tap()
        let detail = element("turn.activity.detail", in: app)
        expect(detail, "tapping the chevron did not open the detail area")

        let rows = app.descendants(matching: .any).matching(identifier: "turn.activity.row")
        XCTAssertGreaterThan(rows.count, 0, "the detail area opened with no rows in it")

        let methods = Self.mockMethodCounts()
        XCTAssertGreaterThan(
            methods["session.activity"] ?? 0,
            0,
            "a paid account's detail area opened without the host being asked for it",
        )

        // Collapse reverses: the area goes away and the summary row stays.
        toggle.tap()
        let collapsed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: detail,
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [collapsed], timeout: Self.patience),
            .completed,
            "tapping the chevron again did not collapse the detail area",
        )
        XCTAssertTrue(activityToggle(in: app).exists, "the summary row left with the detail")
    }

    // MARK: - Helpers

    /// Launch the app against the mock, signed out, with a session open.
    ///
    /// - Parameter session: the session to open on the way in.
    /// - Returns: the running app.
    private func launch(session: String?, paid: Bool = false) -> XCUIApplication {
        Self.resetMockHost()
        let app = XCUIApplication()
        var arguments: [String] = [
            "-mizarPairURI", Self.mockPairingURI,
            "-mizarFreshStart",
            "-mizarSkipPermissionPrompts", "-mizarSkipLoginGate", "-mizarSkipOnboarding", "-mizarCreditsFixture",
            // The fixture answers on a direct address; the transport switches
            // default to off, and without this the app lands on "The transport
            // switches are off" instead of a conversation.
            "-mizarDirectConnection", "-mizarLocalNetworkRoute", "-mizarSkipSplash",
            "-mizarAccountURL", Self.mockAccountURL,
            "-mizarAccountFreshStart",
            "-AppleLanguages", "(en)",
        ]
        if paid { arguments += ["-mizarMockPaid"] }
        if let session { arguments += ["-mizarSelectSession", session] }
        app.launchArguments = arguments
        app.launch()
        dismissNamingIfPresented(app)
        if session != nil {
            openSessionIfNeeded(app)
        }
        return app
    }

    /// Wait until the conversation has drawn a running turn.
    ///
    /// - Parameter app: the running app.
    private func expectRunningRow(_ app: XCUIApplication) {
        let running = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "DeepSeeking for "))
            .firstMatch
        expect(running, "the conversation has no running turn to watch")
    }

    /// The paid running row, found by the label its Button carries.
    ///
    /// The row keeps its historical `turn.<number>` identifier for the other
    /// suites; the paid-only affordance is its "Show/Hide turn details"
    /// accessibility label, which is also what VoiceOver says.
    private func activityToggle(in app: XCUIApplication) -> XCUIElement {
        app.buttons
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "turn details"))
            .firstMatch
    }

    /// Make sure the requested conversation is on screen.
    ///
    /// `-mizarSelectSession` normally opens it on launch, but the selection is
    /// applied after the first session-list read; a test that starts before that
    /// read lands sits on Home and waits twenty seconds for a running row that
    /// belongs to another screen. Tapping the fixture's session row is the same
    /// thing a person would do and removes that race.
    private func openSessionIfNeeded(_ app: XCUIApplication) {
        if app.textViews["composer.field"].waitForExistence(timeout: 5) { return }
        if !app.buttons["sessions.new"].exists {
            app.buttons["shell.sidebarToggle"].tap()
        }
        // The fixture's session lives inside the collapsed `demo` workspace.
        // Expanding it is what a person would do; `-mizarSelectSession` normally
        // bypasses the sidebar, but that selection can race the first list read.
        let workspace = app.buttons["workspace./Users/you/projects/demo"]
        if workspace.waitForExistence(timeout: 5), workspace.exists {
            workspace.tap()
        }
        let row = app.buttons
            .matching(NSPredicate(format: "label CONTAINS %@", "Mock session"))
            .firstMatch
        if row.waitForExistence(timeout: 10), row.isHittable {
            row.tap()
        }
        _ = app.textViews["composer.field"].waitForExistence(timeout: 10)
    }

    /// Bring the sidebar out, if it is not out already.
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

    /// Find an element by accessibility identifier, whatever its type.
    ///
    /// - Parameters:
    ///   - identifier: the identifier.
    ///   - app: the running app.
    /// - Returns: the first matching descendant.
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

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

    /// Scroll the settings window until a row has been built.
    ///
    /// - Parameters:
    ///   - element: the row.
    ///   - app: the running app.
    /// - Returns: whether it turned up.
    @discardableResult
    private func revealInSettings(_ element: XCUIElement, in app: XCUIApplication, attempts: Int = 8) -> Bool {
        if element.waitForExistence(timeout: 3) { return true }
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.66))
        let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.46))
        for _ in 0..<attempts {
            from.press(forDuration: 0.05, thenDragTo: to)
            Thread.sleep(forTimeInterval: 0.45)
            if element.exists, element.isHittable { return true }
        }
        return element.exists
    }

    /// Skip the naming prompt, which pairing offers once.
    /// - Parameter app: the launched app.
    private func dismissNamingIfPresented(_ app: XCUIApplication) {
        for _ in 0..<2 {
            let skip = app.buttons["rename.skip"]
            guard skip.waitForExistence(timeout: Self.patience) else { return }
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

    /// Put the mock host's fixtures back, accounts included.
    private static func resetMockHost() {
        _ = mockJSON("/reset")
    }

    /// Zero the mock's per-method counters.
    private static func resetMockMethodCounts() {
        _ = mockJSON("/loads?reset=1")
    }

    /// The methods the app has asked the host for since the counters were reset.
    /// - Returns: the counts, by method name.
    private static func mockMethodCounts() -> [String: Int] {
        guard let json = mockJSON("/loads"),
              let methods = json["methods"] as? [String: Any] else { return [:] }
        return methods.compactMapValues { $0 as? Int }
    }

    /// GET one mock-host endpoint and decode its JSON.
    /// - Parameter path: the path, starting with `/`.
    /// - Returns: the decoded object, or `nil`.
    private static func mockJSON(_ path: String) -> [String: Any]? {
        guard let url = URL(string: "http://127.0.0.1:\(mockPort)\(path)") else { return nil }
        let done = DispatchSemaphore(value: 0)
        let box = Box()
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        URLSession.shared.dataTask(with: request) { data, _, _ in
            defer { done.signal() }
            guard let data else { return }
            box.value = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }.resume()
        _ = done.wait(timeout: .now() + 6)
        return box.value
    }

    /// A value written on URLSession's queue and read after the semaphore.
    private final class Box: @unchecked Sendable {
        var value: [String: Any]?
    }
}
