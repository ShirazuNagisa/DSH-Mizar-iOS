//
//  SettingsDirectoryTests.swift
//  DSH-MizarTests
//
//  The settings screen's shape, pinned in the source that decides it.
//
//  The screen became a directory of shelves: one row per shelf on the front
//  page, and a page behind each row. Three things about that shape cannot be
//  asserted from a render -- `SettingsView` draws its rows in a `List`, which
//  renders nothing under `ImageRenderer` -- and are not worth an app launch
//  each:
//
//    * the order of the shelves, which is the order of `SettingsTopic`'s cases
//      because the front page draws `allCases`;
//    * the plan moving out of the directory and into the account screen's
//      subscription row;
//    * the files shelf keeping a way to throw the stored sessions away and read
//      them again.
//
//  What is pinned here is the app's own source, read through the same checkout
//  path the compiler used (`AppSourceContract`), so deleting one of these fails
//  the cheap suite rather than waiting for somebody to notice the row is gone.
//

import Foundation
import Testing

struct SettingsDirectoryTests {
    /// The order somebody needs the shelves in, top to bottom, as declared.
    ///
    /// One fragment rather than eight: `expectFragments` checks presence, and
    /// eight separate lines would still be `some` order. The block is the
    /// declaration, so a reordering removes the fragment and fails the test --
    /// which is what "the shelves are in this order" means.
    @Test("the shelves are declared in the order the directory shows them")
    func shelvesAreInOrder() throws {
        try AppSourceContract.expectFragments(
            [
                """
                    case notifications
                    case sending
                    case transfer
                    case localAgent
                    case files
                    case community
                    case logs
                    case about
                """,
            ],
            in: "DSH-Mizar/Views/Settings/SettingsTopic.swift",
            describing: "the shelf order",
        )
    }

    /// The plan is a row on the account screen now, and says 详情.
    ///
    /// It used to be its own section of the settings screen with a sheet behind
    /// it. Both halves are pinned: the account screen still opens the detail,
    /// and the directory does not present a plan of its own any more.
    @Test("the plan moved to the account screen's subscription row")
    func planIsOnTheAccountScreen() throws {
        try AppSourceContract.expectFragments(
            [
                "MizarPaidDetailView()",
                #"Text("Details")"#,
            ],
            in: "DSH-Mizar/Views/Account/AccountScreen.swift",
            describing: "the plan's way in",
        )

        let directory = try AppSourceContract.text(at: "DSH-Mizar/Views/Settings/SettingsView.swift")
        #expect(
            !directory.contains("showingPlanDetail"),
            "the settings directory still presents the plan detail itself",
        )
        #expect(
            !directory.contains("settings.plan"),
            "the settings directory still carries the plan section",
        )
    }

    /// The files shelf can empty both stores and read the sessions again.
    ///
    /// The button is pinned where it lives and the model call behind it is
    /// pinned in the model: a row that exists but calls nothing is exactly the
    /// kind of setting this screen refuses to have.
    @Test("the files shelf can reload everything it kept about the sessions")
    func filesShelfCanReloadTheSessions() throws {
        try AppSourceContract.expectIdentifiers(
            ["settings.sessions.reload"],
            in: "DSH-Mizar/Views/Settings/FilesSettingsView.swift",
        )
        try AppSourceContract.expectFragments(
            [
                "model.clearSessionDataAndReload()",
                #"String(localized: "%lld sessions loaded")"#,
            ],
            in: "DSH-Mizar/Views/Settings/FilesSettingsView.swift",
            describing: "what the reload reports",
        )
        try AppSourceContract.expectFragments(
            [
                "func clearSessionDataAndReload() async -> MetadataReload",
                "await indexStore.clear()",
            ],
            in: "DSH-Mizar/App/AppModel.swift",
            describing: "the reload itself",
        )
    }
}
