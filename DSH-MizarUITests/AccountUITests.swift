//
//  AccountUITests.swift
//  DSH-MizarUITests
//
//  The account, the subscription and the paid-only attachments, driven against
//  `scripts/mock-host.mjs`.
//
//  The mock host serves `/account/v1` from the same process as the protocol, so
//  the app's real ``AccountClient`` — the same URLSession, the same decoding, the
//  same bearer header — talks to a real HTTP server. What is faked is only the
//  account database: one fixture account exists (`shirazu` /
//  `mizar-test-password`) and one invite code turns it paid.
//
//  The subscription is faked at the seam the product allows: a debug-only
//  `MockSubscriptionStore`, selected by `-mizarMockSubscription`, implements the
//  same protocol as StoreKit. A simulator UI test has no App Store account and no
//  payment sheet, so without that seam the only assertion possible about the CTA
//  would be that it exists. With it, the test can press the button and watch the
//  plan change — which is the behaviour that matters. The real path is
//  `StoreKitSubscriptionStore`; manual verification with `DSH-Mizar.storekit` is
//  documented in `docs/testflight.md`.
//
//  Every launch signs out. The Keychain outlives a UI-test process, so without
//  `-mizarAccountFreshStart` the second test would start signed in as the first
//  test's account.
//

import XCTest

final class AccountUITests: XCTestCase {
    /// The mock host, which must be running before this suite is.
    private static let mockPairingURI =
        "mizar://pair?h=127.0.0.1%3A19395&c=MOCK-CODE&n=Mock%20Mac&v=1"
    /// The account URL the launch argument points the app at.
    private static let mockAccountURL = "http://127.0.0.1:19395"
    /// The fixture account in the mock host.
    private static let fixtureUsername = "shirazu"
    private static let fixturePassword = "mizar-test-password"
    /// The invite code the mock host accepts.
    private static let inviteCode = "MOCK-INVITE"
    /// How long to wait for the app or the host to answer.
    private static let patience: TimeInterval = 20
    /// The naming prompt is a first-pairing surface. Three seconds is enough
    /// to see it; spending the full `patience` on every launch that has no
    /// prompt is what makes this suite feel slower than its assertions.
    private static let namingPatience: TimeInterval = 3

    override func setUp() {
        continueAfterFailure = false
        Self.resetMockHost()
    }

    // MARK: - Logged out

    /// The settings row that says nobody is signed in.
    ///
    /// This is the state the app must be perfectly usable in: no account, no
    /// prompt at launch, and a row that says so rather than an error.
    func testSignedOutSettingsShowsBlankAccountRow() {
        let app = launch(session: nil)
        openSettings(app)

        let row = element("settings.account", in: app)
        expect(row, "the settings screen has no account row")

        let name = element("settings.account.name", in: app)
        expect(name, "the account row does not say who is signed in")
        XCTAssertEqual(name.label, "Not signed in", "a signed-out account row says something else")

        let plan = element("settings.account.plan", in: app)
        expect(plan, "the account row does not show a plan")
        XCTAssertEqual(plan.label, "Free account", "a signed-out account row claims a paid plan")
    }

    /// The invite-code screen lives on the account screen, not in About.
    ///
    /// About is about the build; redeeming a code is an account action, so the
    /// settings screen no longer carries a second doorway to it.
    func testAboutDoesNotOfferInviteRedemption() {
        let app = launch(session: nil)
        openSettings(app)

        let redeem = app.descendants(matching: .any).matching(identifier: "settings.about.redeem").firstMatch
        XCTAssertFalse(redeem.exists, "About still has an invite-code row")
    }

    // MARK: - Register

