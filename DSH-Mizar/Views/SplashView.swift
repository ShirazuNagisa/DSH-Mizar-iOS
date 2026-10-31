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

    /// How far the mark has come towards the camera. 1 is the resting size.
    /// How large the transparent hole is, as a multiple of the mark's own size.
    /// 1 is "exactly under the mark"; 30 is past the edges of any screen.
    @State private var hole: CGFloat = 1
    /// The opaque mark's opacity. It is what makes the icon opaque; the moment
    /// it reaches zero the icon is a hole.
    @State private var mark: Double = 1
    /// The wind-up before the push.
    @State private var windUp: CGFloat = 1
    /// Whether the turn has stopped, so the push is a still shape.
    @State private var leaving = false
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
    /// How long the camera takes to reach the mark's arms.
    private static let push = Duration.milliseconds(760)

    /// Whether a launch asked for no splash at all.
    ///
    /// The UI suite launches the app dozens of times and looks for the first
    /// control within a few seconds; a splash that covers the screen while the
    /// first read is in flight is a splash those tests race. The app the
    /// operator opens has it; the app the tests drive does not.
    private static var skipped: Bool {
        ProcessInfo.processInfo.arguments.contains("-mizarSkipSplash")
    }

    var body: some View {
        ZStack {
            // The page. It is drawn full-screen and behind everything the app
            // puts up, so what the operator sees during the hold is this and
            // nothing else.
            // The page, as a background rather than a sibling: a full-screen
            // opaque sibling in a ZStack sits above the mark when the stack is
            // laid out over the whole window, which is how a splash ended up
            // being a blank page with a mark hidden behind it.
            Color.clear
            // The mark. It spins while the app is getting ready, and it is what
            // the camera travels through.
            // The mark, as pixels: see ``SplashMark`` for why it is not the
            // live view here.
            Image(uiImage: SplashMark.image)
                .resizable()
                .interpolation(.high)
                .frame(width: 120, height: 120)
                .scaleEffect(hole)
                .opacity(mark)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.paneBackground)
        .ignoresSafeArea()
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
            // And then the hold, counted from the first frame rather than from
            // the answer: a fast launch must not make the mark invisible.
            let earliest = started + Self.hold
            if ContinuousClock.now < earliest {
                try? await Task.sleep(until: earliest, clock: .continuous)
            }
            // 1. The icon becomes transparent: the mark leaves, the hole stays
            //    exactly where it was, so nothing moves and nothing blinks.
            leaving = true
            withAnimation(.easeOut(duration: 0.18)) { mark = 0 }
            try? await Task.sleep(for: .milliseconds(190))
            // 2. The wind-up: a small pull back, which is what makes the push
            //    read as acceleration rather than as a zoom that was already
            //    running.
            withAnimation(.easeIn(duration: 0.16)) { windUp = 0.92 }
            try? await Task.sleep(for: .milliseconds(170))
            // 3. Through it. The hole opens past the edges of the frame on an
            //    accelerating curve -- a camera, not a growing shape.
            withAnimation(.easeIn(duration: 0.62)) { hole = 30 }
            try? await Task.sleep(for: .milliseconds(640))
            onFinished()
        }
        .accessibilityHidden(true)
    }
}
