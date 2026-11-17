//
//  AttachmentGateSnapshotTests.swift
//  DSH-MizarTests
//
//  The composer's attachment controls in both gate states: the two buttons
//  open for a paid account, and the same two buttons with the lock footer for
//  a signed-out one. These are the states
//  `AccountUITests.testAttachmentsUnlockForPaidAccounts` and
//  `testAttachmentsAreLockedForSignedOutAccounts` each launch the app and walk
//  a sign-in + redeem chain to reach.
//
//  `CommandList` is the view the buttons actually live in -- `ComposerBar`
//  builds it for the composer's "+" control -- and it takes the gate as a
//  plain `Bool`, so both states render from fixtures. The identifier contract
//  pins the three `composer.attach.*` identifiers in the app source. The gate
//  *rule* itself -- account plan to unlock -- is `AppModel
//  .advancedFeaturesUnlocked` in the app target, so no unit test covers it
//  here; the UI test keeps owning that half until the rule moves where a unit
//  test can reach it (docs/phase2-triage.md, the :247 row).
//
//  The titles resolve through the app bundle in the simulator's own language,
//  so the references are pinned by recording on the canonical English-locale
//  simulator (`Mizar Runs`, `AppleLanguages = en-US`), per docs/snapshots.md.
//

import SwiftUI
import Testing
@testable import DSH_Mizar

@MainActor
struct AttachmentGateSnapshotTests {
    enum State: String, CaseIterable, Sendable {
        /// A paid account: both buttons open, no lock footer.
        case unlocked
        /// Signed out: the same buttons carry a lock, and a footer says why.
        case locked
    }

    @Test(arguments: State.allCases)
    func attachmentGate(_ state: State) throws {
        // The three identifiers both UI tests query, still applied in source.
        // photo and file go through the `attachmentButton` helper's `identifier`
        // parameter; the lock footer's is applied directly.
        try AppSourceContract.expectFragments(
            [
                "identifier: \"composer.attach.photo\"",
                "identifier: \"composer.attach.file\"",
                ".accessibilityIdentifier(\"composer.attach.locked\")",
            ],
            in: "DSH-Mizar/Views/ComposerBar.swift",
            describing: "accessibility identifier",
        )

        let snapshot = try SnapshotHarness.assertSnapshot(
            of: CommandList(
                canAttach: state == .unlocked,
                onAttachment: { _ in },
                onBrowse: {},
            ),
            named: "AttachmentGate-\(state.rawValue)",
            size: CGSize(width: 300, height: 380),
        )
        #expect(snapshot.pixelWidth == 600)
        #expect(snapshot.pixelHeight == 760)
    }
}
