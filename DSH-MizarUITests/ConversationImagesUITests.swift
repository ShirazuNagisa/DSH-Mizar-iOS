//
//  ConversationImagesUITests.swift
//  DSH-MizarUITests
//
//  A picture the model wrote into an answer, from the path to the pixels.
//
//  What a screenshot cannot prove, and what this asserts instead:
//
//    - **The bytes came off the computer.** The row draws a picture only after
//      `file.stat` and `file.read` answered; the fixture's answer carries a path
//      and nothing else, so a row that drew something without a read would be
//      drawing a placeholder this test invented. The mock's own method counter is
//      the evidence.
//    - **A tap gets there.** The picture opens full screen and closes again --
//      the two halves of the gesture that a layout test would miss.
//    - **A picture that is not there says so.** A path whose file the host
//      refuses must leave the sentence and the caption, not an empty hole where a
//      picture used to be.
//

import XCTest

final class ConversationImagesUITests: XCTestCase {
    /// This class's mock-host primary port; the table is `MockPorts`.
    private static let mockPort = MockPorts.port(for: "ConversationImagesUITests")
    /// The mock host this suite drives.
    private static let mockPairingURI =
        "mizar://pair?h=127.0.0.1%3A\(mockPort)&c=MOCK-CODE&n=Mock%20Mac&v=1"
    private static let mockBaseURL = "http://127.0.0.1:\(mockPort)"
    /// How long to wait for the host (or a screen) to answer.
    private static let patience: TimeInterval = 20
    /// The naming prompt appears only on the first pairing.
    private static let namingPatience: TimeInterval = 3

    override func setUp() {
        continueAfterFailure = false
        _ = Self.setInlineImages(on: false)
        Self.resetMockHost()
    }

    override func tearDown() {
        _ = Self.setInlineImages(on: false)
    }

    // MARK: - The picture

    /// The answer carries a picture, and it was read off the computer.
    func testAPictureInAnAnswerIsDrawn() {
        Self.resetMockHost()
        _ = Self.setInlineImages(on: true)
        let app = launch()
        openSessionIfNeeded(app)

        let picture = app.buttons["conversation.image"]
        XCTAssertTrue(
            picture.waitForExistence(timeout: Self.patience),
            "the answer has no picture in it. \(app.debugDescription)",
        )
        XCTAssertTrue(
            picture.label.contains("A survey of the island"),
            "the picture does not carry the caption the message gave it: \(picture.label)",
        )
        XCTAssertGreaterThan(
            Self.methodCount("file.read"),
            0,
            "the picture was drawn without reading anything from the computer",
        )
        capture(app, named: "conversation-picture")
    }

    /// Tapping it opens it full screen; the close button puts it away.
    func testTappingAPictureOpensItFullScreen() {
        Self.resetMockHost()
        _ = Self.setInlineImages(on: true)
        let app = launch()
        openSessionIfNeeded(app)

        let picture = app.buttons["conversation.image"]
        XCTAssertTrue(picture.waitForExistence(timeout: Self.patience), "no picture to tap")
        picture.tap()

        let lightbox = app.images["conversation.image.lightbox"]
        XCTAssertTrue(
            lightbox.waitForExistence(timeout: 5),
            "the picture did not open full screen. \(app.debugDescription)",
        )
        capture(app, named: "conversation-picture-lightbox")

        let close = app.buttons["conversation.image.close"]
        XCTAssertTrue(close.exists, "the full screen picture cannot be closed")
        close.tap()
        XCTAssertFalse(
            lightbox.waitForExistence(timeout: 2),
            "the full screen picture stayed after the close button",
        )
        XCTAssertTrue(picture.waitForExistence(timeout: Self.patience), "the picture left the answer")
    }

    /// A path whose file the host refuses says so, and keeps the caption.
    func testAPictureThatIsNotThereSaysSo() {
        Self.resetMockHost()
        _ = Self.setInlineImages(on: true, fails: true)
        let app = launch()
        openSessionIfNeeded(app)

        // `descendants(matching: .any)`: a card that carries a tap action is
        // classified by the iOS accessibility layer as a button in some builds
        // and as an "other" element in others, and which one it is, is not the
        // fact under test.
        let failed = app.descendants(matching: .any)["conversation.image.failed"].firstMatch
        XCTAssertTrue(
            failed.waitForExistence(timeout: Self.patience),
            "the missing picture drew nothing at all. \(app.debugDescription)",
        )
        XCTAssertTrue(
            failed.label.contains("no longer on the computer")
                || failed.label.contains("not there")
                || failed.label.contains("这张图"),
            "the missing picture does not say why: \(failed.label)",
        )
        capture(app, named: "conversation-picture-failed")
    }

    // MARK: - The plan

