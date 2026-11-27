//
//  MessageMenuLayoutTests.swift
//  DSH-MizarTests
//
//  The arithmetic behind a held message: where the lifted bubble lands, how far
//  it shrinks, and which side the menu takes. No screen is involved, so these
//  are the cases an operator would otherwise have to hold a bubble to check:
//  the middle of the page, both edges, and a message longer than the screen.
//

import CoreGraphics
import Testing
@testable import DSH_Mizar

struct MessageMenuLayoutTests {
    private let container = CGRect(x: 0, y: 0, width: 402, height: 760)

    /// A short bubble in the middle: full size, menu above.
    @Test func centredBubbleKeepsItsSizeAndTakesTheMenuAbove() {
        let layout = MessageMenuLayout.place(
            source: CGRect(x: 100, y: 300, width: 285, height: 80),
            container: container,
        )

        #expect(layout.scale == 1)
        #expect(layout.placement == .above)
        #expect(layout.bubbleOrigin.y == 300)
    }

    /// A bubble near the top: there is no room above it, so the menu goes
    /// below and the bubble stays where it was.
    @Test func topBubbleTakesTheMenuBelow() {
        let layout = MessageMenuLayout.place(
            source: CGRect(x: 100, y: 20, width: 285, height: 60),
            container: container,
        )

        #expect(layout.placement == .below)
        #expect(layout.bubbleOrigin.y == 20)
    }

    /// A bubble near the bottom: the menu has room above it.
    @Test func bottomBubbleTakesTheMenuAbove() {
        let layout = MessageMenuLayout.place(
            source: CGRect(x: 100, y: 640, width: 285, height: 100),
            container: container,
        )

        #expect(layout.placement == .above)
    }

    /// A message longer than the screen: it shrinks into the room the menu
    /// leaves, and both stay inside the container.
    @Test func tallerThanTheContainerShrinksToFitAndStaysInside() {
        let source = CGRect(x: 100, y: -200, width: 285, height: 1600)
        let layout = MessageMenuLayout.place(source: source, container: container)

        let expected = (container.height - 2 * MessageMenuLayout.margin
            - MessageMenuLayout.menuSize.height - MessageMenuLayout.gap) / source.height
        #expect(abs(layout.scale - expected) < 0.0001)
        #expect(layout.scale < 1)

        // The menu, inside the container's side margins.
        #expect(layout.menuOrigin.x >= container.minX + MessageMenuLayout.sideMargin)
        #expect(layout.menuOrigin.x + MessageMenuLayout.menuSize.width
            <= container.maxX - MessageMenuLayout.sideMargin)
        #expect(layout.menuOrigin.y >= container.minY)
        #expect(layout.menuOrigin.y + MessageMenuLayout.menuSize.height <= container.maxY)

        // The lifted bubble, inside the container's margins.
        let height = source.height * layout.scale
        #expect(layout.bubbleOrigin.y >= container.minY + MessageMenuLayout.margin)
        #expect(layout.bubbleOrigin.y + height <= container.maxY - MessageMenuLayout.margin)
    }
}
