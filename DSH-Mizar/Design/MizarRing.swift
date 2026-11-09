//
//  MizarRing.swift
//  DSH-Mizar
//
//  The app's mark: five round-capped arcs on one circle, drawn clockwise from
//  the gap at the top. It is the owner's new icon, and it is the same five arcs
//  the macOS, iOS and Live Activity assets are cut from -- the geometry below is
//  where the phone's mark and the icon agree instead of merely resembling each
//  other.
//
//  ### Why the mark is a ring of unequal pieces
//
//  The icon is not a generic spinner: the long right-hand arc, the three short
//  arcs down the left, and the dot at ten o'clock are one drawing. So the
//  motions are the drawing's own pieces, not a rotating copy of it. A spinner
//  that turned the whole icon would be a different mark every frame; this one
//  fills itself clockwise and then lets itself go, and every frame is the icon
//  in some state of being drawn.
//
//  ### The motions
//
//  `running` is the loading loop, in four stages plus a breath:
//
//    A. five dots appear clockwise, with a soft scale/opacity fade;
//    B. each dot grows into its final arc **from its own start**, so the dot
//       becomes the arc's round start cap instead of moving elsewhere;
//    C. the finished icon holds for a beat;
//    D. the arcs shrink back into dots, then the dots shrink and fade.
//
//  This is not a Windows 10 copy. That spinner supplied the rhythm: a
//  clockwise cascade, one element at a time, with air between the beats. The
//  dot→arc morph, the local overshoot, and the different curves for growth and
//  shrink are this mark's own. Nothing rotates as a whole.
//
//  `once` is for arriving: the full icon holds for a beat, the pieces erase
//  clockwise, and then they load back in. It starts and ends on the static
//  icon, so it can play over a screen whose mark is the icon without a jump.
//
//  `opening` is a reading, not decoration: the ring fills clockwise from the
//  gap, so `0` is an empty track and `1` is the icon. It still follows progress
//  under Reduce Motion, because hiding the progress would hide the download.
//
//  Reduce Motion parks `running` and `once` on the icon;
//  `opening` keeps
//  following its fraction.
//

import SwiftUI

// MARK: - Geometry

/// One piece of the ring: a clockwise arc, or the dot when `sweep` is zero.
struct RingSegment: Sendable, Equatable {
    /// Degrees clockwise from three o'clock.
    var start: Double
    /// Degrees the arc covers. Zero means a dot at `start`.
    var sweep: Double

    /// Whether this piece is the round dot rather than an arc.
    var isDot: Bool { sweep <= 0 }
}

/// The mark's numbers, measured from the owner's transparent masters.
///
/// The sources are 706 and 740 pixels square; their centreline radius is
/// 0.385–0.386 of the box and their stroke is 0.078–0.092, depending on the
/// appearance. The values here are the shared middle the two appearances both
/// accept, and the same values are in `icon-design/masters/mizar-icon/
/// ring_geometry.py` for the raster assets. Change one, change both.
enum RingGeometry {
    /// Centreline radius, as a fraction of the mark's box.
    static let radius: CGFloat = 0.385
    /// Stroke width, as a fraction of the mark's box.
    static let stroke: CGFloat = 0.086

    /// The outer edge of the stroke, as a fraction of the box.
    static var outer: CGFloat { radius + stroke / 2 }
    /// The drawn mark's width, as a fraction of the box.
    static var inkShare: CGFloat { outer * 2 }

    /// The five pieces, in the order the loading motion reveals them: long arc,
    /// bottom, lower-left, left, dot. All five are clockwise from the gap at
    /// 270 degrees, so this order is also their angular order.
    static let segments: [RingSegment] = [
        RingSegment(start: 270, sweep: 137),
        RingSegment(start: 70, sweep: 39),
        RingSegment(start: 131, sweep: 32),
        RingSegment(start: 186, sweep: 20),
        RingSegment(start: 230, sweep: 0),
    ]

    /// The gap's clockwise side: where the clock hand starts.
    static let seam: Double = 270

    /// How far clockwise a piece begins, measured from the seam.
    ///
    /// - Parameter segment: one of ``segments``.
    /// - Returns: degrees in `0..<360`.
    static func position(of segment: RingSegment) -> Double {
        let value = (segment.start - seam).truncatingRemainder(dividingBy: 360)
        return value < 0 ? value + 360 : value
    }

    /// A clockwise circular arc as cubic curves.
    ///
    /// `Path.addArc`'s `clockwise` flag means different things in different
    /// coordinate systems; this helper has no such ambiguity. Angles are
    /// degrees, zero at three o'clock, increasing **clockwise on screen**
    /// (because the view's y axis points down). The four-control-point form is
    /// exact for a circular arc of at most ninety degrees.
    ///
    /// - Parameters:
    ///   - center: the circle's centre in the view's coordinates.
    ///   - radius: the circle's radius.
    ///   - start: degrees where the arc begins.
    ///   - end: degrees where it ends. Values below `start` are not wrapped;
    ///     callers pass the positive sweep.
    /// - Returns: a path along the centreline, ready to stroke.
    static func arcPath(center: CGPoint, radius: CGFloat, start: Double, end: Double) -> Path {
        guard end != start else { return Path() }
        // Callers name the long arc's end as 47 even though it begins at 270;
        // take the clockwise way round rather than a negative sweep.
        let target = end < start ? end + 360 : end
        var path = Path()
        path.move(to: CGPoint(
            x: center.x + radius * CGFloat(cos(start * .pi / 180)),
            y: center.y + radius * CGFloat(sin(start * .pi / 180)),
        ))
        var cursor = start
        var remaining = target - start
        while remaining > 0.0001 {
            let step = min(remaining, 90)
            let a = cursor * .pi / 180
            let b = (cursor + step) * .pi / 180
            let p0 = CGPoint(
                x: center.x + radius * CGFloat(cos(a)),
                y: center.y + radius * CGFloat(sin(a)),
            )
            let p3 = CGPoint(
                x: center.x + radius * CGFloat(cos(b)),
                y: center.y + radius * CGFloat(sin(b)),
            )
            let k = 4.0 / 3.0 * tan((b - a) / 4)
            let t0 = CGPoint(x: CGFloat(-sin(a)), y: CGFloat(cos(a)))
            let t3 = CGPoint(x: CGFloat(-sin(b)), y: CGFloat(cos(b)))
            let c1 = CGPoint(
                x: p0.x + radius * CGFloat(k * t0.x),
                y: p0.y + radius * CGFloat(k * t0.y),
            )
            let c2 = CGPoint(
                x: p3.x - radius * CGFloat(k * t3.x),
                y: p3.y - radius * CGFloat(k * t3.y),
            )
            path.addCurve(to: p3, control1: c1, control2: c2)
            cursor += step
            remaining -= step
        }
        return path
    }
}

