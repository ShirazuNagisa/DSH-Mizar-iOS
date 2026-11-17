//
//  CommandPaletteHintSnapshotTests.swift
//  DSH-MizarTests
//
//  The "Open commands and skills" capsule that appears while the field holds a
//  lone `/`, in both appearances. The dark reference is why this file exists:
//  the capsule's glass and its ink are dynamic, and a reference recorded only
//  in light cannot tell a correct inversion from a surface that stayed light.
//
//  `SnapshotHarness` pins the light scheme outermost; the dark case overrides it
//  on the view itself, which is the closer environment and wins. The stage
//  paints `systemBackground`, because the harness's white canvas is not a
//  surface a dark reference should be judged against.
//

import SwiftUI
import Testing
import UIKit
@testable import DSH_Mizar

@MainActor
struct CommandPaletteHintSnapshotTests {
    enum Appearance: String, CaseIterable, Sendable {
        case light
        case dark

        var scheme: ColorScheme { self == .dark ? .dark : .light }
    }

    @Test(arguments: Appearance.allCases)
    func paletteHint(_ appearance: Appearance) throws {
        let snapshot = try SnapshotHarness.assertSnapshot(
            of: CommandPaletteHint {}
                .padding(.horizontal, 18)
                .frame(width: 390, height: 90)
                .background(Color(uiColor: .systemBackground))
                .environment(\.colorScheme, appearance.scheme),
            named: "CommandPaletteHint-\(appearance.rawValue)",
            size: CGSize(width: 390, height: 90),
        )
        #expect(snapshot.pixelWidth == 780)
        #expect(snapshot.pixelHeight == 180)
    }
}
