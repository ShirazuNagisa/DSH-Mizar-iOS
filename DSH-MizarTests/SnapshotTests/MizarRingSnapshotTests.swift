//
//  MizarRingSnapshotTests.swift
//  DSH-MizarTests
//
//  The mark, in the poses the app actually draws.
//
//  This is the cheapest possible snapshot: pure geometry with no environment
//  dependency, so it is also the harness's own smoke test -- if these references
//  stop matching, the renderer or the runtime moved, not the mark.
//
//  The animation itself cannot be pinned here: `running` is a repeating keyframe
//  animator no render transaction stops, and `accessibilityReduceMotion` is a
//  get-only environment key the harness cannot set. What is pinned is the icon's
//  pose, the two ends of the progress reading (the track at zero, half filled,
//  the whole icon at one), and the pale/dark tile.
//

import SwiftUI
import Testing
@testable import DSH_Mizar

@MainActor
struct MizarRingSnapshotTests {
    /// The poses a screen can hold still.
    enum Pose: String, CaseIterable, Sendable {
        case icon
        case openingEmpty
        case openingHalf
        case inkOnNavy
        case darkRunning

        @ViewBuilder var view: some View {
            switch self {
            case .icon:
                MizarRing(motion: .still, size: 68)
            case .openingEmpty:
                MizarRing(motion: .opening(0), size: 68)
            case .openingHalf:
                MizarRing(motion: .opening(0.5), size: 68)
            case .inkOnNavy:
                MizarRing(motion: .still, size: 68, palette: .ink(.white))
                    .background(Color(red: 19 / 255, green: 31 / 255, blue: 61 / 255))
            case .darkRunning:
                // The same mark, in Dark Mode, with no palette named: the ink
                // follows the appearance, so this must come out white. Pinned
                // on black because a white ring on the harness's white ground
                // would pass by being invisible.
                ZStack {
                    Color.black
                    MizarRing(motion: .still, size: 68)
                }
                .environment(\.colorScheme, .dark)
            }
        }

        var size: CGSize {
            CGSize(width: 68, height: 68)
        }
    }

    @Test(arguments: Pose.allCases)
    func mizarRing(_ pose: Pose) throws {
        let snapshot = try SnapshotHarness.assertSnapshot(
            of: pose.view,
            named: "MizarRing-\(pose.rawValue)",
            size: pose.size,
        )

        // The mark's own box, exactly: a changed aspect ratio must not be
        // absorbed by the tolerance.
        #expect(snapshot.pixelWidth == 136)
        #expect(snapshot.pixelHeight == 136)
        #expect(snapshot.recorded == SnapshotHarness.isRecording)
    }

    /// The app icon's own composition: the ring on its tile.
    @Test
    func mizarIconTile() throws {
        let snapshot = try SnapshotHarness.assertSnapshot(
            of: MizarIconTile(size: 64, motion: .still),
            named: "MizarIconTile",
            size: CGSize(width: 64, height: 64),
        )
        #expect(snapshot.pixelWidth == 128)
        #expect(snapshot.pixelHeight == 128)
    }

    /// The same tile in Dark Mode: the icon's other appearance.
    ///
    /// The asset catalog ships a near-black tile for dark, and this is the
    /// settings page agreeing with it. A tile that stayed pale here is the bug
    /// that made this reference exist.
    @Test
    func mizarIconTileDark() throws {
        let snapshot = try SnapshotHarness.assertSnapshot(
            of: MizarIconTile(size: 64, motion: .still)
                .environment(\.colorScheme, .dark),
            named: "MizarIconTile-dark",
            size: CGSize(width: 64, height: 64),
        )
        #expect(snapshot.pixelWidth == 128)
        #expect(snapshot.pixelHeight == 128)
    }
}