// MARK: - The clockwise queue

/// The five pieces as one queue on the ring.
///
/// The queue is what makes this one object instead of five independent dots:
/// each element starts at the previous element's end plus the same gap the
/// finished icon has. Growing an element therefore pushes every element behind
/// it clockwise; shrinking releases that space again.
enum RingQueue {
    static let count = RingGeometry.segments.count
    static let dotIndex = count - 1

    /// Starts in the finished icon, normalised to `0..<360`.
    static let finalStarts: [Double] = RingGeometry.segments.map {
        normalized($0.start)
    }

    /// Arc lengths in the finished icon. The fifth element is the dot (0).
    static let finalLengths: [Double] = RingGeometry.segments.map(\.sweep)

    /// The four gaps between consecutive elements, **measured from the
    /// finished icon**. The elements keep these gaps as they grow, so the
    /// spacing is the icon's own, not an arbitrary spinner spacing.
    static let gaps: [Double] = (0..<4).map { index in
        let current = RingGeometry.segments[index]
        let next = RingGeometry.segments[index + 1]
        return normalized(next.start - (current.start + current.sweep))
    }

    /// The queue at rest: five dots near twelve o'clock, each start pushed
    /// forward by the final gaps. The rear-most dot is position A.
    static let initialStarts: [Double] = {
        var starts = [270.0]
        for index in 0..<4 {
            starts.append(starts[index] + gaps[index])
        }
        return starts
    }()

    /// Unwrapped starts in the finished icon, anchored at the long arc's
    /// `270°`. The first element is the long arc; the fifth is the dot.
    static let finalStartsUnwrapped: [Double] = {
        var starts = [270.0]
        for index in 0..<4 {
            starts.append(starts[index] + finalLengths[index] + gaps[index])
        }
        return starts
    }()

    /// Where each arc's shrinking start ends up: the arc's final end.
    static let finalEnds: [Double] = (0..<count).map { index in
        finalStartsUnwrapped[index] + finalLengths[index]
    }

    /// The renderer's offset from each piece's finished start to its place in
    /// the initial queue.
    static let initialOffsets: [Double] = (0..<count).map {
        initialStarts[$0] - finalStarts[$0]
    }

    /// Position A: the rear-most dot in the initial queue.
    static var positionA: Double { initialStarts[dotIndex] }

    static func normalized(_ angle: Double) -> Double {
        let value = angle.truncatingRemainder(dividingBy: 360)
        return value < 0 ? value + 360 : value
    }

    /// A positive clockwise delta, in `0..<360`.
    static func clockwiseDelta(from start: Double, to end: Double) -> Double {
        normalized(end - start)
    }
}

// MARK: - Palette

/// What the ring is painted in.
///
/// The light icon's glyph is a blue-to-cyan gradient; the dark one's is white.
/// A bare mark follows the same two appearances. The gradient is the icon's,
/// not a decoration: it is what makes the long right-hand arc read as the
/// bright end of the drawing.
struct MizarRingPalette: Sendable {
    /// One colour for a solid ink, three for the icon's gradient.
    var colors: [Color]

    /// The icon's own light-appearance gradient.
    static let brand = MizarRingPalette(colors: [
        Color(red: 62 / 255, green: 134 / 255, blue: 240 / 255),
        Color(red: 93 / 255, green: 196 / 255, blue: 249 / 255),
        Color(red: 127 / 255, green: 228 / 255, blue: 252 / 255),
    ])

    /// A solid ink, for a mark that has to be one colour.
    ///
    /// - Parameter color: the ink.
    /// - Returns: a palette that paints every piece in it.
    static func ink(_ color: Color) -> MizarRingPalette {
        MizarRingPalette(colors: [color])
    }

    /// What a bare mark is drawn in, in a given appearance.
    ///
    /// The light appearance gets the icon's gradient; the dark one gets white,
    /// because the blue family sinks into a dark screen. This is the same rule
    /// the old mark had, and the reason the tile can hand its ring the
    /// appearance without naming a colour.
    ///
    /// - Parameter scheme: the appearance the mark is drawn in.
    /// - Returns: the default palette for a mark that did not name one.
    static func automatic(for scheme: ColorScheme) -> MizarRingPalette {
        scheme == .dark ? .ink(.white) : .brand
    }

    /// The paint for a canvas of a given size.
    ///
    /// - Parameter size: the mark's box.
    /// - Returns: a linear gradient from the lower-left of the box to its
    ///   upper-right, or a flat colour.
    func shading(in size: CGSize) -> GraphicsContext.Shading {
        guard colors.count > 1 else {
            return .color(colors.first ?? .white)
        }
        return .linearGradient(
            Gradient(colors: colors),
            startPoint: CGPoint(x: size.width * 0.14, y: size.height * 0.88),
            endPoint: CGPoint(x: size.width * 0.86, y: size.height * 0.12),
        )
    }
}

// MARK: - The timeline

