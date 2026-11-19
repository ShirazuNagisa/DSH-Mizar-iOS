//
//  AppStoreShotsTour.swift
//  DSH-MizarUITests
//
//  Captures the offline demo for App Store screenshots. Not an assertion
//  suite: it drives the bundled demo (no host, no account, no mock server)
//  and writes one PNG per step.
//
//    TEST_RUNNER_MIZAR_APPSTORE_SHOTS=/tmp/shots scripts/ios.sh test \
//      "Mizar AppStore iPhone 2026-11-19" \
//      -only-testing:DSH-MizarUITests/AppStoreShotsTour/testPhone
//
//  Run the same class on the 13-inch iPad simulator for the iPad set.
//

import XCTest

final class AppStoreShotsTour: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard let path = ProcessInfo.processInfo.environment["MIZAR_APPSTORE_SHOTS"], !path.isEmpty else {
            throw XCTSkip("set TEST_RUNNER_MIZAR_APPSTORE_SHOTS to a folder to write the shots to")
        }
        folder = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func testPhone() throws {
        let app = launch()
        shoot("01-sessions", settle: 1.6)

        open("workshop", in: app)
        tap(app.buttons["demo.tryPrompt"])
        shoot("02-question")

        tap(app.buttons["demo.question.option.0"])
        tap(app.buttons["demo.question.submit"])
        shoot("03-approval")

        tap(app.buttons["approval.allowOnce"])
        shoot("04-delivered", settle: 1.6)

        tap(app.buttons["demo.file"])
        shoot("05-preview", settle: 1.4)
        tap(app.buttons["demo.file.done"])

        app.navigationBars.buttons.element(boundBy: 0).tap()
        open("research", in: app)
        tap(app.buttons["demo.tryPrompt"])
        tap(app.buttons["demo.question.option.1"])
        tap(app.buttons["demo.question.submit"])
        tap(app.buttons["approval.reject"])
        shoot("06-rejected", settle: 1.4)
    }

    func testPad() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = launch()
        shoot("ipad-01-sessions", settle: 1.8)

        open("workshop", in: app)
        tap(app.buttons["demo.tryPrompt"])
        shoot("ipad-02-question")

        tap(app.buttons["demo.question.option.0"])
        tap(app.buttons["demo.question.submit"])
        shoot("ipad-03-approval")

        tap(app.buttons["approval.allowOnce"])
        shoot("ipad-04-delivered", settle: 1.6)
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-mizarFreshStart",
            "-mizarResetOnboarding",
            "-mizarSkipSplash",
            "-mizarSkipPermissionPrompts",
            "-mizarAccountFreshStart",
            "-mizarAccountURL", "http://127.0.0.1:1",
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
        ]
        app.launch()
        let demo = app.buttons["onboarding.demo"]
        XCTAssertTrue(demo.waitForExistence(timeout: 25))
        if !demo.isHittable { app.swipeUp() }
        demo.tap()
        XCTAssertTrue(app.buttons["demo.session.workshop"].waitForExistence(timeout: 8))
        return app
    }

    private func open(_ name: String, in app: XCUIApplication) {
        let session = app.buttons["demo.session.\(name)"]
        if !session.isHittable {
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
        XCTAssertTrue(session.waitForExistence(timeout: 5))
        session.tap()
        XCTAssertTrue(app.staticTexts["demo.banner"].waitForExistence(timeout: 5))
    }

    private func tap(_ element: XCUIElement, timeout: TimeInterval = 8) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout))
        element.tap()
        Thread.sleep(forTimeInterval: 0.5)
    }

    private func shoot(_ name: String, settle: TimeInterval = 1.0) {
        Thread.sleep(forTimeInterval: settle)
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try? png.write(to: folder.appendingPathComponent("\(name).png"))
    }
}
