//
//  CommandSkillPaletteSnapshotTests.swift
//  DSH-MizarTests
//
//  The command and skill palette in every state that is not just "a list of
//  names": the ready catalogue (one ordinary description and one long one that
//  must truncate at two lines), a computer that has synced nothing yet, an old
//  computer without `agent.skills.v1`, and the on-device agent.
//
//  `CommandSkillPalette` is a leaf with no `AppModel` and no navigation chrome,
//  so each state is drawn from a fixture. `scrolls: false` is the snapshot
//  path: the production page puts the same rows in a `ScrollView`, and
//  `ImageRenderer` draws nothing inside a UIKit-backed scroller (the
//  `MarkdownTableGrid` precedent in docs/snapshots.md), so snapshot mode draws
//  the rows without the `ScrollView` and substitutes a static placeholder for
//  the UIKit-backed `TextField` (`ImageRenderer` paints that as a yellow
//  "unsupported view" marker). The identifier and copy contract below pins the
//  live search field and the rows' identifiers.
//

import MizarKit
import SwiftUI
import Testing
@testable import DSH_Mizar

@MainActor
struct CommandSkillPaletteSnapshotTests {
    /// Two skills, one with a description long enough to hit the two-line
    /// clamp. Sorted by name by the view, so this order is not the draw order.
    private static let skills = [
        AgentSkill(
            id: "grilling",
            name: "grilling",
            description: "Stress-test a plan or a decision before committing to it.",
            fingerprint: "fixture-grilling",
            engine: "dsh",
        ),
        AgentSkill(
            id: "icon-draw",
            name: "icon-draw",
            description: "Draw a minimalist app or OSS package icon as a master SVG, then review the pixels at 512, 64, 32 and 16 px before the assets ship.",
            fingerprint: "fixture-icon-draw",
            engine: "dsh",
        ),
    ]

    /// The identifiers and copy the UI suite and the palette's own control
    /// contract depend on. `ImageRenderer` discards accessibility, so this is
    /// the half the pixels cannot prove.
    @Test
    func paletteIdentifiersAndCopyAreAddressable() throws {
        try AppSourceContract.expectFragments(
            [
                #".accessibilityIdentifier("palette.done")"#,
                #".navigationTitle(Text("Commands & Skills"))"#,
                #"TextField("Search commands and skills", text: $query)"#,
                #".accessibilityIdentifier("palette.search")"#,
                #".accessibilityIdentifier("palette.empty")"#,
                #"identifier: "palette.noSkills""#,
                #"identifier: "palette.unsupported""#,
                #"identifier: "palette.localMode""#,
                #""palette.command.\(command.name)""#,
                #""palette.skill.\(skill.id)""#,
            ],
            in: "DSH-Mizar/Views/Commands/CommandSkillPaletteView.swift",
            describing: "palette identifier and copy contract",
        )
    }

    @Test
    func ready() throws {
        let snapshot = try SnapshotHarness.assertSnapshot(
            of: CommandSkillPalette(
                support: .ready,
                skills: Self.skills,
                onPick: { _ in },
                scrolls: false,
            ),
            named: "CommandSkillPalette-ready",
            size: CGSize(width: 390, height: 600),
        )
        #expect(snapshot.pixelWidth == 780)
        #expect(snapshot.pixelHeight == 1200)
    }

    @Test
    func readyWithoutSkills() throws {
        let snapshot = try SnapshotHarness.assertSnapshot(
            of: CommandSkillPalette(
                support: .ready,
                skills: [],
                onPick: { _ in },
                scrolls: false,
            ),
            named: "CommandSkillPalette-noSkills",
            size: CGSize(width: 390, height: 600),
        )
        #expect(snapshot.pixelWidth == 780)
        #expect(snapshot.pixelHeight == 1200)
    }

    @Test
    func unsupportedComputer() throws {
        let snapshot = try SnapshotHarness.assertSnapshot(
            of: CommandSkillPalette(
                support: .unsupported,
                skills: [],
                onPick: { _ in },
                scrolls: false,
            ),
            named: "CommandSkillPalette-unsupported",
            size: CGSize(width: 390, height: 600),
        )
        #expect(snapshot.pixelWidth == 780)
        #expect(snapshot.pixelHeight == 1200)
    }

    @Test
    func localMode() throws {
        let snapshot = try SnapshotHarness.assertSnapshot(
            of: CommandSkillPalette(
                support: .localMode,
                skills: [],
                onPick: { _ in },
                scrolls: false,
            ),
            named: "CommandSkillPalette-localMode",
            size: CGSize(width: 390, height: 600),
        )
        #expect(snapshot.pixelWidth == 780)
        #expect(snapshot.pixelHeight == 1200)
    }

    /// The Chinese page, from the same fixture: the section headers, the two
    /// commands' titles and summaries, and the status sentence all resolve
    /// through the catalogue.
    @Test
    func readyInChinese() throws {
        let snapshot = try SnapshotHarness.assertSnapshot(
            of: CommandSkillPalette(
                support: .ready,
                skills: Self.skills,
                onPick: { _ in },
                scrolls: false,
            ),
            named: "CommandSkillPalette-zh-Hans",
            size: CGSize(width: 390, height: 600),
            locale: Locale(identifier: "zh-Hans"),
        )
        #expect(snapshot.pixelWidth == 780)
        #expect(snapshot.pixelHeight == 1200)
    }
}