/// The numbers the loop is made of.
///
/// The loop is one unified clock, not five timers:
///
/// `five-dot queue → chain growth → hold the icon → chain contraction back to
/// the same five-dot queue`
///
/// There is no appearance or disappearance: the first and last frame are the
/// same fully visible queue. Growth and contraction share one queue constraint,
/// so the rear elements move with the front arc's current length on every
/// frame. The growth curve has one small damped overshoot; contraction is an
/// ease-in-out sine, not a reverse playback.
enum RingMetrics {
    // The initial five-dot queue is already on screen. It holds briefly so the
    // eye can register the queue, then grows immediately from it.
    static let holdQueue: Double = 0.18

    // Stage B — the chain grows. The front arc extends first and pushes the
    // four elements behind it; each subsequent element then grows in turn.
    static let morphStagger: Double = 0.055
    static let morphDuration: Double = 0.38

    // Stage C — the finished icon holds.
    static let holdFull: Double = 0.15

    // Stage D — the chain contracts. Every element's current length shrinks;
    // the starts are recomputed from the same queue constraint every frame,
    // so the five dots are already back in the initial queue when the last
    // length reaches zero.
    static let shrinkStagger: Double = 0.055
    static let shrinkDuration: Double = 0.36

    // MARK: Phase windows

    static var morphStartWindow: Double {
        Double(RingGeometry.segments.count - 1) * morphStagger
    }

    static var shrinkStartWindow: Double {
        Double(RingGeometry.segments.count - 1) * shrinkStagger
    }

    static var morphSpan: Double { morphStartWindow + morphDuration }
    static var shrinkSpan: Double { shrinkStartWindow + shrinkDuration }

    /// The initial queue is on screen at t=0; growth follows it.
    static var morphPhaseStart: Double { holdQueue }
    /// The full-icon hold begins after the last arc has grown.
    static var holdStart: Double { morphPhaseStart + morphSpan }
    /// The chain contraction begins after the hold.
    static var shrinkPhaseStart: Double { holdStart + holdFull }

    /// One full loop. There is no empty hold and no separate reposition: the
    /// loop seam is the initial five-dot queue.
    static var runningLoop: Double { shrinkPhaseStart + shrinkSpan }

    /// The settings header's one-shot: five-dot queue → chain growth → icon.
    /// It stops on the finished icon; nothing shrinks or loops.
    static var assemblySpan: Double { morphPhaseStart + morphSpan }

    /// Let the settings sheet finish rising before the one-shot starts, so the
    /// first frames are actually seen instead of playing behind the sheet.
    static let assemblyDelay: Double = 0.45

    // One short pass for arriving screens: full, erase, hold empty, load,
    // full. Not the loading loop; kept separate so its start/end are the
    // static icon and it can overlay a screen without a jump.
    static let onceHoldFull: Double = 0.14
    static let onceRevealStagger: Double = 0.11
    static let onceRevealDuration: Double = 0.18
    static let onceHoldEmpty: Double = 0.12
    static let onceRetractStagger: Double = 0.10
    static let onceRetractDuration: Double = 0.16

    static var onceRevealStartWindow: Double {
        Double(RingGeometry.segments.count - 1) * onceRevealStagger
    }

    static var onceRetractStartWindow: Double {
        Double(RingGeometry.segments.count - 1) * onceRetractStagger
    }

    static var onceRevealSpan: Double {
        onceRevealStartWindow + onceRevealDuration
    }

    static var onceRetractSpan: Double {
        onceRetractStartWindow + onceRetractDuration
    }

    /// One short pass, from the static icon back to the static icon.
    static var onceDuration: Double {
        onceHoldFull + onceRetractSpan + onceHoldEmpty + onceRevealSpan + onceHoldFull
    }

    // MARK: Curves

    /// A gentle decelerating curve, used where an element is already leaving.
    static func easeOutCubic(_ progress: Double) -> Double {
        let p = clamp(progress)
        return 1 - pow(1 - p, 3)
    }

    /// The main movement curve: starts at rest, accelerates, settles at rest.
    static func easeInOutCubic(_ progress: Double) -> Double {
        let p = clamp(progress)
        return p < 0.5 ? 4 * p * p * p : 1 - pow(-2 * p + 2, 3) / 2
    }

    /// The shrink curve: a sine, not the morph curve and not its reverse. It
    /// leaves the full arc without the long dead beat a quintic has at the
    /// start, eases through the middle, and lands without a bounce.
    static func easeInOutSine(_ progress: Double) -> Double {
        let p = clamp(progress)
        return (1 - cos(.pi * p)) / 2
    }

    /// Kept for the easing test; the shrink itself uses ``easeInOutSine``.
    static func easeInOutQuint(_ progress: Double) -> Double {
        let p = clamp(progress)
        return p < 0.5 ? 16 * p * p * p * p * p : 1 - pow(-2 * p + 2, 5) / 2
    }

    /// Smooth 0→1 with zero slope at both ends.
    static func smoothstep(_ edge0: Double, _ edge1: Double, _ value: Double) -> Double {
        guard edge0 != edge1 else { return value < edge0 ? 0 : 1 }
        let t = clamp((value - edge0) / (edge1 - edge0))
        return t * t * (3 - 2 * t)
    }

    /// One small, damped overshoot near the end of the morph.
    ///
    /// Zero at both ends and shaped like `sin²`, so it has no slope of its own
    /// at the boundaries; it peaks around 84% through the morph and is gone by
    /// 100%. There is no second oscillation, and no bounce on the whole ring.
    static func overshootBump(_ progress: Double) -> Double {
        let q = clamp((clamp(progress) - 0.68) / 0.32)
        guard q > 0, q < 1 else { return 0 }
        let wave = sin(.pi * q)
        return wave * wave
    }

    /// The arc length during the morph.
    ///
    /// The base curve supplies acceleration and deceleration; the bump adds a
    /// ~1–2% overshoot just before the arc lands, then it settles back to
    /// exactly 1. The width and radius get a smaller share of the same bump, so
    /// the elasticity is local to the end of each arc.
    static func morph(_ progress: Double) -> Double {
        easeInOutCubic(progress) + 0.018 * overshootBump(progress)
    }

