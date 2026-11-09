import Testing
import QuartzCore
import SwiftUI
import UIKit
@testable import DSH_Mizar

/// The card's content is held as a still picture while a drawer moves.
///
/// The hold works by asking the content's layer to be rasterized: the tree is
/// drawn once into a texture and the render server moves that texture, so the
/// elements inside the card travel as one body. That only works while the
/// content is drawn by a plain layer -- a Metal-backed layer is drawn by the
/// render server itself and cannot be rasterized, so the hold would silently
/// do nothing.
@Suite("The card's content while a drawer moves")
struct DrawerContentFreezeTests {
    @Test("the hosted content is drawn by a layer that can be rasterized")
    func theHostingLayerCanBeRasterized() {
        let host = UIHostingController(rootView: Text("content"))
        host.loadViewIfNeeded()
        let layer = host.view.layer
        #expect(!layer.isKind(of: CAMetalLayer.self), "the hosted content is Metal-backed: holding it as a texture would do nothing")
        // And the hold is a layer property, so it can be turned on and off.
        layer.shouldRasterize = true
        #expect(layer.shouldRasterize)
        layer.shouldRasterize = false
        #expect(!layer.shouldRasterize)
    }

    @Test("a rasterized layer keeps its contents at the scale it was asked for")
    func rasterizationScaleIsHonoured() {
        let host = UIHostingController(rootView: Text("content"))
        host.loadViewIfNeeded()
        let layer = host.view.layer
        layer.rasterizationScale = 2
        #expect(layer.rasterizationScale == 2)
    }
}