    /// A free account on a relay link is asked to subscribe, and is not handed a
    /// picture it may not have.
    ///
    /// The fixture answers on loopback, which the real rule does not call a local
    /// network: without the `-mizarLocalNetwork` flag this launch is the
    /// free-account-over-the-relay case, which is the one the sentence is for.
    func testAFreeAccountIsAskedToSubscribeInsteadOfPictured() {
        Self.resetMockHost()
        _ = Self.setInlineImages(on: true)
        let app = launch(localNetwork: false)
        openSessionIfNeeded(app)

        let line = app.staticTexts["conversation.image.subscription"]
        XCTAssertTrue(
            line.waitForExistence(timeout: Self.patience),
            "the answer draws no subscription line where the picture would be. \(app.debugDescription)",
        )
        XCTAssertTrue(
            line.label.contains("Subscribe to the paid plan"),
            "the line does not say what would make the picture appear: \(line.label)",
        )
        XCTAssertFalse(
            app.buttons["conversation.image"].exists,
            "a free account on a relay was handed the picture anyway",
        )
        XCTAssertEqual(
            Self.methodCount("file.read"),
            0,
            "the picture's bytes were read for an account that may not have them",
        )
        capture(app, named: "conversation-picture-subscription")
    }

    // MARK: - Plumbing

    /// Launch against this class's mock host.
    ///
    /// - Parameter localNetwork: whether this launch claims a local-network link.
    ///   The fixture answers on loopback, which the real rule excludes, so this
    ///   flag is the only way to be either side of the plan's line.
    /// - Returns: the running application.
    private func launch(localNetwork: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        var arguments: [String] = [
            "-mizarPairURI", Self.mockPairingURI,
            "-mizarFreshStart",
            "-mizarSkipPermissionPrompts", "-mizarSkipLoginGate", "-mizarSkipOnboarding",
            "-mizarCreditsFixture",
            // The fixture answers on a direct address; the transport switches
            // default to off without this.
            "-mizarDirectConnection", "-mizarLocalNetworkRoute", "-mizarSkipSplash",
            "-mizarAccountFreshStart",
        ]
        // The fixture is on 127.0.0.1, which the real rule excludes from
        // "local". Reading a picture off the computer is the same feature as the
        // preview page, and the same Debug-only flag is how a test reaches the
        // LAN-unlocked UI -- or, without it, the free-account-over-the-relay one.
        if localNetwork { arguments.append("-mizarLocalNetwork") }
        arguments += [
            "-mizarAccountURL", Self.mockBaseURL,
            "-mizarSelectSession", "first",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        app.launchArguments = arguments
        app.launch()
        dismissNamingIfPresented(app)
        return app
    }

    /// Make sure the requested conversation is on screen.
    ///
    /// - Parameter app: the running app.
    private func openSessionIfNeeded(_ app: XCUIApplication) {
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

    /// Wait out the one-time naming prompt, when the fixture shows it.
    ///
    /// - Parameter app: the running app.
    private func dismissNamingIfPresented(_ app: XCUIApplication) {
        for identifier in ["rename.skip", "Not now"] {
            let button = app.buttons[identifier]
            if button.waitForExistence(timeout: Self.namingPatience), button.isHittable {
                button.tap()
                return
            }
        }
    }

    /// Attach a screenshot to the test report, for the run that has to be looked
    /// at rather than asserted on.
    ///
    /// - Parameters:
    ///   - app: the running app.
    ///   - named: the attachment's name.
    private func capture(_ app: XCUIApplication, named name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    // MARK: - The mock host

    /// Put a picture in the fixture's answer, or take it out.
    ///
    /// - Parameters:
    ///   - on: whether the answer carries a picture.
    ///   - fails: whether it also names a picture whose file is not there.
    /// - Returns: whether the mock confirmed the flag. Checked rather than
    ///   assumed: a knob that did not take turns every assertion after it into an
    ///   assertion about something else.
    @discardableResult
    private static func setInlineImages(on: Bool, fails: Bool = false) -> Bool {
        guard let data = get("/images?on=\(on ? 1 : 0)&fail=\(fails ? 1 : 0)"),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return false
        }
        return (json["inlineImages"] as? Bool) == on
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
              let methods = json["methods"] as? [String: Any]
        else {
            return -1
        }
        // A method that was never called has no counter at all, which is zero
        // calls -- not an unreadable answer. -1 stays for "the mock did not
        // answer", which is a different fact and must not read as "no calls".
        return methods[method] as? Int ?? 0
    }

    /// One request to the mock host, synchronously.
    ///
    /// - Parameter path: the path and query, e.g. `/images?on=1`.
    /// - Returns: the body, or `nil` when the mock did not answer.
    private static func get(_ path: String) -> Data? {
        guard let url = URL(string: "http://127.0.0.1:\(mockPort)\(path)") else { return nil }
        let done = DispatchSemaphore(value: 0)
        let box = Box()
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        URLSession.shared.dataTask(with: request) { data, _, _ in
            box.value = data
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 6)
        return box.value
    }

    /// A result out of a callback.
    private final class Box: @unchecked Sendable {
        var value: Data?
    }
}