    /// The dot fade-out order: when one piece starts, in an eased window.
    ///
    /// Even spacing reads as a metronome. `easeInOutCubic` makes the cascade
    /// open slowly, run through the middle faster, and land gently. The order
    /// stays clockwise; only the spacing changes.
    static func staggeredStart(index: Int, window: Double) -> Double {
        let count = RingGeometry.segments.count
        guard count > 1 else { return 0 }
        let clamped = min(max(index, 0), count - 1)
        let position = Double(clamped) / Double(count - 1)
        return window * easeInOutCubic(position)
    }

    static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}

/// One piece's pose at one instant.
///
/// The dot and the arc are the same state, not two views: an arc's round start
/// cap is the dot, and `trimEnd` is how far the head has travelled from it.
/// `dotOpacity` is the extra full circle drawn while `trimEnd` is still near
/// zero; it fades as the head leaves the dot.
struct SegmentState: Sendable, Equatable {
    /// Where the visible arc starts, as a fraction of its sweep.
    var trimStart: Double = 0
    /// Where it ends. May exceed 1 by a hair during the morph's overshoot.
    var trimEnd: Double = 0
    /// How opaque the piece is.
    var opacity: Double = 0
    /// The dot's scale; arcs use it for the round start marker.
    var dotScale: Double = 0
    /// Opacity of the full dot at the start of an arc (or of the standalone dot).
    var dotOpacity: Double = 0
    /// Local stroke swelling for the elastic landing.
    var strokeScale: Double = 1
    /// Local outward/ inward radial offset, as a fraction of the radius.
    var radialOffset: Double = 0
    /// Current start angle, in degrees, relative to the piece's final start.
    /// The queue uses this to push and release the elements.
    var positionOffset: Double = 0
    /// Current arc length as a fraction of the piece's final sweep. A dot is 0.
    var sweepScale: Double = 1

    static let full = SegmentState(
        trimStart: 0,
        trimEnd: 1,
        opacity: 1,
        dotScale: 1,
        dotOpacity: 0,
    )

    static let empty = SegmentState()

    /// A dot pose. `dotOpacity` is always 1 here; the renderer draws it as a
    /// circle for the standalone piece and as the start marker for an arc.
    static func dot(
        opacity: Double,
        scale: Double,
        offset: Double = 0,
    ) -> SegmentState {
        SegmentState(
            trimStart: 0,
            trimEnd: 0,
            opacity: opacity,
            dotScale: scale,
            dotOpacity: 1,
            positionOffset: offset,
            sweepScale: 0,
        )
    }

    var isVisible: Bool {
        opacity > 0.001 && (dotOpacity > 0.001 || trimEnd - trimStart > 0.0005)
    }

    /// A piece that is being drawn in, for the separate arrival pass.
    ///
    /// - Parameter progress: 0 at first ink, 1 when the piece is whole.
    static func revealing(_ progress: Double) -> SegmentState {
        let p = RingMetrics.clamp(progress)
        let eased = RingMetrics.easeInOutCubic(p)
        return SegmentState(
            trimStart: 0,
            trimEnd: eased,
            opacity: min(1, p * 4),
            dotScale: 0.55 + 0.45 * eased,
        )
    }

    /// A piece that is being erased from its start, for the arrival pass.
    ///
    /// - Parameter progress: 0 at whole, 1 when the last of it has gone.
    static func retracting(_ progress: Double) -> SegmentState {
        let p = RingMetrics.clamp(progress)
        let eased = RingMetrics.easeInOutCubic(p)
        return SegmentState(
            trimStart: eased,
            trimEnd: 1,
            opacity: p < 0.75 ? 1 : max(0, (1 - p) / 0.25),
            dotScale: 1 - 0.45 * eased,
        )
    }
}

/// What the ring is doing, as a value the canvas can draw and a test can step.
enum RingPresentation: Equatable, Sendable {
    /// The icon's pose: every piece whole.
    case still
    /// A normalized time through the loading loop, `0..<1`.
    case running(Double)
    /// A normalized time through the separate arrival pass, `0...1`.
    case once(Double)
    /// The settings header's one-shot: five dots to the icon, `0...1`.
    case assembling(Double)
    /// A progress reading, `0...1`, filled clockwise from the gap.
    case opening(Double)

    /// The mark's pieces: four arcs and the dot at ten o'clock.
    private static let dotIndex = RingGeometry.segments.count - 1

    /// Whether to draw the unfilled track behind the reading.
    var drawsTrack: Bool {
        if case .opening = self { true } else { false }
    }

    /// The pose of one piece.
    ///
    /// - Parameter index: an index into ``RingGeometry/segments``.
    /// - Returns: the piece's trim, opacity, dot and elastic parameters.
    func state(for index: Int) -> SegmentState {
        switch self {
        case .still:
            return .full
        case .running(let time):
            return Self.runningState(index: index, time: time)
        case .once(let time):
            return Self.onceState(index: index, time: time)
        case .assembling(let time):
            return Self.assemblingState(index: index, time: time)
        case .opening(let fraction):
            return Self.openingState(index: index, fraction: fraction)
        }
    }

    // MARK: The loading loop

    private static func runningState(index: Int, time: Double) -> SegmentState {
        let t = RingMetrics.clamp(time) * RingMetrics.runningLoop
        if t < RingMetrics.morphPhaseStart {
            return initialQueueState(index: index)
        }
        if t < RingMetrics.holdStart {
            return growthState(index: index, t: t - RingMetrics.morphPhaseStart)
        }
        if t < RingMetrics.shrinkPhaseStart {
            return fullState(index: index)
        }
        return shrinkState(index: index, t: t - RingMetrics.shrinkPhaseStart)
    }

