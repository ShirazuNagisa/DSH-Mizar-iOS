//
//  ScreenshotTour.swift
//  DSH-MizarUITests
//
//  Walks the app through its screens and writes a picture of each.
//
//  Not a test of anything: it is how `docs/screenshots` is made, against the
//  mock host, and it is skipped unless a folder to write to is given --
//
//    TEST_RUNNER_MIZAR_SHOTS=/tmp/tour scripts/ios.sh test "iPhone 18 Pro" \
//      -only-testing:DSH-MizarUITests/ScreenshotTour
//
//  `TEST_RUNNER_` is xcodebuild's prefix for passing a variable through to the
//  test runner; the runner sees `MIZAR_SHOTS`.
//

import XCTest

final class ScreenshotTour: XCTestCase {
    private var folder: URL!
    /// This class's mock-host primary port; the table is `MockPorts`.
    private static let mockPort = MockPorts.port(for: "ScreenshotTour")
    private static let pairing = "mizar://pair?h=127.0.0.1%3A\(mockPort)&c=MOCK-CODE&n=Mock%20Mac&v=1"

    override func setUpWithError() throws {
        guard let path = ProcessInfo.processInfo.environment["MIZAR_SHOTS"], !path.isEmpty else {
            throw XCTSkip("set TEST_RUNNER_MIZAR_SHOTS to a folder to write the tour to")
        }
        folder = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        continueAfterFailure = true
    }

    /// A tiny box for the async mock-host helpers: URLSession's completion runs
    /// off the test thread, and the values are read after the semaphore.
    private final class ShotBox: @unchecked Sendable {
        var methods: [String: Int] = [:]
    }

    /// Zero the mock's per-method counters.
    private static func resetMockCounters() {
        _ = mockJSON("/loads?reset=1")
    }

    /// The methods the app has asked the host for since the counters were reset.
    private static func mockMethodCounts() -> [String: Int] {
        guard let json = mockJSON("/loads"),
              let methods = json["methods"] as? [String: Any] else { return [:] }
        return methods.compactMapValues { ($0 as? NSNumber)?.intValue }
    }

    /// GET one mock-host endpoint and decode its JSON.
    private static func mockJSON(_ path: String) -> [String: Any]? {
        guard let url = URL(string: "http://127.0.0.1:\(mockPort)\(path)") else { return nil }
        let done = DispatchSemaphore(value: 0)
        let box = ShotBox()
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        URLSession.shared.dataTask(with: request) { data, _, _ in
            defer { done.signal() }
            guard let data,
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let methods = parsed["methods"] as? [String: Any]
            else { return }
            box.methods = methods.compactMapValues { ($0 as? NSNumber)?.intValue }
        }.resume()
        _ = done.wait(timeout: .now() + 6)
        return ["methods": box.methods]
    }

    private func reset(pending: Bool) {
        let url = URL(string: "http://127.0.0.1:\(MockPorts.port(for: String(describing: Self.self)))/reset?\(pending ? "" : "pending=0")")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let done = expectation(description: "reset")
        URLSession.shared.dataTask(with: request) { _, _, _ in done.fulfill() }.resume()
        wait(for: [done], timeout: 6)
    }

    private func launch(session: String?, language: String, pending: Bool, paid: Bool = false) -> XCUIApplication {
        reset(pending: pending)
        let app = XCUIApplication()
        var arguments = ["-mizarPairURI", Self.pairing, "-mizarFreshStart", "-mizarSkipPermissionPrompts", "-mizarSkipLoginGate", "-mizarCreditsFixture",
                         "-AppleLanguages", "(\(language))"]
        if let session { arguments += ["-mizarSelectSession", session] }
        if paid { arguments.append("-mizarMockPaid") }
        app.launchArguments = arguments
        app.launch()
        let skip = app.buttons["rename.skip"]
        if skip.waitForExistence(timeout: 20) {
            // The sheet can be present before its button is hittable; a tap
            // that lands during the presentation is swallowed. Wait for the
            // button to settle, tap, and tap again if the sheet has not gone.
            settled(skip)
            skip.tap()
            if skip.waitForExistence(timeout: 2) { skip.tap() }
        }
        return app
    }

