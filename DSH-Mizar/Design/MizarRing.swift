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
//  arcs down the left, and the dot at ten o'clock are one drawing. So the two
//  motions are the drawing's own pieces, not a rotating copy of it. A spinner
//  that turned the whole icon would be a different mark every frame; this one
//  fills itself clockwise and then lets itself go, and every frame is the icon
//  in some state of being drawn.
//
//  ### The two motions
//
//  `running` is for waiting: long arc first, then the three short arcs, then
//  the dot, all in clockwise order; a short hold with the ring complete; then
//  the same order erases them. The next cycle starts from empty. It is the
//  Windows 10 boot spinner's grammar -- appear one by one, hold, disappear one
//  by one -- translated onto arcs of unequal length.
//
//  `once` is for arriving: the full icon holds for a beat, the pieces erase
//  clockwise, and then they load back in. It starts and ends on the static
//  icon, so it can play over a screen whose mark is the icon without a jump.
//
//  `opening` is a reading, not decoration: the ring fills clockwise from the
//  gap, so `0` is an empty track and `1` is the icon. It still follows progress
//  under Reduce Motion, because hiding the progress would hide the download.
//
//  Reduce Motion parks `running` and `once` on the icon; `opening` keeps
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

/// The numbers the two motions are made of.
///
/// All durations are seconds. The reveal and retract windows overlap their
/// neighbours: an element starts before the previous one finishes, which is
/// what makes the sequence read as a cascade instead of five separate pops.
enum RingMetrics {
    // Running: full cycle, a calm two and a bit seconds.
    static let runRevealStagger: Double = 0.16
    static let runRevealDuration: Double = 0.26
    static let runHoldFull: Double = 0.34
    static let runRetractStagger: Double = 0.14
    static let runRetractDuration: Double = 0.20
    static let runHoldEmpty: Double = 0.20

    /// How long the five pieces take to load, first start to last finish.
    static var runRevealSpan: Double {
        Double(RingGeometry.segments.count - 1) * runRevealStagger + runRevealDuration
    }

    /// How long they take to erase.
    static var runRetractSpan: Double {
        Double(RingGeometry.segments.count - 1) * runRetractStagger + runRetractDuration
    }

    /// One loop: empty, load, hold, erase, hold empty.
    static var runningLoop: Double {
        runRevealSpan + runHoldFull + runRetractSpan + runHoldEmpty
    }

    // One pass: full, erase, hold empty, load, full. Faster than the loop:
    // this one is a transition the operator is waiting for, not an ambient
    // indicator.
    static let onceHoldFull: Double = 0.14
    static let onceRevealStagger: Double = 0.11
    static let onceRevealDuration: Double = 0.18
    static let onceHoldEmpty: Double = 0.12
    static let onceRetractStagger: Double = 0.10
    static let onceRetractDuration: Double = 0.16

    static var onceRevealSpan: Double {
        Double(RingGeometry.segments.count - 1) * onceRevealStagger + onceRevealDuration
    }

    static var onceRetractSpan: Double {
        Double(RingGeometry.segments.count - 1) * onceRetractStagger + onceRetractDuration
    }

    /// One short pass, from the static icon back to the static icon.
    static var onceDuration: Double {
        onceHoldFull + onceRetractSpan + onceHoldEmpty + onceRevealSpan + onceHoldFull
    }

    /// Ease-out: the leading edge moves quickly and settles, like a paint head.
    static func easeOutCubic(_ progress: Double) -> Double {
        let p = clamp(progress)
        return 1 - pow(1 - p, 3)
    }

    /// Ease-in-out: the erasing head starts and stops without a snap.
    static func easeInOutCubic(_ progress: Double) -> Double {
        let p = clamp(progress)
        return p < 0.5 ? 4 * p * p * p : 1 - pow(-2 * p + 2, 3) / 2
    }

    static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}

/// One piece's pose at one instant.
struct SegmentState: Sendable, Equatable {
    /// Where the visible arc starts, as a fraction of its sweep.
    var trimStart: Double
    /// Where it ends, as a fraction of its sweep.
    var trimEnd: Double
    /// How opaque the piece is.
    var opacity: Double
    /// The dot's scale; arcs ignore it.
    var dotScale: Double

    static let full = SegmentState(trimStart: 0, trimEnd: 1, opacity: 1, dotScale: 1)
    static let empty = SegmentState(trimStart: 0, trimEnd: 0, opacity: 0, dotScale: 0.55)

    var isVisible: Bool {
        opacity > 0.001 && trimEnd - trimStart > 0.0005
    }

    /// A piece that is being drawn in.
    ///
    /// - Parameter progress: 0 at first ink, 1 when the piece is whole.
    static func revealing(_ progress: Double) -> SegmentState {
        let p = RingMetrics.clamp(progress)
        let eased = RingMetrics.easeOutCubic(p)
        return SegmentState(
            trimStart: 0,
            trimEnd: eased,
            // Fade the first quarter only: the arc's own growth does most of
            // the work, and a full-length fade would read as a blink.
            opacity: min(1, p * 4),
            dotScale: 0.55 + 0.45 * eased,
        )
    }

    /// A piece that is being erased from its start.
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
    /// A normalized time through one loop, `0..<1`.
    case running(Double)
    /// A normalized time through one short pass, `0...1`.
    case once(Double)
    /// A progress reading, `0...1`, filled clockwise from the gap.
    case opening(Double)

    /// Whether to draw the unfilled track behind the reading.
    var drawsTrack: Bool {
        if case .opening = self { true } else { false }
    }

