//
//  Feature099UITests.swift
//  DSH-MizarUITests
//
//  The two 0.9.9 screens that talk to the account relay: a banner that can open
//  one settings page, and a questionnaire that pays for itself.
//
//  Both are driven against `scripts/mock-host.mjs`, which now serves the
//  announcement socket (`/app/v1/announcements`), the survey list and the
//  submission, so the app's real client, its real socket and its real decoding
//  are what the test exercises. `-mizarAnnouncementURL` is the only seam: a
//  release build always talks to the production socket.
//
//  The banner test is the one that matters most: the button's *destination* is
//  the part a plain "the banner appeared" assertion cannot see. It taps the
//  button and reads the settings page the server asked for.
//

import XCTest

final class Feature099UITests: XCTestCase {
    private static let mockPort = MockPorts.port(for: "Feature099UITests")
    private static let mockPairingURI =
        "mizar://pair?h=127.0.0.1%3A\(mockPort)&c=MOCK-CODE&n=Mock%20Mac&v=1"
    private static let mockAccountURL = "http://127.0.0.1:\(mockPort)"
    private static let mockAnnouncementURL = "ws://127.0.0.1:\(mockPort)"
    private static let fixtureUsername = "shirazu"
    private static let fixturePassword = "mizar-test-password"
    private static let patience: TimeInterval = 25

    override func setUp() {
        continueAfterFailure = false
        Self.resetMockHost()
    }

    // MARK: - Banner

    /// The banner arrives on the socket, and its button opens the page it names.
    func testBannerOpensTheSettingsPageItNames() {
        let app = launch()
        signIn(app)

        let banner = app.otherElements["announcement.banner"]
        XCTAssertTrue(
            banner.waitForExistence(timeout: Self.patience),
            "the announcement socket produced no banner",
        )
        let title = app.staticTexts["announcement.title"]
        XCTAssertTrue(title.exists, "the banner has no title")
        XCTAssertEqual(title.label, "Mock announcement", "the banner is not the one the relay sent")

        let action = app.buttons["announcement.action"]
        XCTAssertTrue(action.exists, "the banner hid a button the server asked for")
        XCTAssertEqual(action.label, "Open notifications", "the button label is not the server's")
        action.tap()

        // The sheet opens, and the page it pushes is the one the target named.
        XCTAssertTrue(
            app.buttons["settings.done"].waitForExistence(timeout: Self.patience),
            "the banner's button did not open the settings window",
        )
        XCTAssertTrue(
            element("settings.page.notifications", in: app, timeout: Self.patience),
            "the banner opened the settings window but not the notifications page",
        )
        // And the banner is gone: it did its job.
        XCTAssertFalse(banner.exists, "the banner stayed up after its button was tapped")
    }

    /// A banner with no button is still a banner, and has no action to tap.
    ///
    /// The mock always sends the button, so this asserts the *app's* rule from
    /// the other side: `Announcement.actionableButton` hides a button whose
    /// target this build does not know, and the sheet must not open by itself.
    func testBannerDoesNotOpenSettingsOnItsOwn() {
        let app = launch()
        signIn(app)
        XCTAssertTrue(
            app.otherElements["announcement.banner"].waitForExistence(timeout: Self.patience),
            "no banner arrived",
        )
        XCTAssertFalse(
            app.buttons["settings.done"].exists,
            "the banner opened the settings window without anybody asking it to",
        )
    }

    // MARK: - Questionnaire

