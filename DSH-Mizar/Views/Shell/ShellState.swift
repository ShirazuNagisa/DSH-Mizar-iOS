//
//  ShellState.swift
//  DSH-Mizar
//
//  Where the two drawers are, as one number.
//
//  `progress` runs from -1 to 1. At 0 the conversation is in front. Towards 1
//  the workspace sidebar comes out on the left and the conversation is pushed
//  right as a card; towards -1 the turn index comes out on the right and the
//  card is pushed left -- the same gesture, mirrored. One signed number rather
//  than two, so the two drawers can never both be out, and a drag that starts
//  with one closed simply decides by its direction which one it is opening.
//
//  Everything that moves -- the card's offset, its scale, its corner, the shade
//  over it, the toggle's glyph -- is a function of this one value, so a finger
//  dragging it and a spring settling it move every piece together and nothing
//  can get out of step.
//
//  The settle is velocity-matched: a flick carries its speed into the spring, so
//  the card leaves the finger at the speed it was thrown rather than stopping
//  and starting again.
//
//  Nothing in SwiftUI follows `progress`. The surfaces that draw it -- the
//  shell's UIKit container and the toggle's glyph -- attach here and are told
//  directly: while a finger moves, once per display frame from the short spring
//  that follows it; for a settle, once, as the whole path of the spring, which
//  they hand to Core Animation so the render server plays it. A SwiftUI value
//  that changed on every frame re-rendered the whole hosted tree under it --
//  eight milliseconds and more a frame on an iPhone 16 Pro, which held the
//  drawers to 60 Hz -- and an animation SwiftUI handed off on its own could be
//  left drawn half way when the main thread was busy at the wrong moment.
//

import SwiftUI

@MainActor
@Observable
final class ShellState {
    enum Side: Equatable {
        /// The workspace sidebar, on the left.
        case leading
        /// The turn index, on the right.
        case trailing
    }

    /// -1 the index out, 0 closed, 1 the sidebar out: where the drawers are
    /// drawn, or for a settle, where they are going. Values a little beyond
    /// either end while dragging are the rubber band. Not observed: nothing
    /// in SwiftUI may follow it frame by frame (see the top of this file).
    @ObservationIgnored private(set) var progress: CGFloat = 0
    /// Where `progress` is heading: the finger's position while dragging, the
    /// destination while settling. Every decision is made on this.
    @ObservationIgnored private var goal: CGFloat = 0
    @ObservationIgnored private let motion = DrawerMotion()
    /// What draws the drawers.
    @ObservationIgnored private var surfaces: [WeakSurface] = []
    /// Whether a finger is on it right now.
    private(set) var isDragging = false
    /// Whether a spring is still carrying a drawer to its destination.
    ///
    /// A window presented *out of* a control must not come out while that
    /// control is moving. The one-time naming prompt is anchored to either the
    /// computer's name or the sidebar button, and a launch presented it during
    /// the sidebar's close: it dismissed itself under the finger before it could
    /// be answered, and the test that taps it caught a window with no buttons.
    /// The spring's duration is the moment this becomes false again.
    private(set) var isSettling = false
    private var settleGeneration = 0
    /// Which drawer the last settle left out, for the haptic and VoiceOver.
    private(set) var settled: Side?
    /// On a regular width the sidebar sits beside the conversation rather than
    /// under it; this is whether it is showing there.
    var pinnedVisible = true
    /// The same for the turn index, which on a regular width is a column of its
    /// own on the right.
    var indexPinnedVisible = false
    /// Whether there is a turn index to open: there is none on the home screen.
    var trailingAvailable = false
    /// How wide each drawer is, so a drag is measured in drawers.
    var leadingWidth: CGFloat = 320
    var trailingWidth: CGFloat = 300
    /// The whole window's width, for deciding whether both columns fit.
    var containerWidth: CGFloat = 1000
    /// The narrowest the conversation may be squeezed to by the iPad's columns
    /// before one of them steps aside for the other.
    private static let narrowestConversation: CGFloat = 460

