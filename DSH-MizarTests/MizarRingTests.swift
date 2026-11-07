//
//  MizarRingTests.swift
//  DSH-MizarTests
//
//  The ring's geometry and its two timelines, as arithmetic.
//
//  The animation itself cannot be stepped frame by frame in a test -- a
//  repeating keyframe animator is not a clock the harness can advance, and the
//  short pass is driven by SwiftUI's own interpolation. What *can* be pinned is
//  the part that is a decision: which piece starts when, that the loop begins
//  and ends on the same empty pose, that the short pass begins and ends on the
//  icon, and that the progress reading fills clockwise. Those are the things a
//  future edit would break silently -- a loop that starts half full looks like a
//  dropped frame, and a progress ring that fills the wrong way looks like a
//  mirrored icon.
//
//  The shape is pinned the same way: the five pieces' angles and the ring's
//  share of its box, not its pixels (the snapshot suite owns those), so a
//  geometry change fails here first and says which number moved.
//

import SwiftUI
import Testing
@testable import DSH_Mizar

@MainActor
struct MizarRingTests {
    // MARK: The shape

    @Test("the mark is four arcs and one dot")
    func pieces() {
        let segments = RingGeometry.segments
        #expect(segments.count == 5)
        #expect(segments.filter { $0.isDot }.count == 1)
        #expect(segments.filter { !$0.isDot }.count == 4)

        // The dot sits at ten o'clock and is the only zero-sweep piece.
        let dot = segments[4]
        #expect(dot.isDot)
        #expect(abs(dot.start - 230) < 0.001)
    }

    @Test("the five pieces are clockwise from the gap, without overlapping")
    func order() {
        let positions = RingGeometry.segments.map(RingGeometry.position)
        // Long arc at the gap, then bottom, lower-left, left, dot.
        #expect(abs(positions[0] - 0) < 0.001)
        #expect(abs(positions[1] - 160) < 0.001)
        #expect(abs(positions[2] - 221) < 0.001)
        #expect(abs(positions[3] - 276) < 0.001)
        #expect(abs(positions[4] - 320) < 0.001)

        // Every piece starts after the previous one ends: the pieces do not
        // overlap, and the gaps are what the eye reads as gaps.
        for (position, segment) in zip(positions, RingGeometry.segments) {
            let next = (position + segment.sweep).truncatingRemainder(dividingBy: 360)
            #expect(next < 360)
        }
        for index in 1..<positions.count {
            let previous = positions[index - 1] + RingGeometry.segments[index - 1].sweep
            #expect(positions[index] > previous, "piece \(index) overlaps the one before it")
        }

        // The pieces and the gaps between them account for the whole circle.
        let sweeps = RingGeometry.segments.reduce(0) { $0 + $1.sweep }
        let gaps = (0..<positions.count).reduce(0) { total, index in
            let next = positions[(index + 1) % positions.count]
            let end = positions[index] + RingGeometry.segments[index].sweep
            let gap = next >= end ? next - end : next + 360 - end
            return total + gap
        }
        #expect(abs(sweeps + gaps - 360) < 0.001)
    }

    @Test("the ring's ink is the icon's share of the box")
    func proportions() {
        // The transparent masters' glyph is about 85.6% of the canvas, with a
        // centreline radius of 0.385 and a stroke of 0.086. These are the two
        // numbers the in-app mark and the raster assets share.
        #expect(abs(RingGeometry.radius - 0.385) < 0.001)
        #expect(abs(RingGeometry.stroke - 0.086) < 0.001)
        #expect(abs(RingGeometry.outer - (0.385 + 0.043)) < 0.001)
        #expect(abs(RingGeometry.inkShare - 0.856) < 0.001)
        #expect(RingGeometry.inkShare < 1)
    }

    @Test("a clockwise arc's path is non-empty and stays inside its box")
    func arcPath() {
        let center = CGPoint(x: 50, y: 50)
        let path = RingGeometry.arcPath(center: center, radius: 30, start: 270, end: 47)
        #expect(!path.isEmpty)
        // The arc runs from the top of the circle clockwise through the right
        // side to the lower-right. Its control-point box is a little larger
        // than the curve, so the assertions are bounds rather than exact
        // coordinates.
        let box = path.boundingRect
        #expect(box.minX >= 49)
        #expect(box.maxX <= 83)
        #expect(box.minY >= 19)
        #expect(box.maxY <= 73)
    }

    // MARK: Easing

