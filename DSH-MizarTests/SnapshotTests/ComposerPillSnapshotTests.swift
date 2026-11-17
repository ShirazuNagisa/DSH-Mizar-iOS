//
//  ComposerPillSnapshotTests.swift
//  DSH-MizarTests
//
//  The capsule the field draws around a known token, straight from
//  `ComposerPill.image` through `ComposerPillPreview` -- no text view, which
//  `ImageRenderer` cannot draw.
//
//  Four references: the two commands in use, a skill with a hyphenated name,
//  one name long enough to be cut with `…` at the field's width, and the same
//  capsule in dark. The truncation and the ink inversion are the two things a
//  reviewer cannot check from the token list, and both are pixels.
//

import SwiftUI
import Testing
import UIKit
@testable import DSH_Mizar

@MainActor
struct ComposerPillSnapshotTests {
    enum Pill: String, CaseIterable, Sendable {
        /// An ordinary command.
        case goal
        /// A skill, whose name is a wire name rather than a copy key.
        case iconDraw
        /// Longer than the 260-pt field fixture: must end in `…`.
        case longName
        /// The same capsule in the other appearance.
        case dark

        var literal: String {
            switch self {
            case .goal: "/goal"
            case .iconDraw: "/icon-draw"
            case .longName: "/an-extremely-long-skill-name-that-cannot-fit-inside-one-line-of-the-field"
            case .dark: "/icon-draw"
            }
        }

        var style: UIUserInterfaceStyle {
            self == .dark ? .dark : .light
        }

        var scheme: ColorScheme {
            self == .dark ? .dark : .light
        }
    }

    @Test(arguments: Pill.allCases)
    func composerPill(_ pill: Pill) throws {
        let snapshot = try SnapshotHarness.assertSnapshot(
            of: ComposerPillPreview(literal: pill.literal, style: pill.style, maxWidth: 260)
                .padding(.horizontal, 16)
                .frame(width: 300, height: 64, alignment: .leading)
                .background(Color(uiColor: .systemBackground))
                .environment(\.colorScheme, pill.scheme),
            named: "ComposerPill-\(pill.rawValue)",
            size: CGSize(width: 300, height: 64),
        )
        #expect(snapshot.pixelWidth == 600)
        #expect(snapshot.pixelHeight == 128)
    }
}
