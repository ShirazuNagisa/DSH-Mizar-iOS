//
//  RefreshGlyph.swift
//  DSH-Mizar
//
//  The refresh control, in the three states one pass goes through: an arrow, a
//  ring, a check.
//
//  The control used to turn its arrow for as long as a pass ran. A turn is a
//  claim that something is happening; it is not a claim about how much is left,
//  and a pass over every conversation on a relay is long enough for the
//  difference to matter. So the glyph *becomes* the progress -- an accent ring
//  that fills clockwise from the top, one turn for one pass -- and then a check
//  for a beat, so the end of the wait is something the eye catches rather than
//  something it has to deduce from the arrow coming back.
//
//  One control, drawn twice: the sidebar's round button and the conversation's
//  toolbar item share this view, so "what a refresh looks like" is one decision
//  in one place. The sidebar's is the only one with a window behind it, and
//  that is a property of the button, not of the glyph.
//

import SwiftUI

/// How a refresh is going, as a control can draw it.
///
/// A small enum rather than two loose arguments: a pass that has finished and a
/// pass that has not started are both `running == false`, and the check between
/// them is the whole point of the third state.
enum RefreshPhase: Equatable {
    /// Nothing is running.
    case idle
    /// A pass is running, with how far it has got when that is known.
    ///
    /// `nil` is "running, count unknown": an automatic pass -- a launch's first
    /// read, a return to the foreground -- reports no totals, and a ring frozen
    /// at zero would read as a pass that had not started.
    case running(fraction: Double?)
    /// The pass just landed.
    case landed
}

/// The glyph: an arrow at rest, an accent ring while a pass runs, a check when
/// it lands, then the arrow again.
struct RefreshGlyph: View {
    /// Which of the three states to draw.
    let phase: RefreshPhase
    /// The glyph's drawn size, which is the arrow's.
    var size: CGFloat = 15

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: size, weight: .semibold))
                .opacity(showsArrow ? 1 : 0)
                .scaleEffect(showsArrow ? 1 : 0.72)
            if case .running(let fraction) = phase {
                ring(fraction: fraction)
                    .transition(.opacity.combined(with: .scale(scale: 0.72)))
            }
            if phase == .landed {
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.92, weight: .bold))
                    .foregroundStyle(Theme.accentText)
                    .transition(.opacity.combined(with: .scale(scale: 0.6)))
            }
        }
        .frame(width: size * 1.45, height: size * 1.45)
        // One transaction for the three states: the arrow leaves as the ring
        // arrives, and the check replaces the ring the same way. Nothing here
        // is a swap.
        .animation(Motion.pick(.mizarSnappy), value: phase)
        .accessibilityHidden(true)
    }

    /// The arrow shows only at rest: a ring with an arrow inside it is two
    /// controls drawn in one place.
    private var showsArrow: Bool { phase == .idle }

    /// The ring, filling clockwise from twelve o'clock.
    ///
    /// - Parameter fraction: how far the pass has got, or `nil` when it has not
    ///   said. A known fraction is drawn as it arrives -- linear, not sprung: a
    ///   progress ring that overshoots is a progress ring that lies about where
    ///   it is. An unknown one turns a short arc instead, which says "working"
    ///   without claiming a position.
    @ViewBuilder
    private func ring(fraction: Double?) -> some View {
        let diameter = size * 1.35
        let line: CGFloat = 2.1
        ZStack {
            Circle()
                .stroke(Color.accentColor.opacity(0.16), lineWidth: line)
            if let fraction {
                Circle()
                    .trim(from: 0, to: max(0.04, min(1, fraction)))
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: line, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.35), value: fraction)
            } else {
                Circle()
                    .trim(from: 0, to: 0.22)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: line, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .modifier(EndlessTurn(enabled: !reduceMotion))
            }
        }
        .frame(width: diameter, height: diameter)
    }
}

/// A rotation that never settles, for a pass with no count to fill against.
///
/// `phaseAnimator` rather than a `repeatForever` animation: the phase runs from
/// zero to one and starts again, and a whole turn per cycle makes the restart
/// invisible -- the second cycle begins exactly where the first ended. It also
/// stops when the view leaves, which a repeating animation on a stored value
/// does not.
private struct EndlessTurn: ViewModifier {
    let enabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.phaseAnimator([0.0, 1.0]) { arc, phase in
                arc.rotationEffect(.degrees(360 * phase))
            } animation: { _ in
                .linear(duration: 1.15)
            }
        } else {
            content
        }
    }
}

extension RefreshGlyph {
    /// The glyph for a control that knows whether a pass runs and how far it has
    /// got, and holds its own check for a beat after it lands.
    ///
    /// - Parameters:
    ///   - running: whether a pass is on the socket.
    ///   - fraction: how far it has got, when that is known.
    ///   - size: the arrow's size.
    /// - Returns: a glyph that shows the check by itself.
    static func live(running: Bool, fraction: Double?, size: CGFloat = 15) -> LiveRefreshGlyph {
        LiveRefreshGlyph(running: running, fraction: fraction, size: size)
    }
}

/// The glyph with the check's timing built in.
///
/// Separate from ``RefreshGlyph`` because the check is a moment, not a state the
/// caller has: whoever starts a pass knows when it ended, and nobody wants to
/// schedule the fade back to the arrow at every call site.
struct LiveRefreshGlyph: View {
    let running: Bool
    let fraction: Double?
    var size: CGFloat = 15

    /// Whether the check is up, having just landed.
    @State private var landed = false

    /// How long the check stays before the arrow comes back.
    private static let checkDuration = Duration.milliseconds(1100)

    var body: some View {
        RefreshGlyph(phase: phase, size: size)
            .onChange(of: running) { wasRunning, isRunning in
                guard wasRunning, !isRunning else { return }
                withMizarAnimation(.mizarBouncy) { landed = true }
                Task { @MainActor in
                    try? await Task.sleep(for: Self.checkDuration)
                    withMizarAnimation(.mizarSmooth) { landed = false }
                }
            }
    }

    private var phase: RefreshPhase {
        if running { return .running(fraction: fraction) }
        return landed ? .landed : .idle
    }
}