    @Test("both easings start and end at rest and never go backwards")
    func easing() {
        #expect(RingMetrics.easeOutCubic(0) == 0)
        #expect(RingMetrics.easeOutCubic(1) == 1)
        #expect(RingMetrics.easeInOutCubic(0) == 0)
        #expect(RingMetrics.easeInOutCubic(0.5) == 0.5)
        #expect(RingMetrics.easeInOutCubic(1) == 1)

        var previousOut = 0.0
        var previousInOut = 0.0
        for step in 0...1000 {
            let p = Double(step) / 1000
            let out = RingMetrics.easeOutCubic(p)
            let inOut = RingMetrics.easeInOutCubic(p)
            #expect(out >= previousOut)
            #expect(inOut >= previousInOut)
            #expect(out >= 0 && out <= 1)
            #expect(inOut >= 0 && inOut <= 1)
            previousOut = out
            previousInOut = inOut
        }
        #expect(RingMetrics.easeOutCubic(-1) == 0)
        #expect(RingMetrics.easeOutCubic(2) == 1)
        #expect(RingMetrics.easeInOutCubic(-1) == 0)
        #expect(RingMetrics.easeInOutCubic(2) == 1)
    }

    // MARK: The running loop

    @Test("the loop starts and ends on the same empty pose")
    func loopSeam() {
        let start = RingPresentation.running(0)
        let end = RingPresentation.running(1)
        for index in RingGeometry.segments.indices {
            #expect(start.state(for: index) == end.state(for: index))
            #expect(!start.state(for: index).isVisible)
        }
    }

    @Test("the loop holds with the ring whole")
    func loopHoldsWhole() {
        // The last reveal has finished, and no retract has started yet.
        let time = (RingMetrics.runRevealSpan + RingMetrics.runHoldFull / 2) / RingMetrics.runningLoop
        let presentation = RingPresentation.running(time)
        for index in RingGeometry.segments.indices {
            #expect(presentation.state(for: index).isVisible)
            #expect(abs(presentation.state(for: index).trimEnd - 1) < 1e-9)
            #expect(presentation.state(for: index).opacity == 1)
        }
    }

    @Test("the loop's last hold is empty before the seam")
    func loopHoldsEmpty() {
        let time = 1 - RingMetrics.runHoldEmpty / (2 * RingMetrics.runningLoop)
        let presentation = RingPresentation.running(time)
        for index in RingGeometry.segments.indices {
            #expect(!presentation.state(for: index).isVisible)
        }
    }

    @Test("the pieces load and erase in clockwise order")
    func loopOrder() {
        // Just after the second piece starts, the first is already painting,
        // the second is painting, and nothing after them has begun. The
        // stagger overlaps the draws; the order is still one way.
        let time = (RingMetrics.runRevealStagger + 0.02) / RingMetrics.runningLoop
        let reveal = RingPresentation.running(time)
        #expect(reveal.state(for: 0).isVisible)
        #expect(reveal.state(for: 1).isVisible)
        #expect(!reveal.state(for: 2).isVisible)
        #expect(!reveal.state(for: 4).isVisible)

        // The first retract begins before the last piece has started to go.
        let eraseTime = RingMetrics.runRevealSpan
            + RingMetrics.runHoldFull
            + 0.02
        let erase = RingPresentation.running(eraseTime / RingMetrics.runningLoop)
        #expect(erase.state(for: 0).trimStart > 0)
        #expect(abs(erase.state(for: 4).trimStart) < 1e-9)
        #expect(erase.state(for: 4).opacity == 1)
    }

    @Test("the loop is long enough to read and short enough to wait on")
    func loopLength() {
        #expect(RingMetrics.runningLoop > 1.5)
        #expect(RingMetrics.runningLoop < 3.0)
        #expect(RingMetrics.runRevealSpan > 0)
        #expect(RingMetrics.runRetractSpan > 0)
    }

    // MARK: The short pass

    @Test("the short pass starts and ends on the static icon")
    func onceEndsOnIcon() {
        for index in RingGeometry.segments.indices {
            #expect(RingPresentation.once(0).state(for: index) == .full)
            #expect(RingPresentation.once(1).state(for: index) == .full)
        }
    }

    @Test("the short pass is empty between erasing and loading")
    func onceEmpties() {
        let time = (RingMetrics.onceHoldFull
            + RingMetrics.onceRetractSpan
            + RingMetrics.onceHoldEmpty / 2) / RingMetrics.onceDuration
        let presentation = RingPresentation.once(time)
        for index in RingGeometry.segments.indices {
            #expect(!presentation.state(for: index).isVisible)
        }
    }

