//
//  SessionTopStatusRow.swift
//  DSH-Mizar
//
//  The two facts at the top of a desktop DSH session: what it is trying to do,
//  and how far along its plan is.
//
//  The row sits where the session's own chrome would be, and each capsule opens
//  the card behind it -- one card at a time, the same rule as the composer's
//  surfaces. The chips are glass while they are closed; the open one turns
//  solid so the card under it reads as the same object unfolded.
//

import SwiftUI
import MizarKit

/// Which card the top row has open.
enum SessionTopCard: Equatable {
    case goal
    case plan
}

/// The goal and plan capsules above the conversation.
struct SessionTopStatusRow: View {
    let goal: SessionGoal?
    let plan: SessionPlan?
    let openCard: SessionTopCard?
    /// Whether the row scrolls. Production does; a snapshot passes `false`
    /// because `ImageRenderer` cannot draw a `ScrollView`.
    var scrolls = true
    let onToggle: (SessionTopCard) -> Void

    private enum Chip: Identifiable {
        case goal(SessionGoal)
        case plan(SessionPlan)

        var id: String {
            switch self {
            case .goal: "session.goalChip"
            case .plan: "session.planChip"
            }
        }
    }

    /// Goal first, plan second, and only what exists.
    private var chips: [Chip] {
        var chips: [Chip] = []
        if let goal { chips.append(.goal(goal)) }
        if let plan { chips.append(.plan(plan)) }
        return chips
    }

    var body: some View {
        CapsuleScrollRow(items: chips, scrolls: scrolls) { chip in
            switch chip {
            case .goal(let goal):
                GoalChip(goal: goal, isOpen: openCard == .goal) { onToggle(.goal) }
            case .plan(let plan):
                PlanChip(plan: plan, isOpen: openCard == .plan) { onToggle(.plan) }
            }
        }
        .accessibilityIdentifier("session.topRow")
    }
}

// MARK: - Chips

/// The goal, as one capsule: how it is going and for how long.
private struct GoalChip: View {
    let goal: SessionGoal
    let isOpen: Bool
    let onTap: () -> Void

    var body: some View {
        if goal.phase == .active {
            // A running goal's clock is read off the same second tick as the
            // rest of the app, so the capsule moves on its own.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                button(elapsed: SessionGoalDuration.text(from: goal.createdAt, to: context.date))
            }
        } else {
            button(elapsed: SessionGoalDuration.text(from: goal.createdAt, to: goal.updatedAt))
        }
    }

    private func button(elapsed: String) -> some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isOpen ? Color(.systemBackground) : phaseColor)
                Text(phaseLabel)
                Text(elapsed)
                    .monospacedDigit()
                    .foregroundStyle(isOpen ? Color(.systemBackground) : Color.secondary)
            }
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
            .modifier(TopChipSurface(selected: isOpen))
        }
        .buttonStyle(.plain)
        .animation(Motion.pick(.mizarSnappy), value: isOpen)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(phaseLabel), \(elapsed)"))
        .accessibilityAddTraits(isOpen ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("session.goalChip")
    }

    private var phaseLabel: String {
        switch goal.phase {
        case .active: String(localized: "Goal in progress")
        case .paused: String(localized: "Goal paused")
        case .blocked: String(localized: "Goal blocked")
        case .complete: String(localized: "Goal complete")
        }
    }

    private var iconName: String {
        switch goal.phase {
        case .active: "target"
        case .paused: "pause.circle"
        case .blocked: "exclamationmark.triangle"
        case .complete: "checkmark.circle"
        }
    }

    private var phaseColor: Color {
        switch goal.phase {
        case .active: Theme.accentText
        case .paused: Color.secondary
        case .blocked: Theme.waiting
        case .complete: Theme.running
        }
    }
}

/// The plan, as one capsule: how many steps are done.
private struct PlanChip: View {
    let plan: SessionPlan
    let isOpen: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isOpen ? Color(.systemBackground) : iconColor)
                Text(text)
                    .monospacedDigit()
            }
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
            .modifier(TopChipSurface(selected: isOpen))
        }
        .buttonStyle(.plain)
        .animation(Motion.pick(.mizarSnappy), value: isOpen)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(text))
        .accessibilityAddTraits(isOpen ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("session.planChip")
    }

    private var text: String {
        String(format: String(localized: "Plan %lld/%lld"), plan.completedCount, plan.steps.count)
    }

    private var iconColor: Color {
        plan.hasStepInProgress ? Theme.accentText : Color.secondary
    }
}

/// Glass while closed; the solid inverse while its card is open.
private struct TopChipSurface: ViewModifier {
    let selected: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if selected {
            content
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .frame(minHeight: 38)
                .background(Color.primary, in: Capsule())
                .foregroundStyle(Color(.systemBackground))
        } else {
            content.composerStatusCapsule(interactive: true)
        }
    }
}

// MARK: - Duration

/// How long a goal has been (or was) running, in one string.
///
/// One function for the capsule and the card so the two cannot disagree, and
/// pure so the formatting can be tested without a clock.
enum SessionGoalDuration {
    /// - Parameter locale: the locale the words are drawn in. A parameter so a
    ///   test can pin it: the format follows the machine's own locale, and an
    ///   assertion that names "36 min, 40 sec" is only true in English.
    static func text(from start: Date, to end: Date, locale: Locale = .current) -> String {
        let seconds = Int(max(0, end.timeIntervalSince(start)))
        return Duration.seconds(seconds).formatted(
            .units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2)
                .locale(locale),
        )
    }
}
