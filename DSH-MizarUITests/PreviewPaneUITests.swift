//
//  PreviewPaneUITests.swift
//  DSH-MizarUITests
//
//  A delivered file, from the card under the answer to the drawer's preview page.
//
//  Two things are asserted, and they are the two that a screenshot cannot prove:
//
//    - **The tap actually gets there.** A card that draws but does not turn the
//      plane is the failure mode this feature is most likely to have: the plane's
//      page used to be the plane's own private state, so "open the drawer" and
//      "show the preview" were two unrelated things. The test asserts the
//      segmented control's selection, not merely that the preview page exists —
//      all three pages are mounted all the time, so existence proves nothing.
//    - **The file is really read.** The text on the page is the fixture's own
//      document, which the app could only have got from `file.stat` and
//      `file.read` against the mock host.
//
//  A second test pins the empty state, because "no content yet" is the sentence
//  every conversation starts on and the one most likely to be replaced by a
//  spinner that never resolves.
//

import XCTest

final class PreviewPaneUITests: XCTestCase {
    /// This class's mock-host primary port; the table is `MockPorts`.
    private static let mockPort = MockPorts.port(for: "PreviewPaneUITests")
    /// The mock host this suite drives.
    private static let mockPairingURI =
        "mizar://pair?h=127.0.0.1%3A\(mockPort)&c=MOCK-CODE&n=Mock%20Mac&v=1"
    private static let mockBaseURL = "http://127.0.0.1:\(mockPort)"
    /// How long to wait for the host (or a screen) to answer.
    private static let patience: TimeInterval = 20
    /// A naming prompt appears only on the first pairing.
    private static let namingPatience: TimeInterval = 3

    override func setUp() {
        continueAfterFailure = false
        Self.setMockDeliverables(false)
        Self.resetMockHost()
    }

    override func tearDown() {
        // The card is a row under every answer, so a suite that left it on would
        // move every later suite's screen down by one row.
        Self.setMockDeliverables(false)
    }

    // MARK: - The file

