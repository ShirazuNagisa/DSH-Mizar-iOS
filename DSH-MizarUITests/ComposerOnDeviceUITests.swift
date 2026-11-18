//
//  ComposerOnDeviceUITests.swift
//  DSH-MizarUITests
//
//  The two entries the composer grew, as far as a simulator can prove them.
//
//  Neither feature can be driven to a result on this machine: the rewriter
//  needs Apple Intelligence (the simulator reports the model as not ready) and
//  the microphone needs a speech model this runtime does not carry. What can
//  be proven here is the wiring that must hold on every machine -- the entries
//  exist only while the field has the keyboard, a blank draft is refused, the
//  rewrite's window says why when the model is not usable, and a hold on the
//  microphone leaves an explanation instead of doing nothing. The rewrite's
//  checks and the shared edit surface are pinned by the unit suites; the
//  device-side behaviour is recorded in the plan's acceptance matrix.
//

import XCTest

final class ComposerOnDeviceUITests: AppFlowTestBase {
    /// This class's own mock-host pair, from the MockPorts table.
    override class var mockPort: Int { MockPorts.port(for: String(describing: self)) }

    override func setUp() {
        continueAfterFailure = false
        // A microphone alert left by the test before is springboard's, and it
        // outlives the app: the next launch measures the alert instead of the
        // composer. Clear it before every test, not only the one that asks.
        dismissSpringboardAlertIfAny()
        super.setUp()
    }

    /// The microphone is a UIKit view with a button trait, not a SwiftUI
    /// button, so it is queried by identifier without pinning an element type.
    private func microphone(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["composer.mic"]
    }

    /// The two entries only exist while the keyboard is up: with no caret there
    /// is no draft being written and no place for words to land.
    func testTheEntriesComeAndGoWithTheKeyboard() throws {
        let app = launch(pending: false)
        let field = app.textViews["composer.field"]
        expect(field, "the composer is missing")

        XCTAssertFalse(
            microphone(app).exists,
            "the microphone is offered with the keyboard down",
        )

        field.tap()
        expect(microphone(app), "tapping the field did not bring the microphone")
        // The rewrite's entry is permanent unless the hardware can never run
        // the model, which the simulator does not claim; when it is absent the
        // window cannot be exercised, and the test says so rather than passing
        // silently.
        guard app.buttons["composer.enhance"].exists else {
            throw XCTSkip("this runtime hides the rewrite entry: the model is not eligible")
        }

        app.buttons["composer.dismissKeyboard"].tap()
        let gone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: microphone(app),
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [gone], timeout: 5),
            .completed,
            "the microphone stayed after the keyboard left",
        )
    }

    /// A blank draft keeps the button and refuses the tap, so the row does not
    /// jump when the first character arrives.
    func testTheRewriteEntryIsRefusedOnABlankDraft() throws {
        let app = launch(pending: false)
        app.textViews["composer.field"].tap()
        let enhance = app.buttons["composer.enhance"]
        guard enhance.waitForExistence(timeout: 5) else {
            throw XCTSkip("this runtime hides the rewrite entry: the model is not eligible")
        }

        XCTAssertFalse(enhance.isEnabled, "the rewrite entry is enabled with nothing to rewrite")

        app.textViews["composer.field"].typeText("Tidy this up")
        let enabled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isEnabled == true"),
            object: enhance,
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [enabled], timeout: 5),
            .completed,
            "the rewrite entry stayed disabled with a draft",
        )
    }

    /// The window is the intent list when the model can run, and the reason
    /// when it cannot -- never a tap that does nothing.
    func testTheRewriteWindowOffersTheIntentsOrSaysWhyNot() throws {
        let app = launch(pending: false)
        app.textViews["composer.field"].tap()
        let enhance = app.buttons["composer.enhance"]
        guard enhance.waitForExistence(timeout: 5) else {
            throw XCTSkip("this runtime hides the rewrite entry: the model is not eligible")
        }
        app.textViews["composer.field"].typeText("Tidy this up")
        enhance.tap()

        let panel = app.descendants(matching: .any)["composer.enhance.panel"]
        expect(panel, "the rewrite window did not open")
        let detail = app.descendants(matching: .any)["composer.enhance.moreDetail"]
        let explanation = app.descendants(matching: .any)["composer.enhance.explanation"]
        // The window's own children are leaf texts and rows; SwiftUI may merge
        // the container the identifiers sit on, so the copy is the contract
        // that survives: one of the three rows, or the sentence explaining the
        // model's state.
        let offered = [
            "More detail", "Bullet points", "More formal",
            "This iPhone cannot run Apple Intelligence.",
            "Turn on Apple Intelligence to rewrite a prompt.",
            "The on-device model is still getting ready.",
            "The on-device model does not speak this language yet.",
        ].contains { app.staticTexts[$0].exists }
        XCTAssertTrue(
            detail.waitForExistence(timeout: 3) || explanation.exists || offered,
            "the window offers neither the intents nor an explanation",
        )
        attachScreenshot(of: app, named: "rewrite-window")
    }

    /// A hold on the microphone has to leave something on screen: the strip
    /// while it listens, or the reason it cannot. On this runtime speech is
    /// unavailable, so the strip stays until it is dismissed.
    func testAHoldOnTheMicrophoneLeavesTheStrip() throws {
        let app = launch(pending: false)
        let field = app.textViews["composer.field"]
        field.tap()
        let mic = microphone(app)
        expect(mic, "the microphone did not appear")
        attachScreenshot(of: app, named: "composer-entries")

        mic.press(forDuration: 1.0)
        allowMicrophoneIfAsked()
        // A permission answer starts the next press, not the one that asked.
        mic.press(forDuration: 1.0)
        dismissSpringboardAlertIfAny()

        let strip = app.descendants(matching: .any)["composer.dictation.strip"]
        expect(strip, "holding the microphone left nothing on screen")
        attachScreenshot(of: app, named: "dictation-strip")
    }

    // MARK: - Helpers

    /// Answer the system's microphone alert, whatever language it is in.
    ///
    /// A greeted alert is not the feature's: if it stays up, every query after
    /// it measures the alert. The alert's own buttons are the system's copy,
    /// so the last one (Allow) is tapped when neither label matches.
    /// Tap away whichever system alert is up. Used before a launch, when an
    /// alert left by the previous test would cover the app.
    private func dismissSpringboardAlertIfAny() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        guard alert.waitForExistence(timeout: 1) else { return }
        if alert.buttons.count > 0 {
            alert.buttons.element(boundBy: 0).tap()
        }
    }

    private func allowMicrophoneIfAsked() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        guard alert.waitForExistence(timeout: 3) else { return }
        let allow = alert.buttons.matching(
            NSPredicate(format: "label == %@ OR label == %@", "Allow", "允许"),
        ).firstMatch
        if allow.exists {
            allow.tap()
        } else if alert.buttons.count > 0 {
            alert.buttons.element(boundBy: alert.buttons.count - 1).tap()
        }
    }

    private func attachScreenshot(of app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
