//
//  LinkStatusBar.swift
//  DSH-Mizar
//
//  The sidebar's link bar: the phone, the computer, and -- only when the link is
//  relayed -- the server between them.
//
//  A picture rather than a sentence. The old row under the agent capsule said
//  which half of the trip was down in words; it was accurate and it was in the
//  way of the list the sidebar exists for. This says the same thing in one
//  glance: a cross on the segment that failed, and dots that breathe while the
//  link is alive.
//
//  Nothing here is interactive. The connection window at the foot of the
//  sidebar is the door to the explanation, the latency and the reconnect; this
//  is the status light.
//

import SwiftUI

struct LinkStatusBar: View {
    let status: LinkStatus

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Continuous motion holds while a drawer is being dragged or is settling:
    /// the sidebar is travelling with a full-screen mask over it, and frames
    /// spent on decoration there belong to the card under the finger.
    @Environment(\.drawersStill) private var drawersStill

    /// Whether the dots should be breathing right now.
    private var breathing: Bool {
        status.connected && !reduceMotion && drawersStill
    }

    var body: some View {
        // One wave crosses the whole bar, so a relayed picture continues the
        // motion through the server rather than restarting it at each segment.
        let slots = status.topology == .relay ? 10 : 5
        HStack(spacing: 6) {
            // The phone and the computer are the same views in both pictures:
            // only what sits between them changes, so a route that lands on the
            // relay grows a device instead of redrawing the whole bar.
            icon("iphone", tint: .secondary)
            if status.topology == .relay {
                segment(.phoneToRelay, baseSlot: 0, slots: slots)
                icon("server.rack", tint: relayTint)
                    .transition(.opacity)
                segment(.relayToComputer, baseSlot: 5, slots: slots)
                    .transition(.opacity)
            } else {
                segment(.phoneToComputer, baseSlot: 0, slots: slots)
                    .transition(.opacity)
            }
            icon("desktopcomputer", tint: computerTint)
        }
        .frame(height: 22)
        .animation(.mizarSnappy, value: status)
        // One element, one sentence. The icons and the dots are the same fact
        // drawn twice for the eye; VoiceOver gets it once.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(status.label.text))
        .accessibilityIdentifier("sidebar.link")
    }

    // MARK: - Devices

    private var relayTint: HierarchicalShapeStyle {
        status.broken == .phoneToRelay ? .tertiary : .secondary
    }

    /// The computer dims whenever a cross is on the way to it: a broken first
    /// segment means the computer is beyond the break, not merely next to it.
    /// A refusal is the exception -- the computer answered, so it is there.
    private var computerTint: HierarchicalShapeStyle {
        if status.label == .refused { return .secondary }
        return status.broken == nil ? .secondary : .tertiary
    }

    private func icon(_ symbol: String, tint: HierarchicalShapeStyle) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: 14, height: 14)
    }

    // MARK: - The line

    /// Five dots, or four and a cross where this segment is the broken one.
    ///
    /// The cross replaces the middle dot rather than sitting on top of the row:
    /// a mark drawn over a dot is two marks fighting for the same three points,
    /// and this reads at the size the bar is actually drawn at.
    private func segment(_ segment: LinkStatus.Segment, baseSlot: Int, slots: Int) -> some View {
        let broken = status.broken == segment
        let tint = dotTint(segment)
        // A travelling wave needs one clock for the whole bar, not one animation
        // per dot: `phaseAnimator` would drift apart, and a per-dot delay would
        // lengthen the cycle as well as shift it. The timeline gives every dot
        // the same period and a fixed lag by position.
        return TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !breathing || broken)) { context in
            HStack(spacing: 4) {
                ForEach(0..<5, id: \.self) { index in
                    if broken, index == 2 {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .heavy))
                            .foregroundStyle(Theme.failed)
                            .frame(width: 3, height: 3)
                    } else {
                        Circle()
                            .fill(tint)
                            .frame(width: 3, height: 3)
                            .scaleEffect(scale(at: context.date, slot: baseSlot + index, slots: slots))
                    }
                }
            }
        }
    }

    /// Where one dot is in the breath.
    ///
    /// The wave takes 45% of the cycle to cross the bar, whichever picture it
    /// is: five slots for a direct link, ten for a relayed one. That keeps the
    /// apparent speed the same when the server appears, and it keeps the wave
    /// from wrapping onto itself -- a lag of a whole period looks like a bar
    /// that is not moving at all.
    private func scale(at date: Date, slot: Int, slots: Int) -> CGFloat {
        guard breathing else { return 1 }
        let period: TimeInterval = 1.8
        let span = 0.45
        let lead = Double(slot) / Double(max(slots - 1, 1)) * span
        let progress = date.timeIntervalSinceReferenceDate / period
        let phase = (progress - lead).truncatingRemainder(dividingBy: 1)
        let wave = 0.5 - 0.5 * cos(2 * .pi * phase)
        return 0.6 + 0.7 * wave
    }

    /// A broken segment is faint, a live one is the ordinary secondary, and a
    /// segment the phone has already crossed stays visible when the far side is
    /// the part that failed -- that is the difference the picture is for.
    private func dotTint(_ segment: LinkStatus.Segment) -> HierarchicalShapeStyle {
        if status.broken == segment { return .tertiary }
        if status.connected { return .secondary }
        // Still dialling: nothing is known about either hop yet.
        if status.broken == nil { return .tertiary }
        // A failure behind the relay proves the near hop worked. A phone that
        // never reached the server knows nothing about the hop after it, and
        // drawing that one bright would claim a fact the dial did not produce.
        return status.broken == .relayToComputer && segment == .phoneToRelay
            ? .secondary
            : .tertiary
    }
}

extension LinkStatus.Label {
    /// The short sentence VoiceOver reads for this state.
    var text: String {
        switch self {
        case .connectedDirect: String(localized: "Link OK, direct")
        case .connectedRelay: String(localized: "Link OK, through the relay server")
        case .connecting: String(localized: "Connecting")
        case .relayUnreachable: String(localized: "Could not reach the relay server")
        case .offline: String(localized: "This device has no network connection.")
        case .computerAbsent: String(localized: "Connected to the server, but not to the computer.")
        case .computerUnreachable: String(localized: "Could not reach this computer")
        case .refused: String(localized: "The computer refused the connection")
        }
    }
}
