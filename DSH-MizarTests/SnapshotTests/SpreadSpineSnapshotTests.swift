//
//  SpreadSpineSnapshotTests.swift
//  DSH-MizarTests
//
//  The valley, drawn at the size the unfolded Duo gives it: a page's height
//  (669 pt) and the hinge's width (28 pt), with the conversation half read.
//
//  This is the one piece of the fold adaptation a snapshot can hold: it is a
//  leaf view with no environment of its own, and the sizes are the measured
//  ones, so a regression in the hairline, the fill or the handle shows up as
//  bytes rather than as an opinion.
//

import SwiftUI
import Testing
@testable import DSH_Mizar

@MainActor
struct SpreadSpineSnapshotTests {
    /// The unfolded Duo's inner display, in points, and the hinge's own strip.
    private static let page = CGSize(width: 28, height: 669)

    @Test
    func spineWithTheSecondPageOut() throws {
        let snapshot = try SnapshotHarness.assertSnapshot(
            of: SpreadSpine(available: true, open: true, progress: 0.5, toggle: {}),
            named: "SpreadSpine-open",
            size: Self.page,
        )
        // 28 x 669 at 2x.
        #expect(snapshot.pixelWidth == 56)
        #expect(snapshot.pixelHeight == 1338)
    }

    @Test
    func spineWithTheSecondPageFoldedAway() throws {
        _ = try SnapshotHarness.assertSnapshot(
            of: SpreadSpine(available: true, open: false, progress: 0.25, toggle: {}),
            named: "SpreadSpine-closed",
            size: Self.page,
        )
    }

    @Test("The home screen's valley is empty: nothing to invite, nothing to measure")
    func spineWithoutAConversation() throws {
        _ = try SnapshotHarness.assertSnapshot(
            of: SpreadSpine(available: false, open: false, progress: 0, toggle: {}),
            named: "SpreadSpine-unavailable",
            size: Self.page,
        )
    }
}
