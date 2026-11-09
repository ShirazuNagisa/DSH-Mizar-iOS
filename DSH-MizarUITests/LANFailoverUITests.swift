//
//  LANFailoverUITests.swift
//  DSH-MizarUITests
//
//  The LAN going away must switch the phone to the relay, not loop on the dead
//  address.
//
//  A pairing can carry two routes to the same computer: the direct address the
//  QR code's `h` names, and a reverse tunnel's base URL its `u` names. The app
//  prefers the direct one -- same network, nobody else's bandwidth -- and keeps
//  the relay as the fallback. The reported bug: the phone was connected over the
//  LAN, the LAN died, and every reconnect dialled the address it had just lost.
//  The relay was in the same pairing, unused, while the operator watched a
//  reconnect loop.
//
//  Reproducing it needs a computer whose LAN address is gone while the same
//  computer is still reachable at its relay address. `scripts/mock-host.mjs`
//  serves exactly that: a relay stand-in listener on `port + 2`
//  (`ws://127.0.0.1:19397/r/mock-room/mizar/v1/ws`, same process, same fixture,
//  same device token), and `/lan?off=1` on the main port, which drops the live
//  direct sockets and refuses new direct upgrades while the plain HTTP surface
//  -- and the relay listener -- keep answering.
//
//  What this suite measures, and where:
//
//  - **Where the app is now is read at the hosts, not on the screen.** The
//    direct listener's `/connections` counts direct sockets and the relay's
//    counts relayed ones, so "it failed over" is one number going from zero to
//    one rather than a label that might be a stale snapshot.
//  - **The footer names the route.** `sidebar.connection` carries the status and
//    the route in one accessibility label ("Connected, Through the relay"), and
//    the label is required to say both -- a Connected footer on the relay route
//    is the whole fix.
//  - **The app is allowed the report's twenty seconds.** A dead LAN is not
//    noticed by magic: the running poll has a ten-second tick, the direct dial
//    has to run out, and only then can the relay answer. The bug spends its
//    three direct attempts and gives up; the fix falls through to the relay
//    inside that same reconnect.
//
//  Focused run (the mock hosts are started by the script):
//    scripts/ios.sh test-fast "iPhone 18 Pro" -only-testing:DSH-MizarUITests/LANFailoverUITests
//

import XCTest

final class LANFailoverUITests: XCTestCase {
    /// This class's mock-host primary port; the table is `MockPorts`.
    private static let mockPort = MockPorts.port(for: "LANFailoverUITests")
    /// The mock host's main listener: the computer's own address.
    private static let mockBaseURL = "http://127.0.0.1:\(mockPort)"
    /// The relay stand-in's listener, on `port + 2`, at the room the pairing URI
    /// names. Its `/connections` counts relayed sockets and nothing else.
    private static let mockRelayBaseURL = "http://127.0.0.1:\(mockPort + 2)"

    /// A pairing with both routes in one URI.
    ///
    /// `h` is the direct address (what the app dials first, and the route the
    /// app must *leave*), `u` is the relay base URL the app turns into
    /// `ws://127.0.0.1:<mockPort + 2>/r/mock-room/mizar/v1/ws` (the route it must fall
    /// back to). One URI carrying both is the arrangement the bug is about: the
    /// fallback exists, and a reconnect that never names it is a route plan with
    /// one route in it.
    ///
    /// The two are percent-encoded exactly as a QR code carries them.
    private static let mockPairingURI =
        "mizar://pair?h=127.0.0.1%3A\(mockPort)&c=MOCK-CODE&n=Mock%20Mac&v=1"
        + "&u=http%3A%2F%2F127.0.0.1%3A\(mockPort + 2)%2Fr%2Fmock-room"

