import XCTest

final class OfflineDemoUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testFirstRunDemoAllowsAndRejectsThenReturnsToWelcome() {
        let app = launch(extraArguments: [])
        openDemo(app, from: "onboarding.demo")

        openSession("workshop", in: app)
        let composer = app.descendants(matching: .any)["demo.composer"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap()
        composer.typeText("Help me draft the agenda.")
        app.buttons["demo.send"].tap()
        answerQuestion(in: app)

        app.buttons["approval.allowOnce"].tap()
        let file = app.buttons["demo.file"]
        XCTAssertTrue(file.waitForExistence(timeout: 5))
        file.tap()
        // The resource resolves in the simulator's system language, not the
        // test's assumed language, so accept either localized title.
        let previewTitle = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@",
                        "Community Repair Workshop", "社区维修工作坊日程")
        ).firstMatch
        XCTAssertTrue(previewTitle.waitForExistence(timeout: 5))
        app.buttons["demo.file.done"].tap()

        openSession("research", in: app)
        let prompt = app.buttons["demo.tryPrompt"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 5))
        prompt.tap()
        answerQuestion(in: app, option: 1)
        app.buttons["approval.reject"].tap()
        let rejection = app.descendants(matching: .any)["demo.rejected"].firstMatch
        XCTAssertTrue(rejection.waitForExistence(timeout: 5))
        XCTAssertTrue(rejection.label.contains("For traceable evidence") || rejection.label.contains("证据可追溯"))
        XCTAssertFalse(file.exists)

        openSession("workshop", in: app)
        XCTAssertTrue(file.waitForExistence(timeout: 5))
        app.buttons["demo.close"].firstMatch.tap()
        XCTAssertTrue(app.buttons["onboarding.next"].waitForExistence(timeout: 5))
        openDemo(app, from: "onboarding.demo")
        openSession("workshop", in: app)
        XCTAssertTrue(app.buttons["demo.tryPrompt"].waitForExistence(timeout: 5))
        XCTAssertFalse(file.exists)
    }

    func testChineseSignedOutGateOpensLocalizedDemoAndFile() {
        let app = launch(extraArguments: [
            "-mizarSkipOnboarding", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
        ])
        openDemo(app, from: "welcome.gate.demo", expectedLabel: "体验演示")

        openSession("research", in: app)
        XCTAssertEqual(app.buttons["demo.tryPrompt"].label, "写一份研究简报，总结两种方法的取舍。")
        app.buttons["demo.tryPrompt"].tap()
        answerQuestion(in: app)
        app.buttons["approval.allowOnce"].tap()
        let file = app.buttons["demo.file"]
        XCTAssertTrue(file.waitForExistence(timeout: 5))
        file.tap()
        XCTAssertTrue(app.staticTexts["笔记整理流程简报"].waitForExistence(timeout: 5))
        app.buttons["demo.file.done"].tap()
        app.buttons["demo.close"].firstMatch.tap()

        XCTAssertTrue(app.buttons["welcome.gate.signIn"].waitForExistence(timeout: 5))
    }

    func testAccountStepStaysSignedOutAfterDemo() {
        let app = launch(extraArguments: ["-mizarOnboardingStep", "4"])
        XCTAssertTrue(app.buttons["onboarding.account.signIn"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["onboarding.next"].isEnabled)
        openDemo(app, from: "onboarding.demo")

        app.buttons["demo.close"].firstMatch.tap()
        XCTAssertTrue(app.buttons["onboarding.account.signIn"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["onboarding.next"].isEnabled)
    }

    private func launch(extraArguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-mizarFreshStart",
            "-mizarResetOnboarding",
            "-mizarSkipSplash",
            "-mizarSkipPermissionPrompts",
            "-mizarAccountFreshStart",
            "-mizarAccountURL", "http://127.0.0.1:1",
        ] + extraArguments
        app.launch()
        return app
    }

    private func openDemo(_ app: XCUIApplication, from identifier: String, expectedLabel: String? = nil) {
        let button = app.buttons[identifier]
        XCTAssertTrue(button.waitForExistence(timeout: 20))
        if let expectedLabel { XCTAssertEqual(button.label, expectedLabel) }
        if !button.isHittable { app.swipeUp() }
        button.tap()
        XCTAssertTrue(app.buttons["demo.session.workshop"].waitForExistence(timeout: 5))
    }

    private func openSession(_ name: String, in app: XCUIApplication) {
        let session = app.buttons["demo.session.\(name)"]
        if !session.isHittable {
            // Compact split view uses the system back button to return to the list.
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
        XCTAssertTrue(session.waitForExistence(timeout: 5))
        session.tap()
        XCTAssertTrue(app.staticTexts["demo.banner"].waitForExistence(timeout: 5))
    }

    private func answerQuestion(in app: XCUIApplication, option: Int = 0) {
        let answer = app.buttons["demo.question.option.\(option)"]
        XCTAssertTrue(answer.waitForExistence(timeout: 5))
        let submit = app.buttons["demo.question.submit"]
        XCTAssertFalse(submit.isEnabled)
        answer.tap()
        XCTAssertTrue(submit.isEnabled)
        submit.tap()
        XCTAssertTrue(app.buttons["approval.allowOnce"].waitForExistence(timeout: 5))
    }
}
