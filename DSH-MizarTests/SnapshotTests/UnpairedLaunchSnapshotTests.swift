//
//  UnpairedLaunchSnapshotTests.swift
//  DSH-MizarTests
//
//  The screen a signed-in phone with no computer lands on: the navy first-run
//  screen with the searching mark and the account's computers. Manual QR/code
//  pairing is no longer an entrance; the scanner identifier is deliberately
//  gone from the product.
//
//  The golden pins this state; the contract pins the account-only title and
//  the session list's new-session control. A launch that reached neither screen
//  can only come back by failing this test or the contract.
//
//  `MizarStar`'s loop runs on a repeating keyframe animator, which no
//  transaction can stop, and `accessibilityReduceMotion` is a get-only
//  environment key the harness cannot set. The app view therefore takes its
//  mark as an injectable subview (`UnpairedView(mark:)`; the shipping
//  `UnpairedView()` keeps the turning one), and this reference pins the pose
//  the loop's reduce-motion branch rests on: the star still, in the screen's
//  own white ink, at the same size.
//
//  The screen's copy resolves through the app bundle in the simulator's own
//  language, so this reference is pinned by recording on the canonical
//  English-locale simulator (`Mizar Runs`, `AppleLanguages = en-US`), per
//  docs/snapshots.md.
//

import SwiftUI
import Testing
@testable import DSH_Mizar

@MainActor
struct UnpairedLaunchSnapshotTests {
    @Test
    func unpairedLaunchScreen() throws {
        // What the UI test asked for: the unpaired screen's way forward, and
        // the paired fallback's new-session control, still declared in source.
        try AppSourceContract.expectIdentifiers(
            ["unpaired.choose"],
            in: "DSH-Mizar/Views/HostListView.swift",
        )
        try AppSourceContract.expectIdentifiers(
            ["sessions.new"],
            in: "DSH-Mizar/Views/Shell/Sidebar.swift",
        )

        let snapshot = try SnapshotHarness.assertSnapshot(
            of: UnpairedView(
                mark: MizarStar(motion: .still, size: 112, palette: .ink(.white)),
            ),
            named: "UnpairedLaunch-unpaired",
            size: CGSize(width: 390, height: 844),
        )
        #expect(snapshot.pixelWidth == 780)
        #expect(snapshot.pixelHeight == 1688)
    }
}
