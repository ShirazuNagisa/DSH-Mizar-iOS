//
//  FoldLayoutTests.swift
//  DSH-MizarTests
//
//  The three shapes, pinned to the sizes measured off the hardware. A fold is
//  hard to test by launching an app -- the simulator cannot unfold itself --
//  so the rule that decides which layout a window gets is pure, and these
//  tests are the proof that it answers for every window the app can meet.
//

import Testing
import SwiftUI
import UIKit
@testable import DSH_Mizar

/// The window as pages.
@Suite("Fold geometry")
struct FoldLayoutTests {
    /// The measurements, from `iPhone Duo.simdevicetype/Contents/Resources/capabilities.plist`.
    private static let duoCover = CGSize(width: 466, height: 678)
    private static let duoInner = CGSize(width: 951, height: 669)

    private func layout(
        _ size: CGSize,
        width: UserInterfaceSizeClass? = .regular,
        idiom: UIUserInterfaceIdiom = .phone,
    ) -> FoldLayout {
        FoldLayout(size: size, widthClass: width, idiom: idiom)
    }

    @Test("The unfolded Duo is a spread, and each page is a phone's width")
    func unfoldedDuoIsASpread() {
        let fold = layout(Self.duoInner)
        #expect(fold.shape == .spread)
        #expect(fold.pages.count == 2)
        // 951 - 28 valley, halved.
        #expect(fold.pageWidth == (951 - FoldLayout.gutter) / 2)
        #expect(fold.leftPage.width == fold.rightPage.width)
        #expect(fold.leftPage.width == 461.5)
        #expect(fold.spineX == 475.5)
        // The valley is between them, and the two pages plus it are the window.
        #expect(fold.valley?.width == FoldLayout.gutter)
        #expect(fold.leftPage.maxX + (fold.valley?.width ?? 0) + fold.rightPage.width == 951)
        // The whole point: a page is never wider than the cover display, so
        // unfolding does not reflow the conversation.
        #expect(fold.readingWidth <= FoldLayout.measure)
        #expect(fold.readingWidth == 461.5)
    }

    @Test("The folded Duo is one page, and it is the cover display")
    func foldedDuoIsOnePage() {
        let fold = layout(Self.duoCover)
        #expect(fold.shape == .phone)
        #expect(fold.pages.count == 1)
        #expect(fold.pageWidth == 466)
        #expect(fold.valley == nil)
        #expect(fold.spineX == nil)
        #expect(fold.readingWidth == 466)
    }

    @Test("A landscape iPhone stays one wide page rather than becoming a book")
    func landscapePhoneIsNotASpread() {
        // iPhone 16 Pro, landscape: 874 x 402, ratio 2.17.
        let fold = layout(CGSize(width: 874, height: 402))
        #expect(fold.shape == .phone)
        // A portrait phone is compact width and also one page.
        #expect(layout(CGSize(width: 402, height: 874), width: .compact).shape == .phone)
    }

    @Test("The iPad keeps its columns")
    func padKeepsItsColumns() {
        // 13" iPad Pro, landscape, and a narrow split view: both are the
        // tablet's, because the idiom is what decides, not the width.
        #expect(layout(CGSize(width: 1366, height: 1024), idiom: .pad).shape == .columns)
        #expect(layout(CGSize(width: 700, height: 900), width: .compact, idiom: .pad).shape == .columns)
    }

    @Test("A spread needs both the width and the proportion")
    func spreadNeedsWidthAndRatio() {
        // Wide enough but far too wide relative to its height: a display, not
        // a book.
        #expect(layout(CGSize(width: 1400, height: 500)).shape == .phone)
        // Proportionate but too narrow for two readable pages.
        #expect(layout(CGSize(width: 880, height: 669)).shape == .phone)
        // Compact width never spreads, however wide the window gets.
        #expect(layout(Self.duoInner, width: .compact).shape == .phone)
        // A degenerate size during launch must not claim to be a book.
        #expect(layout(.zero).shape == .phone)
    }

    @Test("Both halves of a spread meet the reading measure the cover sets")
    func spreadKeepsTheMeasure() {
        // Whatever the spread's width, a page never exceeds the measure the
        // folded phone reads at, and never falls below the narrowest column
        // the iPad's own layout already accepts (460). The upper bound is where
        // the proportion rule stops calling it a book: 669 x 1.7 is 1137.
        for width in stride(from: CGFloat(900), through: 1130, by: 50) {
            let fold = layout(CGSize(width: width, height: 669))
            #expect(fold.shape == .spread)
            #expect(fold.readingWidth <= FoldLayout.measure)
        }
        #expect(layout(Self.duoInner).readingWidth >= 460)
    }
}