    /// The loop's first and last frame: the five-dot queue, already full.
    private static func initialQueueState(index: Int) -> SegmentState {
        .dot(
            opacity: 1,
            scale: 1,
            offset: RingQueue.initialOffsets[index],
        )
    }

    /// The finished icon's pose for one piece. The standalone dot needs its
    /// final offset (its unwrapped start is one turn ahead), not the bare
    /// `.full` arc pose.
    private static func fullState(index: Int) -> SegmentState {
        if index == RingQueue.dotIndex {
            let base = RingGeometry.segments[index].start
            return .dot(
                opacity: 1,
                scale: 1,
                offset: RingQueue.finalStartsUnwrapped[index] - base,
            )
        }
        return .full
    }

    /// The five queue starts, in unwrapped degrees, after the given lengths.
    /// `s(i+1) = s(i) + L(i) + G(i)`.
    private static func queueStarts(front: Double = 270, lengths: [Double]) -> [Double] {
        var starts = [front]
        for index in 1..<RingQueue.count {
            starts.append(starts[index - 1] + lengths[index - 1] + RingQueue.gaps[index - 1])
        }
        return starts
    }

    /// Stage B: the front arc grows and pushes the four elements behind it.
    private static func growthState(index: Int, t: Double) -> SegmentState {
        let lengths = (0..<4).map { piece -> Double in
            let start = RingMetrics.staggeredStart(
                index: piece,
                window: RingMetrics.morphStartWindow,
            )
            guard t > start else { return 0 }
            let p = (t - start) / RingMetrics.morphDuration
            guard p > 0 else { return 0 }
            if p >= 1 { return RingQueue.finalLengths[piece] }
            return RingQueue.finalLengths[piece] * RingMetrics.morph(p)
        }
        let starts = queueStarts(lengths: lengths)
        let base = RingGeometry.segments[index].start
        let offset = starts[index] - base

        if index == RingQueue.dotIndex {
            return .dot(opacity: 1, scale: 1, offset: offset)
        }

        let finalLength = RingQueue.finalLengths[index]
        let length = lengths[index]
        guard length > 0.0001 else {
            return .dot(opacity: 1, scale: 1, offset: offset)
        }
        let scale = length / finalLength
        let p = RingMetrics.clamp(
            (t - RingMetrics.staggeredStart(index: index, window: RingMetrics.morphStartWindow))
                / RingMetrics.morphDuration,
        )
        let bump = RingMetrics.overshootBump(p)
        return SegmentState(
            trimStart: 0,
            trimEnd: 1,
            opacity: 1,
            dotScale: 1,
            dotOpacity: 1 - RingMetrics.smoothstep(0.02, 0.16, min(scale, 1)),
            strokeScale: 1 + 0.02 * bump,
            radialOffset: 0.003 * bump,
            positionOffset: offset,
            sweepScale: scale,
        )
    }

    /// Stage D: every arc is eaten by a shrink front that moves **clockwise**
    /// from the arc's start toward its end and beyond, back to the initial
    /// queue. The queue is anchored at the first front; every rear front and
    /// tail is recomputed from the current lengths. This is not a reverse
    /// morph: the front moves forward while the remaining arc shrinks.
    private static func shrinkState(index: Int, t: Double) -> SegmentState {
        let q = RingMetrics.clamp(t / RingMetrics.shrinkSpan)
        let eased = RingMetrics.easeInOutSine(q)
        if eased >= 1 { return initialQueueState(index: index) }

        let lengths = (0..<4).map { piece in
            RingQueue.finalLengths[piece] * (1 - eased)
        }
        // The first front makes one clockwise lap so that the queue ends at
        // the initial five-dot positions rather than at the old arc ends.
        let starts = queueStarts(front: 270 + 360 * eased, lengths: lengths)
        let base = RingGeometry.segments[index].start
        let offset = starts[index] - base

        if index == RingQueue.dotIndex {
            return .dot(opacity: 1, scale: 1, offset: offset)
        }

        let finalLength = RingQueue.finalLengths[index]
        let length = lengths[index]
        guard length > 0.0001 else {
            return .dot(opacity: 1, scale: 1, offset: offset)
        }
        let scale = length / finalLength
        return SegmentState(
            trimStart: 0,
            trimEnd: 1,
            opacity: 1,
            dotScale: 1,
            dotOpacity: 1 - RingMetrics.smoothstep(0.02, 0.16, min(scale, 1)),
            strokeScale: 1,
            radialOffset: 0,
            positionOffset: offset,
            sweepScale: scale,
        )
    }

    /// The four (plus the dot) clockwise shrink-front angles at a given
    /// presentation time, for the debug preview and tests. `nil` outside the
    /// contraction phase.
    func shrinkFrontAngles() -> [Double]? {
        shrinkFrontsUnwrapped()?.map(RingQueue.normalized)
    }

    /// Unwrapped shrink fronts, for tests that need to prove the direction
    /// across the twelve o'clock wrap. Internal.
    func shrinkFrontsUnwrapped() -> [Double]? {
        guard case .running(let time) = self else { return nil }
        let t = RingMetrics.clamp(time) * RingMetrics.runningLoop
        guard t >= RingMetrics.shrinkPhaseStart else { return nil }
        let eased = RingMetrics.easeInOutSine(
            RingMetrics.clamp((t - RingMetrics.shrinkPhaseStart) / RingMetrics.shrinkSpan),
        )
        if eased >= 1 {
            return RingQueue.initialStarts.map { $0 + 360 }
        }
        let lengths = (0..<4).map { piece in
            RingQueue.finalLengths[piece] * (1 - eased)
        }
        return Self.queueStarts(front: 270 + 360 * eased, lengths: lengths)
    }

    // MARK: The settings one-shot

