//
//  WelcomeGateUITests.swift
//  DSH-MizarUITests
//
//  The one screen every other UI test launches past.
//
//  `AppFlowTestBase` passes `-mizarSkipLoginGate` because the screens it drives
//  live behind the gate and the suite has no account. That makes the gate itself
//  the one part of the launch path nothing else covers -- so it is covered here,
//  by launching the app the way a person does.
//

import XCTest

final class WelcomeGateUITests: XCTestCase {
    /// A fresh install with no session lands on the gate, not the pairing page.
    func testAFreshLaunchStopsAtTheGate() {
        let app = launchPastNothing()
        XCTAssertTrue(
            app.descendants(matching: .any)["welcome.gate"].waitForExistence(timeout: 25),
            "a fresh install did not land on the login gate",
        )
        XCTAssertTrue(app.buttons["welcome.gate.signIn"].exists, "the gate has no sign-in button")
        XCTAssertTrue(app.buttons["welcome.gate.register"].exists, "the gate has no register button")
        XCTAssertFalse(
            app.buttons["unpaired.scan"].exists,
            "the scan page appeared before the gate",
        )
    }

    /// "Create account" opens the half of the form that creates one.
    func testRegisterOpensTheCreateForm() {
        let app = launchPastNothing()
        let register = app.buttons["welcome.gate.register"]
        XCTAssertTrue(register.waitForExistence(timeout: 25), "the gate never appeared")
        // A notification prompt from an earlier run can still be on screen; it
        // covers the button and eats the tap.
        dismissSystemAlertIfPresent(app)
        if !register.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(register.isHittable, "the register button cannot be tapped")
        register.tap()
        XCTAssertTrue(
            app.textFields["account.username.field"].waitForExistence(timeout: 10),
            "the create-account form did not open",
        )
    }

    /// Tap away a system permission alert, if one is up.
    private func dismissSystemAlertIfPresent(_ app: XCUIApplication) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Don’t Allow", "Don't Allow", "Allow"] {
            let button = springboard.buttons[label]
            if button.exists {
                button.tap()
                return
            }
        }
        _ = app
    }

    /// Launch without the gate bypass or a stored pairing.
    private func launchPastNothing() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-mizarFreshStart",
            "-mizarAccountFreshStart",
            "-mizarSkipPermissionPrompts", "-mizarSkipOnboarding",
            "-mizarAccountURL", "http://127.0.0.1:\(MockPorts.port(for: "WelcomeGateUITests"))",
        ]
        app.launch()
        return app
    }
}