    /// Tap the card the model delivered, and read the file it names.
    func testTappingADeliveredFileOpensItsPreview() {
        Self.setMockDeliverables(true)
        let app = launch()
        openSessionIfNeeded(app)

        let card = app.buttons["turn.1.deliverable.0"]
        XCTAssertTrue(
            card.waitForExistence(timeout: Self.patience),
            "the delivered file has no card under the answer",
        )
        // The card says what the file is, not only that one exists.
        XCTAssertTrue(
            card.label.contains("delivered.md"),
            "the card does not name the file: \(card.label)",
        )
        card.tap()

        let dismiss = app.buttons["shell.dismissSidebar"]
        _ = dismiss.waitForExistence(timeout: 3)
        let control = app.descendants(matching: .any)["side.tab.bar"]
        XCTAssertTrue(
            control.waitForExistence(timeout: Self.patience),
            "the drawer has no page control. dismiss=\(dismiss.exists)\n\(app.debugDescription)",
        )
        let tab = control.buttons["Preview"]
        XCTAssertTrue(
            waitForSelected(tab),
            "the drawer opened but did not turn to the preview page",
        )

        // The document's own text: the only place this app could have got it is
        // the host's `file.read`.
        let body = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "This file was read from the computer."),
        ).firstMatch
        XCTAssertTrue(
            body.waitForExistence(timeout: Self.patience),
            "the preview page never showed the file's contents",
        )
    }

    /// A delivered source file opens as text, with every line read.
    func testATappedSourceFileIsDrawnAsText() {
        Self.setMockDeliverables(true, file: "code")
        let app = launch()
        openSessionIfNeeded(app)

        let card = app.buttons["turn.1.deliverable.0"]
        XCTAssertTrue(card.waitForExistence(timeout: Self.patience), "the source file has no card under the answer")
        XCTAssertTrue(
            card.label.contains("demo.swift"),
            "the card does not name the source file: \(card.label)",
        )
        card.tap()

        let code = app.textViews["preview.code"]
        XCTAssertTrue(
            code.waitForExistence(timeout: Self.patience),
            "the source preview never appeared. \(app.debugDescription)",
        )
        XCTAssertTrue(
            (code.value as? String)?.contains("MIZAR_SOURCE_MARKER") == true,
            "the source preview does not hold the file's text: \(String(describing: code.value))",
        )
    }

    /// A delivered PNG opens in the image viewer.
    func testATappedImageIsDrawn() {
        Self.setMockDeliverables(true, file: "image")
        let app = launch()
        openSessionIfNeeded(app)

        let card = app.buttons["turn.1.deliverable.0"]
        XCTAssertTrue(card.waitForExistence(timeout: Self.patience), "the image has no card under the answer")
        XCTAssertTrue(
            card.label.contains("chart.png"),
            "the card does not name the image: \(card.label)",
        )
        card.tap()

        let image = app.descendants(matching: .any)["preview.image"]
        XCTAssertTrue(
            image.waitForExistence(timeout: Self.patience),
            "the image preview never appeared. \(app.debugDescription)",
        )
    }

    /// A second look at the same file does not ask the computer again.
    ///
    /// The evidence is the mock's own method counter: one `file.stat` per open
    /// (the cache is only trusted when the host agrees it is current) and no
    /// second `file.read`, because the bytes are already on the phone.
    func testASecondLookDoesNotReadTheFileAgain() {
        Self.setMockDeliverables(true)
        let app = launch()
        openSessionIfNeeded(app)

        let card = app.buttons["turn.1.deliverable.0"]
        XCTAssertTrue(card.waitForExistence(timeout: Self.patience), "no delivered file card")
        card.tap()

        let body = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "This file was read from the computer."),
        ).firstMatch
        XCTAssertTrue(body.waitForExistence(timeout: Self.patience), "the first open did not read the file")
        let afterFirst = Self.methodCount("file.read")
        XCTAssertGreaterThan(afterFirst, 0, "the first open never asked the computer for the file")

        // Close the drawer, then open the same file again. The card behind it is
        // one big dismiss button while the drawer is out.
        let dismiss = app.buttons["shell.dismissSidebar"]
        XCTAssertTrue(dismiss.waitForExistence(timeout: Self.patience), "the drawer cannot be closed")
        dismiss.tap()
        XCTAssertTrue(card.waitForExistence(timeout: Self.patience), "the card went away with the drawer")
        card.tap()
        XCTAssertTrue(body.waitForExistence(timeout: Self.patience), "the second open showed nothing")

        // One `stat` per open is the whole point: it is how the app knows the
        // copy it holds is still current. A second `read` would mean the bytes
        // crossed the link twice.
        let afterSecond = Self.methodCount("file.read")
        XCTAssertEqual(
            afterSecond,
            afterFirst,
            "the second look read the file again (\(afterFirst) -> \(afterSecond)) instead of using the cache",
        )
    }

    // MARK: - The empty state

    /// A conversation that has delivered nothing says so.
    func testThePreviewPageStartsEmpty() {
        let app = launch(openPreview: true)

        let empty = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "Nothing yet"),
        ).firstMatch
        XCTAssertTrue(
            empty.waitForExistence(timeout: Self.patience),
            "the preview page has no empty state",
        )
    }

    // MARK: - Plumbing

    /// - Parameters:
    ///   - openPreview: whether to launch with the right drawer already on the
    ///     preview page.
    /// - Returns: the running application.
    private func launch(openPreview: Bool = false) -> XCUIApplication {
        var arguments: [String] = [
            "-mizarPairURI", Self.mockPairingURI,
            "-mizarFreshStart",
            "-mizarSkipPermissionPrompts", "-mizarSkipLoginGate", "-mizarSkipOnboarding", "-mizarCreditsFixture",
            // The fixture answers on a direct address; the transport switches
            // default to off, and without this the app lands on "The transport
            // switches are off" instead of a conversation.
            "-mizarDirectConnection", "-mizarLocalNetworkRoute", "-mizarSkipSplash",
            "-mizarAccountFreshStart",
            // The fixture is on 127.0.0.1, which the real rule excludes from
            // "local"; without this the preview page correctly says the plan
            // is needed, and every test here measures the locked card. The
            // flag is Debug-only and is the LAN-unlocked UI's way in.
            "-mizarLocalNetwork",
            "-mizarAccountURL", Self.mockBaseURL,
            "-mizarSelectSession", "first",
            // Every test here measures a first look at a file, so the cache has
            // to start empty: it survives relaunches, and one run's downloaded
            // copy would answer the next run's open.
            "-mizarFreshPreviews",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        if openPreview {
            // The drawer belongs to a gesture, which `simctl` cannot make: these
            // two arguments are the Debug way in, and they are the same pair the
            // screenshot tour uses.
            arguments += ["-mizarOpenTurnIndex", "-mizarSidePagePreview"]
        }
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
        dismissNamingIfPresented(app)
        return app
    }

    /// Make sure the requested conversation is on screen.
    ///
    /// `-mizarSelectSession` is applied after the first session-list read, so a
    /// test that starts before that read lands sits on the list.
    ///
    /// - Parameter app: the running app.
    private func openSessionIfNeeded(_ app: XCUIApplication) {
        // A cold launch spends several seconds on the welcome gate and the first
        // session read, and a five-second wait here was enough to fail one run in
        // three before the fixture had even answered.
        if app.textViews["composer.field"].waitForExistence(timeout: Self.patience) { return }

        let toggle = app.buttons["shell.sidebarToggle"]
        if toggle.waitForExistence(timeout: Self.patience), !app.buttons["sessions.new"].exists {
            toggle.tap()
        }
        let workspace = app.buttons["workspace./Users/you/projects/demo"]
        if workspace.waitForExistence(timeout: Self.patience), workspace.exists {
            workspace.tap()
        }
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Mock session")).firstMatch
        if row.waitForExistence(timeout: Self.patience), row.isHittable {
            row.tap()
        }
        XCTAssertTrue(
            app.textViews["composer.field"].waitForExistence(timeout: Self.patience),
            "the fixture's conversation never opened",
        )
    }

    /// Wait for a segment to be the chosen one.
    ///
    /// - Parameter segment: the segment.
    /// - Returns: whether it became selected within the patience window.
    private func waitForSelected(_ segment: XCUIElement) -> Bool {
        let selected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "selected == true"),
            object: segment,
        )
        return XCTWaiter().wait(for: [selected], timeout: Self.patience) == .completed
    }

    /// Wait out the one-time naming prompt, when the fixture shows it.
    ///
    /// - Parameter app: the running app.
    private func dismissNamingIfPresented(_ app: XCUIApplication) {
        // The fixture offers `rename.skip` ("Skip") and `rename.save`; the sheet
        // is modal, so leaving it up puts a dismiss region over everything the
        // test is about to look at.
        for identifier in ["rename.skip", "Not now"] {
            let button = app.buttons[identifier]
            if button.waitForExistence(timeout: Self.namingPatience), button.isHittable {
                button.tap()
                return
            }
        }
    }

    // MARK: - The mock host

    /// Turn the fixture's delivered file on or off.
    ///
    /// - Parameter on: whether the first turn should declare a file.
    /// - Parameters:
    ///   - on: whether the first turn declares a file.
    ///   - file: which fixture: `md`, `code`, or `image`.
    private static func setMockDeliverables(_ on: Bool, file: String = "md") {
        _ = get("/deliverables?on=\(on ? 1 : 0)&file=\(file)")
    }

    /// Put the mock host's conversation back to its fixture.
    private static func resetMockHost() {
        _ = get("/reset?pending=0&running=0")
    }

    /// How many times the mock was asked for one method, in this process.
    ///
    /// - Parameter method: the wire method.
    /// - Returns: the count, or `-1` when the answer was unreadable.
    private static func methodCount(_ method: String) -> Int {
        guard let data = get("/loads"),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let counts = json["methods"] as? [String: Any] else {
            return -1
        }
        return counts[method] as? Int ?? 0
    }

    /// One request to the mock host, synchronously.
    ///
    /// - Parameter path: the path, with its query.
    /// - Returns: the body, when there was one.
    private static func get(_ path: String) -> Data? {
        guard let url = URL(string: "http://127.0.0.1:\(mockPort)\(path)") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        let done = DispatchSemaphore(value: 0)
        var body: Data?
        URLSession.shared.dataTask(with: request) { data, _, _ in
            body = data
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 6)
        return body
    }
}
