//
//  FlightOverlay.swift
//  DSH-Mizar
//
//  A send, travelling.
//
//  When the operator sends, the words lift out of the field and fly up into the
//  place their bubble will take, turning from typed text into a sent message on
//  the way. It is the one moment in the app that is pure motion, and it earns
//  its place: it says "that went" at the instant of the tap, a round trip before
//  the host can say so.
//
//  It is honest about being a promise. The bubble it lands in is a stand-in --
//  hidden from VoiceOver and from anything reading the screen -- and it gives
//  way to the conversation's own copy the moment the host's record is read
//  back. If the host refuses the message, the stand-in goes and the text is
//  back in the field.
//

import SwiftUI

/// A message sent and not yet read back.
struct OutgoingMessage: Identifiable, Equatable {
    var id = UUID()
    let text: String
    /// Whether the flight has arrived, so the stand-in can show.
    var landed = false
}

/// The ghost's journey.
struct Flight: Equatable {
    let id: UUID
    let text: String
    /// The field, where it starts.
    let from: CGRect
    /// The stand-in bubble, where it ends, once it has been laid out.
    var to: CGRect?
    var progress: CGFloat = 0
}

/// Where each stand-in was last laid out, read once when its flight starts.
///
/// Not state: the frame moves on every layout pass while the conversation
/// settles, and nothing needs to redraw when it does.
@MainActor
final class FlightFrames {
    static let shared = FlightFrames()
    var frames: [UUID: CGRect] = [:]
    var scheduled: Set<UUID> = []
}

/// The stand-in, in the conversation.
struct PendingBubble: View {
    let text: String
    let visible: Bool

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 56)
            SentBubbleBody(text: text)
        }
        .opacity(visible ? 0.85 : 0)
        .accessibilityHidden(true)
        .accessibilityIdentifier("message.pending")
    }
}

/// The look of a sent message, shared by the stand-in and the ghost.
struct SentBubbleBody: View {
    let text: String

    var body: some View {
        Text(text)
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                    .fill(Color.accentColor.gradient)
            }
    }
}

/// The words in flight.
struct FlightGhost: View {
    let flight: Flight

    var body: some View {
        if let to = flight.to {
            let p = flight.progress
            // Laid out at the bubble's own width from the start, so the text
            // does not reflow mid-air; it lifts from the field's leading edge,
            // sitting on the field's baseline, and travels to the bubble.
            let start = CGPoint(x: flight.from.minX, y: flight.from.maxY - to.height)
            let x = start.x + (to.minX - start.x) * p
            let y = start.y + (to.minY - start.y) * p
            SentBubbleBody(text: flight.text)
                .frame(width: to.width, height: to.height)
                // A little arc: up and out first, then down into place.
                .scaleEffect(0.86 + 0.14 * p, anchor: .bottomLeading)
                .offset(x: x, y: y - sin(p * .pi) * 18)
                .opacity(Double(min(1, p * 4)))
                .shadow(color: Color.accentColor.opacity(0.35 * (1 - p)), radius: 14, y: 6)
        }
    }
}

/// The way back to the newest message, when the operator has scrolled away.
struct JumpToLatest: View {
    /// Messages that arrived below since.
    let unseen: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                GlassCircleLabel(size: 28) {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 11, weight: .semibold))
                        .symbolEffect(.bounce.down, value: unseen)
                }
                if unseen > 0 {
                    Text("\(unseen)")
                        .font(.system(size: 9, weight: .bold).monospacedDigit())
                        .foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, 4)
                        .frame(minWidth: 14, minHeight: 14)
                        .background(Color.accentColor, in: Capsule())
                        .offset(x: 3, y: -3)
                        .contentTransition(.numericText())
                        .transition(.pop)
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(.rect)
            .animation(.mizarBouncy, value: unseen)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Jump to the latest message"))
        .accessibilityIdentifier("conversation.jumpToLatest")
    }
}