    /// Creating an account from the account screen signs in and stores the
    /// profile in the Keychain, which is what a relaunch proves.
    func testRegisterCreatesAccount() {
        let app = launch(session: nil)
        openAccount(app)

        tapCreateAccountMode(in: app)
        // Not the fixture account: the mock seeds `shirazu` for the login test,
        // so registering that name would be a 409 and prove nothing about
        // registration.
        let newUsername = "newcomer"
        type(newUsername, into: "account.username.field", in: app)
        type("new-user@example.com", into: "account.email.field", in: app)
        type(Self.fixturePassword, into: "account.password", in: app)

        let submit = app.buttons["account.submit"]
        expect(submit, "the register form has no submit button")
        submit.tap()

        // The account is not created until the code from the email is accepted:
        // the sheet is the whole point of the flow.
        let code = element("verify.code", in: app)
        expect(code, "the verification sheet did not open after asking to register")
        type("123456", into: "verify.code", in: app)

        let username = element("account.username", in: app)
        expect(username, "the account screen did not switch to a profile after registering")
        XCTAssertTrue(username.label.contains(newUsername), "the profile shows the wrong username")

        let plan = element("account.plan", in: app)
        expect(plan, "a new account has no plan row")
        XCTAssertEqual(plan.label, "Free account", "a new account is not free")

        // The Keychain, not just the screen: a relaunch with the mock's session
        // still valid has to come back signed in. No `/reset` between launches --
        // that would delete the session the point is to keep.
        relaunch(app)
        openSettings(app)
        let name = element("settings.account.name", in: app)
        expect(name, "the account row is not there after a relaunch")
        XCTAssertTrue(name.label.contains(newUsername), "the stored account did not survive a relaunch")
    }

    // MARK: - Sign in

    /// The fixture account signs in, and the settings row says who it is.
    func testLoginWithFixtureAccount() {
        let app = launch(session: nil)
        openAccount(app)

        type(Self.fixtureUsername, into: "account.identifier", in: app)
        type(Self.fixturePassword, into: "account.password", in: app)
        let submit = app.buttons["account.submit"]
        expect(submit, "the sign-in form has no submit button")
        submit.tap()

        let username = element("account.username", in: app)
        expect(username, "signing in did not show a profile")
        XCTAssertTrue(username.label.contains(Self.fixtureUsername), "the profile shows the wrong username")
    }

    /// A wrong password stays on the form, with a sentence rather than a dead
    /// button.
    func testWrongPasswordShowsAnError() {
        let app = launch(session: nil)
        openAccount(app)

        type(Self.fixtureUsername, into: "account.identifier", in: app)
        type("definitely-not-the-password", into: "account.password", in: app)
        app.buttons["account.submit"].tap()

        let error = element("account.error", in: app)
        expect(error, "a refused sign-in left no message on screen")
        XCTAssertTrue(error.label.lowercased().contains("sign") || error.label.lowercased().contains("wrong"),
                      "the error does not explain the failure: \(error.label)")
    }

    // MARK: - Invite

    /// Redeeming a code makes the account paid, and the plan row says so.
    func testRedeemInviteMakesAccountPaid() {
        let app = launch(session: nil)
        signIn(app)

        let redeem = app.descendants(matching: .any).matching(identifier: "account.redeem").firstMatch
        XCTAssertTrue(revealInSettings(redeem, in: app), "the account screen has no invite-code row")
        redeem.tap()

        let field = element("account.redeem.field", in: app)
        expect(field, "the invite screen has no field")
        field.tap()
        field.typeText(Self.inviteCode)
        app.buttons["account.redeem.submit"].tap()

        let result = element("account.redeem.result", in: app)
        expect(result, "redeeming the invite produced no result")
        XCTAssertTrue(result.label.contains("Paid until") || result.label.contains("accepted"),
                      "the invite result does not mention paid time: \(result.label)")

        // Back to the profile: the plan row has to have changed, not just the
        // invite screen.
        let back = app.buttons["BackButton"]
        expect(back, "the invite screen has no back button")
        back.tap()
        // Back on the account screen, put the list at the top: the profile and
        // its plan row are above the invite row that was just visited.
        app.swipeDown()
        let plan = element("account.plan", in: app)
        XCTAssertTrue(revealInSettings(plan, in: app), "the account screen has no plan row after redeeming")
        XCTAssertEqual(plan.label, "Paid account", "redeeming an invite did not make the account paid")
    }

    // MARK: - Subscription

