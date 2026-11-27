//
//  ComposerControlsSnapshotTests.swift
//  DSH-MizarTests
//
//  The composer's model pill and context ring, labelled and compact.
//
//  `AppFlowTests.testTheComposerBarShowsTheModelContextAndCommands` launches the
//  app and drives it into a session to assert three buttons exist and that the
//  context figure is the host's number. The pill's label composition and the
//  ring's static drawing are the parts a snapshot can own; the identifiers are
//  pinned against `ComposerBar.swift` so the buttons stay addressable for the
//  tests that still need the running app.
//

import SwiftUI
import Testing
@testable import DSH_Mizar

@MainActor
struct ComposerControlsSnapshotTests {
    enum Variant: String, CaseIterable, Sendable {
        case labelled
        case compact
    }

    @Test(arguments: Variant.allCases)
    func composerControls(_ variant: Variant) throws {
        // The identifiers are applied in ComposerBar.swift, around these two
        // views; the XCUITest queries them by identifier, not by position.
        try AppSourceContract.expectIdentifiers(
            ["composer.model", "composer.context"],
            in: "DSH-Mizar/Views/ComposerBar.swift",
        )

        // The permission key moved from the toolbar into the bar in the same
        // batch; its identifier is the one the UI tests tap.
        try AppSourceContract.expectIdentifiers(
            ["composer.permissions"],
            in: "DSH-Mizar/Views/Composer/PermissionAppearance.swift",
        )

        // The composition rule is copy, so assert it exactly rather than
        // trusting the snapshot to be legible.
        #expect(modelPillLabel(model: "deepseek-flash", effort: "high") == "deepseek-flash · High")
        #expect(modelPillLabel(model: "deepseek-flash", effort: nil) == "deepseek-flash")
        #expect(modelPillLabel(model: "deepseek-flash", effort: "") == "deepseek-flash")

        let controls = HStack(spacing: 10) {
            ModelPill(
                label: modelPillLabel(model: "deepseek-flash", effort: "high"),
                compact: variant == .compact,
                action: {},
            )
            ContextRing(percent: 35)
        }
        .frame(width: 260, height: 40)

        let snapshot = try SnapshotHarness.assertSnapshot(
            of: controls,
            named: "ComposerControls-\(variant.rawValue)",
            size: CGSize(width: 260, height: 40),
        )
        #expect(snapshot.pixelWidth == 520)
        #expect(snapshot.pixelHeight == 80)
    }
}
