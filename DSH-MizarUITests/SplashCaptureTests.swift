//
//  SplashCaptureTests.swift
//  DSH-MizarUITests
//
//  Not a test: two pictures of the launch animation, taken from the outside.
//
//  The splash is an overlay that is gone before any control exists, so no
//  assertion can see it and the screenshot tour -- which launches with
//  `-mizarSkipSplash` -- never will. This runs the real launch and photographs
//  it twice: while the mark is held, and while the camera is going through it.
//

import XCTest

final class SplashCaptureTests: XCTestCase {
    func testCaptureTheLaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["-mizarSkipLoginGate", "-mizarSkipOnboarding", "-mizarSkipPermissionPrompts"]
        app.launch()
        // A first launch asks for notifications; the dialog is springboard's and
        // covers everything until it is answered.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Allow", "允许", "Don’t Allow", "不允许"] where springboard.buttons[label].exists {
            springboard.buttons[label].tap()
            break
        }

        // The real launch: terminate, start again, and photograph the first
        // second and a half in slices -- the splash lives for about a second, so
        // two frames can miss it entirely and read as "there is no splash".
        app.terminate()
        app.launch()
        for slice in 0..<12 {
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = String(format: "slice-%02d", slice)
            shot.lifetime = .keepAlways
            add(shot)
            Thread.sleep(forTimeInterval: 0.12)
        }
        Thread.sleep(forTimeInterval: 1.0)
        let held = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        held.name = "splash-hold"
        held.lifetime = .keepAlways
        add(held)

        Thread.sleep(forTimeInterval: 0.55)
        let pushed = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        pushed.name = "splash-push"
        pushed.lifetime = .keepAlways
        add(pushed)

        Thread.sleep(forTimeInterval: 1.2)
        let after = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        after.name = "splash-after"
        after.lifetime = .keepAlways
        add(after)
    }
}
