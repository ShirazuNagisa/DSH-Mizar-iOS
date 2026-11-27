//
//  Shimmer.swift
//  DSH-Mizar
//
//  A band of light for text that is still being worked on.
//

import SwiftUI

// MARK: - Shimmer

extension View {
    /// A band of light sweeping across, for text that is still being worked on.
    ///
    /// Drawn over the content and masked by it, so the content itself -- and
    /// what it says to VoiceOver -- is untouched. While the shell's drawers
    /// move, the sweep holds: those frames belong to the card.
    func shimmering(active: Bool = true) -> some View {
        modifier(Shimmer(active: active))
    }
}

private struct Shimmer: ViewModifier {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    /// Held while a drawer is being dragged or settles: the sweep redraws
    /// -- and re-masks -- every frame it runs, and those frames belong to
    /// the card.
    @Environment(\.drawersStill) private var drawersStill

    func body(content: Content) -> some View {
        if active && !reduceMotion && drawersStill {
            content
                .overlay {
                    GeometryReader { geometry in
                        let width = geometry.size.width
                        LinearGradient(
                            colors: [
                                .clear,
                                Color.accentColor.opacity(0.95),
                                (colorScheme == .dark ? Color(red: 0.28, green: 0.68, blue: 1.0) : .white).opacity(0.9),
                                Color.accentColor.opacity(0.95),
                                .clear,
                            ],
                            startPoint: .leading,
                            endPoint: .trailing,
                        )
                        .frame(width: max(40, width * 0.45))
                        .keyframeAnimator(initialValue: CGFloat(0), repeating: true) { band, phase in
                            band.offset(x: -width * 0.45 + phase * width * 1.45)
                        } keyframes: { _ in
                            CubicKeyframe(1, duration: 1.6)
                            LinearKeyframe(1, duration: 0.6)
                        }
                    }
                    .mask(content)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
        } else {
            content
        }
    }
}
