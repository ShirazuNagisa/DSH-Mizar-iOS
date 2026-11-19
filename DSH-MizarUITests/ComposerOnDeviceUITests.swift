//
//  ComposerOnDeviceUITests.swift
//  DSH-MizarUITests
//
//  The two entries the composer grew, as far as a simulator can prove them.
//
//  Neither feature can be driven to a result on this machine: the rewriter
//  needs Apple Intelligence (the simulator reports the model as not ready) and
//  the microphone needs a speech model this runtime does not carry. What can
//  be proven here is the wiring that must hold on every machine -- the rewrite
//  entry exists only while the field has the keyboard, a blank draft is
//  refused, its window says why when the model is not usable, and a hold on
//  the *resting* field is the microphone: it must leave the strip (or its
//  explanation) without taking the field's own selection gesture away when the
//  keyboard is up. The rewrite's checks and the shared edit surface are pinned
//  by the unit suites; the device-side behaviour is recorded in the plan's
//  acceptance matrix.
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

    /// The rewrite entry belongs to the keyboard: with no caret there is no
    /// draft being written, and the row keeps its resting shape.
    func testTheRewriteEntryComesAndGoesWithTheKeyboard() throws {
        let app = launch(pending: false)
        let field = app.textViews["composer.field"]
        expect(field, "the composer is missing")

        XCTAssertFalse(
            app.buttons["composer.enhance"].exists,
            "the rewrite entry is offered with the keyboard down",
        )

        _ = focusEmptyComposer(app)
        // The entry is always drawn now, even when this runtime cannot run the
        // model; if it is absent the window cannot be exercised and the test
        // says so rather than passing silently.
        guard app.buttons["composer.enhance"].exists else {
            throw XCTSkip("the rewrite entry is not drawn on this runtime")
        }

        app.buttons["composer.dismissKeyboard"].tap()
        let gone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: app.buttons["composer.enhance"],
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [gone], timeout: 5),
            .completed,
            "the rewrite entry stayed after the keyboard left",
        )
    }

    /// The settings switch's other half: with the desktop model chosen, the
    /// rewrite goes to the paired computer and its answer lands in the field.
    ///
    /// The mock host answers `session.enhancePrompt` with the draft plus a
    /// marker, so this proves the toggle chooses the other path and that the
    /// result goes through the same validation and edit handoff as the
    /// on-device one.
    func testTheDesktopModelRewritesWhenTheSwitchAsks() throws {
        let app = launch(pending: false, extraArguments: ["-mizarDesktopEnhance"])
        let field = focusEmptyComposer(app)
        field.typeText("Tidy this up")
        app.buttons["composer.enhance"].tap()

        // The popover merges its rows' identifiers into the panel's, so the
        // row is found by its label -- the same way the person finds it.
        let moreDetail = app.buttons
            .matching(NSPredicate(format: "label == %@", "More detail"))
            .firstMatch
        expect(moreDetail, "the desktop path did not offer the intents")
        moreDetail.tap()

        let rewritten = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", "rewritten on the desktop"),
            object: field,
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [rewritten], timeout: 15),
            .completed,
            "the desktop rewrite never reached the field; value=\(String(describing: field.value))",
        )
    }

    /// A blank draft keeps the button and refuses the tap, so the row does not
    /// jump when the first character arrives.
    func testTheRewriteEntryIsRefusedOnABlankDraft() throws {
        let app = launch(pending: false)
        let field = focusEmptyComposer(app)
        let enhance = app.buttons["composer.enhance"]
        guard enhance.waitForExistence(timeout: 5) else {
            throw XCTSkip("this runtime hides the rewrite entry: the model is not eligible")
        }

        let refused = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isEnabled == false"),
            object: enhance,
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [refused], timeout: 5),
            .completed,
            "the rewrite entry is enabled with nothing to rewrite; draft=\(String(describing: field.value))",
        )

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
        let field = focusEmptyComposer(app)
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
            "Apple Intelligence is not available on this device.",
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

    /// A hold on the resting field is the microphone. On this runtime speech is
    /// unavailable, so the strip carries its explanation and stays until it is
    /// dismissed -- which is exactly the "it answered instead of doing nothing"
    /// property the device needs.
    func testAHoldOnTheRestingFieldLeavesTheStrip() throws {
        let app = launch(pending: false)
        let field = app.textViews["composer.field"]
        expect(field, "the composer is missing")
        attachScreenshot(of: app, named: "composer-entries")

        // No tap first: the hold has to work on the field at rest, which is
        // where the operator meets it.
        field.press(forDuration: 1.0)
        allowMicrophoneIfAsked()
        dismissSpringboardAlertIfAny()

        // On the simulator speech is unavailable and the strip carries the
        // explanation; on a device the microphone opens, and whatever it heard
        // leaves either a transcript in the field or a note that it heard
        // nothing. Both are "the hold answered"; silence is the bug this
        // catches.
        let strip = app.descendants(matching: .any)["composer.dictation.strip"]
        let note = app.descendants(matching: .any)["composer.onDevice.note"]
        XCTAssertTrue(
            strip.waitForExistence(timeout: 2) || note.waitForExistence(timeout: 8) || strip.exists,
            "holding the resting field left nothing on screen",
        )
        attachScreenshot(of: app, named: "dictation-strip")
    }

    /// With the keyboard up the same hold belongs to the text: it selects, and
    /// must not start a recording over the operator's selection.
    func testAHoldWithTheKeyboardUpDoesNotDictate() throws {
        let app = launch(pending: false)
        let field = focusEmptyComposer(app)
        field.press(forDuration: 1.0)
        let strip = app.descendants(matching: .any)["composer.dictation.strip"]
        XCTAssertFalse(
            strip.waitForExistence(timeout: 2),
            "a hold with the keyboard up started dictation",
        )
        // Dismiss whatever selection menu the press opened before the next
        // test measures the screen.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
    }

    // MARK: - Helpers

    /// Focus the composer on a blank draft, whatever it held before.
    ///
    /// Tapping the field is not enough on a simulator: the field is near the
    /// keyboard, and a tap resolved while the keyboard was rising can land on
    /// a key -- the Chinese layout's `/` sits under the caret -- so the field
    /// can end up holding a slash no test typed. A previous test's draft can
    /// also survive a relaunch for a moment. Both are cleared here, so a test
    /// about a blank draft starts from one.
    @discardableResult
    private func focusEmptyComposer(_ app: XCUIApplication) -> XCUIElement {
        let field = app.textViews["composer.field"]
        expect(field, "the composer is missing")
        field.tap()
        let placeholder = "Tap to type, or hold to talk."
        if let value = field.value as? String, !value.isEmpty, value != placeholder {
            // Delete, not select-all: the field is a `UITextView`, and a
            // command-key shortcut is not guaranteed to reach it as a selection
            // -- if it does not, the "a" is typed and the delete removes that
            // instead, leaving the draft exactly as it was.
            let length = (value as NSString).length
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: length + 2))
        }
        let blank = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", placeholder),
            object: field,
        )
        _ = XCTWaiter.wait(for: [blank], timeout: 5)
        return field
    }

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
