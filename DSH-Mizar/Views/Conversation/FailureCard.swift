//
//  FailureCard.swift
//  DSH-Mizar
//
//  The prominent state for a turn that produced nothing.
//

import SwiftUI

/// A turn that produced nothing.
///
/// Internal rather than private so the snapshot suite can render it from a
/// fixture (`ComposerLanguageSnapshotTests`), the way `CommandList` is: it owns
/// no environment, and a failure older than twenty seconds never arms the
/// shake, so a fixture renders the resting card.
struct FailureCard: View {
    let message: String
    /// When the turn failed. Only a failure that just happened shakes: one
    /// scrolled back into view is news nobody needs announced twice.
    let at: Date
    @State private var shakes = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("The turn ended without a response", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.failed)
            Text(message)
                .font(.caption)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.failed.opacity(0.09), in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                .strokeBorder(Theme.failed.opacity(0.28), lineWidth: 1)
        }
        // A small shake when it first comes on screen: two swings of four points,
        // the "no" of a head being shaken. Still under Reduce Motion.
        .keyframeAnimator(initialValue: CGFloat(0), trigger: shakes) { content, x in
            content.offset(x: x)
        } keyframes: { _ in
            KeyframeTrack {
                CubicKeyframe(4, duration: 0.07)
                CubicKeyframe(-4, duration: 0.1)
                CubicKeyframe(3, duration: 0.1)
                CubicKeyframe(-2, duration: 0.09)
                CubicKeyframe(0, duration: 0.09)
            }
        }
        .onAppear {
            guard !Motion.reduced, Date().timeIntervalSince(at) < 20 else { return }
            shakes += 1
        }
    }
}
