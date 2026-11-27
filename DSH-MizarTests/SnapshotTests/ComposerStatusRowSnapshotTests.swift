//
//  ComposerStatusRowSnapshotTests.swift
//  DSH-MizarTests
//
//  The composer's status row when its three capsules do not fit.
//
//  The row used to share width between its items and truncate the older ones.
//  It now scrolls sideways instead, with its edges fading where more is hidden;
//  a 300 pt container is narrower than the three items at their natural width,
//  so the reference captures the overflow state rather than the centred one.
//
//  The row is rendered with `scrolls: false`: `ImageRenderer` cannot draw a
//  `ScrollView` (the reference came out an empty white rectangle), so the same
//  capsules are drawn without the UIKit container -- the stopgap
//  `CommandSkillPaletteView.scrolls` already documents. What the reference
//  pins is the part that changed: three capsules at their natural width, none
//  of them given an ellipsis to fit.
//

import SwiftUI
import Testing
import MizarKit
@testable import DSH_Mizar

@MainActor
struct ComposerStatusRowSnapshotTests {
    @Test
    func statusRowOverflows() throws {
        let row = ComposerStatusRow(
            items: [
                .git(WorkspaceGitStatus(files: 178, additions: 8406, deletions: 2773)),
                .paletteHint,
                .receipt(ComposerReceipt(text: String(localized: "Answer sent"), allowed: true)),
            ],
            onOpenPalette: {},
            scrolls: false,
        )

        let snapshot = try SnapshotHarness.assertSnapshot(
            of: row,
            named: "ComposerStatusRow-overflow",
            size: CGSize(width: 300, height: 50),
        )
        #expect(snapshot.pixelWidth == 600)
        #expect(snapshot.pixelHeight == 100)
    }
}
