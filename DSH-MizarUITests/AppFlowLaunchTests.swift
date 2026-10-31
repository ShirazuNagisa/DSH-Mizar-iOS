//
//  AppFlowLaunchTests.swift
//  DSH-MizarUITests
//
//  Methods moved verbatim from AppFlowTests.swift (launch / pairing / settings).
//

import XCTest

final class AppFlowLaunchTests: AppFlowTestBase {
    /// This class's own mock-host pair, from the MockPorts table.
    override class var mockPort: Int { MockPorts.port(for: String(describing: self)) }
    // MARK: - Sessions

    func testSessionListNamesTheHostAndOffersANewSession() {
        let app = launch(session: nil)
        expect(app.staticTexts["Mock Mac (fixture)"], "the host's name is not shown")
        expect(app.buttons["sessions.new"], "there is no way to start a session")
        expect(app.buttons["sessions.refresh"], "there is no way to refresh")
        // The row is titled by its directory, which is what tells two sessions
        // apart when neither has a title yet.
        expect(app.staticTexts["demo"], "the session row is missing")
    }

    func testAnUnpairedLaunchOffersPairing() throws {
        throw XCTSkip("migrated to snapshot: unpairedLaunch (HostListView golden + Sidebar contract); placeholder until map v2")
        let app = launch(pairing: false, session: nil)
        // A launch without a pairing URI either finds one stored from an earlier
        // launch and connects, or has none and shows the pairing screen. Both are
        // correct; what must not happen is neither.
        // A never-paired phone now says what to do rather than showing an empty
        // list, and offers the scanner directly.
        let unpaired = app.buttons["unpaired.scan"]
        let sessions = app.buttons["sessions.new"]
        let appeared = unpaired.waitForExistence(timeout: Self.patience)
            || sessions.waitForExistence(timeout: Self.patience)
        XCTAssertTrue(appeared, "the app reached neither the pairing screen nor the session list")
    }

    /// The settings: the four sections, each with something in it.
    ///
    /// Opened from the gear at the foot of the sidebar, and asked for as a
    /// settings screen rather than a placeholder. What is asserted is that each
    /// of the four sections has its control -- the switches, the export button
    /// and the source link -- because a screen can be present and empty.
    func testTheSidebarOpensSettings() {
        let app = launch(session: nil)
        openSettings(app)
        // 发送: whether a message sent into a running turn is guidance, or waits
        // for the end of that turn above the field. It sits above 通知.
        XCTAssertTrue(
            revealInSettings(settingControl("settings.send.guidedSend", in: app), in: app),
            "there is no guided-send switch",
        )
        // 通知: the four switches, and the system permission they sit under.
        expect(settingControl("settings.notify.turn-finished", in: app), "there is no 任务完成 switch")
        expect(settingControl("settings.notify.turn-interrupted", in: app), "there is no 任务中断 switch")
        expect(settingControl("settings.notify.question", in: app), "there is no 模型询问 switch")
        expect(settingControl("settings.notify.approval", in: app), "there is no 权限授予 switch")
        expect(
            app.descendants(matching: .any).matching(identifier: "settings.notify.authorization").firstMatch,
            "the system notification permission is not shown",
        )
        // 实时活动. The settings are a small window out of the gear now, not a
        // sheet, and this section starts below its fold -- so it is scrolled to
        // before it is asked for, since a lazy list has not built it yet.
        XCTAssertTrue(
            revealInSettings(settingControl("settings.liveActivity", in: app), in: app),
            "there is no live activity switch",
        )
        // 日志 and 关于 are below the fold too.
        XCTAssertTrue(
            revealInSettings(app.buttons["settings.logs.export"], in: app),
            "there is no log export button",
        )
        XCTAssertTrue(
            revealInSettings(app.descendants(matching: .any)["settings.about.version"], in: app),
            "the about section is missing",
        )
        // And it can be left, so a sheet that opened over a screen it cannot
        // close would not pass.
        let done = app.buttons["settings.done"]
        expect(done, "the settings cannot be closed")
        done.tap()
        expect(app.buttons["sessions.new"], "closing the settings did not go back to the sessions")
    }

