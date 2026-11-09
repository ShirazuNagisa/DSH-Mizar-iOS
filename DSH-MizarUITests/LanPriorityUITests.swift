//
//  LanPriorityUITests.swift
//  DSH-MizarUITests
//
//  The Settings' Transfer switch, 局域网优先 / "Local network first", and the one
//  behaviour it decides: whether a reconnect asks the local network before it
//  settles for the stored route.
//
//  Off (the default) is the fast path the feature exists for: a manual refresh
//  must go straight to the stored route, with no probe. On, the same refresh is
//  allowed to ask the LAN question first and fall back to the relay.
//
//  The probe is invisible from the screen -- a scan that finds nothing and a
//  scan that never ran look identical -- so the evidence is read at the host.
//  `scripts/mock-host.mjs` counts inbound `GET /mizar/v1/hello` requests, which
//  is exactly the scan's question, and reports the number on `/hellos`
//  (reset by `/reset`). The assertions are deltas around one pull-to-refresh:
//  no growth with the switch off, growth with it on.
//
//  The switch itself is read as a switch: its accessibility `value` ("0"/"1"),
//  not the label, so the test does not depend on interface copy. It is turned
//  back off at the end -- the app's defaults outlive a reinstall, and a suite
//  that left a setting on would hand the next suite (and its own next run) a
//  different app.
//
//  Focused run (the mock hosts are started by the script):
//    scripts/ios.sh test-fast "iPhone 18 Pro" -only-testing:DSH-MizarUITests/LanPriorityUITests
//

import XCTest

final class LanPriorityUITests: XCTestCase {
    /// This class's mock-host primary port; the table is `MockPorts`.
    private static let mockPort = MockPorts.port(for: "LanPriorityUITests")
    /// The mock host this suite drives.
    private static let mockPairingURI =
        "mizar://pair?h=127.0.0.1%3A\(mockPort)&c=MOCK-CODE&n=Mock%20Mac&v=1"
    private static let mockBaseURL = "http://127.0.0.1:\(mockPort)"

    /// The switch under test.
    ///
    /// Its identifier, not its label: "Local network first" is interface copy
    /// and the identifier is the contract with the screen.
    private static let toggleIdentifier = "settings.transfer.lanPriority"

    /// How long to wait for the host (or a screen) to answer.
    private static let patience: TimeInterval = 20
    /// A naming prompt appears only on the first pairing; waiting the full
    /// `patience` when it does not appear would add twenty seconds per launch.
    private static let namingPatience: TimeInterval = 3
    /// How long a launch gets to prove it carried this test's pairing arguments.
    ///
    /// Same race as the other suites: a run reinstalls the app, and a Live
    /// Activity left by an earlier run can make the system open the app by
    /// itself with no arguments. A launch is only accepted once the host has
    /// answered a pairing request, which only the requested launch can make.
    private static let launchPatience: TimeInterval = 15
    /// How long to let a refresh settle before the probe count is read.
    ///
    /// The scan runs *before* the session-list read the refresh ends with, so a
    /// probe cannot arrive after it -- but a straggling one is the failure this
    /// test exists to catch, so it is given a moment to land rather than the
    /// absence being asserted at the first instant it could be true.
    private static let refreshSettle: TimeInterval = 0.7

    override func setUp() {
        continueAfterFailure = false
        // Every test starts from the default fixture. The session is reported
        // as stopped (`running=0`): this suite is about transfers and scans, and
        // a posted Live Activity would be a second process in the way.
        Self.resetMockHost()
    }

