//
//  SplashView.swift
//  DSH-Mizar
//
//  The first second of the app: the mark, turning, and then a camera through it.
//
//  A cold launch has nothing to show yet -- the session store is being read and
//  the socket is being dialled -- and a screen that fills in later is a screen
//  that flickers. So the app opens on the mark alone, turning at the same speed
//  the rest of the app uses for waiting, and leaves when the work is done: the
//  mark fades as it comes at the camera, so the last thing the splash shows is
//  the inside of the icon and the first thing the app shows is the page behind
//  it. The shape is the icon's, so the two halves of that cut are the same
//  drawing at two scales rather than a cut between two pictures.
//
//  The turn is the app's own `running` motion, which is linear and endless --
//  a launch of any length looks the same, and the loop's seam is invisible
//  because a whole turn per cycle starts where it ended.
//
//  Nothing here is a network state. The splash waits for `phase` to leave the
//  launching ones, and gives up after a few seconds whatever the phase says:
//  a splash that waits on a computer that is not answering would be a splash
//  that never ends.
//

import SwiftUI

/// The cold-launch splash: the mark, then the camera through it.
struct SplashView: View {
    /// Called once, when the splash has nothing left to cover.
    var onFinished: () -> Void = {}

    @Environment(AppModel.self) private var model
    /// Which appearance the mark is drawn in.
    @Environment(\.colorScheme) private var colorScheme

    /// How far the mark has come towards the camera. 1 is the resting size.
    /// How visible the page is, so it can leave rather than cut.
    @State private var fade: Double = 1
    /// How far the two layers have turned, in degrees. One revolution takes the
    /// same nine seconds the app's running mark takes, so the splash and the
    /// rows behind it are the same motion at two sizes.
    @State private var angle: Double = 0
    /// How long the wait for the app is allowed to last.
    private static let patience = Duration.seconds(6)
    /// How long the mark is held before the camera starts, whatever the app is
    /// doing.
    ///
    /// This is the whole difference between a splash and a flicker. The first
    /// version left as soon as the phase was an answer -- which, on a launch
    /// with a stored session, is the first frame -- so the screen the operator
    /// saw was a single frame of a star that had not turned yet, and the launch
    /// read as "there is no splash". X holds its mark long enough to be read.
    private static let hold = Duration.milliseconds(1100)

    /// Whether a launch asked for no splash at all.
    ///
    /// The UI suite launches the app dozens of times and looks for the first
    /// control within a few seconds; a splash that covers the screen while the
    /// first read is in flight is a splash those tests race. The app the
    /// operator opens has it; the app the tests drive does not.
    /// The mark, drawn from its two baked layers for this appearance.
    ///
    /// - Parameter size: the box's edge, in points.
    private func mark(size: CGFloat) -> some View {
        let layers = SplashMark.layers(for: colorScheme)
        return ZStack {
            Image(uiImage: layers.back)
                .resizable()
                .interpolation(.high)
                .rotationEffect(.degrees(-angle))
            Image(uiImage: layers.front)
                .resizable()
                .interpolation(.high)
                .rotationEffect(.degrees(angle))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private static var skipped: Bool {
        ProcessInfo.processInfo.arguments.contains("-mizarSkipSplash")
    }

    var body: some View {
        ZStack {
            Theme.paneBackground
                .ignoresSafeArea()
            // One mark, turning: the icon, at the size the icon would be if it
            // were the whole screen. The two layers are the appearance's own --
            // the blue pair on a light screen, the white pair on a dark one --
            // which is why they are drawn per appearance rather than tinted.
            mark(size: 108)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.paneBackground)
        .opacity(fade)
        .ignoresSafeArea()
        // Constant speed, not eased: the mark is a clock, and a clock that
        // accelerates is a clock that looks broken.
        .onAppear {
            withAnimation(.linear(duration: StarMetrics.revolution).repeatForever(autoreverses: false)) {
                angle = 360
            }
        }
        .task {
            if Self.skipped {
                onFinished()
                return
            }
            let started = ContinuousClock.now
            // Wait for the app to have something to show. The phases that mean
            // "still finding out" are the launching ones; anything else is an
            // answer, even if the answer is that there is no computer.
            let deadline = started + Self.patience
            while ContinuousClock.now < deadline {
                if model.phase != .launching, !(model.phase == .connecting && model.host == nil) {
                    break
                }
                try? await Task.sleep(for: .milliseconds(80))
            }
            // A beat, counted from the first frame rather than from the answer,
            // so a fast launch does not make the mark a flicker.
            let earliest = started + Self.hold
            if ContinuousClock.now < earliest {
                try? await Task.sleep(until: earliest, clock: .continuous)
            }
            withAnimation(.easeOut(duration: 0.28)) { fade = 0 }
            try? await Task.sleep(for: .milliseconds(300))
            onFinished()
        }
        .accessibilityHidden(true)
    }
}
