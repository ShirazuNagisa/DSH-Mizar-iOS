//
//  OnboardingUITests.swift
//  DSH-MizarUITests
//
//  The first-run guide is the one launch path every other suite skips. This
//  covers its first two pages without an account: welcome, then the login step
//  with Continue correctly disabled.
//

import XCTest

final class OnboardingUITests: XCTestCase {
    func testFreshLaunchShowsWelcomeThenTheAccountGate() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-mizarFreshStart",
            "-mizarResetOnboarding",
            "-mizarSkipSplash",
            "-mizarSkipPermissionPrompts",
            "-mizarAccountFreshStart",
            "-mizarAccountURL", "http://127.0.0.1:1",
        ]
        app.launch()

        let next = app.buttons["onboarding.next"]
        XCTAssertTrue(
            next.waitForExistence(timeout: 25),
            "a fresh install did not land on the first-run guide",
        )
        XCTAssertTrue(next.waitForExistence(timeout: 5), "the guide has no Continue button")
        XCTAssertTrue(next.isEnabled, "the welcome page cannot advance")
        next.tap()

        let signIn = app.buttons["onboarding.account.signIn"]
        XCTAssertTrue(signIn.waitForExistence(timeout: 6), "the account page did not appear")
        XCTAssertFalse(next.isEnabled, "the account page let a signed-out person continue")

        app.terminate()
    }

    func testPlanPageKeepsPaidDisabled() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-mizarFreshStart",
            "-mizarResetOnboarding",
            "-mizarSkipSplash",
            "-mizarSkipPermissionPrompts",
            "-mizarAccountFreshStart",
            "-mizarAccountURL", "http://127.0.0.1:1",
            "-mizarOnboardingStep", "5",
        ]
        app.launch()

        let upgrade = app.buttons["onboarding.plan.upgrade"]
        XCTAssertTrue(upgrade.waitForExistence(timeout: 25), "the plan page has no paid control")
        XCTAssertFalse(upgrade.isEnabled, "the TestFlight paid control is tappable")
        XCTAssertTrue(
            app.staticTexts["TestFlight 版本暂不支持购买。"].exists
                || app.staticTexts["TestFlight version: purchases are temporarily unavailable."].exists,
            "the plan page does not explain why the paid control is disabled",
        )
        app.terminate()
    }
}