    /// How long the app gets to notice the LAN is gone and be back on the relay.
    ///
    /// Twenty seconds is the report's own budget, and it is deliberately not
    /// shorter: the running poll ticks every ten, the dead direct attempt has to
    /// run out, and only then does the relay get dialled. It is also not longer,
    /// because the bug is not "slow" -- the buggy build gives up after three
    /// direct attempts and does not try again for half a minute.
    private static let failoverPatience: TimeInterval = 20
    /// How long a launch gets to prove it carried this test's arguments.
    ///
    /// The proof is a pairing request reaching the host, and a launch against
    /// the mock pairs in about a second. The budget is generous because the
    /// first launch attempt is allowed to lose a race -- see ``launch()`` --
    /// and the retry then has to pay for a fresh launch.
    private static let launchPatience: TimeInterval = 15
    /// How long to wait for a screen (or the host) to answer.
    private static let patience: TimeInterval = 20
    /// A naming prompt appears only on the first pairing; waiting the full
    /// `patience` when it does not appear would add twenty seconds per launch.
    private static let namingPatience: TimeInterval = 3
    /// How long between reads of the footer and the host counters while the
    /// failover is being waited on.
    private static let pollInterval: TimeInterval = 0.5

    override func setUp() {
        continueAfterFailure = false
        // Every test starts against the default fixture, with the LAN up: the
        // launch pairs as it always did, and nothing about the failover is
        // pending. `/reset` also puts the LAN back, so an interrupted run
        // cannot hand the next suite a computer that refuses its own address.
        Self.resetMockHost()
    }

    /// The report: connected over the LAN, the LAN goes away, and the phone comes
    /// back over the relay without anybody touching it.
    func testTheLANGoingAwayFailsOverToTheRelay() {
        let app = launch()
        // Pairing finishes on the session list; the footer is the screen's own
        // answer to "how am I reaching the computer".
        expect(app.buttons["sessions.new"], "the session list never arrived")
        openSidebar(app)
        let connection = app.buttons["sidebar.connection"]
        expect(connection, "there is no connection control")

        // The starting state the report describes: connected, over the direct
        // address, with no relay socket at all. Read at the hosts, because the
        // footer alone cannot say which listener the socket went to.
        XCTAssertTrue(
            labelLands(connection, containing: "Connected"),
            "the app never came up connected: \(connection.label)",
        )
        XCTAssertGreaterThanOrEqual(
            Self.mockConnections(Self.mockBaseURL) ?? 0,
            1,
            "the direct listener has no socket: the app did not connect over the LAN",
        )
        XCTAssertEqual(
            Self.mockConnections(Self.mockRelayBaseURL) ?? -1,
            0,
            "the relay was dialled before the LAN went away",
        )

        // The LAN goes away. The HTTP surface stays up -- that is how the
        // failure is asked for and how the fixture is put back -- and the relay
        // listener is untouched, which is the entire situation being tested.
        XCTAssertTrue(
            Self.setLAN(off: true),
            "the mock did not take the LAN-off switch. Diagnostics: \(diagnostics(app, connection))",
        )

        // Notice the dead socket, redial, fall through to the relay. The
        // assertion polls because every part of it is a round trip: the socket
        // close has to be seen, the poll has to tick, the direct dial has to
        // fail, and only then does the relay answer.
        let failedOver = waitForRelay(connection: connection)
        XCTAssertTrue(
            failedOver,
            "the app never failed over to the relay. It is still on the dead LAN route. "
                + "Diagnostics: \(diagnostics(app, connection))",
        )
        // And it did not get there by accident: the relay listener is the one
        // that took the socket, after having none.
        XCTAssertGreaterThanOrEqual(
            Self.mockConnections(Self.mockRelayBaseURL) ?? 0,
            1,
            "the footer says relay but the relay listener never accepted a socket",
        )

        // Put the LAN back. The app stays on the relay -- it has a working socket
        // and no reason to move -- and the next suite inherits a fixture whose
        // direct address answers again.
        XCTAssertTrue(Self.setLAN(off: false), "the mock did not take the LAN-on switch")
    }

    // MARK: - Waiting for the failover

