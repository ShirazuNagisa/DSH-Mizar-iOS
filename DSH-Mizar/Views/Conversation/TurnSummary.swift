//
//  TurnSummary.swift
//  DSH-Mizar
//
//  How long a turn took, why it stopped, and whether it has more behind it.
//

import SwiftUI
import MizarKit

/// "DeepSeeking for 2 min 14 s", "Completed in 2 min 14 s", or why it did not.
struct TurnSummary: View {
    let turn: ConversationTurn
    /// Whether the row offers the paid detail, so a chevron shows that there is
    /// more behind it. Off for free accounts and for turns with no detail.
    var showsChevron = false
    /// Which way the chevron points, and where the detail is going.
    var expanded = false

    var body: some View {
        HStack(spacing: 7) {
            // The state, as a glyph that changes rather than appears: the mark
            // turning while it works, settling into a tick when it is done.
            ZStack {
                if turn.isRunning {
                    MizarRing(ink: 17, motion: .running)
                        .transition(.pop)
                } else if turn.isEndInferred {
                    // A later turn proves this one is over, but the log never
                    // said how. A hollow tick rather than a filled one: the row
                    // may not claim a completion the host did not report.
                    Image(systemName: "checkmark.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .symbolRenderingMode(.hierarchical)
                        .transition(.pop)
                } else {
                    Image(systemName: turn.failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(turn.failed ? Theme.waiting : Theme.running)
                        .symbolRenderingMode(.hierarchical)
                        .transition(.pop)
                }
            }
            // The running mark is 17 points of ink, and its box is that over
            // the design margin (about 24); the column is wide enough that the
            // arms do not crowd the headline.
            .frame(width: 20, height: 20)

            headline
            Spacer(minLength: 8)
            // Only when the log actually said. A turn whose markers were trimmed
            // away by the pager shows no number rather than a zero it would be
            // counted as -- "no steps" is a claim this row cannot make.
            // No step count and no disclosure: the host no longer streams the
            // per-step detail this row used to open, so the number and the
            // chevron would be an invitation to nothing.
            if showsChevron {
                // A chevron that turns rather than swaps: the row is the same
                // row open and shut, and the glyph saying so should be the same
                // glyph. Rotated, not replaced, so no second element appears.
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .animation(.mizarSnappy, value: expanded)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 2)
        .animation(.mizarBouncy, value: turn.isRunning)
        .animation(.mizarSnappy, value: turn.stepCount)
        // One small tap when a turn the operator is watching finishes. Only on
        // the change, never on the first draw of a finished turn -- and never
        // for a turn settled from a missing record, which nobody just watched.
        .mizarFeedback(.success, trigger: turn.isRunning) { old, new in
            old && !new && !turn.failed && !turn.isEndInferred
        }
    }

    /// The state of the turn, and for a running one a clock that moves.
    ///
    /// One `Text` -- the headline is the row's whole statement, and it is read
    /// as one sentence. Ticked locally rather than by asking the computer: the host
    /// already said when the turn started.
    @ViewBuilder private var headline: some View {
        if turn.isRunning, turn.beganAt != nil {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                // Through `elapsed(asOf:)`, which clamps at zero: the start came
                // off the host's clock and `context.date` is the phone's.
                let running = turn.elapsed(asOf: context.date) ?? 0
                // No shimmer here. The sweep is a repeating keyframe animation
                // that re-masks its text every frame, and this text lives in
                // the conversation's LazyVStack: a stack measured it while the
                // mask was animating, and the text-layout attribute looped
                // (100% CPU, memory climbing). The clock still ticks and its
                // digits still transition; the decoration is not worth a
                // layout fight inside a lazy row.
                // A plain text, updated once a second: no numeric transition
                // and no animation. The animated variant kept the row's text
                // layout attribute in play inside the lazy stack -- the same
                // failure class as the shimmer removed above, only at 1 Hz.
                // Monospaced digits keep the width from stepping.
                Text(String(format: String(localized: "DeepSeeking for %@"), Self.spell(running)))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        } else {
            Text(staticHeadline)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .contentTransition(.interpolate)
        }
    }

    /// The headline for a turn whose text does not change.
    private var staticHeadline: String {
        // A turn with a number and no end is running; this case is reached when
        // it also has no start to measure from.
        if turn.isRunning { return String(localized: "DeepSeeking") }
        // A turn whose end record never arrived, but which a later turn proves
        // is over. No duration: the end this row was given is an upper bound,
        // not a measurement, and a figure here would read as one.
        if turn.isEndInferred { return String(localized: "Ended") }
        if turn.failed {
            return turn.duration.map {
                String(format: String(localized: "Unfinished after %@"), Self.spell($0))
            } ?? String(localized: "Unfinished")
        }
        return turn.duration.map {
            String(format: String(localized: "Completed in %@"), Self.spell($0))
        } ?? String(localized: "Completed")
    }

    /// Minutes and seconds, because that is the unit a turn is measured in.
    static func spell(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return String(format: String(localized: "%lld s"), total) }
        return String(format: String(localized: "%lld min %lld s"), total / 60, total % 60)
    }
}