    /// The settings header: hold the five-dot queue, grow the chain once, stop
    /// on the finished icon. It never shrinks or repeats.
    private static func assemblingState(index: Int, time: Double) -> SegmentState {
        let t = RingMetrics.clamp(time) * RingMetrics.assemblySpan
        if t < RingMetrics.morphPhaseStart {
            return initialQueueState(index: index)
        }
        if t >= RingMetrics.assemblySpan {
            return fullState(index: index)
        }
        return growthState(index: index, t: t - RingMetrics.morphPhaseStart)
    }

    // MARK: The arrival pass

    /// One piece in the short arrival pass. Kept separate from the loading
    /// loop: this one starts and ends on the icon, not on a dot.
    private static func onceState(index: Int, time: Double) -> SegmentState {
        let t = RingMetrics.clamp(time) * RingMetrics.onceDuration
        let retractStart = RingMetrics.onceHoldFull
            + RingMetrics.staggeredStart(index: index, window: RingMetrics.onceRetractStartWindow)
        let retractEnd = retractStart + RingMetrics.onceRetractDuration
        let revealStart = RingMetrics.onceHoldFull
            + RingMetrics.onceRetractSpan
            + RingMetrics.onceHoldEmpty
            + RingMetrics.staggeredStart(index: index, window: RingMetrics.onceRevealStartWindow)
        let revealEnd = revealStart + RingMetrics.onceRevealDuration

        if t < retractStart { return .full }
        if t < retractEnd {
            return .retracting((t - retractStart) / RingMetrics.onceRetractDuration)
        }
        if t <= revealStart { return .empty }
        if t < revealEnd {
            return .revealing((t - revealStart) / RingMetrics.onceRevealDuration)
        }
        return .full
    }

    // MARK: Progress

    /// One piece of the progress reading, from the gap.
    private static func openingState(index: Int, fraction: Double) -> SegmentState {
        let segment = RingGeometry.segments[index]
        let f = RingMetrics.clamp(fraction)
        if f >= 1 { return .full }

        if segment.isDot {
            let dotStart = RingGeometry.position(of: segment) / 360
            let local = (f - dotStart) / 0.08
            guard local > 0 else { return .empty }
            let eased = RingMetrics.clamp(local)
            return SegmentState(
                trimStart: 0,
                trimEnd: 1,
                opacity: eased,
                dotScale: 0.55 + 0.45 * eased,
                dotOpacity: 1,
            )
        }

        let position = RingGeometry.position(of: segment) / 360
        let width = segment.sweep / 360
        guard width > 0, f > position else { return .empty }
        let local = min((f - position) / width, 1)
        guard local > 0 else { return .empty }
        return SegmentState(trimStart: 0, trimEnd: local, opacity: 1, dotScale: 1, dotOpacity: 0)
    }
}

// MARK: - The mark

/// The app's ring, at one of the four things it does.
struct MizarRing: View {
    /// What the ring is doing.
    enum Motion: Equatable {
        /// The icon's pose: every piece whole.
        case still
        /// Endless: load clockwise, hold, erase clockwise, hold empty.
        case running
        /// One pass: the icon, erased clockwise, loaded back, the icon again.
        case once
        /// The settings header: five dots grow once into the icon and stop.
        case assembling
        /// A reading: `0` is an empty track, `1` the icon.
        case opening(Double)
    }

    /// What it is doing.
    var motion: Motion = .still
    /// The mark's box, in points. The drawn ring is ``RingGeometry/inkShare``
    /// of this; use ``init(ink:motion:palette:)`` to name the ink instead.
    var size: CGFloat = 64
    /// What the ring is painted in, or `nil` for the appearance's own ink.
    var palette: MizarRingPalette?
    /// Debug preview: mark each arc's clockwise shrink front with a red/white
    /// pip. Off everywhere except the visual harness/tests.
    var debugShrinkFronts: Bool = false

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.drawersStill) private var drawersStill
    /// Start of the shared loading clock; every piece is derived from it.
    @State private var runningStart = Date()
    /// Linear time through the short pass, animated by SwiftUI.
    @State private var onceProgress: Double = 0
    /// Linear time through the settings one-shot.
    @State private var assemblyProgress: Double = 0
    /// Keeps one appearance from replaying the one-shot.
    @State private var assemblyStarted = false

    var body: some View {
        Group {
            switch motion {
            case .still:
                canvas(.still)
            case .running:
                running
            case .once:
                once
            case .assembling:
                assembling
            case .opening(let fraction):
                opening(fraction)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    /// The palette this mark is drawn in.
    private var ink: MizarRingPalette {
        palette ?? .automatic(for: colorScheme)
    }

    private func canvas(_ presentation: RingPresentation) -> some View {
        RingCanvas(
            presentation: presentation,
            palette: ink,
            debugShrinkFronts: debugShrinkFronts,
        )
    }

    // MARK: Running

    /// The loop, or the icon's pose when motion is not allowed.
    ///
    /// One `TimelineView` clock drives all five pieces: no per-element timers,
    /// so the clockwise phase offsets cannot drift. The timeline is pure
    /// (`RingPresentation.running`), which is what lets the tests step it.
    @ViewBuilder private var running: some View {
        if reduceMotion || !drawersStill {
            canvas(.still)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 120.0)) { timeline in
                let elapsed = timeline.date.timeIntervalSince(runningStart)
                let phase = elapsed.truncatingRemainder(dividingBy: RingMetrics.runningLoop)
                    / RingMetrics.runningLoop
                RingCanvas(
                    presentation: .running(phase),
                    palette: ink,
                    debugShrinkFronts: debugShrinkFronts,
                )
            }
            .onAppear { runningStart = Date() }
        }
    }

    // MARK: One pass

    /// One throw, from the static icon to the static icon.
    private var once: some View {
        OnceRing(
            progress: reduceMotion ? 1 : onceProgress,
            palette: ink,
            size: size,
        )
        .onAppear {
            guard !reduceMotion else { return }
            onceProgress = 0
            withAnimation(.linear(duration: RingMetrics.onceDuration)) { onceProgress = 1 }
        }
    }

    // MARK: Settings one-shot

    /// Five dots grow once into the icon, then stop. The settings sheet gives
    /// the header a fresh `id` each time, so every open starts at the dots.
    @ViewBuilder private var assembling: some View {
        if reduceMotion || !drawersStill {
            canvas(.still)
        } else {
            AssemblingRing(
                progress: assemblyProgress,
                palette: ink,
                size: size,
            )
            .onAppear {
                guard !assemblyStarted else { return }
                assemblyStarted = true
                DispatchQueue.main.asyncAfter(deadline: .now() + RingMetrics.assemblyDelay) {
                    withAnimation(.linear(duration: RingMetrics.assemblySpan)) {
                        assemblyProgress = 1
                    }
                }
            }
        }
    }

    // MARK: Opening

    /// The ring filled by a progress reading.
    ///
    /// - Parameter fraction: how far along, 0 to 1.
    private func opening(_ fraction: Double) -> some View {
        let clamped = RingMetrics.clamp(fraction)
        return OpeningRing(progress: clamped, palette: ink, size: size)
            .animation(reduceMotion ? nil : .mizarGentle, value: clamped)
    }
}

