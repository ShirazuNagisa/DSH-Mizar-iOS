//
//  LocalAgentUITests.swift
//  DSH-MizarUITests
//
//  The on-device agent's two doors: the first row of the agent list, and the
//  model configuration under Settings.
//
//  What is worth a launch here is the wiring that a unit test cannot see -- the
//  row exists, is reachable, carries both capsules, and the screen behind it is
//  the model list rather than an empty shell. The kernel itself is covered on
//  the host by `LocalKernelTests`; a UI test that booted JavaScriptCore would be
//  re-proving that suite at twenty seconds a test.
//

import XCTest

final class LocalAgentUITests: AppFlowTestBase {
    override class var mockPort: Int { MockPorts.port(for: "LocalAgentUITests") }

    /// The list is about agents now, and the first of them needs no computer.
    func testAAgentListLeadsWithTheOnDeviceAgent() {
        let app = launch(session: nil)

        openSidebar(app)
        let opener = app.buttons["sessions.hosts"]
        expect(opener, "the session list has no way to the agent list")
        opener.tap()

        let row = app.buttons["host.row.local"]
        XCTAssertTrue(
            row.waitForExistence(timeout: Self.patience),
            "the agent list has no on-device agent row",
        )
        // The row's label is the concatenation of its texts, which is the whole
        // reason both capsules are asserted from it: a badge that was never
        // built is a badge this test can see missing.
        XCTAssertTrue(
            row.label.contains("On-Device Agent"),
            "the row is not named as the on-device agent: \(row.label)",
        )
        XCTAssertTrue(
            row.label.contains("On-device"),
            "the row has no On-device capsule: \(row.label)",
        )
        XCTAssertTrue(
            row.label.contains("No model configured"),
            "a fresh install should say no model is configured: \(row.label)",
        )
        attach(app, named: "agent-list")

        // Tapping it starts the kernel and lands in local mode. The row is the
        // one thing that proves the transport seam is wired to a real kernel.
        row.tap()
        XCTAssertTrue(
            app.buttons["sessions.hosts"].waitForExistence(timeout: Self.patience),
            "the on-device agent never produced a session list",
        )
    }

    /// Settings has a model configuration, and it is a real list.
    func testBSettingsOpenTheModelConfiguration() {
        let app = launch(session: nil)

        openSettings(app)
        openSettingsTopic("localAgent", in: app)
        let row = app.buttons["settings.localAgent.models"]
        XCTAssertTrue(
            revealInSettings(row, in: app),
            "the settings have no model configuration row",
        )
        row.tap()

        let add = app.buttons["localAgent.addProvider"]
        XCTAssertTrue(
            add.waitForExistence(timeout: Self.patience),
            "the provider list never loaded from the kernel",
        )
        attach(app, named: "model-configuration")
        add.tap()

        XCTAssertTrue(
            app.textFields["localAgent.form.address"].waitForExistence(timeout: 10),
            "the new-provider form has no address field",
        )
        XCTAssertTrue(
            app.secureTextFields["localAgent.form.key"].exists,
            "the new-provider form has no key field",
        )
        XCTAssertTrue(
            app.buttons["localAgent.form.test"].exists,
            "the new-provider form has no way to test the connection",
        )
        attach(app, named: "provider-form")
    }

    /// An address with nothing behind it is a sentence, not a spinner.
    func testCAnUnreachableProviderSaysSo() {
        let app = launch(session: nil)

        openSettings(app)
        openSettingsTopic("localAgent", in: app)
        let row = app.buttons["settings.localAgent.models"]
        XCTAssertTrue(revealInSettings(row, in: app), "no model configuration row")
        row.tap()
        let add = app.buttons["localAgent.addProvider"]
        XCTAssertTrue(add.waitForExistence(timeout: Self.patience), "the provider list never loaded")
        add.tap()

        let address = app.textFields["localAgent.form.address"]
        XCTAssertTrue(address.waitForExistence(timeout: 10), "the form never opened")
        address.tap()
        // Port 9 is the discard port: nothing listens, so this is a refusal
        // rather than a timeout, and the test does not wait for one.
        address.typeText("http://127.0.0.1:9")
        let key = app.secureTextFields["localAgent.form.key"]
        key.tap()
        key.typeText("sk-not-a-real-key")
        app.buttons["localAgent.form.test"].tap()

        XCTAssertTrue(
            app.staticTexts["Could not reach this address."].waitForExistence(timeout: Self.patience),
            "an unreachable provider did not say so",
        )
        attach(app, named: "provider-unreachable")
    }

    /// A workspace is a folder with the operator's name on it.
    ///
    /// Two things are asserted, and both were wrong before this test existed:
    /// the row shows the workspace's *name* rather than the container path it
    /// lives at, and creating one puts a folder under the agent's root that
    /// appears without a manual refresh.
    func testDTheAgentWorkspacesAreFolders() {
        let app = launch(session: nil)

        openSidebar(app)
        let opener = app.buttons["sessions.hosts"]
        expect(opener, "the session list has no way to the agent list")
        opener.tap()
        let local = app.buttons["host.row.local"]
        XCTAssertTrue(local.waitForExistence(timeout: Self.patience), "the agent list has no on-device agent")
        local.tap()
        closeHosts(app)

        let rows = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "workspace."),
        )
        let first = rows.firstMatch
        XCTAssertTrue(
            first.waitForExistence(timeout: Self.patience),
            "the on-device agent lists no workspace",
        )
        XCTAssertTrue(
            first.label.contains("Default workspace"),
            "the workspace row shows its path instead of its name: \(first.label)",
        )

        let newWorkspace = app.buttons["sessions.newWorkspace"]
        expect(newWorkspace, "there is no way to create a workspace")
        newWorkspace.tap()
        let field = app.textFields["localWorkspace.name"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the name sheet never opened")
        // A folder in the Files app outlives the app's data between runs, so a
        // fixed name would be "already exists" on the second run of this test.
        let name = "Projects-\(UUID().uuidString.prefix(6))"
        field.tap()
        field.typeText(name)
        app.buttons["localWorkspace.create"].tap()

        let created = app.buttons.matching(
            NSPredicate(format: "identifier ENDSWITH %@", "/\(name)"),
        ).firstMatch
        XCTAssertTrue(
            created.waitForExistence(timeout: Self.patience),
            "the new workspace never appeared in the list",
        )
        attach(app, named: "local-workspaces")
    }

    /// Keep a screenshot with the result bundle, so a failure can be looked at
    /// and a change can be reviewed without re-running the test by hand.
    private func attach(_ app: XCUIApplication, named name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