    /// Wait until the footer says Connected over the relay and the relay
    /// listener holds a socket.
    ///
    /// Polled rather than asserted once, because the switch is a sequence of
    /// separate facts that land seconds apart. A failure is diagnosed by what
    /// the footer last said and what each listener was asked, which is why
    /// ``diagnostics(_:_:)`` exists.
    ///
    /// - Parameters:
    ///   - connection: the footer element.
    ///   - timeout: how long the app gets.
    /// - Returns: whether all three facts held together before the deadline.
    private func waitForRelay(
        connection: XCUIElement,
        timeout: TimeInterval = LANFailoverUITests.failoverPatience,
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let label = connection.exists ? connection.label : ""
            let relayed = Self.mockConnections(Self.mockRelayBaseURL) ?? 0
            if label.contains("Connected"), label.contains("Through the relay"), relayed >= 1 {
                return true
            }
            Thread.sleep(forTimeInterval: Self.pollInterval)
        }
        return false
    }

    // MARK: - Launching

    /// Launch the app against the mock with both routes paired in one URI, and a
    /// clean install.
    ///
    /// Retried, because the first launch of a run is not always this test's.
    /// A run reinstalls the app, and a Live Activity left by an earlier run
    /// makes the system open the app *by itself* at that moment -- an activation
    /// with no arguments, which connects from the stored (single-route) pairing.
    /// `XCUIApplication.launch()` can end up driving that process, and then the
    /// app was never told about the relay and the failover below measures the
    /// wrong launch.
    ///
    /// So a launch is only accepted once the host has seen the pairing request
    /// that only a launch carrying `-mizarPairURI` makes. Anything else is
    /// terminated and tried again; the system's one-shot activation does not
    /// come back.
    ///
    /// - Returns: the running application, launched with these arguments.
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        let arguments = [
            "-mizarPairURI", Self.mockPairingURI,
            "-mizarFreshStart",
            "-mizarSkipPermissionPrompts", "-mizarSkipLoginGate", "-mizarSkipOnboarding", "-mizarCreditsFixture",
            // The fixture answers on a direct address; the transport switches
            // default to off, and without this the app lands on "The transport
            // switches are off" instead of a conversation.
            "-mizarDirectConnection", "-mizarSkipSplash",
            "-mizarAccountFreshStart",
            "-mizarAccountURL", Self.mockBaseURL,
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        for attempt in 1...4 {
            app.terminate()
            waitForTermination(app)
            let pairingsBefore = Self.mockPairings()
            app.launchArguments = arguments
            app.launch()
            if Self.waitForPairing(above: pairingsBefore) {
                dismissNamingIfPresented(app)
                return app
            }
            NSLog("LANFailoverUITests: launch attempt %d was not started with this test's arguments", attempt)
            app.terminate()
        }
        XCTFail(
            "the app never launched with this test's arguments: no pairing request reached the host "
                + "in any of four launches",
        )
        return app
    }

    /// Wait until the app process is actually gone.
    ///
    /// `terminate()` returns before the process has necessarily finished
    /// dying, and a launch issued in that window can attach to the process
    /// that is on its way out -- which is how a launch with arguments ends up
    /// running a process that never saw them.
    ///
    /// - Parameter app: the application proxy.
    private func waitForTermination(_ app: XCUIApplication) {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, app.state != .notRunning {
            Thread.sleep(forTimeInterval: 0.1)
        }
        // A moment for any system activation already queued to show up as a
        // process; the loop's next `terminate()` is what deals with it.
        Thread.sleep(forTimeInterval: 0.4)
    }

    /// Bring the sidebar out, if it is not out already.
    ///
    /// Idempotent: a launch with nothing selected leaves the list out, so this
    /// is normally already true; it is checked rather than assumed because the
    /// suite must not depend on which screen the launch happened to land on.
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
    /// Labels here come from reads that land after the screen does, so a plain
    /// `label.contains` is an assertion about a snapshot taken at an arbitrary
    /// moment. Polling is what the rest of the suite does for the same reason.
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

    /// What the screen and both listeners look like right now.
    ///
    /// Diagnostics are part of the failure message on purpose: "the footer never
    /// went back to Connected", "the app reconnected somewhere the relay did not
    /// see" and "the app never noticed the socket died" are different bugs, and
    /// the assertion alone cannot tell them apart.
    ///
    /// - Parameters:
    ///   - app: the running app.
    ///   - connection: the footer element.
    /// - Returns: a one-line description.
    private func diagnostics(_ app: XCUIApplication, _ connection: XCUIElement) -> String {
        "footer=\(connection.exists ? connection.label : "missing")"
            + " pairings=\(Self.mockPairings())"
            + " direct=\(Self.mockConnections(Self.mockBaseURL).map(String.init) ?? "unreachable")"
            + " relay=\(Self.mockConnections(Self.mockRelayBaseURL).map(String.init) ?? "unreachable")"
            + " sidebar=\(app.buttons["sessions.new"].exists)"
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

    /// Put the mock host's fixtures back, interaction cards off.
    ///
    /// `/reset` also puts the LAN back, so this is what makes every test start
    /// from the default fixture whatever the last one did. The running session is
    /// left on: it is what the app's own running poll is watching, and that poll
    /// is the tick that notices the dead socket.
    private static func resetMockHost() {
        _ = mockJSON(Self.mockBaseURL, "/reset?pending=0")
    }

    /// Take the LAN away, or put it back.
    ///
    /// Checked rather than assumed: a knob that did not take would turn the
    /// assertion into one about a host that never failed in the first place.
    ///
    /// - Parameter off: whether the direct address should stop answering.
    /// - Returns: whether the mock confirmed the state.
    @discardableResult
    private static func setLAN(off: Bool) -> Bool {
        guard let json = mockJSON(Self.mockBaseURL, "/lan?\(off ? "off" : "on")=1") else { return false }
        return (json["lan"] as? String) == (off ? "off" : "on")
    }

    /// How many WebSocket sockets one listener has accepted since the last reset.
    ///
    /// The main port's count is the direct route; the relay port's count is the
    /// relayed one. Read at the host because the footer only names the route it
    /// *believes* it is on, and the assertion here is about which listener
    /// actually took the socket.
    ///
    /// - Parameter baseURL: which listener to ask.
    /// - Returns: the count, or `nil` when that listener is not answering.
    private static func mockConnections(_ baseURL: String) -> Int? {
        guard let json = mockJSON(baseURL, "/connections") else { return nil }
        return json["connections"] as? Int
    }

    /// How many pairing requests the main listener has answered since the last
    /// reset.
    ///
    /// The launch's own footprint: a launch carrying `-mizarPairURI` pairs
    /// before it connects, and a launch the system performed with no arguments
    /// cannot. Read at the host because the app's process arguments are not
    /// observable from a UI test.
    ///
    /// - Returns: the count, or zero when the mock is not answering.
    private static func mockPairings() -> Int {
        guard let json = mockJSON(Self.mockBaseURL, "/loads") else { return 0 }
        return json["pairings"] as? Int ?? 0
    }

    /// Wait for a fresh pairing request to reach the host.
    ///
    /// - Parameter count: the pairing count taken before the launch.
    /// - Returns: whether the host answered a newer pairing request.
    private static func waitForPairing(above count: Int) -> Bool {
        let deadline = Date().addingTimeInterval(Self.launchPatience)
        while Date() < deadline {
            if mockPairings() > count { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return mockPairings() > count
    }

    /// What the mock host has been asked, by method, since the last reset.
    /// - Returns: method name to count.
    private static func mockMethodCounts() -> [String: Int] {
        guard let json = mockJSON(Self.mockBaseURL, "/loads"),
              let methods = json["methods"] as? [String: Any] else { return [:] }
        return methods.compactMapValues { ($0 as? NSNumber)?.intValue }
    }

    /// GET one mock-host endpoint and decode its JSON.
    /// - Parameters:
    ///   - baseURL: the listener to ask.
    ///   - path: the path, starting with `/`.
    /// - Returns: the decoded object, or `nil`.
    private static func mockJSON(_ baseURL: String, _ path: String) -> [String: Any]? {
        guard let url = URL(string: "\(baseURL)\(path)") else { return nil }
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