extension MizarRing {
    /// A mark whose *ink* is a given width, rather than whose box is.
    ///
    /// A running indicator in a 17-point row wants a 17-point ring, not a
    /// 20-point box with the icon's margin around it. The box is larger than
    /// the ink by ``RingGeometry/inkShare``, so this divides it back out.
    ///
    /// - Parameters:
    ///   - diameter: how wide the drawn ring should be, in points.
    ///   - motion: what it is doing. Running, almost always.
    ///   - palette: an explicit ink, or `nil` for the appearance's own.
    init(
        ink diameter: CGFloat,
        motion: Motion = .running,
        palette: MizarRingPalette? = nil,
    ) {
        self.init(
            motion: motion,
            size: diameter / RingGeometry.inkShare,
            palette: palette,
        )
    }
}

// MARK: - Drawing

/// The five pieces, painted from one presentation value.
///
/// One `Canvas` rather than five shapes: the pieces are a single drawing with a
/// single ink, and a canvas can stroke them in the order and with the opacity
/// the timeline asks for without five view bodies per frame.
private struct RingCanvas: View {
    let presentation: RingPresentation
    let palette: MizarRingPalette
    var debugShrinkFronts: Bool = false

    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = RingGeometry.radius * side
            let width = RingGeometry.stroke * side
            let shading = palette.shading(in: size)
            let style = StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)

            if presentation.drawsTrack {
                context.opacity = 0.12
                for segment in RingGeometry.segments {
                    draw(segment, from: 0, to: 1, center: center, radius: radius, style: style, in: &context, shading: shading)
                }
                context.opacity = 1
            }

            for (index, segment) in RingGeometry.segments.enumerated() {
                let state = presentation.state(for: index)
                guard state.opacity > 0.001 else { continue }

                let pieceRadius = radius * (1 + state.radialOffset)
                let pieceWidth = width * state.strokeScale
                let pieceStart = segment.start + state.positionOffset
                let pieceStyle = StrokeStyle(
                    lineWidth: pieceWidth,
                    lineCap: .round,
                    lineJoin: .round,
                )

                if segment.isDot {
                    drawDot(
                        angle: pieceStart,
                        center: center,
                        radius: pieceRadius,
                        diameter: pieceWidth * state.dotScale,
                        opacity: state.opacity,
                        shading: shading,
                        in: &context,
                    )
                    continue
                }

                // The dot at the start of an arc is the same round cap that
                // the arc will keep; it fades only after the head has left.
                if state.dotOpacity > 0.001 {
                    drawDot(
                        angle: pieceStart,
                        center: center,
                        radius: pieceRadius,
                        diameter: pieceWidth * state.dotScale,
                        opacity: state.opacity * state.dotOpacity,
                        shading: shading,
                        in: &context,
                    )
                }

                let start = pieceStart + segment.sweep * state.trimStart
                let end = pieceStart + segment.sweep * (state.trimStart + (state.trimEnd - state.trimStart) * state.sweepScale)
                guard end - start > 0.01 else { continue }
                let path = RingGeometry.arcPath(
                    center: center,
                    radius: pieceRadius,
                    start: start,
                    end: end,
                )
                context.opacity = state.opacity
                context.stroke(path, with: shading, style: pieceStyle)
            }

            if debugShrinkFronts, let fronts = presentation.shrinkFrontAngles() {
                let marker = width * 0.8
                for angle in fronts {
                    let radians = angle * .pi / 180
                    let point = CGPoint(
                        x: center.x + radius * CGFloat(cos(radians)),
                        y: center.y + radius * CGFloat(sin(radians)),
                    )
                    let rect = CGRect(
                        x: point.x - marker / 2,
                        y: point.y - marker / 2,
                        width: marker,
                        height: marker,
                    )
                    context.fill(Path(ellipseIn: rect), with: .color(.white))
                    context.stroke(
                        Path(ellipseIn: rect),
                        with: .color(.red),
                        lineWidth: max(1, width * 0.12),
                    )
                }
            }
        }
    }

    private func draw(
        _ segment: RingSegment,
        from: Double,
        to: Double,
        center: CGPoint,
        radius: CGFloat,
        style: StrokeStyle,
        in context: inout GraphicsContext,
        shading: GraphicsContext.Shading,
    ) {
        if segment.isDot {
            let angle = segment.start * .pi / 180
            let point = CGPoint(
                x: center.x + radius * CGFloat(cos(angle)),
                y: center.y + radius * CGFloat(sin(angle)),
            )
            let dot = style.lineWidth
            let rect = CGRect(
                x: point.x - dot / 2,
                y: point.y - dot / 2,
                width: dot,
                height: dot,
            )
            context.fill(Path(ellipseIn: rect), with: shading)
            return
        }
        let start = segment.start + segment.sweep * from
        let end = segment.start + segment.sweep * to
        guard end - start > 0.01 else { return }
        let path = RingGeometry.arcPath(center: center, radius: radius, start: start, end: end)
        context.stroke(path, with: shading, style: style)
    }

    /// A round piece: the standalone dot, or the full dot that becomes an
    /// arc's start cap.
    private func drawDot(
        angle: Double,
        center: CGPoint,
        radius: CGFloat,
        diameter: CGFloat,
        opacity: Double,
        shading: GraphicsContext.Shading,
        in context: inout GraphicsContext,
    ) {
        guard diameter > 0.01 else { return }
        let radians = angle * .pi / 180
        let point = CGPoint(
            x: center.x + radius * CGFloat(cos(radians)),
            y: center.y + radius * CGFloat(sin(radians)),
        )
        let rect = CGRect(
            x: point.x - diameter / 2,
            y: point.y - diameter / 2,
            width: diameter,
            height: diameter,
        )
        context.opacity = opacity
        context.fill(Path(ellipseIn: rect), with: shading)
    }
}