    @Test("the short pass is a transition, not a wait")
    func onceLength() {
        #expect(RingMetrics.onceDuration > 1.0)
        #expect(RingMetrics.onceDuration < 2.0)
        #expect(RingMetrics.onceDuration < RingMetrics.runningLoop)
    }

    @Test("the short pass erases and loads in the same order")
    func onceOrder() {
        let eraseTime = (RingMetrics.onceHoldFull + 0.02) / RingMetrics.onceDuration
        let erase = RingPresentation.once(eraseTime)
        #expect(erase.state(for: 0).trimStart > 0)
        #expect(erase.state(for: 4).trimStart == 0)

        let loadTime = (RingMetrics.onceHoldFull
            + RingMetrics.onceRetractSpan
            + RingMetrics.onceHoldEmpty
            + 0.02) / RingMetrics.onceDuration
        let load = RingPresentation.once(loadTime)
        #expect(load.state(for: 0).isVisible)
        #expect(!load.state(for: 2).isVisible)
    }

    // MARK: The progress reading

    @Test("the progress reading is empty at zero and the icon at one")
    func openingEnds() {
        for index in RingGeometry.segments.indices {
            #expect(!RingPresentation.opening(0).state(for: index).isVisible)
            #expect(RingPresentation.opening(1).state(for: index) == .full)
        }
    }

    @Test("the progress reading fills clockwise")
    func openingOrder() {
        // Half way is 180 degrees: the long arc (0...137) is whole, the bottom
        // arc (160...199) is part-way, and everything after it is untouched.
        let half = RingPresentation.opening(0.5)
        #expect(abs(half.state(for: 0).trimEnd - 1) < 1e-9)
        #expect(half.state(for: 1).trimEnd > 0)
        #expect(half.state(for: 1).trimEnd < 1)
        #expect(!half.state(for: 2).isVisible)
        #expect(!half.state(for: 3).isVisible)
        #expect(!half.state(for: 4).isVisible)
    }

    @Test("the dot is the last piece the reading lights")
    func openingDotLast() {
        // 320 of 360 degrees is where the dot's position begins.
        let beforeDot = RingPresentation.opening(0.87)
        #expect(!beforeDot.state(for: 4).isVisible)
        let atDot = RingPresentation.opening(0.9)
        #expect(atDot.state(for: 4).isVisible)
        #expect(atDot.state(for: 4).dotScale > 0.5)
    }

    @Test("the reading never goes backwards")
    func openingMonotonic() {
        var previous = [Double](repeating: -1, count: RingGeometry.segments.count)
        for step in 0...360 {
            let presentation = RingPresentation.opening(Double(step) / 360)
            for index in RingGeometry.segments.indices {
                let state = presentation.state(for: index)
                // `trimEnd` is only meaningful while a piece is visible; an
                // empty piece's sentinel is not a fill value.
                let value = state.isVisible ? state.trimEnd : 0
                #expect(value >= previous[index])
                previous[index] = value
            }
        }
    }

    // MARK: The piece states

    @Test("a revealing piece grows and a retracting one shrinks")
    func pieceStates() {
        #expect(!SegmentState.revealing(0).isVisible)
        #expect(SegmentState.revealing(1) == .full)
        #expect(SegmentState.retracting(0) == .full)
        #expect(!SegmentState.retracting(1).isVisible)

        var previousTrim = 0.0
        for step in 0...100 {
            let state = SegmentState.revealing(Double(step) / 100)
            #expect(state.trimEnd >= previousTrim)
            #expect(state.opacity >= 0 && state.opacity <= 1)
            previousTrim = state.trimEnd
        }
        var previousErase = 0.0
        for step in 0...100 {
            let state = SegmentState.retracting(Double(step) / 100)
            #expect(state.trimStart >= previousErase)
            #expect(state.opacity >= 0 && state.opacity <= 1)
            previousErase = state.trimStart
        }
    }

    @Test("only the progress reading draws a track")
    func track() {
        #expect(RingPresentation.opening(0.5).drawsTrack)
        #expect(!RingPresentation.still.drawsTrack)
        #expect(!RingPresentation.running(0.5).drawsTrack)
        #expect(!RingPresentation.once(0.5).drawsTrack)
    }
}
