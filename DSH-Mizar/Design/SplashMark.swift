//
//  SplashMark.swift
//  DSH-Mizar
//
//  The launch mark, as pixels.
//
//  `MizarStar` is a live SwiftUI view: two shapes, a keyframe animator, and an
//  environment it reads the appearance from. In the window the splash lives in
//  it draws nothing at all -- a plain `Circle` in the same ZStack draws, the
//  mark does not, and neither does a bare `MizarStarLayer` filled with a flat
//  colour. Rather than keep guessing at the reason, the splash uses the mark's
//  own geometry drawn once into an image: the same path the icon is cut from,
//  the same two flat colours, and no SwiftUI inside the window.
//

import SwiftUI
import UIKit

/// The mark the splash shows, drawn once per layer.
///
/// `MizarStar` is a live SwiftUI view: two shapes, a keyframe animator, and an
/// environment it reads the appearance from. In the splash it draws nothing at
/// all -- a plain `Circle` in the same stack draws, the mark does not. So the
/// splash uses the mark's own geometry drawn into images: the same path the icon
/// is cut from, the same two flat colours, and no SwiftUI shapes to fail.
///
/// Two images, not one, because the splash turns them against each other: the
/// front layer clockwise, the back layer the same amount the other way, which is
/// the same motion the app's running indicator makes.
enum SplashMark {
    /// The front layer, in the light appearance's ink.
    static let frontLight: UIImage = layer(fill: MizarStarPalette.brand.front)
    /// The layer behind it, in the light appearance's ink.
    static let backLight: UIImage = layer(fill: MizarStarPalette.brand.back)
    /// The front layer, in the dark appearance's ink.
    static let frontDark: UIImage = layer(fill: .white)
    /// The layer behind it, in the dark appearance's ink.
    static let backDark: UIImage = layer(fill: Color(white: 1, opacity: 0.55))

    /// The pair for an appearance.
    ///
    /// Two sets, drawn once each, because the ink is part of the drawing: the
    /// icon is the blue pair on a light screen and the white pair on a dark one,
    /// and a single baked image cannot be both.
    ///
    /// - Parameter scheme: the appearance the splash is being drawn in.
    /// - Returns: the front and back layers.
    static func layers(for scheme: ColorScheme) -> (front: UIImage, back: UIImage) {
        scheme == .dark
            ? (frontDark, backDark)
            : (frontLight, backLight)
    }

    private static func layer(fill colour: Color) -> UIImage {
        let side: CGFloat = 1024
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
        return renderer.image { context in
            let cg = context.cgContext
            var scale = CGAffineTransform(scaleX: side, y: side)
            guard let path = StarGeometry.path().cgPath.copy(using: &scale) else { return }
            cg.addPath(path)
            cg.setFillColor(UIColor(colour).cgColor)
            cg.fillPath()
        }
    }
}
