//
//  DebugFoldPreview.swift
//  DSH-Mizar
//
//  The app at a window size it cannot have.
//
//  A simulator cannot unfold an iPhone Duo: the display the app would meet when
//  the phone opens is powered from the host's chrome, and a headless
//  `simctl`-booted device never folds. So the one thing that has to be true of
//  the spread -- that at 951 x 669 nothing is left as a black bar -- could not
//  be checked by running the app at all.
//
//  `-mizarGeometry 951x669` renders the whole app at that size and scales the
//  result down to fit the window, which is enough to prove layout, widths,
//  gutters, type and the valley. It deliberately does not pretend to be the
//  real window: the safe area is still the cover display's, and the scale is a
//  transform, so a screenshot taken this way says what the layout does and
//  nothing about how a physical unfold feels. Debug builds only.
//

#if DEBUG
import SwiftUI

struct DebugFoldPreview<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        if let size = Self.requested {
            GeometryReader { proxy in
                let scale = min(proxy.size.width / size.width, proxy.size.height / size.height)
                content
                    .frame(width: size.width, height: size.height)
                    // The window the injected size stands for is a regular
                    // width; the cover display the app is actually running on
                    // is compact. Without this the geometry would be faked and
                    // the size class would still say "folded".
                    .environment(\.horizontalSizeClass, .regular)
                    .scaleEffect(scale, anchor: .topLeading)
            }
            .ignoresSafeArea()
            .background(Color.black.ignoresSafeArea())
        } else {
            content
        }
    }

    /// `-mizarGeometry 951x669`, as two numbers.
    private static var requested: CGSize? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "-mizarGeometry"),
              arguments.index(after: flag) < arguments.endIndex
        else { return nil }
        let parts = arguments[arguments.index(after: flag)].lowercased().split(separator: "x")
        guard parts.count == 2,
              let width = Double(parts[0]), let height = Double(parts[1]),
              width > 0, height > 0
        else { return nil }
        return CGSize(width: width, height: height)
    }
}
#else
import SwiftUI

struct DebugFoldPreview<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View { content }
}
#endif
