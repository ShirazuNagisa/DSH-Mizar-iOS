//
//  Motion.swift
//  DSH-Mizar
//
//  How things move, in four springs.
//
//  Springs rather than curves because a spring can be interrupted: retargeted
//  mid-flight it carries its velocity into the new destination instead of
//  restarting, and that -- not speed -- is what makes a touch feel answered.
//  The four are SwiftUI's own (duration, bounce) pairs, named for what they are
//  used for rather than for their numbers:
//
//    snappy  controls answering a tap: chevrons, toggles, highlights
//    smooth  things changing place: rows, sheets of content, the composer
//    bouncy  something arriving that wants to be noticed: a send, a badge
//    gentle  the slow settle of large surfaces and of numbers counting up
//
//  Reduce Motion is honoured the way the app always has: fewer transitions, not
//  shorter ones. Nothing is skipped -- a state still changes, and changes
//  visibly -- but nothing travels; it cross-fades in place.
//

import SwiftUI
import UIKit

extension Animation {
    static let mizarSnappy = Animation.spring(duration: 0.3, bounce: 0)
    static let mizarSmooth = Animation.spring(duration: 0.5, bounce: 0)
    static let mizarBouncy = Animation.spring(duration: 0.45, bounce: 0.18)
    static let mizarGentle = Animation.spring(duration: 0.8, bounce: 0.05)
    /// What every one of them becomes under Reduce Motion.
    static let mizarFade = Animation.easeInOut(duration: 0.22)
}

enum Motion {
    /// Whether the operator asked for less movement.
    ///
    /// Read from UIKit rather than the environment because the callers that need
    /// it are actions, not view bodies, and the environment is not there.
    @MainActor static var reduced: Bool { UIAccessibility.isReduceMotionEnabled }

    /// The animation to use, given the operator's setting.
    @MainActor static func pick(_ animation: Animation) -> Animation {
        reduced ? .mizarFade : animation
    }
}

/// `withAnimation`, with Reduce Motion folded in.
///
/// - Parameters:
///   - animation: the spring to use when movement is welcome.
///   - body: the state change.
@MainActor
func withMizarAnimation<Result>(_ animation: Animation = .mizarSmooth, _ body: () throws -> Result) rethrows -> Result {
    try withAnimation(Motion.pick(animation), body)
}

// MARK: - Drawer motion

/// Whether the shell's drawers are still, for continuous motion that yields
/// to them.
///
/// Decoration that animates for ever -- the shimmer over a running turn's
/// headline, the turning mark, a pulsing glyph -- redraws its layer on
/// every frame it runs. While a drawer is being dragged or is settling,
/// those frames belong to the card the finger is moving: the card carries a
/// full-screen mask, a blurred shadow and glass, and content that changes
/// under those effects cannot be served from cache. So the shell publishes
/// this key, continuous effects read it and hold, and everything resumes the
/// moment the drawers stop -- the same gate the turn index's bar growth
/// already applies.
///
/// The default is `true`: motion is the ordinary state, and anything drawn
/// outside the shell -- a snapshot, a popover that missed the injection --
/// animates exactly as it did before.
private struct DrawersStillKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// Whether the shell's drawers are at rest. `false` while one is being
    /// dragged or is still settling into place.
    var drawersStill: Bool {
        get { self[DrawersStillKey.self] }
        set { self[DrawersStillKey.self] = newValue }
    }

    /// The same fact as an object, for the code that runs between frames.
    ///
    /// The key above is a value: reading it in a body registers a dependency,
    /// so every view that reads it is re-rendered when a drawer starts or
    /// stops. The typewriter's answer is a long Markdown, and re-laying it
    /// out at the moment the finger lands is a frame the card does not move
    /// on -- which reads as a card that does not follow the finger. This one
    /// is an object, so reading it registers nothing: the reveal reads it
    /// between its ticks and the row is not touched.
    var drawerGate: DrawerMotionGate {
        get { self[DrawerGateKey.self] }
        set { self[DrawerGateKey.self] = newValue }
    }
}

/// Whether the shell's drawers are moving, for the code that runs between
/// frames.
///
/// A plain class on purpose: reading it does not register a dependency, so
/// the view that reads it is not re-rendered when a drawer starts or stops.
final class DrawerMotionGate: @unchecked Sendable {
    /// Whether the drawers are at rest.
    ///
    /// Written and read on the main actor only -- the shell moves the
    /// drawers, and the reveal reads between its ticks.
    var still = true
}

