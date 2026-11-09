import Testing
import CoreGraphics
import QuartzCore
@testable import DSH_Mizar

/// The conversation card's narrowing, as a drawer comes out.
///
/// The card used to arrive at its narrowest over the first third of the
/// travel and then only translated for the rest of it, which read as a card
/// that had finished shrinking while the drawer was still coming. These pin
/// the narrowing to the whole travel: the card narrows with the drawer, and
/// is exactly as narrow as it will be at the moment the drawer arrives.
@Suite("The conversation card's narrowing")
struct DrawerNarrowingTests {
    /// A phone: a 390-point-wide screen with the sidebar 320 points wide and
    /// the turn index 300.
    private let width: CGFloat = 390
    private let height: CGFloat = 844
    private let leadingWidth: CGFloat = 320
    private let trailingWidth: CGFloat = 300

    private func look(_ progress: CGFloat) -> DrawerLook {
        DrawerLook(
            progress: progress,
            leadingWidth: leadingWidth,
            trailingWidth: trailingWidth,
            size: CGSize(width: width, height: height),
        )
    }

    /// The card's own scale, as the transform carries it.
    private func scale(_ look: DrawerLook) -> CGFloat {
        look.cardTransform.m11
    }

    /// A point on the card, in the layer's own coordinates: the card is
    /// centred on its anchor point, so its edges are half a width either way.
    private func place(_ look: DrawerLook, x: CGFloat, y: CGFloat = 0) -> CGPoint {
        let affine = CATransform3DGetAffineTransform(look.cardTransform)
        return CGPoint(x: x, y: y).applying(affine)
    }

    @Test("the card is at rest at zero and narrowest with the drawer out")
    func narrowingEnds() {
        #expect(DrawerLook.cardScale(reveal: 0) == 1)
        #expect(abs(DrawerLook.cardScale(reveal: 1) - (1 - DrawerLook.cardShrink)) < 0.0001)
    }

    @Test("the narrowing runs the whole travel, not the first third of it")
    func narrowingIsNotEarly() {
        // The old ramp finished over the first third: the card was already as
        // narrow as it would ever be there, and only translated afterwards.
        #expect(DrawerLook.cardScale(reveal: 1.0 / 3.0) > DrawerLook.cardScale(reveal: 1))
        #expect(DrawerLook.cardScale(reveal: 0.5) > DrawerLook.cardScale(reveal: 1))
        #expect(DrawerLook.cardScale(reveal: 0.9) > DrawerLook.cardScale(reveal: 1))
    }

    @Test("the narrowing is linear in the travel")
    func narrowingIsLinear() {
        let rest = DrawerLook.cardScale(reveal: 0)
        let out = DrawerLook.cardScale(reveal: 1)
        for step in 1...10 {
            let reveal = CGFloat(step) / 10
            let expected = rest + (out - rest) * reveal
            #expect(abs(DrawerLook.cardScale(reveal: reveal) - expected) < 0.0001)
        }
    }

    @Test("the card narrows the same way towards either drawer")
    func bothDrawersNarrowAlike() {
        for step in 0...10 {
            let reveal = CGFloat(step) / 10
            #expect(abs(scale(look(reveal)) - scale(look(-reveal))) < 0.0001)
            #expect(abs(scale(look(reveal)) - DrawerLook.cardScale(reveal: reveal)) < 0.0001)
        }
    }

    @Test("the edge the drawer pushes against keeps its place")
    func thePinnedEdgeDoesNotMove() {
        // The sidebar on the left: the card's left edge is pinned to the
        // drawer's width, and the narrowing comes off its right edge.
        for step in 1...10 {
            let progress = CGFloat(step) / 10
            let look = look(progress)
            let left = place(look, x: -width / 2)
            let right = place(look, x: width / 2)
            #expect(abs(left.x - (-width / 2 + leadingWidth * progress)) < 0.0001)
            #expect(abs((right.x - left.x) - width * DrawerLook.cardScale(reveal: progress)) < 0.0001)
        }
        // The turn index on the right: the card's right edge is pinned, and
        // the narrowing comes off its left edge.
        for step in 1...10 {
            let progress = -CGFloat(step) / 10
            let look = look(progress)
            let left = place(look, x: -width / 2)
            let right = place(look, x: width / 2)
            #expect(abs(right.x - (width / 2 - trailingWidth * CGFloat(step) / 10)) < 0.0001)
            #expect(abs((right.x - left.x) - width * DrawerLook.cardScale(reveal: -progress)) < 0.0001)
        }
    }

    @Test("the card is narrower at every step of the travel")
    func theCardNarrowsOnTheWay() {
        // What the operator sees: the conversation is a little shorter the
        // further the drawer comes out, all the way to the end.
        func drawnHeight(_ look: DrawerLook) -> CGFloat {
            place(look, x: 0, y: height / 2).y - place(look, x: 0, y: -height / 2).y
        }
        var previous = CGFloat.infinity
        for step in 0...10 {
            let reveal = CGFloat(step) / 10
            let drawn = drawnHeight(look(reveal))
            #expect(drawn < previous)
            previous = drawn
        }
        // At the end of the travel it is `cardShrink` shorter than at rest,
        // towards either drawer.
        let rest = drawnHeight(look(0))
        #expect(abs(drawnHeight(look(1)) - rest * (1 - DrawerLook.cardShrink)) < 0.0001)
        #expect(abs(drawnHeight(look(-1)) - rest * (1 - DrawerLook.cardShrink)) < 0.0001)
    }
}
