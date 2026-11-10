//
//  FoldLayout.swift
//  DSH-Mizar
//
//  The window read as pages.
//
//  iPhone Duo is the first iPhone whose window is not one screen. Folded it is
//  a 466 x 678 pt cover display; unfolded it is a 951 x 669 pt spread with the
//  hinge running down the middle, and each half of that spread is -- to within
//  a few points -- the cover display's own width. That is the fact this file
//  turns into a rule: **a page is a page whether the phone is open or closed**,
//  so the conversation's reading measure never changes when the fold does.
//
//  Three shapes, and only one of them is new:
//
//    - `phone`: one page, everything the app has ever drawn on an iPhone.
//    - `spread`: two pages with a valley between them. The left page behaves
//      exactly like the phone's page -- the same compact layout, the same
//      drawers -- and the right page is the context plane.
//    - `columns`: the iPad's pinned columns, untouched by any of this.
//
//  Why the resolution is a measurement rather than a device check: the app
//  should not care which iPhone it is on, only how wide the window is and how
//  it is proportioned. `UIDevice` says nothing useful here -- the Duo reports
//  `phone` for both of its displays -- and a model check would break the day
//  Apple ships a second foldable with a different hinge.
//
//  The numbers are measured, not chosen. `capabilities.plist` for
//  `iPhone Duo.simdevicetype` declares two integrated displays: `LCD`
//  1398 x 2034 px at 3x (466 x 678 pt, corners 8 pt on the spine side and
//  59 pt outside) and `LCD-1` 2007 x 2853 px at 3x, presented at 270 degrees
//  (951 x 669 pt, corners 55 pt). `docs/ios/ios-iphone-duo-adaptation.md`
//  records the measurement and how to repeat it.
//

import SwiftUI
import UIKit

/// The window as one page, two pages, or the iPad's columns.
struct FoldLayout: Equatable {
    enum Shape: Equatable {
        /// One page: the folded cover display, and every other iPhone.
        case phone
        /// Two pages side by side, the hinge between them.
        case spread
        /// The iPad's pinned columns.
        case columns
    }

    /// The reading measure: the widest a column of the conversation's own
    /// content may be, folded or unfolded.
    ///
    /// It is the cover display's width (466 pt), because that is the width the
    /// conversation was designed to be read at and the width it must keep when
    /// the second page appears. Anything wider and unfolding would reflow the
    /// text the operator was already reading, which is the one thing a fold
    /// must not do.
    static let measure: CGFloat = 466

    /// The valley the hinge leaves between two pages, in points: 14 on each
    /// page's spine side. Content keeps out of it; only the spine may enter.
    static let gutter: CGFloat = 28

    /// A spread is at least this wide. The unfolded Duo measures 951, so the
    /// threshold only has to separate a spread from a landscape phone (874 on
    /// an iPhone 16 Pro), and it does with room to spare.
    static let spreadMinimumWidth: CGFloat = 900

    /// ...and no more than this many times as wide as it is tall. The unfolded
    /// Duo is 1.42; a landscape iPhone is 2.17. A phone lying on its side is a
    /// single page that happens to be wide, not a book.
    static let spreadMaximumRatio: CGFloat = 1.7

    let shape: Shape
    /// The whole window, safe area included -- the same size the shell measures.
    let canvas: CGSize

    init(size: CGSize, widthClass: UserInterfaceSizeClass?, idiom: UIUserInterfaceIdiom = .phone) {
        canvas = size
        shape = Self.resolve(size: size, widthClass: widthClass, idiom: idiom)
    }

    /// Which shape this window is. Pure, so the rule can be tested with the
    /// measured sizes instead of by opening a phone.
    static func resolve(
        size: CGSize,
        widthClass: UserInterfaceSizeClass?,
        idiom: UIUserInterfaceIdiom = .phone,
    ) -> Shape {
        if idiom == .pad { return .columns }
        guard widthClass == .regular, size.width > 0, size.height > 0 else { return .phone }
        let ratio = size.width / size.height
        guard size.width >= spreadMinimumWidth, ratio <= spreadMaximumRatio else { return .phone }
        return .spread
    }

    var isSpread: Bool { shape == .spread }

    /// One page's width. A spread splits the window minus the valley; a phone
    /// is one page.
    var pageWidth: CGFloat {
        guard isSpread else { return canvas.width }
        return (canvas.width - Self.gutter) / 2
    }

    /// The window's two pages, left to right. One entry for a phone.
    var pages: [CGRect] {
        let height = canvas.height
        guard isSpread else { return [CGRect(x: 0, y: 0, width: canvas.width, height: height)] }
        return [
            CGRect(x: 0, y: 0, width: pageWidth, height: height),
            CGRect(x: canvas.width - pageWidth, y: 0, width: pageWidth, height: height),
        ]
    }

    var leftPage: CGRect { pages[0] }
    var rightPage: CGRect { pages.count > 1 ? pages[1] : pages[0] }

    /// The strip between the two pages, where nothing is drawn but the spine.
    var valley: CGRect? {
        guard isSpread else { return nil }
        return CGRect(x: pageWidth, y: 0, width: Self.gutter, height: canvas.height)
    }

    /// The hinge's own coordinate: the x the spine and its hairline sit on.
    var spineX: CGFloat? { isSpread ? canvas.width / 2 : nil }

    /// The widest the page's content may be. Equal to the page in a spread
    /// (the valley is already out of it); capped by the measure on a wide phone.
    var readingWidth: CGFloat { min(pageWidth, Self.measure) }
}
