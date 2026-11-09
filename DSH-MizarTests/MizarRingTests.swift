//
//  MizarRingTests.swift
//  DSH-MizarTests
//
//  The ring's geometry and its timelines, as arithmetic.
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

    @Test("the easings start and end at rest and never go backwards")
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

        #expect(RingMetrics.easeInOutQuint(0) == 0)
        #expect(RingMetrics.easeInOutQuint(0.5) == 0.5)
        #expect(RingMetrics.easeInOutQuint(1) == 1)

        #expect(RingMetrics.easeInOutSine(0) == 0)
        #expect(abs(RingMetrics.easeInOutSine(0.5) - 0.5) < 1e-9)
        #expect(RingMetrics.easeInOutSine(1) == 1)
        // The shrink must actually move at the beginning; a quintic sits
        // almost still for the first tenth of a second and reads as a stutter.
        #expect(RingMetrics.easeInOutSine(0.1) > 0.02)

        // The morph overshoots by a hair and lands exactly on 1; the shrink is
        // a different curve and never crosses below empty.
        var previousShrink = 0.0
        var morphPeak = 0.0
        for step in 0...1000 {
            let p = Double(step) / 1000
            let morph = RingMetrics.morph(p)
            let shrink = RingMetrics.easeInOutQuint(p)
            morphPeak = max(morphPeak, morph)
            #expect(shrink >= previousShrink)
            #expect(shrink >= 0 && shrink <= 1)
            previousShrink = shrink
        }
        #expect(RingMetrics.morph(0) == 0)
        #expect(RingMetrics.morph(1) == 1)
        #expect(morphPeak > 1)
        #expect(morphPeak < 1.05)
    }

    @Test("the starts accelerate and decelerate instead of ticking")
    func staggeredStarts() {
        let starts = (0..<RingGeometry.segments.count).map {
            RingMetrics.staggeredStart(index: $0, window: 1)
        }
        #expect(starts.first == 0)
        #expect(starts.last == 1)
        for (earlier, later) in zip(starts, starts.dropFirst()) {
            #expect(earlier < later)
        }
        // Slow, fast, slow: the edge gaps are shorter than the middle ones.
        #expect(starts[1] - starts[0] < starts[2] - starts[1])
        #expect(starts[4] - starts[3] < starts[3] - starts[2])
    }

    // MARK: The running loop

    @Test("the first and last frame are the same full five-dot queue")
    func loopSeam() {
        let start = RingPresentation.running(0)
        let end = RingPresentation.running(1)
        let expected = RingQueue.initialStarts.map(RingQueue.normalized)
        for index in RingGeometry.segments.indices {
            let a = start.state(for: index)
            let b = end.state(for: index)
            #expect(a == b)
            #expect(a.opacity == 1)
            #expect(a.dotOpacity == 1)
            #expect(a.dotScale == 1)
            #expect(a.sweepScale == 0)
            let angle = RingQueue.normalized(
                RingGeometry.segments[index].start + a.positionOffset,
            )
            #expect(abs(angle - expected[index]) < 1e-6)
        }
    }

    @Test("the finished icon holds with every piece whole")
    func loopHoldsWhole() {
        let time = (RingMetrics.holdStart + RingMetrics.holdFull / 2) / RingMetrics.runningLoop
        let presentation = RingPresentation.running(time)
        for index in 0..<4 {
            let state = presentation.state(for: index)
            #expect(state.isVisible)
            #expect(abs(state.trimEnd - 1) < 1e-9)
            #expect(abs(state.sweepScale - 1) < 1e-9)
            #expect(state.opacity == 1)
        }
        let dot = presentation.state(for: 4)
        #expect(dot.isVisible)
        #expect(dot.sweepScale == 0)
        #expect(dot.opacity == 1)
    }

    @Test("the initial queue is already complete before growth")
    func loopInitialQueue() {
        let time = 0.01 / RingMetrics.runningLoop
        let presentation = RingPresentation.running(time)
        let expected = RingQueue.initialStarts.map(RingQueue.normalized)
        for index in RingGeometry.segments.indices {
            let state = presentation.state(for: index)
            #expect(state.opacity == 1)
            #expect(state.dotScale == 1)
            #expect(state.sweepScale == 0)
            let angle = RingQueue.normalized(
                RingGeometry.segments[index].start + state.positionOffset,
            )
            #expect(abs(angle - expected[index]) < 1e-6)
        }
    }

    @Test("the front arc grows and pushes the dots behind it clockwise")
    func loopChainPush() {
        let time = (RingMetrics.morphPhaseStart + 0.10) / RingMetrics.runningLoop
        let presentation = RingPresentation.running(time)

        let front = presentation.state(for: 0)
        #expect(front.sweepScale > 0)
        #expect(front.sweepScale < 1)
        #expect(front.positionOffset >= 0)

        let second = presentation.state(for: 1)
        let initialSecond = RingQueue.initialStarts[1]
        let actualSecond = RingGeometry.segments[1].start + second.positionOffset
        #expect(actualSecond > initialSecond)

        let frontEnd = RingGeometry.segments[0].start + front.positionOffset
            + RingGeometry.segments[0].sweep * front.sweepScale
        #expect(abs((actualSecond - frontEnd) - RingQueue.gaps[0]) < 1e-6)
    }

    @Test("growth lands exactly on the finished icon")
    func loopGrowthLands() {
        let time = (RingMetrics.holdStart + RingMetrics.holdFull / 2) / RingMetrics.runningLoop
        let presentation = RingPresentation.running(time)
        for index in 0..<4 {
            let state = presentation.state(for: index)
            #expect(abs(state.sweepScale - 1) < 1e-9)
            #expect(state.trimEnd == 1)
            #expect(state.dotOpacity == 0)
            let start = RingGeometry.segments[index].start + state.positionOffset
            #expect(abs(RingQueue.normalized(start) - RingQueue.finalStarts[index]) < 1e-6)
        }
        let dot = presentation.state(for: 4)
        #expect(dot.dotOpacity > 0)
        #expect(dot.sweepScale == 0)
        let dotStart = RingGeometry.segments[4].start + dot.positionOffset
        #expect(abs(RingQueue.normalized(dotStart) - RingQueue.finalStarts[4]) < 1e-6)
    }

    @Test("contraction keeps the chain gaps and re-forms the queue in one process")
    func loopShrink() {
        let time = (RingMetrics.shrinkPhaseStart + 0.12) / RingMetrics.runningLoop
        let presentation = RingPresentation.running(time)

        // Every arc has started to contract; the queue starts are still
        // constrained by the adjacent gaps.
        for index in 0..<4 {
            let state = presentation.state(for: index)
            #expect(state.sweepScale <= 1)
            #expect(state.sweepScale >= 0)
            if index > 0 {
                let previous = presentation.state(for: index - 1)
                let previousEnd = RingGeometry.segments[index - 1].start
                    + previous.positionOffset
                    + RingGeometry.segments[index - 1].sweep * previous.sweepScale
                let currentStart = RingGeometry.segments[index].start + state.positionOffset
                #expect(abs((currentStart - previousEnd) - RingQueue.gaps[index - 1]) < 1e-6)
            }
        }

        // The debug fronts move strictly clockwise for every piece, across
        // the twelve o'clock wrap.
        let early = RingPresentation.running(
            (RingMetrics.shrinkPhaseStart + 0.08) / RingMetrics.runningLoop,
        ).shrinkFrontsUnwrapped()
        let late = RingPresentation.running(
            (RingMetrics.shrinkPhaseStart + 0.30) / RingMetrics.runningLoop,
        ).shrinkFrontsUnwrapped()
        #expect(early != nil)
        #expect(late != nil)
        if let early, let late {
            for index in 0..<4 {
                #expect(late[index] > early[index])
            }
        }

        // The last frame is the initial queue, not a detached set of dots:
        // the starts have continuously followed the shrinking lengths.
        let end = RingPresentation.running(
            (RingMetrics.shrinkPhaseStart + RingMetrics.shrinkSpan) / RingMetrics.runningLoop,
        )
        let expected = RingQueue.initialStarts.map(RingQueue.normalized)
        for index in RingGeometry.segments.indices {
            let state = end.state(for: index)
            #expect(state.opacity == 1)
            #expect(state.dotScale == 1)
            #expect(state.sweepScale == 0)
            let angle = RingQueue.normalized(
                RingGeometry.segments[index].start + state.positionOffset,
            )
            #expect(abs(angle - expected[index]) < 1e-6)
        }
    }

    @Test("one loop is a continuous chain, not a sequence of empty states")
    func loopLength() {
        #expect(RingMetrics.runningLoop > 1.2)
        #expect(RingMetrics.runningLoop < 2.5)
        #expect(RingMetrics.holdQueue > 0)
        #expect(RingMetrics.morphSpan > 0)
        #expect(RingMetrics.shrinkSpan > 0)
    }

    @Test("the settings one-shot starts on the five-dot queue")
    func assemblyStartsAtDots() {
        let presentation = RingPresentation.assembling(0)
        let expected = RingQueue.initialStarts.map(RingQueue.normalized)
        for index in RingGeometry.segments.indices {
            let state = presentation.state(for: index)
            #expect(state.opacity == 1)
            #expect(state.dotScale == 1)
            #expect(state.sweepScale == 0)
            let angle = RingQueue.normalized(
                RingGeometry.segments[index].start + state.positionOffset,
            )
            #expect(abs(angle - expected[index]) < 1e-6)
        }
    }

    @Test("the settings one-shot stops on the finished icon")
    func assemblyEndsOnIcon() {
        let presentation = RingPresentation.assembling(1)
        for index in 0..<4 {
            let state = presentation.state(for: index)
            #expect(state.isVisible)
            #expect(abs(state.trimEnd - 1) < 1e-9)
            #expect(abs(state.sweepScale - 1) < 1e-9)
            #expect(state.opacity == 1)
        }
        let dot = presentation.state(for: 4)
        #expect(dot.isVisible)
        #expect(dot.sweepScale == 0)
        #expect(dot.opacity == 1)
    }

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
        #expect(RingMetrics.onceDuration < 2.0)
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

    // MARK: The settings assembly

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
