//
//  MarkdownTableSnapshotTests.swift
//  DSH-MizarTests
//
//  A table cell holds every line it was given.
//
//  The conversation, the typewriter and the preview all draw tables through
//  `MarkdownTableGrid`. Inside the real horizontal `ScrollView` the cells used
//  to be measured with an unspecified width, report their single-line size, and
//  be given one line of height -- so a long cell was cut off with an ellipsis.
//  A definite column width is the fix, and this reference is what makes the
//  wrapped two- and three-line cells visible in review.
//
//  The grid is snapshotted without its scroller on purpose: `ImageRenderer`
//  draws SwiftUI drawing and draws nothing inside a `ScrollView`, so the real
//  composition cannot be a reference. The grid itself is the layout that
//  regressed.
//

import MizarKit
import SwiftUI
import Testing
@testable import DSH_Mizar

@MainActor
struct MarkdownTableSnapshotTests {
    @Test
    func longCellsWrapInsideTheirColumn() throws {
        let source = """
        | File | Notes |
        | --- | --- |
        | Sources/App/Conversation/MarkdownMessage.swift | This cell is long enough that the old one-line layout cut its tail off with an ellipsis; it has to wrap inside the column and make its row taller instead. |
        | 说明 | 这一格同样很长，长到旧的一行布局会在单元格里用省略号把它截掉；现在应该在格内换行，行高随之增加。 |
        | a.md | short |
        """
        guard case .table(let table) = MarkdownBlocks.parse(source).first else {
            Issue.record("the table fixture did not parse as a table")
            return
        }

        let snapshot = try SnapshotHarness.assertSnapshot(
            of: MarkdownTableGrid(table: table).padding(12),
            named: "MarkdownTable-long-cells",
            size: CGSize(width: 504, height: 520),
        )
        #expect(snapshot.pixelWidth == 1008)
        #expect(snapshot.pixelHeight == 1040)
    }



}
