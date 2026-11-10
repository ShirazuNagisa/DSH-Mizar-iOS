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

        // The page after the welcome sends the operator to the desktop app:
        // the link can be opened in the browser or copied for another machine.
        let releaseURL = app.staticTexts["onboarding.desktop.url"]
        XCTAssertTrue(releaseURL.waitForExistence(timeout: 6), "the download page did not appear")
        XCTAssertTrue(
            releaseURL.label.contains("github.com/ShirazuNagisa/AGI-Mizar/releases"),
            "the download page does not name the release page: \(releaseURL.label)",
        )
        XCTAssertTrue(app.buttons["onboarding.desktop.open"].exists, "the download link cannot be opened")
        let copy = app.buttons["onboarding.desktop.copy"]
        XCTAssertTrue(copy.exists, "the download link cannot be copied")
        copy.tap()
        XCTAssertTrue(
            app.buttons["onboarding.desktop.copy"].waitForExistence(timeout: 3),
            "the copy button went away after a tap",
        )
        XCTAssertTrue(
            copy.label.contains("Link copied") || copy.label.contains("链接已复制"),
            "tapping copy said nothing: \(copy.label)",
        )

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
            "-mizarOnboardingStep", "6",
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

    /// A phone that walked an older guide walks this one again.
    ///
    /// The migration is about the guide, not the account: the operator who
    /// updates from 0.9.8 sees the guide once more, with the account and the
    /// settings they already have.
    func testAPhoneThatWalkedAnOlderGuideWalksItAgain() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-mizarFreshStart",
            "-mizarResetOnboarding",
            "-mizarSkipSplash",
            "-mizarSkipPermissionPrompts",
            "-mizarAccountFreshStart",
            "-mizarAccountURL", "http://127.0.0.1:1",
            "-mizarOnboardingVersion", "0.9.8",
        ]
        app.launch()

        let next = app.buttons["onboarding.next"]
        XCTAssertTrue(
            next.waitForExistence(timeout: 25),
            "a phone carrying an older guide did not walk this one",
        )
        app.terminate()
    }

    /// The reload of the session information, before the summary.
    func testTheRefreshPageLoadsTheSessionsAgain() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-mizarFreshStart",
            "-mizarResetOnboarding",
            "-mizarSkipSplash",
            "-mizarSkipPermissionPrompts",
            "-mizarAccountFreshStart",
            "-mizarAccountURL", "http://127.0.0.1:1",
            "-mizarOnboardingStep", "7",
        ]
        app.launch()

        let state = app.descendants(matching: .any)["onboarding.refresh.state"]
        XCTAssertTrue(state.waitForExistence(timeout: 25), "the refresh page did not appear")
        XCTAssertTrue(
            app.staticTexts["正在读取你的会话…"].exists
                || app.staticTexts["Loading your sessions…"].exists
                || app.staticTexts["电脑没有回应。"].exists
                || app.staticTexts["Your computer did not answer."].exists,
            "the refresh page says nothing about the reload",
        )
        app.terminate()
    }


}
