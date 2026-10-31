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

/// The mark the splash shows, drawn once.
enum SplashMark {
    /// The image, drawn on first use.
    ///
    /// Two layers, exactly as ``MizarStarPose`` stacks them: the back layer
    /// offset along its own axis, the front layer on top. Both are flat fills --
    /// the depth is the second tone, never a gradient.
    static let image: UIImage = draw()

    private static func draw() -> UIImage {
        let side: CGFloat = 1024
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
        return renderer.image { context in
            let cg = context.cgContext
            let base = StarGeometry.path().cgPath
            // The geometry is normalised to a unit square; the two layers are
            // the same path, the back one slid by the design's own offset.
            var scale = CGAffineTransform(scaleX: side, y: side)
            let back = base.copy(using: &scale) ?? base
            let front = base.copy(using: &scale) ?? base

            let offset = CGFloat(StarGeometry.backOffset) / 1024 * side
            cg.saveGState()
            cg.translateBy(x: -offset * 0.5, y: offset * 0.5)
            cg.addPath(back)
            cg.setFillColor(UIColor(MizarStarPalette.brand.back).cgColor)
            cg.fillPath()
            cg.restoreGState()

            cg.addPath(front)
            cg.setFillColor(UIColor(MizarStarPalette.brand.front).cgColor)
            cg.fillPath()
        }
    }
}
