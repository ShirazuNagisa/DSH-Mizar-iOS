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
    private static let offlineLaunchArguments = [
        "-mizarSkipSplash",
        "-mizarSkipPermissionPrompts",
        "-mizarAccountFreshStart",
        "-mizarAccountURL", "http://127.0.0.1:1",
    ]

    func testFreshLaunchShowsWelcomeThenTheAccountGate() {
        let app = XCUIApplication()
        app.launchArguments = ["-mizarFreshStart", "-mizarResetOnboarding"]
            + Self.offlineLaunchArguments
        app.launch()

        let next = app.buttons["onboarding.next"]
        XCTAssertTrue(
            next.waitForExistence(timeout: 25),
            "a fresh install did not land on the first-run guide",
        )
        XCTAssertTrue(next.waitForExistence(timeout: 5), "the guide has no Continue button")
        XCTAssertTrue(next.isEnabled, "the welcome page cannot advance")
        next.tap()

        // The page after the welcome is the server choice. The official
        // server is the default, so Continue stays enabled without a check.
        XCTAssertTrue(
            app.buttons["onboarding.server.official"].waitForExistence(timeout: 6),
            "the server page did not appear after the welcome",
        )
        XCTAssertTrue(app.buttons["onboarding.server.self"].exists, "the server page has no self-hosted choice")
        XCTAssertTrue(next.isEnabled, "the official server should need no verification")
        next.tap()

        // The page after the server sends the operator to the desktop app:
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
        app.launchArguments = ["-mizarFreshStart", "-mizarResetOnboarding"]
            + Self.offlineLaunchArguments
            + ["-mizarOnboardingStep", "8"]
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
        app.launchArguments = Self.offlineLaunchArguments + ["-mizarSkipOnboarding"]
        app.launch()

        let welcomeGate = app.descendants(matching: .any)["welcome.gate"]
        XCTAssertTrue(
            welcomeGate.waitForExistence(timeout: 25),
            "the skip launch did not establish the completed-guide state",
        )
        app.terminate()

        app.launchArguments = Self.offlineLaunchArguments + [
            "-mizarOnboardingVersion", "0.9.8",
            "-mizarOnboardingStep", "10",
        ]
        app.launch()

        let done = app.buttons["onboarding.done"]
        XCTAssertTrue(
            done.waitForExistence(timeout: 25),
            "a phone carrying the 0.9.8 guide did not open the summary page",
        )
        done.tap()
        XCTAssertTrue(
            welcomeGate.waitForExistence(timeout: 10),
            "finishing the migrated guide did not return to the welcome gate",
        )
        app.terminate()

        app.launchArguments = Self.offlineLaunchArguments
        app.launch()

        XCTAssertTrue(
            welcomeGate.waitForExistence(timeout: 25),
            "the completed guide did not stay complete across a plain relaunch",
        )
        app.terminate()
    }

    /// The reload of the session information, before the summary.
    func testTheRefreshPageLoadsTheSessionsAgain() {
        let app = XCUIApplication()
        app.launchArguments = ["-mizarFreshStart", "-mizarResetOnboarding"]
            + Self.offlineLaunchArguments
            + ["-mizarOnboardingStep", "9"]
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


    /// The server page: official by default, and a self-hosted address cannot
    /// be walked past until it has answered.
    ///
    /// The invalid-origin case is deliberate: `ServerProbe` refuses it before
    /// any request, so the test proves the gate without a relay to talk to.
    func testServerPageNeedsAVerifiedSelfHostedAddress() {
        let app = XCUIApplication()
        app.launchArguments = ["-mizarFreshStart", "-mizarResetOnboarding"]
            + Self.offlineLaunchArguments
            + ["-mizarOnboardingStep", "1"]
        app.launch()

        let next = app.buttons["onboarding.next"]
        let official = app.buttons["onboarding.server.official"]
        XCTAssertTrue(official.waitForExistence(timeout: 25), "the server page did not appear")
        XCTAssertTrue(next.isEnabled, "the official server should need no verification")

        app.buttons["onboarding.server.self"].tap()
        let domain = app.textFields["onboarding.server.domain"]
        XCTAssertTrue(domain.waitForExistence(timeout: 6), "the self-hosted fields did not appear")
        XCTAssertFalse(next.isEnabled, "a self-hosted server let an unverified address continue")

        domain.tap()
        domain.typeText("http://relay.example.com")
        app.buttons["onboarding.server.verify"].tap()

        let status = app.descendants(matching: .any)["onboarding.server.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 6), "the check produced no status line")
        let refused = status.label.contains("Enter the server's address")
            || status.label.contains("请输入服务器地址")
        XCTAssertTrue(refused, "an http origin was not refused: \(status.label)")
        XCTAssertFalse(next.isEnabled, "an unverified address let the guide continue")

        app.terminate()
        app.launchArguments = Self.offlineLaunchArguments + ["-mizarOnboardingStep", "2"]
        app.launch()

        let desktop = app.staticTexts["onboarding.desktop.url"]
        XCTAssertTrue(
            desktop.waitForExistence(timeout: 25),
            "the persisted self-hosted draft did not reopen on the raw desktop page",
        )
        let relaunchedNext = app.buttons["onboarding.next"]
        XCTAssertTrue(
            relaunchedNext.waitForExistence(timeout: 6),
            "the raw desktop page has no Continue button",
        )
        relaunchedNext.tap()

        XCTAssertTrue(
            app.buttons["onboarding.connect.skip"].waitForExistence(timeout: 6),
            "Continue from the desktop page did not reach the self-hosted connect page",
        )

        let back = app.buttons["onboarding.back"]
        XCTAssertTrue(
            back.waitForExistence(timeout: 6),
            "the self-hosted connect page has no back control",
        )
        XCTAssertTrue(back.isHittable, "the self-hosted connect page's back control is not tappable")
        back.tap()
        XCTAssertTrue(
            desktop.waitForExistence(timeout: 6),
            "the first back tap did not return to the raw desktop page",
        )
        XCTAssertTrue(
            back.waitForExistence(timeout: 6),
            "the raw desktop page has no back control",
        )
        XCTAssertTrue(back.isHittable, "the raw desktop page's back control is not tappable")
        back.tap()

        let restoredOfficial = app.buttons["onboarding.server.official"]
        XCTAssertTrue(
            restoredOfficial.waitForExistence(timeout: 6),
            "the server page did not reappear after navigating back",
        )
        XCTAssertTrue(restoredOfficial.isHittable, "the official server choice cannot be tapped")
        restoredOfficial.tap()
        app.terminate()
    }
}
