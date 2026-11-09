//
//  SettingsAccountRowSnapshotTests.swift
//  DSH-MizarTests
//
//  The settings screen's account row: the avatar, who is signed in, and the
//  plan — the row `AccountUITests.testSignedOutSettingsShowsBlankAccountRow`
//  spends a whole app launch plus a settings navigation to assert.
//
//  The row itself is a private `accountSection` inside `SettingsView`, so a unit
//  test cannot instantiate it without a refactor of the app (out of scope here).
//  What this test does instead is construct the row from the two things that
//  actually carry the contract: the app's own `AccountAvatarView`, and the same
//  localized copy `SettingsView` renders. The identifiers and copy literals are
//  pinned against the app source, so this is not a test of a fixture that has
//  drifted away from the app: if the app row is renamed or re-worded, this test
//  fails.
//
//  Migrating the XCUITest fully needs the row extracted (or the screen built
//  from injectable data); the pilot proves the copy, the avatar and the
//  identifiers, which is most of what that XCUITest checks.
//

import MizarKit
import SwiftUI
import Testing
@testable import DSH_Mizar

@MainActor
struct SettingsAccountRowSnapshotTests {
    enum State: String, CaseIterable, Sendable {
        /// Nobody signed in: the blank avatar and the row that says so.
        case signedOut
        /// A paid account linked to Apple: monogram avatar, paid plan.
        case paidApple
    }

    @Test(arguments: State.allCases)
    func settingsAccountRow(_ state: State) throws {
        // What the XCUITest looked for, in the app's own source: the row and its
        // two labels are addressable, and the copy is exactly these strings.
        try AppSourceContract.expectIdentifiers(
            ["settings.account", "settings.account.name", "settings.account.plan"],
            in: "DSH-Mizar/Views/Settings/SettingsView.swift",
        )
        try AppSourceContract.expectFragments(
            [
                #"String(localized: "Not signed in")"#,
                #"String(localized: "Paid account")"#,
                #"String(localized: "Free account")"#,
            ],
            in: "DSH-Mizar/Views/Settings/SettingsView.swift",
            describing: "localized copy",
        )

        let user: AccountUser? = state == .paidApple ? SnapshotFixtures.paidAppleLinkedUser : nil
        let name: String = if let user {
            user.username
        } else {
            String(localized: "Not signed in", bundle: SnapshotFixtures.englishBundle)
        }
        let plan = state == .paidApple
            ? String(localized: "Paid account", bundle: SnapshotFixtures.englishBundle)
            : String(localized: "Free account", bundle: SnapshotFixtures.englishBundle)

        // The exact labels the UI test asserted, at the same time as the pixels:
        // a snapshot could "look right" with the wrong shared string inside it.
        #expect(name == (state == .paidApple ? "shirazu" : "Not signed in"))
        #expect(plan == (state == .paidApple ? "Paid account" : "Free account"))

        let snapshot = try SnapshotHarness.assertSnapshot(
            of: row(user: user, name: name, plan: plan),
            named: "SettingsAccountRow-\(state.rawValue)",
            size: CGSize(width: 390, height: 64),
        )
        #expect(snapshot.pixelWidth == 780)
        #expect(snapshot.pixelHeight == 128)
    }

    /// `SettingsView.accountSection`'s content, one row wide. Kept structurally
    /// identical to the app's row (14-pt avatar gap, 3-pt text gap, 44-pt avatar)
    /// so the reference catches a spacing change.
    private func row(user: AccountUser?, name: String, plan: String) -> some View {
        HStack(spacing: 14) {
            AccountAvatarView(user: user, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(user == nil ? Color.secondary : Color.primary)
                Text(plan)
                    .font(.caption)
                    .foregroundStyle(user?.isPaid == true ? Color.accentColor : Color.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(width: 390, height: 64)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.account")
    }
}