    /// Whether both iPad columns fit beside a readable conversation.
    private var bothColumnsFit: Bool {
        containerWidth - leadingWidth - trailingWidth >= Self.narrowestConversation
    }
    /// Which workspaces are open, per computer, for the life of the process.
    ///
    /// Collapsed is the default -- the set starts empty -- because a list of
    /// five workspaces each holding a dozen sessions is not a list anybody can
    /// read. Kept here rather than in the sidebar so that a switch to another
    /// computer and back finds its groups as they were left.
    private var expandedByHost: [String: Set<String>] = [:]

    private var dragOrigin: CGFloat = 0

    init() {
        motion.write = { [weak self] value in self?.show(value) }
    }

    /// Whether the sidebar is the one out.
    var settledOpen: Bool { settled == .leading }
    /// Whether the turn index is the one out.
    var trailingOpen: Bool { settled == .trailing }

    // MARK: Opening and closing

    func open() { settle(to: 1) }
    func openTrailing() {
        guard trailingAvailable else { return }
        settle(to: -1)
    }
    func close() { settle(to: 0) }

    func toggle(compact: Bool) {
        if compact {
            settle(to: settledOpen ? 0 : 1)
        } else {
            withMizarAnimation(.mizarSmooth) {
                pinnedVisible.toggle()
                // On a window too narrow for both, the column coming in asks
                // the other to step aside -- the way Mail trades its sidebar
                // for the message list.
                if pinnedVisible, !bothColumnsFit { indexPinnedVisible = false }
            }
        }
    }

    func toggleTrailing(compact: Bool) {
        if compact {
            if trailingOpen { close() } else { openTrailing() }
        } else {
            withMizarAnimation(.mizarSmooth) {
                indexPinnedVisible.toggle()
                if indexPinnedVisible, !bothColumnsFit { pinnedVisible = false }
            }
        }
    }

    /// Put it somewhere without animating, for the first frame.
    func place(open: Bool) {
        goal = open ? 1 : 0
        motion.stop()
        stopPlaying()
        show(goal)
        settled = open ? .leading : nil
        settleGeneration &+= 1
        isSettling = false
    }

    // MARK: Dragging

    /// Whether a horizontal drag in this direction can change the drawers.
    ///
    /// One sign, one answer: a drawer that is already out can only be put
    /// away, and a closed shell can open the sidebar to the right or the turn
    /// index to the left. The pan asks this when the axis first becomes clear,
    /// not once per touch, so a gesture can be reversed during an animation.
    ///
    /// - Parameter dx: positive towards the sidebar, negative towards the index.
    /// - Returns: whether the shell should take the drag.
    func canDrag(towards dx: CGFloat) -> Bool {
        if goal > 0.01 {
            // Sidebar out or arriving: only left puts it back.
            return dx < 0
        }
        if goal < -0.01 {
            // Index out or arriving: only right puts it back.
            return dx > 0
        }
        return dx > 0 || trailingAvailable
    }

    func beginDrag() {
        isDragging = true
        dragOrigin = goal
        // The finger takes the card over from the spring.
        settleGeneration &+= 1
        isSettling = false
        resignKeyboard()
    }

    /// Follow the finger.
    ///
    /// - Parameter points: the horizontal translation since the drag began.
    func drag(by points: CGFloat) {
        let raw = dragOrigin + fraction(points)
        // A drag that started with a drawer out may close it but not carry on
        // through into the other one; a drag that started closed may open
        // either, the index only where there is one.
        let low: CGFloat = dragOrigin > 0.01 || !trailingAvailable ? 0 : -1
        let high: CGFloat = dragOrigin < -0.01 ? 0 : 1
        // Past either end the card still moves, less the further it goes: the
        // edge is felt, not hit.
        let banded: CGFloat
        if raw > high {
            banded = high + rubberBand(raw - high)
        } else if raw < low {
            banded = low - rubberBand(low - raw)
        } else {
            banded = raw
        }
        // A very short spring rather than an assignment: grabbing the card
        // while it is still settling blends from where it is drawn instead of
        // jumping to where the model says it is.
        goal = banded
        if let state = motion.interruptPath() {
            stopPlaying()
            motion.follow(to: banded, from: state.position, velocity: state.velocity)
        } else {
            motion.follow(to: banded, from: progress, velocity: 0)
        }
    }