    /// Wait until something can be touched where it is drawn -- not merely
    /// exists -- so a tap does not land where a moving control used to be.
    @discardableResult
    private func settled(_ element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true"), object: element)
        let ok = XCTWaiter().wait(for: [ready], timeout: timeout) == .completed
        Thread.sleep(forTimeInterval: 0.5)
        return ok
    }

    private func shoot(_ name: String, settle: TimeInterval = 1.2) {
        Thread.sleep(forTimeInterval: settle)
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try? png.write(to: folder.appendingPathComponent("\(name).png"))
    }

    func testTour() {
        for language in ["en", "zh-Hans"] {
            let suffix = language == "en" ? "" : "-zh"

            // The sidebar, as a launch with nothing selected shows it.
            var app = launch(session: nil, language: language, pending: true)
            _ = app.buttons["sessions.new"].waitForExistence(timeout: 20)
            // A cold launch lands on Home with the sidebar closed. The tour's
            // first picture is the sidebar, so open it the way a person does.
            if app.buttons["shell.sidebarToggle"].waitForExistence(timeout: 10) {
                app.buttons["shell.sidebarToggle"].tap()
            }
            let workspace = app.buttons["workspace./Users/you/projects/demo"]
            if settled(workspace) {
                workspace.staticTexts.element(boundBy: 0).tap()
            }
            shoot("01-sidebar\(suffix)")

            // A conversation, with the requests docked above the composer.
            app.terminate()
            app = launch(session: "first", language: language, pending: true)
            _ = app.textViews["composer.field"].waitForExistence(timeout: 20)
            shoot("02-conversation-dock\(suffix)", settle: 2.5)

            // The sidebar out, and the conversation pushed aside as a card.
            app.buttons["shell.sidebarToggle"].tap()
            shoot("03-sidebar-card\(suffix)")
            settled(app.buttons["shell.dismissSidebar"])
            app.buttons["shell.dismissSidebar"].tap()

            // Typing tucks the requests away.
            settled(app.textViews["composer.field"])
            app.textViews["composer.field"].tap()
            app.textViews["composer.field"].typeText("Run the tests again")
            shoot("04-typing\(suffix)")
            // The tucked pill brings them back and puts the keyboard away.
            let tucked = app.buttons["interactions.tucked"]
            if settled(tucked) { tucked.tap() }

            // The question card, from the deck.
            if language == "en" {
                let next = app.buttons["interactions.next"]
                if settled(next) { next.tap() }
                shoot("05-question\(suffix)")
            }

            // The model picker, as a small window out of its chip.
            app.buttons["composer.model"].tap()
            shoot("06-model\(suffix)")
            dismissWindow(app)

            // Home, and the settings.
            app.terminate()
            app = launch(session: nil, language: language, pending: false)
            _ = app.buttons["sessions.new"].waitForExistence(timeout: 20)
            settled(app.buttons["shell.dismissSidebar"])
            app.buttons["shell.dismissSidebar"].tap()
            shoot("07-home\(suffix)", settle: 1.6)
            app.buttons["shell.sidebarToggle"].tap()
            // Tapped until the window is up: a tap that lands while the sidebar
            // is still settling is a tap on a control that is moving.
            for _ in 0..<3 {
                settled(app.buttons["sidebar.settings"])
                app.buttons["sidebar.settings"].tap()
                if app.buttons["settings.done"].waitForExistence(timeout: 4) { break }
            }
            shoot("08-settings\(suffix)")
            app.terminate()
        }
    }