/// The short pass, as an animatable progress.
///
/// `Canvas` draws from a value; SwiftUI interpolates values, not drawings. This
/// wrapper is the value: one `Double` in, the same timeline out.
private struct OnceRing: View, Animatable {
    var progress: Double
    let palette: MizarRingPalette
    let size: CGFloat

    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        RingCanvas(presentation: .once(progress), palette: palette)
            .frame(width: size, height: size)
    }
}

/// The settings header's one-shot, as an animatable fraction.
private struct AssemblingRing: View, Animatable {
    var progress: Double
    let palette: MizarRingPalette
    let size: CGFloat

    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        RingCanvas(presentation: .assembling(progress), palette: palette)
            .frame(width: size, height: size)
    }
}

/// The progress reading, as an animatable fraction.
private struct OpeningRing: View, Animatable {
    var progress: Double
    let palette: MizarRingPalette
    let size: CGFloat

    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        RingCanvas(presentation: .opening(progress), palette: palette)
            .frame(width: size, height: size)
    }
}

// MARK: - The icon, drawn

/// The app icon as a view: the ring on its own tile.
///
/// Used where the app shows *itself* rather than a status -- the settings
/// header. It is the icon's composition, not a copy of the bitmap: the tile's
/// corner radius and the ring's share of it are the icon's own numbers, so the
/// mark survives every size without a second asset.
///
/// Two appearances, matching the two the icon ships: the light tile's pale blue
/// glow with the blue-to-cyan ring, and the dark tile's near-black ground with
/// the white ring.
struct MizarIconTile: View {
    var size: CGFloat = 64
    /// What the ring inside is doing. The tile itself never moves.
    var motion: MizarRing.Motion = .still
    /// Recreates the ring when a sheet presents again, so the loop starts
    /// fresh at the five-dot queue instead of inheriting an old phase.
    var animationToken: Int = 0

    @Environment(\.colorScheme) private var colorScheme

    /// Apple's icon corner radius, as a share of the width.
    private static let radiusShare: CGFloat = 185.0 / 824.0

    /// Whether this is the dark appearance.
    private var isDark: Bool { colorScheme == .dark }

    var body: some View {
        RoundedRectangle(cornerRadius: size * Self.radiusShare, style: .continuous)
            .fill(background)
            .overlay {
                // `MizarRing`'s box is the tile, and its ink is 85.6% of that
                // box -- the same share the icon's glyph occupies.
                MizarRing(motion: motion, size: size)
                    .id(animationToken)
                    .shadow(
                        color: isDark ? Color.white.opacity(0.12) : Color.accentColor.opacity(0.16),
                        radius: size * 0.045,
                        y: size * 0.012,
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: size * Self.radiusShare, style: .continuous)
                    .strokeBorder(
                        isDark ? Color.white.opacity(0.10) : Color.black.opacity(0.08),
                        lineWidth: 1,
                    )
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    /// The icon's ground: a pale blue centre in the light, near-black in the
    /// dark.
    private var background: AnyShapeStyle {
        if isDark {
            return AnyShapeStyle(Color(red: 26 / 255, green: 26 / 255, blue: 26 / 255))
        }
        return AnyShapeStyle(
            RadialGradient(
                colors: [
                    Color(red: 0.918, green: 0.957, blue: 0.996),
                    Color(red: 0.988, green: 0.992, blue: 1.0),
                ],
                center: .center,
                startRadius: 0,
                endRadius: size * 0.62,
            ),
        )
    }
}

#Preview("The mark") {
    ScrollView {
        VStack(spacing: 28) {
            HStack(spacing: 24) {
                MizarRing(motion: .still, size: 28)
                MizarRing(motion: .running, size: 28)
                MizarRing(motion: .once, size: 28)
                MizarRing(motion: .opening(0.5), size: 28)
            }
            HStack(spacing: 24) {
                MizarRing(motion: .still, size: 72)
                MizarRing(motion: .running, size: 72)
                MizarRing(motion: .once, size: 72)
                MizarRing(motion: .opening(0.5), size: 72)
            }
            HStack(spacing: 24) {
                MizarRing(motion: .still, size: 72, palette: .ink(.white))
                    .background(Color(red: 19 / 255, green: 31 / 255, blue: 61 / 255))
                MizarRing(motion: .running, size: 72, palette: .ink(.white))
                    .background(Color(red: 19 / 255, green: 31 / 255, blue: 61 / 255))
            }
            HStack(spacing: 24) {
                MizarIconTile(size: 64, motion: .still)
                MizarIconTile(size: 128, motion: .once)
            }
            HStack(spacing: 24) {
                MizarRing(motion: .opening(0), size: 96)
                MizarRing(motion: .opening(0.5), size: 96)
                MizarRing(motion: .opening(1), size: 96)
            }
        }
        .padding(32)
    }
}