    /// Let go.
    ///
    /// - Parameter velocity: the finger's speed in points per second.
    func endDrag(velocity: CGFloat) {
        isDragging = false
        let speed = fraction(velocity)
        // Where a flick would carry it, a tenth of a second on. Deciding on the
        // projection rather than the position is what lets a short quick flick
        // open a drawer and a long slow drag that changes its mind close it.
        let projected = goal + speed * 0.12
        let target: CGFloat
        // A flick that closes one drawer never throws the card on into the
        // other: only a drag that began closed, or on that side, may end there.
        if projected > 0.5, dragOrigin > -0.01 {
            target = 1
        } else if projected < -0.5, trailingAvailable, dragOrigin < 0.01 {
            target = -1
        } else {
            target = 0
        }
        settle(to: target, velocity: speed)
    }

    // MARK: Drawing

    /// Draw the drawers from now on, starting where they are.
    func attach(_ surface: DrawerSurface) {
        surfaces.removeAll { $0.surface == nil || $0.surface === surface }
        surfaces.append(WeakSurface(surface: surface))
        surface.show(progress: progress)
    }

    private func show(_ value: CGFloat) {
        progress = value
        for entry in surfaces { entry.surface?.show(progress: value) }
    }

    private func play(_ path: DrawerPath) {
        progress = path.target
        for entry in surfaces { entry.surface?.play(path) }
    }

    private func stopPlaying() {
        for entry in surfaces { entry.surface?.stopPlaying() }
    }

    /// Points as a fraction of the drawer they move.
    private func fraction(_ points: CGFloat) -> CGFloat {
        // The side is the one the card is already towards, or the one the
        // finger is heading for when it is closed.
        let towardsTrailing = goal < -0.001 || (abs(goal) <= 0.001 && points < 0)
        return points / max(1, towardsTrailing ? trailingWidth : leadingWidth)
    }

    /// - Parameter velocity: the finger's, in progress per second, when thrown;
    ///   `nil` keeps whatever speed the drawers already have.
    private func settle(to target: CGFloat, velocity: CGFloat? = nil) {
        // From where the drawers are drawn right now and as fast as they are
        // moving: mid-drag, mid-settle or still.
        let now = motion.interruptPath() ?? motion.stopFollowing() ?? (position: progress, velocity: 0)
        let distance = target - now.position
        // At most thirty whole journeys per second, as the spring's initial
        // velocity always was.
        let limit = 30 * abs(distance)
        let speed = velocity ?? now.velocity
        let launch = abs(distance) > 0.001 ? max(-limit, min(limit, speed)) : 0
        if target != 0 { resignKeyboard() }
        goal = target
        stopPlaying()
        let path = DrawerPath(from: now.position, to: target, velocity: launch, reduced: Motion.reduced)
        motion.playing(path)
        if path.samples.count > 1 {
            play(path)
        } else {
            show(target)
        }
        settled = target > 0.5 ? .leading : (target < -0.5 ? .trailing : nil)
        // The spring is "still moving" until it has arrived. A newer settle, a
        // drag, or the first frame placing the card invalidates this one's
        // countdown, so only the last spring decides when the drawers are still.
        settleGeneration &+= 1
        let generation = settleGeneration
        isSettling = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(520))
            guard settleGeneration == generation, !isDragging else { return }
            isSettling = false
        }
    }

    private func rubberBand(_ overshoot: CGFloat) -> CGFloat {
        let limit: CGFloat = 0.08
        return limit * (1 - 1 / (overshoot * 3 / limit + 1))
    }

    private func resignKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    // MARK: Workspaces

    func expanded(for hostId: String?) -> Set<String> {
        expandedByHost[hostId ?? ""] ?? []
    }

    func setExpanded(_ expanded: Set<String>, for hostId: String?) {
        expandedByHost[hostId ?? ""] = expanded
    }
}