    /// The subscription CTA shows the App Store price and completes the purchase
    /// flow with the mock store.
    ///
    /// The real StoreKit path shows Apple's payment sheet; the mock store returns
    /// a verified transaction, the app carries it to `/appstore/transaction`, and
    /// the plan flips. Every step except the sheet itself is the production one.
    func testSubscriptionCTAUsesStoreKitAndMakesAccountPaid() {
        let app = launch(session: nil, mockSubscription: true)
        signIn(app)

        let price = element("account.subscription.price", in: app)
        XCTAssertTrue(revealInSettings(price, in: app), "the subscription section has no price")
        XCTAssertTrue(price.label.contains("¥6.00"), "the price is not the product's own: \(price.label)")

        let cta = app.buttons["account.subscription.cta"]
        XCTAssertTrue(revealInSettings(cta, in: app), "the subscription section has no subscribe button")
        cta.tap()

        let plan = element("account.plan", in: app)
        XCTAssertTrue(revealInSettings(plan, in: app), "the account screen has no plan row after subscribing")
        let paid = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "Paid account"),
            object: plan,
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [paid], timeout: Self.patience),
            .completed,
            "the subscription purchase did not make the plan paid (label: \(plan.label))",
        )
    }

    // MARK: - Attachments

    /// A signed-out account sees the two attachment buttons, locked, and tapping
    /// one explains itself instead of doing nothing.
    func testAttachmentsAreLockedForSignedOutAccounts() {
        let app = launch(session: "first")
        openCommands(app)

        expect(app.buttons["composer.attach.photo"], "there is no 添加照片 button")
        expect(app.buttons["composer.attach.file"], "there is no 添加文件 button")
        expect(element("composer.attach.locked", in: app), "the attachment buttons do not say why they are locked")

        app.buttons["composer.attach.photo"].tap()
        // The locked button opens the account screen rather than swallowing the
        // tap: the refusal has to have a way forward.
        expect(element("account.mode", in: app), "a locked attachment button did not open the account screen")
    }

    /// A paid account gets the same two buttons without the lock.
    func testAttachmentsUnlockForPaidAccounts() {
        let app = launch(session: "first")
        signIn(app)
        redeemInvite(app)
        // redeemInvite already popped back to the account screen. Its Done
        // button closes the settings sheet; the root Done is not on this pushed
        // screen, and tapping the trailing toolbar first would close the sheet
        // before closeSettings could find it.
        closeSettings(app)
        openCommands(app)

        expect(app.buttons["composer.attach.photo"], "there is no 添加照片 button")
        expect(app.buttons["composer.attach.file"], "there is no 添加文件 button")
        XCTAssertFalse(
            element("composer.attach.locked", in: app).exists,
            "a paid account still sees the paid-accounts-only lock",
        )
    }

    // MARK: - Helpers

    /// Launch the app, paired with the mock, signed out.
    ///
    /// - Parameters:
    ///   - session: a session to open on the way in, or `nil` for the list.
    ///   - mockSubscription: whether to select the mock StoreKit store.
    /// - Returns: the running app.
    private func launch(session: String?, mockSubscription: Bool = false) -> XCUIApplication {
        // `setUp` has already reset the fixture for this test.
        let app = XCUIApplication()
        var arguments: [String] = [
            "-mizarPairURI", Self.mockPairingURI,
            "-mizarFreshStart",
            "-mizarSkipPermissionPrompts", "-mizarSkipLoginGate", "-mizarSkipOnboarding", "-mizarCreditsFixture",
            // The fixture answers on a direct address; the transport switches
            // default to off, and without this the app lands on "The transport
            // switches are off" instead of a conversation.
            "-mizarDirectConnection", "-mizarLocalNetworkRoute", "-mizarSkipSplash",
            "-mizarAccountURL", Self.mockAccountURL,
            "-mizarAccountFreshStart",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        if let session { arguments += ["-mizarSelectSession", session] }
        if mockSubscription { arguments += ["-mizarMockSubscription", "-mizarMockSubscriptionPrice", "¥6.00"] }
        app.launchArguments = arguments
        app.launch()
        dismissSystemAlertIfPresent(app)
        dismissNamingIfPresented(app)
        return app
    }

    /// Relaunch the same installed app without signing out.
    ///
    /// The launch arguments are kept except for `-mizarAccountFreshStart`, which
    /// exists precisely to make every *test* start signed out and would defeat a
    /// test about the stored session surviving a process.
    ///
    /// - Parameter app: the running app.
    private func relaunch(_ app: XCUIApplication) {
        app.terminate()
        app.launchArguments.removeAll { $0 == "-mizarAccountFreshStart" }
        app.launch()
        dismissSystemAlertIfPresent(app)
        dismissNamingIfPresented(app)
    }

    /// Sign in with the fixture account, from wherever the app currently is.
    ///
    /// - Parameter app: the running app.
    private func signIn(_ app: XCUIApplication) {
        openAccount(app)
        type(Self.fixtureUsername, into: "account.identifier", in: app)
        type(Self.fixturePassword, into: "account.password", in: app)
        let submit = app.buttons["account.submit"]
        expect(submit, "the sign-in form has no submit button")
        submit.tap()
        expect(element("account.username", in: app), "signing in did not show a profile")
    }

    /// Redeem the invite code from the account screen, and check it paid.
    /// - Parameter app: the running app, already signed in on the account screen.
    private func redeemInvite(_ app: XCUIApplication) {
        let redeem = app.descendants(matching: .any).matching(identifier: "account.redeem").firstMatch
        XCTAssertTrue(revealInSettings(redeem, in: app), "the account screen has no invite-code row")
        redeem.tap()
        let field = element("account.redeem.field", in: app)
        expect(field, "the invite screen has no field")
        field.tap()
        field.typeText(Self.inviteCode)
        app.buttons["account.redeem.submit"].tap()
        expect(element("account.redeem.result", in: app), "redeeming the invite produced no result")
        let back = app.buttons["BackButton"]
        expect(back, "the invite screen has no back button")
        back.tap()
        // Back on the account screen, put the list at the top: the profile and
        // its plan row are above the invite row that was just visited.
        app.swipeDown()
        let plan = element("account.plan", in: app)
        XCTAssertTrue(revealInSettings(plan, in: app), "the account screen has no plan row after redeeming")
        XCTAssertEqual(plan.label, "Paid account", "the invite did not make the account paid")
    }

    /// Switch the signed-out form to "Create account".
    /// - Parameter app: the running app.
    private func tapCreateAccountMode(in app: XCUIApplication) {
        let segment = app.segmentedControls.buttons["Create account"]
        if segment.waitForExistence(timeout: 5) {
            segment.tap()
            return
        }
        let button = app.buttons["Create account"].firstMatch
        expect(button, "the account screen cannot switch to the register form")
        button.tap()
    }

    /// Open the sidebar, if it is not out already.
    /// - Parameter app: the running app.
    private func openSidebar(_ app: XCUIApplication) {
        let marker = app.buttons["sessions.new"]
        if marker.exists, marker.isHittable { return }
        let toggle = app.buttons["shell.sidebarToggle"]
        if !toggle.waitForExistence(timeout: Self.patience) {
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "no-sidebar"
            shot.lifetime = .keepAlways
            add(shot)
            dismissSystemAlertIfPresent(app)
            if !toggle.waitForExistence(timeout: Self.patience) {
                XCTFail("there is no way to open the sidebar")
                return
            }
        }
        toggle.tap()
        let shown = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true"),
            object: marker,
        )
        XCTAssertEqual(XCTWaiter().wait(for: [shown], timeout: Self.patience), .completed, "the sidebar did not open")
    }

    /// Open the settings sheet.
    /// - Parameter app: the running app.
    private func openSettings(_ app: XCUIApplication) {
        openSidebar(app)
        let gear = app.buttons["sidebar.settings"]
        expect(gear, "there is no way to the settings")
        gear.tap()
        expect(element("settings.account", in: app), "the settings screen has no account row")
    }

    /// Close the settings sheet.
    /// - Parameter app: the running app.
    private func closeSettings(_ app: XCUIApplication) {
        let done = app.buttons["settings.done"]
        expect(done, "the settings cannot be closed")
        done.tap()
    }

    /// Open the account screen from settings.
    /// - Parameter app: the running app.
    private func openAccount(_ app: XCUIApplication) {
        openSettings(app)
        let row = element("settings.account", in: app)
        expect(row, "the settings screen has no account row")
        row.tap()
        expect(element("account.mode", in: app), "the account screen has no sign-in form")
    }

    /// Open the composer's command popover, where the attachment buttons live.
    /// - Parameter app: the running app.
    private func openCommands(_ app: XCUIApplication) {
        // Settings are opened from the sidebar, and closing the sheet returns to
        // the sidebar rather than to the conversation. Put it away first, or
        // the composer sits underneath an open drawer and every tap misses.
        let dismissSidebar = app.buttons["shell.dismissSidebar"]
        if dismissSidebar.exists, dismissSidebar.isHittable {
            dismissSidebar.tap()
            Thread.sleep(forTimeInterval: 0.5)
        }
        let commands = app.buttons["composer.commands"]
        expect(commands, "the composer has no command button")
        // The sheet can still be animating away after Done; tapping a button
        // that is present but not yet hittable loses the tap and the popover
        // never opens. Wait for it, then retry once if the popover still missed.
        let hittable = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true"),
            object: commands,
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [hittable], timeout: Self.patience),
            .completed,
            "the command button never became tappable",
        )
        for _ in 0..<2 {
            commands.tap()
            if app.buttons["command.goal"].waitForExistence(timeout: 5) { return }
        }
        XCTFail("the command popover did not open")
    }

    /// Tap away a system permission alert, if one is up.
    ///
    /// The notification prompt can outlive the process that asked for it: a
    /// launch that is interrupted leaves the dialog on screen for the next one,
    /// where it covers the sidebar and eats every tap under it.
    ///
    /// - Parameter app: the launched app, unused beyond keeping the signature
    ///   parallel with the other launch helpers.
    private func dismissSystemAlertIfPresent(_ app: XCUIApplication) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        // The dialog can arrive a beat after the app does: it is raised by the
        // app's own first request, not by the launch itself.
        for _ in 0..<3 {
            for label in ["Don’t Allow", "Don't Allow", "Allow"] {
                let button = springboard.buttons[label]
                if button.waitForExistence(timeout: 1), button.isHittable {
                    button.tap()
                    return
                }
            }
        }
        _ = app
    }

    /// Find an element by accessibility identifier, whatever its type.
    ///
    /// - Parameters:
    ///   - identifier: the identifier.
    ///   - app: the running app.
    /// - Returns: the first matching descendant.
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Wait for an element to exist.
    /// - Parameters:
    ///   - element: the element.
    ///   - message: what to say when it never appears.
    private func expect(_ element: XCUIElement, _ message: String) {
        XCTAssertTrue(
            element.waitForExistence(timeout: Self.patience),
            "\(message) (waited \(Self.patience)s)",
        )
    }

    /// Type into a field found by identifier.
    ///
    /// - Parameters:
    ///   - text: what to type.
    ///   - identifier: the field's identifier.
    ///   - app: the running app.
    private func type(_ text: String, into identifier: String, in app: XCUIApplication) {
        let field = app.textFields[identifier].exists
            ? app.textFields[identifier]
            : app.secureTextFields[identifier]
        expect(field, "there is no field \(identifier)")
        field.tap()
        field.typeText(text)
    }

    /// Scroll the settings window until a row has been built.
    ///
    /// A SwiftUI `List` is lazy: a row below the fold is not in the accessibility
    /// tree at all, and `waitForExistence` cannot see what the app has not built.
    ///
    /// - Parameters:
    ///   - element: the row to look for.
    ///   - app: the running app.
    ///   - attempts: how many windows' worth to travel.
    /// - Returns: whether it turned up.
    @discardableResult
    private func revealInSettings(_ element: XCUIElement, in app: XCUIApplication, attempts: Int = 8) -> Bool {
        if element.waitForExistence(timeout: 3) { return true }
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.66))
        let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.46))
        for _ in 0..<attempts {
            from.press(forDuration: 0.05, thenDragTo: to)
            Thread.sleep(forTimeInterval: 0.45)
            if element.exists, element.isHittable { return true }
        }
        return element.exists
    }

    /// Skip the naming prompt, which pairing offers once.
    /// - Parameter app: the launched app.
    private func dismissNamingIfPresented(_ app: XCUIApplication) {
        for _ in 0..<2 {
            let skip = app.buttons["rename.skip"]
            guard skip.waitForExistence(timeout: Self.namingPatience) else { return }
            guard skip.isHittable else {
                Thread.sleep(forTimeInterval: 0.4)
                continue
            }
            skip.tap()
            if !skip.waitForExistence(timeout: 2) { return }
            Thread.sleep(forTimeInterval: 0.4)
        }
    }

    /// Put the mock host's fixtures back between tests.
    private static func resetMockHost() {
        guard let url = URL(string: "http://127.0.0.1:19395/reset") else { return }
        let done = DispatchSemaphore(value: 0)
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        URLSession.shared.dataTask(with: request) { _, _, _ in done.signal() }.resume()
        // Bounded: a mock host that is not running is a suite about to fail on
        // its own terms, not one to hang on here.
        _ = done.wait(timeout: .now() + 6)
    }
}
