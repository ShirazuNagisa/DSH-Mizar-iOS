//
//  ComposerEffortStripSnapshotTests.swift
//  DSH-MizarTests
//
//  The thinking strip's drawing, without the environment it normally reads:
//  the title row and the level track. The strip's own wrapper reads the
//  catalogue from `AppModel` -- a connection-scoped value a unit test has none
//  of -- so what renders here is `ComposerEffortStripBody` from fixture data,
//  which is the whole of its pixels.
//

import MizarKit
import SwiftUI
import Testing
@testable import DSH_Mizar

@MainActor
struct ComposerEffortStripSnapshotTests {
    /// The four levels a host that accepts an explicit `off` serves, in its own
    /// order. Decoded rather than built: the catalogue types are the wire's,
    /// and they have no public initialiser.
    private static func fourLevels() throws -> [ReasoningEffortOption] {
        let json = """
        [
          { "id": "off", "name": "Off" },
          { "id": "low", "name": "Low" },
          { "id": "high", "name": "High" },
          { "id": "max", "name": "Max" }
        ]
        """
        return try JSONDecoder().decode([ReasoningEffortOption].self, from: Data(json.utf8))
    }

    @Test func fourLevelsWithHighChosen() throws {
        let snapshot = try SnapshotHarness.assertSnapshot(
            of: ComposerEffortStripBody(
                modelName: "DeepSeek-V41-Flash",
                effortName: "High",
                efforts: try Self.fourLevels(),
                selectedIndex: 2,
                loading: false,
                failure: nil,
                enabled: true,
                onTitle: {},
                onCommit: { _ in },
            ),
            named: "EffortStrip-4levels-high",
            size: CGSize(width: 382, height: 98),
        )
        #expect(snapshot.pixelWidth == 764)
        #expect(snapshot.pixelHeight == 196)
    }

    @Test func aModelWithoutLevels() throws {
        let snapshot = try SnapshotHarness.assertSnapshot(
            of: ComposerEffortStripBody(
                modelName: "DeepSeek-V41-Flash",
                effortName: nil,
                efforts: [],
                selectedIndex: 0,
                loading: false,
                failure: nil,
                enabled: true,
                onTitle: {},
                onCommit: { _ in },
            ),
            named: "EffortStrip-noLevels",
            size: CGSize(width: 382, height: 98),
        )
        #expect(snapshot.pixelWidth == 764)
        #expect(snapshot.pixelHeight == 196)
    }
}