    /// Fill in the survey and collect the days.
    func testQuestionnairePaysSevenDays() {
        let app = launch()
        signIn(app)

        openSettings(app)
        let row = app.buttons["settings.topic.about"]
        XCTAssertTrue(revealInSettings(row, in: app), "the settings directory has no About shelf")
        row.tap()

        let surveys = app.buttons["settings.about.surveys"]
        XCTAssertTrue(
            revealInSettings(surveys, in: app),
            "About & More has no Questionnaires row",
        )
        surveys.tap()

        let first = app.descendants(matching: .any).matching(identifier: "surveys.row.mock-survey").firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: Self.patience), "the survey list is empty")
        first.tap()

        // Single choice: the picker's menu.
        let rating = app.buttons["survey.question.rating"]
        XCTAssertTrue(rating.waitForExistence(timeout: Self.patience), "the rating question is missing")
        rating.tap()
        let good = app.buttons["Good"]
        XCTAssertTrue(good.waitForExistence(timeout: 8), "the picker offered no options")
        good.tap()

        // Multi choice: one row is enough.
        let option = app.buttons["survey.option.used.banner"]
        XCTAssertTrue(revealInSettings(option, in: app), "the multi-select question is missing")
        option.tap()

        // Text.
        let answer = app.textFields["survey.answer.note"]
        if revealInSettings(answer, in: app) {
            answer.tap()
            answer.typeText("Looks good.")
        }

        let submit = app.buttons["survey.submit"]
        XCTAssertTrue(revealInSettings(submit, in: app), "the form has no submit button")
        XCTAssertTrue(submit.isEnabled, "a required answer was not accepted")
        submit.tap()

        let reward = app.staticTexts["survey.reward"]
        XCTAssertTrue(
            reward.waitForExistence(timeout: Self.patience),
            "submitting the questionnaire produced no reward",
        )
        XCTAssertTrue(reward.label.contains("7"), "the reward is not the seven days the survey pays: \(reward.label)")

        // The plan followed the grant: back to the directory, close the sheet,
        // then read the plan the directory row shows (the same row the account
        // tests assert, and no deeper navigation to get wrong).
        goBack(app)     // form -> list
        goBack(app)     // list -> About & More
        let done = app.buttons["settings.done"]
        if done.waitForExistence(timeout: 5) { done.tap() }
        openSettings(app)
        let plan = app.descendants(matching: .any).matching(identifier: "settings.account.plan").firstMatch
        XCTAssertTrue(plan.waitForExistence(timeout: Self.patience), "the settings directory has no plan row")
        XCTAssertTrue(
            plan.label.contains("Paid"),
            "the survey paid, but the directory still reads \(plan.label)",
        )
    }

    /// Go back one page, whichever way the navigation bar spells it.
    private func goBack(_ app: XCUIApplication) {
        let named = app.buttons["BackButton"]
        let back = named.exists ? named : app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(back.waitForExistence(timeout: 8), "there is no way back from this page")
        back.tap()
    }

    // MARK: - Launch and sign in

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-mizarPairURI", Self.mockPairingURI,
            "-mizarFreshStart",
            "-mizarSkipPermissionPrompts", "-mizarSkipLoginGate", "-mizarSkipOnboarding", "-mizarCreditsFixture",
            "-mizarDirectConnection", "-mizarLocalNetworkRoute", "-mizarSkipSplash",
            "-mizarAccountURL", Self.mockAccountURL,
            "-mizarAccountFreshStart",
            "-mizarAnnouncementURL", Self.mockAnnouncementURL,
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        app.launch()
        dismissSystemAlertIfPresent(app)
        // The first launch after an install settles later than the rest: the
        // naming window is presented once the drawers stop moving, so wait for
        // either it or the shell before deciding the app is ready.
        let shell = app.buttons["sessions.new"]
        let naming = app.buttons["rename.skip"]
        let deadline = Date().addingTimeInterval(Self.patience)
        while Date() < deadline {
            if naming.exists, naming.isHittable { break }
            if shell.exists { break }
            Thread.sleep(forTimeInterval: 0.3)
        }
        dismissNamingIfPresented(app)
        return app
    }

    /// Sign in through the settings sheet, as the operator would.
    private func signIn(_ app: XCUIApplication) {
        openSettings(app)
        let account = app.buttons["settings.account"]
        XCTAssertTrue(account.waitForExistence(timeout: Self.patience), "settings has no account row")
        account.tap()
        let identifier = app.textFields["account.identifier"]
        XCTAssertTrue(identifier.waitForExistence(timeout: Self.patience), "the account screen has no sign-in form")
        identifier.tap()
        identifier.typeText(Self.fixtureUsername)
        let password = app.secureTextFields["account.password"]
        expect(password, "the sign-in form has no password field")
        password.tap()
        password.typeText(Self.fixturePassword)
        let submit = app.buttons["account.submit"]
        expect(submit, "the sign-in form has no submit button")
        submit.tap()
        XCTAssertTrue(
            app.staticTexts["account.username"].waitForExistence(timeout: Self.patience),
            "signing in did not produce a profile",
        )
        // Close the sheet: the banner and the survey list live on the shell,
        // and the sidebar is behind the settings window while it is open.
        let done = app.buttons["settings.done"]
        if done.exists { done.tap() }
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: done)
        _ = XCTWaiter().wait(for: [gone], timeout: 5)
    }

    // MARK: - Helpers

    private func openSettings(_ app: XCUIApplication) {
        let marker = app.buttons["sessions.new"]
        if !(marker.exists && marker.isHittable) {
            let toggle = app.buttons["shell.sidebarToggle"]
            if !toggle.waitForExistence(timeout: Self.patience) {
                dismissSystemAlertIfPresent(app)
                // A naming window that arrived late covers the shell and eats
                // the tap; it is the one overlay a launch can still have up.
                dismissNamingIfPresented(app)
                expect(toggle, "there is no way to open the sidebar")
            }
            toggle.tap()
            let shown = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == true AND hittable == true"),
                object: marker,
            )
            XCTAssertEqual(
                XCTWaiter().wait(for: [shown], timeout: Self.patience),
                .completed,
                "the sidebar did not open",
            )
        }
        let gear = app.buttons["sidebar.settings"]
        XCTAssertTrue(gear.waitForExistence(timeout: Self.patience), "the sidebar has no settings button")
        for _ in 0..<3 {
            if app.buttons["settings.done"].exists { break }
            if !gear.isHittable {
                let opened = app.buttons["shell.sidebarToggle"]
                if opened.exists, opened.isHittable { opened.tap() }
            }
            if gear.isHittable { gear.tap() }
            _ = app.buttons["settings.done"].waitForExistence(timeout: 4)
        }
        XCTAssertTrue(app.buttons["settings.done"].exists, "the settings window did not open")
    }

    /// Scroll the settings window until an element is built.
    @discardableResult
    private func revealInSettings(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        if !element.exists {
            for _ in 0..<5 {
                if element.exists { break }
                let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
                let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
                start.press(forDuration: 0.05, thenDragTo: end)
            }
        }
        return element.waitForExistence(timeout: 4)
    }

    private func element(_ identifier: String, in app: XCUIApplication, timeout: TimeInterval = 5) -> Bool {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch.waitForExistence(timeout: timeout)
    }

    private func expect(_ element: XCUIElement, _ message: String) {
        XCTAssertTrue(element.waitForExistence(timeout: Self.patience), message)
    }

    private func dismissSystemAlertIfPresent(_ app: XCUIApplication) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Allow", "OK", "Continue"] {
            let button = springboard.buttons[label]
            if button.waitForExistence(timeout: 1) { button.tap() }
        }
    }

    private func dismissNamingIfPresented(_ app: XCUIApplication) {
        // The window is presented once the drawers settle, which can be after
        // the first frame a UI test sees; two six-second looks cover a slow
        // simulator without costing a fast one anything (the second only runs
        // when the first one did not find the sheet).
        for _ in 0..<2 {
            let skip = app.buttons["rename.skip"]
            guard skip.waitForExistence(timeout: 6) else { return }
            guard skip.isHittable else {
                Thread.sleep(forTimeInterval: 0.4)
                continue
            }
            skip.tap()
            if !skip.waitForExistence(timeout: 3) { return }
            Thread.sleep(forTimeInterval: 0.4)
        }
    }

    private static func resetMockHost() {
        guard let url = URL(string: "http://127.0.0.1:\(MockPorts.port(for: "Feature099UITests"))/reset") else { return }
        let done = DispatchSemaphore(value: 0)
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        URLSession.shared.dataTask(with: request) { _, _, _ in done.signal() }.resume()
        _ = done.wait(timeout: .now() + 6)
    }
}
