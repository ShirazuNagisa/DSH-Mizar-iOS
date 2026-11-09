//
//  Live099UITests.swift
//  DSH-MizarUITests
//
//  The production path, on a real phone, opt-in only.
//
//  Everything else in the suite talks to `scripts/mock-host.mjs`. That proves
//  the phone's half; it cannot prove that the deployed relay answers the same
//  contract, that the free/paid lane carries the phone, or that the mail and
//  survey links between the two servers work. Those are exactly the things that
//  can only be seen against production, so this class exists and **skips unless
//  it is explicitly asked for**:
//
//      MIZAR_LIVE_099=1 xcodebuild test -destination 'platform=iOS,id=<udid>' \
//          -only-testing:DSH-MizarUITests/Live099UITests
//
//  It never runs in the default suite and never creates an account: it uses the
//  session already on the phone. The questionnaire it fills in is the operator's
//  own live one, and filling it pays this account the reward — so run it on a
//  phone whose account may receive the paid days.
//

import XCTest

final class Live099UITests: XCTestCase {
    private static let patience: TimeInterval = 30

    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MIZAR_LIVE_099"] == "1",
            "the production check is opt-in: set MIZAR_LIVE_099=1",
        )
        continueAfterFailure = false
    }

    /// Open the live questionnaires and fill in whatever the operator dispatched.
    func testLiveQuestionnaireListsAndPays() throws {
        let app = XCUIApplication()
        // No account URL, no announcement URL, no fresh start: the production
        // relay and the session already on this phone.
        app.launchArguments = ["-mizarSkipOnboarding", "-mizarSkipSplash"]
        app.launch()

        openSettings(app)
        let about = app.buttons["settings.topic.about"]
        XCTAssertTrue(reveal(about, in: app), "the settings directory has no About shelf")
        about.tap()

        let surveys = app.buttons["settings.about.surveys"]
        XCTAssertTrue(reveal(surveys, in: app), "About & More has no Questionnaires row")
        surveys.tap()

        // Survey rows are `NavigationLink`s, which XCUITest sees as buttons
        // (not cells); the identifier prefix is the only stable handle.
        let first = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'surveys.row.'")).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: Self.patience), "the live survey list is empty")
        first.tap()

        // The form opened when its submit button is reachable; the list and the
        // form are both `List`s, so waiting on the button (after scrolling) is
        // the assertion that cannot pass on the list itself.
        let submit = app.buttons["survey.submit"]
        XCTAssertTrue(
            reveal(submit, in: app),
            "the questionnaire did not open (or has no submit button)",
        )

        // Answer what this deployment asks. A single choice is a picker menu;
        // either language's option labels are accepted because the operator's
        // survey and this phone may disagree about the language.
        for question in ["survey.question.settings", "survey.question.rating"] {
            let picker = app.buttons[question]
            guard reveal(picker, in: app) else { continue }
            picker.tap()
            let labels = ["好用", "还行", "不好用", "Good", "Bad", "Great", "OK"]
            let option = app.buttons.matching(NSPredicate(format: "label IN %@", labels)).firstMatch
            if option.waitForExistence(timeout: 5) { option.tap() }
            break
        }
        for identifier in ["survey.option.used.banner", "survey.option.used.survey"] {
            let option = app.buttons[identifier]
            if reveal(option, in: app) { option.tap() }
        }
        let text = app.textFields.matching(NSPredicate(format: "identifier BEGINSWITH 'survey.answer.'")).firstMatch
        if reveal(text, in: app) {
            text.tap()
            text.typeText("ok")
        }
        XCTAssertTrue(reveal(submit, in: app), "the live questionnaire has no submit button")
        XCTAssertTrue(submit.isEnabled, "the production form says an answer is missing")
        submit.tap()

        XCTAssertTrue(
            app.staticTexts["survey.reward"].waitForExistence(timeout: Self.patience)
                || app.staticTexts["survey.completed"].waitForExistence(timeout: Self.patience),
            "production did not accept the answer (no reward, no completion)",
        )
    }

    // MARK: - Helpers

    private func openSettings(_ app: XCUIApplication) {
        let marker = app.buttons["sessions.new"]
        if !(marker.exists && marker.isHittable) {
            let toggle = app.buttons["shell.sidebarToggle"]
            XCTAssertTrue(toggle.waitForExistence(timeout: Self.patience), "there is no way to open the sidebar")
            toggle.tap()
        }
        let gear = app.buttons["sidebar.settings"]
        XCTAssertTrue(gear.waitForExistence(timeout: Self.patience), "the sidebar has no settings button")
        for _ in 0..<3 {
            if app.buttons["settings.done"].exists { break }
            if gear.isHittable { gear.tap() }
            _ = app.buttons["settings.done"].waitForExistence(timeout: 4)
        }
        XCTAssertTrue(app.buttons["settings.done"].exists, "the settings window did not open")
    }

    @discardableResult
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        if !(element.exists && element.isHittable) {
            for _ in 0..<6 {
                if element.exists { break }
                let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
                let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
                start.press(forDuration: 0.05, thenDragTo: end)
            }
        }
        return element.waitForExistence(timeout: 5)
    }
}