    /// A switch is a setting, not a picture of one.
    ///
    /// The value asserted is the one the switch moved to rather than its default,
    /// because the app's defaults outlive a test run -- `xcodebuild test`
    /// reinstalls the app but does not wipe its container, so a suite that
    /// insisted on "on" would fail on the second run and pass on the third.
    /// What matters is that the change survives the process, which is the whole
    /// difference between a switch and a decoration.
    func testANotificationSwitchSurvivesARelaunch() {
        let app = launch(session: nil)
        openSettings(app)
        // The identifier is built from the notification kind's wire name, which
        // is hyphenated -- `settings.notify.turn-finished`, not `turnFinished`.
        let identifier = "settings.notify.turn-finished"
        let control = settingControl(identifier, in: app)
        expect(control, "there is no 任务完成 switch")
        let before = settingState(identifier, in: app)
        XCTAssertNotNil(
            before,
            "the switch reports no state to read: \(control.debugDescription)",
        )
        flip(control, in: app)
        XCTAssertTrue(
            settingChanges(identifier, in: app, from: before),
            "the switch did not move when it was tapped: \(control.debugDescription)",
        )
        let after = settingState(identifier, in: app)

        // The same phone, the same app, a new process. Nothing here is in memory
        // only, or this is where it shows.
        app.terminate()
        let reopened = launch(session: nil, freshStart: false)
        openSettings(reopened)
        expect(settingControl(identifier, in: reopened), "the settings screen did not come back")
        XCTAssertEqual(
            settingState(identifier, in: reopened),
            after,
            "the switch did not survive a relaunch",
        )
        // Put it back, so the next run of this suite starts where this one did.
        flip(settingControl(identifier, in: reopened), in: reopened)
    }

    /// The export button produces a zip and offers it.
    ///
    /// The two things that must not be flaky: the file is made, and something
    /// offers it. The file is asserted first and always; the share sheet is the
    /// system's `UIActivityViewController`, so it is recognised rather than
    /// driven -- picking a destination in it is a test of iOS, not of this app.
    /// The archive itself is checked outside the test, by unzipping it from the
    /// app's container.
    func testTheLogExportMakesAZipAndOffersIt() {
        let app = launch(session: nil)
        openSettings(app)
        let export = app.buttons["settings.logs.export"]
        XCTAssertTrue(revealInSettings(export, in: app), "there is no log export button")
        export.tap()
        // The row that names the file, which is also what tells the operator the
        // export happened after the share sheet has been dismissed.
        let produced = app.descendants(matching: .any).matching(identifier: "settings.logs.lastArchive").firstMatch
        // The file's name as text as well, because a `List` row is a container
        // whose accessibility shape is the system's to decide: if the identifier
        // lands somewhere that is not an element, the name is still on screen.
        let named = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", ".zip")).firstMatch
        XCTAssertTrue(
            produced.waitForExistence(timeout: Self.patience) || named.exists,
            "the export produced no file",
        )
        XCTAssertTrue(
            named.waitForExistence(timeout: 5) || produced.label.contains(".zip"),
            "the export did not name the zip it made",
        )
        // And it is offered: the share sheet comes up on its own, without a
        // second tap. It is asserted and then left alone -- the first version of
        // this test swiped it away, and the swipe never came back from
        // "wait for the app to idle", which killed the test after every
        // assertion in it had already passed. Choosing a destination in that
        // sheet is a test of iOS, not of this app; the archive's contents are
        // checked outside the suite, by unzipping it from the app's container.
        XCTAssertTrue(
            app.otherElements["ActivityListView"].waitForExistence(timeout: Self.patience),
            "the export was made but nothing offered to share it",
        )
    }