    /// The report, end to end: the switch starts off and means "do not scan";
    /// turning it on means "scan"; and the choice survives a relaunch.
    func testLocalNetworkFirstGatesTheScanAndSurvivesARelaunch() {
        let app = launchPaired()
        openSidebar(app)
        openSettings(app)

        // The switch exists, in a section a person can reach, and starts off.
        // The rows below Live Activity are below the fold of the settings
        // window, and a lazy `List` has not built them yet, so it is scrolled to.
        let found = settingControl(Self.toggleIdentifier, in: app)
        XCTAssertTrue(
            revealInSettings(found, in: app, attempts: 10),
            "there is no Local network first switch in the settings. Diagnostics: \(settingsDiagnostics(app))",
        )
        let control = settingControl(Self.toggleIdentifier, in: app)
        // The state is what makes this a switch rather than a row that merely
        // carries the identifier; the label is interface copy and is asserted by
        // the language test rather than here.
        XCTAssertNotNil(
            settingState(Self.toggleIdentifier, in: app),
            "the switch reports no state to read: \(control.debugDescription)",
        )

        // Default off. A previous interrupted run can have left the switch on --
        // the app's defaults outlive a reinstall, unlike its conversations -- so
        // a stale value is put back first. On an install that has never had the
        // switch touched (the first run of this suite, and any fresh container)
        // the read below is the product's default itself, and the assertions
        // that follow are what it buys: a refresh that does not probe.
        if settingState(Self.toggleIdentifier, in: app) == true {
            flip(control, in: app)
            XCTAssertTrue(
                settingChanges(Self.toggleIdentifier, in: app, from: true),
                "the Local network first switch could not be turned off",
            )
        }
        XCTAssertEqual(
            settingState(Self.toggleIdentifier, in: app),
            false,
            "the Local network first switch is not off by default",
        )

        // --- Off: a refresh must not probe the local network ------------------
        closeSettings(app)
        var probes = Self.mockHellos()
        var reads = Self.mockSessionListReads()
        pullToRefresh(app)
        XCTAssertTrue(
            Self.waitForSessionListRead(above: reads),
            "the pull-to-refresh never asked the host for the session list",
        )
        Thread.sleep(forTimeInterval: Self.refreshSettle)
        XCTAssertEqual(
            Self.mockHellos(),
            probes,
            "a refresh probed the local network with Local network first off "
                + "(the scan must be skipped). Diagnostics: \(refreshDiagnostics(app))",
        )

        // --- On: the same refresh is allowed to ask the question --------------
        openSettings(app)
        let offControl = settingControl(Self.toggleIdentifier, in: app)
        XCTAssertTrue(
            revealInSettings(offControl, in: app, attempts: 10),
            "the Local network first switch went missing after closing the settings",
        )
        XCTAssertEqual(
            settingState(Self.toggleIdentifier, in: app),
            false,
            "the switch moved while the settings window was closed",
        )
        flip(settingControl(Self.toggleIdentifier, in: app), in: app)
        XCTAssertTrue(
            settingChanges(Self.toggleIdentifier, in: app, from: false),
            "the Local network first switch did not move when it was tapped",
        )
        XCTAssertEqual(
            settingState(Self.toggleIdentifier, in: app),
            true,
            "the Local network first switch did not stay on",
        )

        closeSettings(app)
        probes = Self.mockHellos()
        reads = Self.mockSessionListReads()
        pullToRefresh(app)
        XCTAssertTrue(
            Self.waitForSessionListRead(above: reads),
            "the pull-to-refresh never re-read the session list with the switch on",
        )
        Thread.sleep(forTimeInterval: Self.refreshSettle)
        XCTAssertGreaterThan(
            Self.mockHellos(),
            probes,
            "a refresh never probed the local network with Local network first on "
                + "(the operator asked for the scan). Diagnostics: \(refreshDiagnostics(app))",
        )

        // --- The setting is a setting, not a picture of one -------------------
        // The same phone, the same app, a new process. Nothing about this is in
        // memory only, or this is where it shows.
        app.terminate()
        waitForTermination(app)
        let reopened = relaunch()
        openSidebar(reopened)
        openSettings(reopened)
        let persisted = settingControl(Self.toggleIdentifier, in: reopened)
        XCTAssertTrue(
            revealInSettings(persisted, in: reopened, attempts: 10),
            "the settings screen did not come back after a relaunch",
        )
        XCTAssertEqual(
            settingState(Self.toggleIdentifier, in: reopened),
            true,
            "the Local network first switch did not survive a relaunch",
        )

        // Put it back, so the next run of this suite starts where this one did:
        // the default is the value every other suite measures.
        flip(settingControl(Self.toggleIdentifier, in: reopened), in: reopened)
        XCTAssertTrue(
            settingChanges(Self.toggleIdentifier, in: reopened, from: true),
            "the switch could not be put back off after the persistence check",
        )
    }

    // MARK: - Launching

    /// Launch the app paired with the mock, and make sure the launch is this
    /// test's.
    ///
    /// Retried because the first launch of a run is not always the requested
    /// one: a reinstall plus a Live Activity left by an earlier run is enough
    /// for the system to open the app by itself, and `XCUIApplication.launch()`
    /// can end up driving that process. That process would be paired from the
    /// *stored* host -- which another suite may have left pointing at the second
    /// mock -- and the probe counts below would then be read from a computer the
    /// app is not talking to.
    ///
    /// - Returns: the running application, paired with the fixture host.
    private func launchPaired() -> XCUIApplication {
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
        for _ in 0..<4 {
            app.terminate()
            waitForTermination(app)
            let pairingsBefore = Self.mockPairings()
            app.launchArguments = arguments
            app.launch()
            if Self.waitForPairing(above: pairingsBefore) {
                dismissNamingIfPresented(app)
                return app
            }
            app.terminate()
        }
        XCTFail("the app never launched with this test's pairing arguments")
        return app
    }

