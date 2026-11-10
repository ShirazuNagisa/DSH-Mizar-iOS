//
//  FoldLayout.swift
//  DSH-Mizar
//
//  The window read as pages.
//
//  iPhone Duo is the first iPhone whose window is not one screen. Folded it is
//  a 466 x 678 pt cover display -- an iPhone, in every way the app already
//  knows. Unfolded it is a 951 x 669 pt spread with the hinge down the middle.
//
//  The spread is the iPad's arrangement, not a new one: the conversation keeps
//  two thirds of the window, one sidebar takes the other third, and the two
//  sidebars trade places because a third and a third and two thirds do not fit
//  in a whole. That is exactly what the iPad's columns already do -- see
//  `DrawerContainer.layoutColumns()` -- so the fold reuses it rather than
//  inventing a second multi-pane system.
//
//  What this file adds is only the arithmetic: which shape the window is, and
//  how wide a sidebar is when the shape is a spread.
//
//  Why the resolution is a measurement rather than a device check: the app
//  should not care which iPhone it is on, only how wide the window is and how
//  it is proportioned. `UIDevice` says nothing useful here -- the Duo reports
//  `phone` for both of its displays -- and a model check would break the day
//  Apple ships a second foldable with a different hinge.
//
//  The numbers are measured, not chosen. `capabilities.plist` for
//  `iPhone Duo.simdevicetype` declares two integrated displays: `LCD`
//  1398 x 2034 px at 3x (466 x 678 pt) and `LCD-1` 2007 x 2853 px at 3x,
//  presented at 270 degrees (951 x 669 pt).
//  `docs/ios/ios-iphone-duo-adaptation.md` records the measurement and how to
//  repeat it.
//

import SwiftUI
import UIKit

extension EnvironmentValues {
    /// Whether this part of the hierarchy is one pane of a spread.
    ///
    /// A value rather than the shell's context object, so a screen rendered on
    /// its own -- the snapshot suite renders `SessionDetailView` directly --
    /// keeps the phone's behaviour instead of crashing on a missing object.
    ///
    /// It exists because the quick rail is drawn by the shell on a spread: the
    /// rail inside the conversation is gated on `sizeClass == .regular`, and
    /// that trait belongs to the hosting controller's window. The debug
    /// geometry injection can fake the layout but not the trait, so a rail that
    /// lived behind the trait could never be photographed before the hardware
    /// arrives.
    @Entry var spreadWindow = false
}

/// The window as one page, two pages, or the iPad's columns.
struct FoldLayout: Equatable {
    enum Shape: Equatable {
        /// One page: the folded cover display, and every other iPhone.
        case phone
        /// Two panes: the unfolded inner display, laid out as the iPad's columns.
        case spread
        /// The iPad's pinned columns.
        case columns
    }

    /// The window is divided into this many shares on a spread; one sidebar
    /// takes one, the conversation the other two.
    ///
    /// A proportion, not a fixed width: the whole point of a spread is that it
    /// is wide, and a 320-point column on a 951-point window wastes the page it
    /// is standing on. Divided rather than multiplied by a fraction, so 951
    /// gives exactly 317 and three of them are exactly the window.
    static let sidebarDivisor: CGFloat = 3

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

    /// How wide one sidebar is on a spread: a third of the window.
    ///
    /// The shell hands this to both columns, which is what makes them mutually
    /// exclusive: a third and a third and two thirds cannot all be on screen,
    /// so opening one closes the other -- the iPad's own rule, arriving at the
    /// same answer by arithmetic instead of by a special case.
    var sidebarWidth: CGFloat { canvas.width / Self.sidebarDivisor }

    /// What the conversation has left when one sidebar is out: two thirds.
    var conversationWidth: CGFloat { canvas.width - sidebarWidth }
}
