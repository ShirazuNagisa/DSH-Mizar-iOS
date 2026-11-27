//
//  MessageMenuSnapshotTests.swift
//  DSH-MizarTests
//
//  The held message's menu: two rows of glass at its own fixed size.
//
//  The card carries no environment, so the snapshot is the whole of what the
//  operator sees when a bubble is held -- copy above, select below. Its size is
//  fixed by the layout arithmetic (`MessageMenuLayout.menuSize`), and the
//  render is checked at that size so a row that grows or a padding that drifts
//  is a failure here rather than a menu that no longer fits the screen.
//

import SwiftUI
import Testing
@testable import DSH_Mizar

@MainActor
struct MessageMenuSnapshotTests {
    @Test func messageMenuCard() throws {
        let card = MessageMenuCard(onCopy: {}, onSelect: {})
            .frame(width: 248, height: 104)

        let snapshot = try SnapshotHarness.assertSnapshot(
            of: card,
            named: "MessageMenu-card",
            size: CGSize(width: 248, height: 104),
        )
        #expect(snapshot.pixelWidth == 496)
        #expect(snapshot.pixelHeight == 208)
    }
}