    /// The Live Activity as the system draws it: compact and expanded island
    /// on the Home Screen. The Lock Screen card is captured separately by
    /// locking the simulator; this test leaves the activity running for it.
    func testLiveActivityTour() {
        let app = launch(session: "first", language: "en", pending: true)
        _ = app.textViews["composer.field"].waitForExistence(timeout: 20)
        // The first poll has to land, the decision has to start an activity,
        // and ActivityKit has to publish it; five seconds covers a cold start.
        Thread.sleep(forTimeInterval: 5)
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 2)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        // First use asks whether DSH-Mizar may show Live Activities. The alert
        // is springboard's, not the app's, and it sits on top of the card, so
        // allow it here and again after the pull-down if it queued late.
        allowLiveActivity(in: springboard)
        shoot("LA-01-home-compact", settle: 0.4)
        let island = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.035))
        island.press(forDuration: 1.2)
        Thread.sleep(forTimeInterval: 1.2)
        shoot("LA-02-expanded", settle: 0.4)

        // A tap outside collapses it again; the last picture proves the
        // expanded state did not leave the island stuck open.
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        Thread.sleep(forTimeInterval: 1)
        shoot("LA-03-collapsed", settle: 0.4)

        // Pull down the Lock Screen / Notification Center. The Live Activity
        // card is the light/dark surface the island cannot show: the island is
        // always the system's black, while the card takes the app's two
        // appearances.
        let top = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.005))
        let bottom = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95))
        top.press(forDuration: 0.05, thenDragTo: bottom)
        Thread.sleep(forTimeInterval: 1.5)
        allowLiveActivity(in: springboard)
        shoot("LA-04-lock-screen", settle: 0.4)
        unlock(springboard)
        app.terminate()
    }

    /// The other Live Activity shape: no approval, just the running rows. The
    /// approval shape above is the tall one; this is the one the old card was
    /// designed around, and it must not clip now that the type is larger.
    func testLiveActivityRowsTour() {
        let app = launch(session: "first", language: "en", pending: false, paid: true)
        _ = app.textViews["composer.field"].waitForExistence(timeout: 20)
        Thread.sleep(forTimeInterval: 5)
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 2)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        allowLiveActivity(in: springboard)
        shoot("LA-R-01-home-compact", settle: 0.4)

        let island = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.035))
        island.press(forDuration: 1.2)
        Thread.sleep(forTimeInterval: 1.2)
        shoot("LA-R-02-expanded", settle: 0.4)
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        Thread.sleep(forTimeInterval: 1)

        let top = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.005))
        let bottom = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95))
        top.press(forDuration: 0.05, thenDragTo: bottom)
        Thread.sleep(forTimeInterval: 1.5)
        allowLiveActivity(in: springboard)
        shoot("LA-R-03-lock-screen", settle: 0.4)
        unlock(springboard)
        app.terminate()
    }

    /// The Live Activity's "Allow once" button has to reach the computer.
    ///
    /// This is the one live-activity assertion in the tour: a button that looks
    /// right but never opens a socket is worse than no button. The mock's
    /// per-method counter is the proof that the intent ran and the answer
    /// arrived, which a screenshot alone cannot show.
    func testLiveActivityAllowOnceReachesHost() {
        let app = launch(session: "first", language: "en", pending: true, paid: true)
        _ = app.textViews["composer.field"].waitForExistence(timeout: 20)
        Thread.sleep(forTimeInterval: 5)
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 2)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        allowLiveActivity(in: springboard)

        let top = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.005))
        let bottom = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95))
        top.press(forDuration: 0.05, thenDragTo: bottom)
        Thread.sleep(forTimeInterval: 1.5)
        allowLiveActivity(in: springboard)
        Self.resetMockCounters()

        let allow = springboard.buttons["允许一次"]
        guard allow.waitForExistence(timeout: 5) else {
            shoot("LA-ALLOW-00-missing", settle: 0)
            print(springboard.debugDescription)
            XCTFail("the Live Activity card has no Allow once button")
            app.terminate()
            return
        }
        allow.tap()

        let deadline = Date().addingTimeInterval(20)
        var counts: [String: Int] = [:]
        repeat {
            Thread.sleep(forTimeInterval: 1)
            counts = Self.mockMethodCounts()
        } while (counts["approval.answer"] ?? 0) == 0 && Date() < deadline
        shoot("LA-ALLOW-01-after", settle: 1)
        XCTAssertGreaterThan(
            counts["approval.answer"] ?? 0,
            0,
            "tapping Allow once never sent approval.answer to the host: \(counts)",
        )
        unlock(springboard)
        app.terminate()
    }

    /// Swipe up out of the Lock Screen, so a class that runs both tours does
    /// not start its next test behind the lock screen.
    private func unlock(_ springboard: XCUIApplication) {
        let bottom = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95))
        let top = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.42))
        bottom.press(forDuration: 0.05, thenDragTo: top)
        Thread.sleep(forTimeInterval: 0.8)
    }

    /// Allow the system's one-time "Live Activities" permission for this app.
    /// The alert lives on springboard, so it is queried there; the exact label
    /// "允许" is the system's confirm button (the card's own are "允许一次" / "拒绝").
    private func allowLiveActivity(in springboard: XCUIApplication) {
        // The first alert offers "允许"; the follow-up that keeps the activity
        // allowed across launches offers "始终允许". Tap whichever is up, and
        // give the follow-up a moment to appear.
        for _ in 0..<2 {
            let always = springboard.buttons["始终允许"]
            if always.waitForExistence(timeout: 3) {
                always.tap()
                Thread.sleep(forTimeInterval: 0.8)
                continue
            }
            let allow = springboard.buttons["允许"]
            if allow.waitForExistence(timeout: 2) {
                allow.tap()
                Thread.sleep(forTimeInterval: 0.8)
            }
        }
    }

    /// Put away whatever small window is out, the way a person would: a tap
    /// outside it.
    private func dismissWindow(_ app: XCUIApplication) {
        let region = app.otherElements["PopoverDismissRegion"]
        if region.waitForExistence(timeout: 2) {
            region.tap()
        }
        Thread.sleep(forTimeInterval: 0.6)
    }

    /// Every small window, out of the control that opens it, and the turn index.
    func testWindowsTour() {
        // The sidebar's windows.
        var app = launch(session: nil, language: "en", pending: true)
        _ = app.buttons["sessions.new"].waitForExistence(timeout: 20)
        settled(app.buttons["sessions.hosts"])
        app.buttons["sessions.hosts"].tap()
        shoot("w01-computers")
        dismissWindow(app)
        app.buttons["sidebar.connection"].tap()
        shoot("w02-connection", settle: 5)
        dismissWindow(app)
        app.buttons["sessions.new"].tap()
        shoot("w03-new-session")
        dismissWindow(app)
        app.buttons["sessions.refresh"].tap()
        shoot("w04-refresh", settle: 2)
        dismissWindow(app)
        app.buttons["sidebar.settings"].tap()
        shoot("w05-settings")
        dismissWindow(app)
        app.terminate()

        // The conversation, its windows, and the turn index.
        app = launch(session: "first", language: "en", pending: false)
        _ = app.textViews["composer.field"].waitForExistence(timeout: 20)
        Thread.sleep(forTimeInterval: 2)
        app.buttons["composer.model"].tap()
        shoot("w06-model")
        dismissWindow(app)
        app.buttons["composer.context"].tap()
        shoot("w07-context")
        dismissWindow(app)
        app.buttons["composer.commands"].tap()
        shoot("w08-commands")
        dismissWindow(app)
        app.buttons["session.permissions"].tap()
        if app.buttons["permission.row.danger-full-access"].waitForExistence(timeout: 5) {
            app.buttons["permission.row.danger-full-access"].tap()
        }
        shoot("w09-permissions")
        dismissWindow(app)

        // The index, by a drag to the left across the conversation.
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.45))
        let finish = app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.47))
        start.press(forDuration: 0.05, thenDragTo: finish)
        shoot("w10-turn-index")
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'turnIndex.entry.'"))
        if rows.count > 0 {
            rows.element(boundBy: 0).tap()
            shoot("w11-jumped", settle: 1.0)
        }
        // And by the title.
        app.buttons["session.turnIndex"].tap()
        shoot("w12-turn-index-title")
        app.terminate()
    }


    /// The iPad: the index as a column, and as the rail when it is put away.
    func testPadTour() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("an iPad tour") }
        let app = launch(session: "first", language: "en", pending: false, paid: true)
        _ = app.textViews["composer.field"].waitForExistence(timeout: 20)
        shoot("p01-rail", settle: 2)
        app.buttons["shell.turnIndexToggle"].tap()
        shoot("p02-index-column", settle: 1.5)
        app.buttons["sidebar.connection"].tap()
        shoot("p03-connection", settle: 5)
        app.terminate()
    }

}
