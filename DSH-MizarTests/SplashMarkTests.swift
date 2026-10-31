//
//  SplashMarkTests.swift
//  DSH-MizarTests
//
//  The launch mark has to be ink on transparency, not an empty square.
//

import Foundation
import Testing
import UIKit
@testable import DSH_Mizar

@MainActor
struct SplashMarkTests {
    @Test func theMarkIsDrawn() throws {
        let image = SplashMark.image
        #expect(image.size.width == 1024)
        let cg = try #require(image.cgImage)
        let width = cg.width
        let height = cg.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
        ))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        // The centre of the mark's box is inside the star.
        let centre = ((height / 2) * width + width / 2) * 4
        let alpha = pixels[centre + 3]
        #expect(alpha > 200, "the mark's centre is transparent: the drawing produced nothing")
        // And the corner is outside it.
        let corner = pixels[3]
        #expect(corner < 40, "the corner is painted: the mark fills its whole box")
    }
}