// MARK: - The springs

/// Something that draws the drawers: the shell's container, the toggle's glyph.
@MainActor
protocol DrawerSurface: AnyObject {
    /// Draw the drawers at this progress, now, without animating.
    func show(progress: CGFloat)
    /// Hand a settle to Core Animation: draw the model at the path's end and
    /// play the path's samples from its begin time.
    func play(_ path: DrawerPath)
    /// Stop a settle that is playing. The caller shows where it was next.
    func stopPlaying()
}

private struct WeakSurface {
    weak var surface: DrawerSurface?
}

/// A settle, as a curve: where the drawers are at every instant from its
/// begin time, and the same curve sampled once per 120 Hz frame for Core
/// Animation to play.
///
/// The spring is the one SwiftUI ran, `interpolatingSpring(duration: 0.42,
/// bounce: 0)`: critically damped, so it has a closed form and the drawers'
/// position and speed at any instant are exact -- which is what lets a finger
/// take the card over mid-flight without a jump. Under Reduce Motion it is
/// `mizarFade`'s ease in and out over 0.22 s.
struct DrawerPath {
    static let rate: Double = 120
    private static let omega = 2 * Double.pi / 0.42
    private static let fadeDuration: Double = 0.22

    let start: CGFloat
    let target: CGFloat
    let velocity: CGFloat
    let reduced: Bool
    let beginTime: CFTimeInterval
    let duration: CFTimeInterval
    /// One value per frame, from `beginTime`; the last is `target`.
    let samples: [CGFloat]

    init(from start: CGFloat, to target: CGFloat, velocity: CGFloat, reduced: Bool) {
        self.start = start
        self.target = target
        self.velocity = reduced ? 0 : velocity
        self.reduced = reduced
        beginTime = CACurrentMediaTime()
        var duration: Double = 0
        if abs(Double(target - start)) > 0.0005 || abs(Double(velocity)) > 0.02 {
            if reduced {
                duration = Self.fadeDuration
            } else {
                // Until it is within half a thousandth and nearly still, as the
                // display-link spring stopped; never more than two seconds.
                let step = 1 / Self.rate
                var t = step
                while t < 2 {
                    let (x, v) = Self.spring(start - target, self.velocity, at: t)
                    if abs(x) < 0.0005, abs(v) < 0.02 { break }
                    t += step
                }
                duration = t
            }
        }
        let frames = Int((duration * Self.rate).rounded(.up))
        self.duration = Double(frames) / Self.rate
        var samples: [CGFloat] = []
        samples.reserveCapacity(frames + 1)
        for frame in 0...frames {
            samples.append(frame == frames ? target : CGFloat(Self.value(
                start: start, target: target, velocity: self.velocity, reduced: reduced,
                at: Double(frame) / Self.rate,
            ).position))
        }
        self.samples = samples
    }

    /// Where the drawers are, and how fast they move, at a media time.
    func state(at time: CFTimeInterval) -> (position: CGFloat, velocity: CGFloat) {
        let t = time - beginTime
        guard t < duration else { return (target, 0) }
        let state = Self.value(start: start, target: target, velocity: velocity, reduced: reduced, at: max(0, t))
        return (CGFloat(state.position), CGFloat(state.velocity))
    }

    var endTime: CFTimeInterval { beginTime + duration }

