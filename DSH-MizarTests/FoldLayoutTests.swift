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

    @Test("The unfolded Duo is a spread, and its sidebar is a third of it")
    func unfoldedDuoIsASpread() {
        let fold = layout(Self.duoInner)
        #expect(fold.shape == .spread)
        // 951 / 3.
        #expect(fold.sidebarWidth == 317)
        // The conversation keeps the other two thirds.
        #expect(fold.conversationWidth == 634)
        #expect(fold.conversationWidth == fold.sidebarWidth * 2)
    }

    @Test("The folded Duo is a phone, and has no spread arithmetic")
    func foldedDuoIsAPhone() {
        let fold = layout(Self.duoCover)
        #expect(fold.shape == .phone)
        #expect(!fold.isSpread)
        // The sidebar width is the shell's business on a phone; the spread
        // arithmetic is what this type owns, and it is a third either way.
        #expect(abs(fold.sidebarWidth - 466.0 / 3.0) < 0.0001)
    }

    @Test("A landscape iPhone stays one page rather than becoming a spread")
    func landscapePhoneIsNotASpread() {
        // iPhone 16 Pro, landscape: 874 x 402, ratio 2.17.
        #expect(layout(CGSize(width: 874, height: 402)).shape == .phone)
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

    @Test("Two sidebars and two thirds can never all fit, which is the trade")
    func theFractionsMakeTheColumnsExclusive() {
        // This is the arithmetic the shell relies on to make opening one
        // sidebar close the other: a third plus a third plus two thirds is
        // more than the window, at every spread size.
        for width in stride(from: CGFloat(900), through: 1130, by: 50) {
            let fold = layout(CGSize(width: width, height: 669))
            #expect(fold.shape == .spread)
            let bothSidebarsAndTheConversation =
                fold.sidebarWidth * 2 + fold.conversationWidth
            #expect(bothSidebarsAndTheConversation > fold.canvas.width)
            // And one sidebar plus the conversation is exactly the window.
            #expect(fold.sidebarWidth + fold.conversationWidth == fold.canvas.width)
        }
    }
}
