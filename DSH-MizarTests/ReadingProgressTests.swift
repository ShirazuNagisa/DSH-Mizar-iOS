//
//  ReadingProgressTests.swift
//  DSH-MizarTests
//
//  The spine's one number, pinned to scroll geometry. The first attempt used
//  the turn index's visibility set and it did not answer the question -- on the
//  Duo spread `turns=4 visible=0` ten seconds after launch -- so the fraction now
//  comes from the scroll view itself, which always knows.
//

import Testing
import CoreGraphics
@testable import DSH_Mizar

@Suite("Reading progress")
struct ReadingProgressTests {
    private func fraction(
        content: CGFloat = 4000,
        viewport: CGFloat = 1000,
        minY: CGFloat = 0,
        topInset: CGFloat = 0,
    ) -> Double {
        ReadingProgress.fraction(
            contentHeight: content,
            viewportHeight: viewport,
            visibleMinY: minY,
            topInset: topInset,
        )
    }

    @Test("The top of the page is 0 and the bottom is 1")
    func endsAreExact() {
        #expect(fraction(minY: 0) == 0)
        // 4000 content - 1000 viewport = 3000 travel; at 3000 the end is on screen.
        #expect(fraction(minY: 3000) == 1)
        #expect(fraction(minY: 2999) > 0.999)
    }

    @Test("Half way down is half the spine")
    func middleIsHalf() {
        #expect(fraction(minY: 1500) == 0.5)
    }

    @Test("The content's own top inset is part of the travel")
    func topInsetCounts() {
        // Pulled down under the bar, the first line is not at 0.
        #expect(fraction(minY: -60, topInset: 60) == 0)
        #expect(fraction(minY: 1440, topInset: 60) == 0.5)
    }

    @Test("A page that fits has nothing left to read")
    func shortPageIsComplete() {
        // Content no taller than the viewport: there is no travel, and the
        // whole conversation is already on screen.
        #expect(fraction(content: 900, viewport: 1000, minY: 0) == 1)
        #expect(fraction(content: 1000, viewport: 1000, minY: 0) == 1)
    }

    @Test("The spine never leaves its track")
    func valuesAreClamped() {
        // Over-scrolled at either end: rubber-banding must not fill past 1 or
        // rewind below 0.
        #expect(fraction(minY: 9000) == 1)
        #expect(fraction(minY: -500) == 0)
    }
}