    /// The pose of one piece.
    ///
    /// - Parameter index: an index into ``RingGeometry/segments``.
    /// - Returns: the piece's trim, opacity and dot scale.
    func state(for index: Int) -> SegmentState {
        switch self {
        case .still:
            return .full
        case .running(let time):
            return Self.runningState(index: index, time: time)
        case .once(let time):
            return Self.onceState(index: index, time: time)
        case .opening(let fraction):
            return Self.openingState(index: index, fraction: fraction)
        }
    }

    // MARK: Running

    /// One piece in the loop.
    ///
    /// The loop's phases, in order: reveal (staggered), hold with the ring
    /// whole, retract (staggered), hold empty. `time` is normalized over the
    /// whole loop, so the seam at `0`/`1` is the empty hold and the loop wraps
    /// without a jump.
    private static func runningState(index: Int, time: Double) -> SegmentState {
        let t = RingMetrics.clamp(time) * RingMetrics.runningLoop
        let revealStart = Double(index) * RingMetrics.runRevealStagger
        let revealEnd = revealStart + RingMetrics.runRevealDuration
        let retractStart = RingMetrics.runRevealSpan
            + RingMetrics.runHoldFull
            + Double(index) * RingMetrics.runRetractStagger
        let retractEnd = retractStart + RingMetrics.runRetractDuration

        if t <= revealStart { return .empty }
        if t < revealEnd {
            return .revealing((t - revealStart) / RingMetrics.runRevealDuration)
        }
        if t < retractStart { return .full }
        if t < retractEnd {
            return .retracting((t - retractStart) / RingMetrics.runRetractDuration)
        }
        return .empty
    }

    // MARK: One pass

    /// One piece in the short pass.
    ///
    /// Starts on the whole ring, erases in the same clockwise order, holds
    /// empty, loads in the same order, and ends on the whole ring again.
    private static func onceState(index: Int, time: Double) -> SegmentState {
        let t = RingMetrics.clamp(time) * RingMetrics.onceDuration
        let retractStart = RingMetrics.onceHoldFull
            + Double(index) * RingMetrics.onceRetractStagger
        let retractEnd = retractStart + RingMetrics.onceRetractDuration
        let revealStart = RingMetrics.onceHoldFull
            + RingMetrics.onceRetractSpan
            + RingMetrics.onceHoldEmpty
            + Double(index) * RingMetrics.onceRevealStagger
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

    /// One piece of the progress reading.
    ///
    /// The filled angle sweeps clockwise from the gap. An arc is trimmed to
    /// whatever part of it the head has passed; the dot, having no length,
    /// fades and grows over the twelve degrees its cap covers.
    private static func openingState(index: Int, fraction: Double) -> SegmentState {
        guard RingGeometry.segments.indices.contains(index) else { return .empty }
        let segment = RingGeometry.segments[index]
        let filled = RingMetrics.clamp(fraction) * 360
        let position = RingGeometry.position(of: segment)
        if segment.isDot {
            let local = RingMetrics.clamp((filled - position) / 12)
            guard local > 0 else { return .empty }
            return SegmentState(
                trimStart: 0,
                trimEnd: 1,
                opacity: local,
                dotScale: 0.55 + 0.45 * local,
            )
        }
        let local = RingMetrics.clamp((filled - position) / segment.sweep)
        guard local > 0 else { return .empty }
        return SegmentState(trimStart: 0, trimEnd: local, opacity: 1, dotScale: 1)
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

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.drawersStill) private var drawersStill
    /// Linear time through the short pass, animated by SwiftUI.
    @State private var onceProgress: Double = 0

    var body: some View {
        Group {
            switch motion {
            case .still:
                canvas(.still)
            case .running:
                running
            case .once:
                once
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
        RingCanvas(presentation: presentation, palette: ink)
    }

    // MARK: Running

    /// The loop, or the icon's pose when motion is not allowed.
    ///
    /// A linear clock drives the whole timeline; the phases are computed from
    /// it. A repeating eased animation would stutter once a cycle, which is
    /// exactly the seam the empty hold is meant to hide.
    @ViewBuilder private var running: some View {
        if reduceMotion || !drawersStill {
            canvas(.still)
        } else {
            let palette = ink
            RingCanvas(presentation: .running(0), palette: palette)
                .keyframeAnimator(initialValue: 0.0, repeating: true) { _, time in
                    RingCanvas(presentation: .running(time), palette: palette)
                } keyframes: { _ in
                    LinearKeyframe(1.0, duration: RingMetrics.runningLoop)
                }
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
                guard state.isVisible else { continue }
                context.opacity = state.opacity
                if segment.isDot {
                    let angle = segment.start * .pi / 180
                    let point = CGPoint(
                        x: center.x + radius * CGFloat(cos(angle)),
                        y: center.y + radius * CGFloat(sin(angle)),
                    )
                    let dot = width * state.dotScale
                    let rect = CGRect(
                        x: point.x - dot / 2,
                        y: point.y - dot / 2,
                        width: dot,
                        height: dot,
                    )
                    context.fill(Path(ellipseIn: rect), with: shading)
                } else {
                    let start = segment.start + segment.sweep * state.trimStart
                    let end = segment.start + segment.sweep * state.trimEnd
                    guard end - start > 0.01 else { continue }
                    let path = RingGeometry.arcPath(
                        center: center,
                        radius: radius,
                        start: start,
                        end: end,
                    )
                    context.stroke(path, with: shading, style: style)
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