    /// Relaunch the app on its stored pairing, which is what a person reopening
    /// it gets.
    ///
    /// No pairing URI: this launch is about what the *process* remembers, and
    /// pairing again would be a second setup step rather than a relaunch.
    ///
    /// - Returns: the reopened application.
    private func relaunch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        dismissNamingIfPresented(app)
        return app
    }

    /// Wait until the app process is actually gone.
    ///
    /// `terminate()` returns before the process has necessarily finished dying,
    /// and a launch issued in that window can attach to the process on its way
    /// out instead of starting with the arguments it was given.
    ///
    /// - Parameter app: the application proxy.
    private func waitForTermination(_ app: XCUIApplication) {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, app.state != .notRunning {
            Thread.sleep(forTimeInterval: 0.1)
        }
        Thread.sleep(forTimeInterval: 0.4)
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

    // MARK: - The sidebar and the settings

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

    /// Open the settings window from the foot of the sidebar.
    /// - Parameter app: the running app.
    private func openSettings(_ app: XCUIApplication) {
        openSidebar(app)
        let gear = app.buttons["sidebar.settings"]
        expect(gear, "there is no way to the settings")
        gear.tap()
        expect(app.buttons["settings.done"], "the settings window did not open")
    }

    /// Put the settings window away.
    /// - Parameter app: the running app.
    private func closeSettings(_ app: XCUIApplication) {
        let done = app.buttons["settings.done"]
        expect(done, "the settings cannot be closed")
        done.tap()
        XCTAssertTrue(
            waitForDisappearance(done, timeout: Self.patience),
            "the settings window did not close",
        )
    }

    /// Scroll the settings window until a row has been built and is on screen.
    ///
    /// A SwiftUI `List` is lazy in the same way the conversation is: a row below
    /// the fold is not in the accessibility tree at all, and `waitForExistence`
    /// cannot see what the app has not built. The settings are a small window
    /// out of the gear, so the thing to scroll is the window and not the screen.
    ///
    /// Copied from `AppFlowTests`, including the reason for short drags: a
    /// `swipeUp()` carries the list several rows past the one being asked for,
    /// which is indistinguishable from it not existing.
    ///
    /// - Parameters:
    ///   - element: the row to look for.
    ///   - app: the running app.
    ///   - attempts: how many windows' worth to travel.
    /// - Returns: whether it turned up.
    @discardableResult
    private func revealInSettings(_ element: XCUIElement, in app: XCUIApplication, attempts: Int = 8) -> Bool {
        if element.waitForExistence(timeout: 3) {
            nudgeIntoView(element, in: app)
            return true
        }
        // Inside the settings window on every phone: it hangs from the gear at
        // the foot of the sidebar, so this band is its content, nowhere near the
        // edges the window can be dismissed from.
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.66))
        let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.46))
        for _ in 0..<attempts {
            from.press(forDuration: 0.05, thenDragTo: to)
            // A row that has just been built under a finger still moving is not
            // a tap target yet.
            Thread.sleep(forTimeInterval: 0.45)
            if element.exists, element.isHittable {
                nudgeIntoView(element, in: app)
                return true
            }
        }
        return element.exists
    }

    /// Move a row that was revealed at the window's very bottom edge up a little.
    /// - Parameters:
    ///   - element: the row that was found.
    ///   - app: the running app.
    private func nudgeIntoView(_ element: XCUIElement, in app: XCUIApplication) {
        guard element.exists, element.frame.maxY > app.frame.height * 0.72 else { return }
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.66))
        let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.46))
        from.press(forDuration: 0.05, thenDragTo: to)
        Thread.sleep(forTimeInterval: 0.45)
    }

    // MARK: - The switch

    /// The control behind one settings row.
    ///
    /// A SwiftUI `Toggle` is a switch on some OS versions and a toggle on
    /// others, and an identifier can land on the row instead of the control, so
    /// every shape is tried. The control is wanted rather than the row: tapping
    /// the row works too, but the thing being measured is the switch.
    ///
    /// - Parameters:
    ///   - identifier: the row's accessibility identifier.
    ///   - app: the running app.
    /// - Returns: the control to read or tap.
    private func settingControl(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        for candidate in [app.switches[identifier], app.toggles[identifier]] where candidate.exists {
            return candidate
        }
        let row = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        for inner in [row.switches.firstMatch, row.toggles.firstMatch] where inner.exists {
            return inner
        }
        return row
    }

    /// What one switch is set to, read from whichever element reports it.
    ///
    /// - Parameters:
    ///   - identifier: the row's accessibility identifier.
    ///   - app: the running app.
    /// - Returns: the state, or `nil` when nothing reported one.
    private func settingState(_ identifier: String, in app: XCUIApplication) -> Bool? {
        let candidates = [
            app.switches[identifier],
            app.toggles[identifier],
            app.descendants(matching: .any).matching(identifier: identifier).firstMatch,
        ]
        for candidate in candidates where candidate.exists {
            if let state = Self.onValue(candidate) { return state }
            // The identifier reached a row: the state is on something inside it,
            // which may carry no identifier of its own. Bounded, because this
            // walks the accessibility tree of one row.
            let inside = candidate.descendants(matching: .any)
            for index in 0..<min(inside.count, 12) {
                if let state = Self.onValue(inside.element(boundBy: index)) { return state }
            }
        }
        return nil
    }

    /// Tap the trailing edge of a switch, which is where the control is drawn.
    /// - Parameters:
    ///   - control: the switch.
    ///   - app: the running app.
    private func flip(_ control: XCUIElement, in app: XCUIApplication) {
        _ = app
        control.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
    }

    /// Wait until a switch reports a different state.
    ///
    /// Polled rather than read once: the write goes through SwiftUI's binding and
    /// comes back as a re-render, which is a frame later than the tap.
    ///
    /// - Parameters:
    ///   - identifier: the row's accessibility identifier.
    ///   - app: the running app.
    ///   - before: the state it had.
    /// - Returns: whether it moved.
    private func settingChanges(_ identifier: String, in app: XCUIApplication, from before: Bool?) -> Bool {
        let moved = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in self.settingState(identifier, in: app) != before },
            object: nil,
        )
        return XCTWaiter().wait(for: [moved], timeout: 5) == .completed
    }

    /// A switch's value, as a `Bool`.
    /// - Parameter element: the element to read.
    /// - Returns: whether it is on, or `nil` when it reports nothing.
    private static func onValue(_ element: XCUIElement) -> Bool? {
        switch (element.value as? String)?.lowercased() {
        case "1", "on", "true": true
        case "0", "off", "false": false
        default: nil
        }
    }

    // MARK: - Refreshing

    /// Pull the sidebar down, which is `ScrollView.refreshable`'s path into
    /// `AppModel.manualRefresh`.
    ///
    /// Copied from `AppFlowTests`: a press and a drag, because `swipeDown()`
    /// gives the scroll view a different gesture than a finger does.
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

    /// Wait until an element is gone.
    /// - Parameters:
    ///   - element: what to watch.
    ///   - timeout: how long to wait.
    /// - Returns: whether it went away.
    private func waitForDisappearance(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }

    /// What the settings/sidebar look like right now.
    /// - Parameter app: the running app.
    /// - Returns: a one-line description.
    private func settingsDiagnostics(_ app: XCUIApplication) -> String {
        "settings=\(app.buttons["settings.done"].exists)"
            + " sidebar=\(app.buttons["sessions.new"].exists)"
            + " hellos=\(Self.mockHellos())"
            + " methods=\(Self.mockMethodCounts())"
    }

    /// What a refresh left behind, for a failure message.
    /// - Parameter app: the running app.
    /// - Returns: a one-line description.
    private func refreshDiagnostics(_ app: XCUIApplication) -> String {
        "hellos=\(Self.mockHellos())"
            + " reads=\(Self.mockSessionListReads())"
            + " methods=\(Self.mockMethodCounts())"
            + " sidebar=\(app.buttons["sessions.new"].exists)"
    }

    // MARK: - The mock host

    /// Put the mock host's default fixture back, with the session stopped and
    /// the interaction cards out of the way.
    private static func resetMockHost() {
        _ = mockJSON(Self.mockBaseURL, "/reset?pending=0&running=0")
    }

    /// How many LAN-scan probes the mock host has answered since the last reset.
    ///
    /// Each is an HTTP `GET /mizar/v1/hello`, the question `scanForLocalNetwork`
    /// asks of every candidate address. The scan is silent from the screen, so
    /// this is the only place "the scan ran" is a fact.
    ///
    /// - Returns: the count, or zero when the mock is not answering.
    private static func mockHellos() -> Int {
        guard let json = mockJSON(Self.mockBaseURL, "/hellos") else { return 0 }
        return json["hellos"] as? Int ?? 0
    }

    /// How many pairing requests the host has answered since the last reset.
    /// - Returns: the count, or zero when the mock is not answering.
    private static func mockPairings() -> Int {
        guard let json = mockJSON(Self.mockBaseURL, "/loads") else { return 0 }
        return json["pairings"] as? Int ?? 0
    }

    /// Wait for a fresh pairing request to reach the host.
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

    /// How many `session.list` reads the host has answered since the last reset.
    ///
    /// A refresh the scroll view ignored and one that ran look the same on
    /// screen, so "the list was re-read" is read at the host, where it is a fact.
    ///
    /// - Returns: the count, or zero when the mock is not answering.
    private static func mockSessionListReads() -> Int {
        mockMethodCounts()["session.list"] ?? 0
    }

    /// Wait for the app to ask the host for the session list again.
    /// - Parameter count: the read count taken before the refresh.
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