    /// 关于: where it comes from, what it is, and who made it.
    func testTheAboutSectionShowsTheVersionAndBothCredits() {
        let app = launch(session: nil)
        openSettings(app)
        let source = app.buttons["settings.about.source"]
        XCTAssertTrue(revealInSettings(source, in: app), "there is no source code button")
        XCTAssertTrue(source.isEnabled, "the source code button cannot be tapped")

        let version = labelled("settings.about.version", in: app, contains: ".")
        XCTAssertTrue(version.waitForExistence(timeout: 5), "the version is not shown")
        // A version, not a specific version: the release is cut elsewhere, and a
        // test that fails on a bump is a test somebody deletes.
        XCTAssertNotNil(
            version.label.range(of: #"[0-9]+\.[0-9]+"#, options: .regularExpression),
            "the version row does not show a version: \(version.label)",
        )

        // 开发者鸣谢: one row per person, fetched from GitHub (the suite runs a
        // fixed list). The text element of each row, not its avatar.
        let shirazu = labelled("settings.credits.row.ShirazuNagisa", in: app, contains: "ShirazuNagisa")
        let arowey = labelled("settings.credits.row.Arowey", in: app, contains: "Arowey")
        XCTAssertTrue(revealInSettings(arowey, in: app), "the credits are missing")
        XCTAssertTrue(shirazu.exists, "the first credit is missing")
        XCTAssertTrue(shirazu.label.contains("ShirazuNagisa"), "the first credit is mislabelled: \(shirazu.label)")
        XCTAssertTrue(arowey.label.contains("Arowey"), "the second credit is mislabelled: \(arowey.label)")
        XCTAssertNotEqual(
            shirazu.frame.origin.y,
            arowey.frame.origin.y,
            "the two credits are on one line, not one per row",
        )
        // The link is asserted and not tapped. Tapping it opens Safari, and every
        // assertion after that would be about Safari.
    }

    /// Chinese-first: the settings screen follows the phone's language.
    func testTheSettingsScreenFollowsTheLanguage() throws {
        throw XCTSkip("migrated to snapshot: settings language (zh/en goldens + identifier contract); placeholder until map v2")
        // The section headers, which are interface copy, in Chinese.
        let chinese = launch(session: nil, language: "zh-Hans")
        openSettings(chinese)
        expect(settingControl("settings.notify.turn-finished", in: chinese), "there is no notifications section")
        expect(chinese.staticTexts["通知"], "通知 is not on the settings screen")
        // The account row moved this section past the first screenful; swipe
        // the settings list itself rather than relying on the generic reveal
        // helper, whose drag starts over a row full of switches.
        for _ in 0..<4 where !chinese.staticTexts["实时活动"].exists {
            chinese.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.68))
                .press(forDuration: 0.05, thenDragTo: chinese.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.40)))
            Thread.sleep(forTimeInterval: 0.5)
        }
        expect(chinese.staticTexts["实时活动"], "实时活动 is not on the settings screen")
        XCTAssertTrue(
            revealInSettings(chinese.staticTexts["开发者鸣谢"], in: chinese),
            "关于 is not on the settings screen",
        )
        expect(chinese.staticTexts["源代码"], "源代码 is not translated")
        // A name is not translated, in either language. The credits are the last
        // rows of a small window, so the row is scrolled to rather than assumed
        // to have been built.
        let firstCredit = labelled("settings.credits.shirazu", in: chinese, contains: "ShirazuNagisa")
        XCTAssertTrue(revealInSettings(firstCredit, in: chinese), "the first credit is missing in Chinese")
        chinese.terminate()

        // The same screen in English, so a catalogue that lost one of the two
        // languages is caught rather than the other one being taken on trust.
        let english = launch(session: nil, language: "en")
        openSettings(english)
        expect(settingControl("settings.notify.turn-finished", in: english), "there is no notifications section")
        expect(english.staticTexts["Notifications"], "the notifications section did not translate")
        XCTAssertTrue(
            revealInSettings(english.staticTexts["Live Activity"].firstMatch, in: english),
            "the live activity section did not translate",
        )
        XCTAssertTrue(
            revealInSettings(english.staticTexts["Credits"], in: english),
            "the about section did not translate",
        )
        expect(english.staticTexts["Source code"], "the source link did not translate")
    }

    /// A first pairing downloads everything, and says how far along it is.
    ///
    /// Without the stalled mock this screen is invisible: a local host answers
    /// in milliseconds, so the whole download lives inside one runloop turn. The
    /// delay is what makes the assertion possible at all, and what it asserts is
    /// the thing that was asked for -- that the operator is shown progress
    /// rather than an empty app.
    func testAFirstPairingShowsAFullScreenDownload() {
        // A long stall, and the reason is the estimate rather than the counter.
        // The estimate exists only between one session finishing and the next --
        // `SyncProgress.remaining` refuses to guess before it has a sample -- so
        // the window this test has to catch is one session's worth of answers,
        // and at 500 ms that window is about a second wide. Measured: it was
        // missed on a loaded machine, in a suite where all 39 other tests passed.
        // 1.5 s makes the window three times wider and costs this one test eight
        // seconds.
        let app = launch(session: nil, slow: 1500, naming: false)
        XCTAssertTrue(
            app.staticTexts["firstload.title"].waitForExistence(timeout: Self.patience),
            "a first pairing downloaded the history with nothing on screen to say so",
        )
        // And it is a download, not a splash: it counts, and it says how much
        // longer. The estimate needs at least one session finished, which is
        // exactly the restraint being asserted -- a number invented before any
        // sample exists is a number that will change.
        XCTAssertTrue(
            app.staticTexts["firstload.counter"].waitForExistence(timeout: Self.patience),
            "the full-screen download showed no progress count",
        )
        XCTAssertTrue(
            app.staticTexts["firstload.eta"].waitForExistence(timeout: Self.patience),
            "the full-screen download showed no estimate",
        )
        // And it gets out of the way when it is done, handing over to the naming
        // prompt rather than sitting under it.
        dismissNamingIfPresented(app)
        XCTAssertTrue(
            app.buttons["sessions.new"].waitForExistence(timeout: Self.patience * 3),
            "the download never finished",
        )
    }

    /// A refresh reports itself in a window, with an estimate.
    ///
    /// The sheet existed and nothing presented it, so tapping refresh was a
    /// spinner in the toolbar and no idea how long the wait was.
    func testRefreshingShowsAProgressWindow() {
        let app = launch(session: nil)
        // The first download has to be finished first: the refresh button is
        // disabled while it runs, and a disabled button that does nothing would
        // fail this test for the wrong reason.
        expect(app.buttons["sessions.new"], "the session list never arrived")
        expect(app.staticTexts["demo"], "the session list is empty")

        // Slowed now, not at launch, and deliberately: the window exists to say
        // how long something is taking, so a host that answers instantly leaves
        // nothing to look at.
        Self.stallMockHost(1200)

        let refresh = app.buttons["sessions.refresh"]
        expect(refresh, "there is no way to refresh")
        refresh.tap()

        XCTAssertTrue(
            app.buttons["sync.done"].waitForExistence(timeout: Self.patience),
            "tapping refresh did not show the progress window",
        )
        // The window is the point: it says how far along, and how much longer.
        XCTAssertTrue(
            app.staticTexts["sync.counter"].waitForExistence(timeout: Self.patience),
            "the progress window showed no count",
        )
        XCTAssertTrue(
            app.staticTexts["sync.eta"].waitForExistence(timeout: Self.patience),
            "the progress window showed no estimate",
        )
        app.buttons["sync.done"].tap()
        Self.stallMockHost(0)
    }

    /// An unreachable computer does not take away what this phone already has.
    ///
    /// The other half of the local storage: reading a conversation is entirely
    /// local once it has been synced, so a failure screen that replaces the list
    /// does not report a problem, it destroys an answer. And the phone is opened
    /// on trains, in lifts, and on the far side of a relay having a bad day.
    func testAnUnreachableMacKeepsTheStoredSessions() {
        // First: a normal launch, so there is something stored to keep.
        let first = launch(session: nil)
        expect(first.staticTexts["demo"], "the session list never synced")
        first.terminate()

        Self.setMockOffline(true)
        defer { Self.setMockOffline(false) }

        // Second: the same pairing, the same stored data, and a computer that has
        // stopped answering.
        let app = launch(session: nil, naming: false, freshStart: false)
        XCTAssertTrue(
            app.staticTexts["demo"].waitForExistence(timeout: Self.patience),
            "an unreachable computer hid the sessions this phone already had",
        )
        // And it says so rather than pretending everything is fine: the link
        // bar marks the segment, in place of the error row that used to spell
        // the failure out. The bar is a status, not a control -- there is no
        // Retry on it, and the recovery is the gesture the list already has.
        let link = app.descendants(matching: .any)["sidebar.link"]
        XCTAssertTrue(
            link.waitForExistence(timeout: Self.patience),
            "the app did not say the computer was unreachable",
        )
        XCTAssertEqual(
            link.label,
            "Could not reach this computer",
            "the link bar did not mark the link as broken",
        )
        XCTAssertFalse(
            app.buttons["Retry"].exists,
            "the list still offers a Retry control; the recovery is the list's own gesture",
        )

        // A refresh while unreachable must not report an all-clear, and it must
        // not open a progress window that has nothing to report: the window fills
        // in, and a window that can only ever fill in is a window that lies. The
        // button says the one thing the operator can act on, where they tapped.
        let refresh = app.buttons["sessions.refresh"]
        expect(refresh, "there is no way to refresh")
        refresh.tap()
        XCTAssertTrue(
            app.staticTexts["refresh.unreachable"].waitForExistence(timeout: Self.patience),
            "tapping refresh against an unreachable computer said nothing",
        )
        XCTAssertFalse(
            app.buttons["sync.done"].waitForExistence(timeout: 2),
            "a refresh with no socket opened a progress window anyway",
        )
        // Anywhere else puts the note away: it is a sentence, not a decision.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.62)).tap()
        XCTAssertTrue(
            app.staticTexts["refresh.unreachable"].waitForNonExistence(timeout: 5),
            "the note stayed up after a tap somewhere else",
        )

        // And when the computer comes back, the list recovers through the gesture it
        // already has. Pull to refresh lands in `refreshSessions`, which opens a
        // socket when there is none -- the recovery the old Retry button did by
        // hand, now on the path the operator already uses.
        Self.setMockOffline(false)
        let pullStart = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.28))
        let pullEnd = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.88))
        pullStart.press(forDuration: 0.1, thenDragTo: pullEnd)
        let recovered = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "Link OK, direct"),
            object: link,
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [recovered], timeout: Self.patience),
            .completed,
            "a read that recovered left the link marked as broken",
        )
    }

}
