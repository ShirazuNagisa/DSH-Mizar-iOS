//
//  Theme.swift
//  DSH-Mizar
//
//  The few numbers the whole app is drawn with.
//
//  Restraint is the design: one accent, one radius scale, one spacing grid. The
//  accent is the asset catalogue's `AccentColor` -- the icon's bright cyan-blue
//  in the light appearance, and white itself in the dark one, where the ring is
//  white and a blue accent beside it reads as a second colour the product does
//  not have. `onAccent` is the ink that goes on top: near-black in both
//  appearances, because white on the bright cyan is unreadable and the dark
//  appearance's accent is already white.
//
//  Every radius here is meant for `style: .continuous`. A circular-arc corner is
//  the one detail that makes a SwiftUI screen look like a web page.
//

import SwiftUI

enum Theme {
    /// Corner radii, smallest to largest. Nest them concentrically: a surface
    /// inset by `n` inside one of radius `r` takes `concentric(r, inset: n)`.
    enum Radius {
        static let xs: CGFloat = 8
        static let sm: CGFloat = 12
        static let md: CGFloat = 16
        static let lg: CGFloat = 20
        static let xl: CGFloat = 26
        /// A sheet-sized card.
        static let card: CGFloat = 22
    }

    /// The radius of a surface nested inside another, so their curves stay
    /// parallel instead of pinching at the corners.
    ///
    /// - Parameters:
    ///   - outer: the containing surface's radius.
    ///   - inset: how far inside it the nested surface sits.
    /// - Returns: the nested radius, never negative.
    static func concentric(_ outer: CGFloat, inset: CGFloat) -> CGFloat {
        max(0, outer - inset)
    }

    /// The 4-pt grid the apps have always used.
    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 24
        static let huge: CGFloat = 32
    }

    /// The icon's own navy, used where the brand rather than the system is
    /// speaking: the pairing screen and the Live Activity card.
    static let navy = Color(red: 19 / 255, green: 31 / 255, blue: 61 / 255)
    static let navyDeep = Color(red: 8 / 255, green: 13 / 255, blue: 27 / 255)

    /// Ink for text drawn on an accent fill.
    ///
    /// Near-black in both appearances. The light accent is the icon's bright
    /// cyan, which white text cannot sit on; the dark accent is already white,
    /// so the same near-black is the readable ink there too.
    static let onAccent = Color(red: 3 / 255, green: 20 / 255, blue: 31 / 255)

    /// The accent as ink, for text and small glyphs.
    ///
    /// In the light appearance the asset's accent is the icon's bright cyan,
    /// which is right as a fill and too light as 11-point text; this is the
    /// same hue taken down to a contrast that holds on white. In the dark
    /// appearance the accent is already white, so the ink is white too. Fills
    /// keep using `Color.accentColor`.
    static let accentText = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? .white
            : UIColor(red: 10 / 255, green: 120 / 255, blue: 174 / 255, alpha: 1)
    })

    /// The states the app has always coloured, kept to the system's hues so
    /// they follow the appearance and the accessibility contrast setting.
    static let running = Color.green
    static let waiting = Color.orange
    static let failed = Color.red
    static let question = Color.blue

    /// The sidebar's ground: one step off the conversation's, so the card the
    /// conversation becomes reads as lifted off it.
    static let sidebarBackground = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.075, green: 0.082, blue: 0.098, alpha: 1)
            : UIColor(red: 0.953, green: 0.957, blue: 0.969, alpha: 1)
    })

    /// The highlight under the selected row: a sheet of paper on the light
    /// sidebar, a faint lift on the dark one.
    static let selectionFill = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 1, alpha: 0.085)
            : UIColor.white
    })

    /// The conversation's ground.
    static let paneBackground = Color(UIColor.systemBackground)
}
