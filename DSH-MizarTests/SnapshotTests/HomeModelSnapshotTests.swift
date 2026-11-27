//
//  HomeModelSnapshotTests.swift
//  DSH-MizarTests
//
//  The model route: the pill that names what a session will start on, and the
//  drawer row that route is chosen from -- the view half of
//  `AppFlowNavigationTests.testTheHomeScreenChoosesTheModelItsSessionStartsOn`,
//  which keeps the request half (that the started session really runs on the
//  chosen model) because that belongs to the host round-trip, not to pixels.
//
//  The pill is the app's own `ModelPill` fed by `modelPillLabel`'s exact
//  composition, and the composition is asserted alongside the pixels. The
//  drawer itself is not rendered: it reads its catalogue from the environment's
//  `AppModel` -- a connection-scoped value a unit test has none of -- and its
//  rows need a `Namespace` only a view can hold. What renders instead is the
//  row the drawer draws, `ModelDrawerRow`, from a decoded `ModelCatalog`
//  fixture, seeded the way the drawer seeds a chosen row: ticked.
//

import MizarKit
import SwiftUI
import Testing
@testable import DSH_Mizar

@MainActor
struct HomeModelSnapshotTests {
    /// The catalogue as the UI test's host serves it: one provider, one model,
    /// an Off and a High level, High the default the row seeds with.
    private static func catalogFixture() throws -> ModelCatalog {
        let json = """
        {
          "default": null,
          "providers": [
            {
              "id": "deepseek",
              "name": "DeepSeek",
              "models": [
                {
                  "id": "deepseek-v4-pro",
                  "name": "DeepSeek V4 Pro",
                  "description": "The strongest reasoner on the shelf.",
                  "efforts": [
                    { "id": "off", "name": "Off" },
                    { "id": "high", "name": "High" }
                  ],
                  "defaultEffort": "high"
                }
              ]
            }
          ],
          "failures": []
        }
        """
        return try JSONDecoder().decode(ModelCatalog.self, from: Data(json.utf8))
    }

    @Test func homeModelPillNamesTheModelItWillStartOn() throws {
        // The home page no longer carries a composer: its model pill went with
        // it, and the picker is reached from a conversation. What is left to
        // check is the label composition the pill used, which the composer's
        // pill still draws.
        // The UI test asserted the label contains the model's id;
        // `modelPillLabel` is what composes it, and the same composition feeds
        // the pixels below.
        let label = modelPillLabel(model: "deepseek-v4-pro", effort: "off")
        #expect(label == "deepseek-v4-pro · Off")

        let snapshot = try SnapshotHarness.assertSnapshot(
            of: ModelPill(label: label, action: {}),
            named: "HomeModelPill-deepseek-v4-pro",
            size: CGSize(width: 220, height: 44),
        )
        #expect(snapshot.pixelWidth == 440)
        #expect(snapshot.pixelHeight == 88)
    }

    @Test func modelPickerRowRevealsTheReasoningEffort() throws {
        // The old picker's row is gone with its sheet; the drawer's row carries
        // the same wire identifier, and that is what the UI suite taps.
        try AppSourceContract.expectFragments(
            [#".accessibilityIdentifier("model.row.\(option.id)")"#],
            in: "DSH-Mizar/Views/Composer/ModelDrawer.swift",
            describing: "the model row's wire identifier",
        )

        let model = try Self.catalogFixture().providers[0].models[0]

        let snapshot = try SnapshotHarness.assertSnapshot(
            of: ModelDrawerRowFixture(option: model),
            named: "ModelDrawerRow-deepseek-v4-pro",
            size: CGSize(width: 340, height: 120),
        )
        #expect(snapshot.pixelWidth == 680)
        #expect(snapshot.pixelHeight == 240)
    }
}

/// The drawer's chosen row, hosted on its own: the row needs the drawer's tick
/// namespace, which only a view can hold, and the drawer itself reads the
/// environment's catalogue.
private struct ModelDrawerRowFixture: View {
    let option: ModelOption
    @Namespace private var tick

    var body: some View {
        ModelDrawerRow(
            option: option,
            isChosen: true,
            isApplying: false,
            tick: tick,
            action: {},
        )
    }
}