    private static func value(
        start: CGFloat,
        target: CGFloat,
        velocity: CGFloat,
        reduced: Bool,
        at t: Double,
    ) -> (position: Double, velocity: Double) {
        if reduced {
            let u = min(1, max(0, t / fadeDuration))
            let eased = u < 0.5 ? 2 * u * u : 1 - pow(-2 * u + 2, 2) / 2
            let slope = (u < 0.5 ? 4 * u : 2 * (-2 * u + 2)) / fadeDuration
            let distance = Double(target - start)
            return (Double(start) + distance * eased, distance * slope)
        }
        let (x, v) = spring(start - target, velocity, at: t)
        return (Double(target) + x, v)
    }

    /// The critically damped spring's offset from rest and its speed.
    private static func spring(_ x0: CGFloat, _ v0: CGFloat, at t: Double) -> (Double, Double) {
        let a = Double(x0)
        let b = Double(v0) + omega * a
        let decay = exp(-omega * t)
        return ((a + b * t) * decay, (b - omega * (a + b * t)) * decay)
    }
}

/// The short spring that follows a finger, stepped once per display frame,
/// and the bookkeeping of the settle Core Animation is playing.
///
/// The follow spring is the one SwiftUI used to run under the finger,
/// `interactiveSpring(response: 0.14, dampingFraction: 0.86)`. A frame that
/// arrives late is stepped through the time it missed, so a stall costs frames,
/// never the destination.
@MainActor
private final class DrawerMotion: NSObject {
    private static let omega = 2 * Double.pi / 0.14
    private static let damping = 0.86

    /// Where each frame goes.
    var write: (CGFloat) -> Void = { _ in }

    private var link: CADisplayLink?
    private var position: Double = 0
    private var velocity: Double = 0
    private var target: Double = 0
    private var lastTime: CFTimeInterval?
    private var path: DrawerPath?

    /// Chase a finger: retarget the short spring, keeping the speed it has.
    func follow(to target: CGFloat, from drawn: CGFloat, velocity: CGFloat) {
        if link == nil {
            position = Double(drawn)
            self.velocity = Double(velocity)
        }
        self.target = Double(target)
        start()
    }

    /// Stop following, and say where the drawers were and how fast.
    func stopFollowing() -> (position: CGFloat, velocity: CGFloat)? {
        guard link != nil else { return nil }
        stop()
        return (CGFloat(position), CGFloat(velocity))
    }

    /// Remember a settle Core Animation is now playing.
    func playing(_ path: DrawerPath) {
        stop()
        self.path = path
    }

    /// End a settle that is still playing, and say where it had got to.
    func interruptPath() -> (position: CGFloat, velocity: CGFloat)? {
        guard let path else { return nil }
        self.path = nil
        let now = CACurrentMediaTime()
        guard now < path.endTime else { return nil }
        return path.state(at: now)
    }

    func stop() {
        link?.invalidate()
        link = nil
        lastTime = nil
        path = nil
    }

    private func start() {
        path = nil
        guard link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(step(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        // Common modes: a drag is a tracking run loop, and the card moves
        // under it.
        link.add(to: .main, forMode: .common)
        self.link = link
        lastTime = CACurrentMediaTime()
    }

    @objc private func step(_ link: CADisplayLink) {
        let now = link.targetTimestamp
        let elapsed = min(0.25, max(0, now - (lastTime ?? now)))
        lastTime = now
        // Small fixed steps: a frame that came late is the same curve, only
        // sampled less often.
        let count = max(1, Int((elapsed / 0.001).rounded(.up)))
        let h = elapsed / Double(count)
        let stiffness = Self.omega * Self.omega
        let friction = 2 * Self.damping * Self.omega
        for _ in 0..<count {
            let acceleration = -stiffness * (position - target) - friction * velocity
            velocity += acceleration * h
            position += velocity * h
        }
        // The spring keeps running while the finger holds still, so that the
        // speed a release reads is the speed the card is moving at. It rests
        // on the target once it has arrived and costs nothing until the next
        // move.
        if abs(position - target) < 0.0005, abs(velocity) < 0.02 {
            position = target
            velocity = 0
            link.invalidate()
            self.link = nil
            lastTime = nil
        }
        write(CGFloat(position))
    }
}