private struct DrawerGateKey: EnvironmentKey {
    static let defaultValue = DrawerMotionGate()
}

// MARK: - Transitions

/// Rising into place: a few points of travel, a little blur, and the fade.
///
/// The blur is what makes it read as focus arriving rather than as a box
/// sliding. Under Reduce Motion only the fade is left.
struct RiseTransition: Transition {
    var distance: CGFloat = 10
    var blur: CGFloat = 5

    func body(content: Content, phase: TransitionPhase) -> some View {
        RiseEffect(identity: phase.isIdentity, distance: distance, blur: blur) { content }
    }
}

private struct RiseEffect<Wrapped: View>: View {
    let identity: Bool
    let distance: CGFloat
    let blur: CGFloat
    @ViewBuilder var wrapped: Wrapped
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        wrapped
            .opacity(identity ? 1 : 0)
            .offset(y: identity || reduceMotion ? 0 : distance)
            .blur(radius: identity || reduceMotion ? 0 : blur)
    }
}

/// Settling out of a scale: for things that grow from a point, like a badge or
/// a confirmation capsule.
struct PopTransition: Transition {
    var scale: CGFloat = 0.82

    func body(content: Content, phase: TransitionPhase) -> some View {
        PopEffect(identity: phase.isIdentity, scale: scale) { content }
    }
}

private struct PopEffect<Wrapped: View>: View {
    let identity: Bool
    let scale: CGFloat
    @ViewBuilder var wrapped: Wrapped
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        wrapped
            .opacity(identity ? 1 : 0)
            .scaleEffect(identity || reduceMotion ? 1 : scale)
            .blur(radius: identity || reduceMotion ? 0 : 4)
    }
}

extension Transition where Self == RiseTransition {
    static var rise: RiseTransition { RiseTransition() }
    static func rise(distance: CGFloat, blur: CGFloat = 5) -> RiseTransition {
        RiseTransition(distance: distance, blur: blur)
    }
}

extension Transition where Self == PopTransition {
    static var pop: PopTransition { PopTransition() }
}

/// Rising out of something below, and sinking back into it.
///
/// For the bar of a held prompt above the composer: it arrives from the field's
/// top edge and leaves the same way, so the two surfaces are understood as one
/// thing -- the message was typed there and the bar is where it waits. The blur
/// does the materialising; under Reduce Motion only the fade is left, and
/// nothing travels through the layout.
struct FromBelowTransition: Transition {
    var distance: CGFloat = 24
    var scale: CGFloat = 0.94
    var blur: CGFloat = 8

    func body(content: Content, phase: TransitionPhase) -> some View {
        FromBelowEffect(
            identity: phase.isIdentity,
            distance: distance,
            scale: scale,
            blur: blur,
        ) { content }
    }
}

private struct FromBelowEffect<Wrapped: View>: View {
    let identity: Bool
    let distance: CGFloat
    let scale: CGFloat
    let blur: CGFloat
    @ViewBuilder var wrapped: Wrapped
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let still = identity || reduceMotion
        wrapped
            .opacity(identity ? 1 : 0)
            .offset(y: still ? 0 : distance)
            .scaleEffect(still ? 1 : scale, anchor: .bottom)
            .blur(radius: still ? 0 : blur)
    }
}

extension Transition where Self == FromBelowTransition {
    /// A surface arriving from, and leaving into, the thing under it.
    static var fromBelow: FromBelowTransition { FromBelowTransition() }
}

// MARK: - Haptics

/// The switch every haptic in the app answers to.
///
/// Stored with `@AppStorage` under this key: on by default, and a feedback the
/// operator switched off is not played anywhere -- one switch, read at the
/// moment of the event, so it takes effect without a relaunch.
enum Haptics {
    static let storageKey = "mizar.haptics"

    static var enabled: Bool {
        UserDefaults.standard.object(forKey: storageKey) as? Bool ?? true
    }
}

extension View {
    /// `sensoryFeedback`, gated by the operator's haptics switch.
    ///
    /// - Parameters:
    ///   - feedback: what to play.
    ///   - trigger: the value whose change plays it.
    ///   - when: an extra condition on the old and new values.
    func mizarFeedback<T: Equatable>(
        _ feedback: SensoryFeedback,
        trigger: T,
        when: @escaping (T, T) -> Bool = { _, _ in true },
    ) -> some View {
        sensoryFeedback(feedback, trigger: trigger) { old, new in
            Haptics.enabled && when(old, new)
        }
    }
}
