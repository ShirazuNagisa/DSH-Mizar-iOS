//
//  SessionGoalPlanCards.swift
//  DSH-Mizar
//
//  The two cards the top row unfolds into: the goal's objective and its verbs,
//  and the plan's checklist.
//
//  Both are solid paper, not glass: they carry paragraphs and lists, and a
//  panel of reflections behind a paragraph is the one place the material is
//  wrong. The goal card is the only editable one; its actions are drawn as
//  small round buttons so the email-length objective keeps the whole width.
//

import SwiftUI
import MizarKit

// MARK: - Goal

/// The goal, what is blocking it, and what the operator can do about it.
struct SessionGoalCard: View {
    let goal: SessionGoal
    /// The moment the card is drawn, so the running duration agrees with the
    /// capsule above it.
    let now: Date
    let notice: String?
    let onEdit: () -> Void
    let onPause: () -> Void
    let onResume: () -> Void
    let onDelete: () -> Void

    @State private var confirmingDelete = false
    @State private var lightTaps = 0
    @State private var warningTaps = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Text(goal.objective)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineLimit(8)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("goal.objective")
            if goal.phase == .blocked, let reason = goal.blockedReason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(Theme.waiting)
            }
            if let notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(Theme.waiting)
                    .accessibilityIdentifier("goal.notice")
            }
            actions
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidCard(radius: Theme.Radius.lg)
        .mizarFeedback(.impact(weight: .light), trigger: lightTaps)
        .mizarFeedback(.warning, trigger: warningTaps)
        .task(id: confirmingDelete) {
            guard confirmingDelete else { return }
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withMizarAnimation(.mizarSnappy) { confirmingDelete = false }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: phaseIcon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(phaseColor)
            Text(phaseLabel)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(phaseColor)
            Spacer(minLength: 0)
            Text(elapsed)
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            actionButton(
                systemImage: "pencil",
                tint: Color.secondary,
                label: "Edit goal",
                identifier: "goal.edit",
                action: onEdit,
            )
            .opacity(confirmingDelete ? 0 : 1)
            .allowsHitTesting(!confirmingDelete)

            if goal.phase == .active {
                actionButton(
                    systemImage: "pause.fill",
                    tint: Color.secondary,
                    label: "Pause goal",
                    identifier: "goal.pause",
                    action: onPause,
                )
                .opacity(confirmingDelete ? 0 : 1)
                .allowsHitTesting(!confirmingDelete)
            }
            if goal.phase == .paused {
                actionButton(
                    systemImage: "play.fill",
                    tint: Color.secondary,
                    label: "Resume goal",
                    identifier: "goal.resume",
                    action: onResume,
                )
                .opacity(confirmingDelete ? 0 : 1)
                .allowsHitTesting(!confirmingDelete)
            }

            if confirmingDelete {
                Button(action: deleteTapped) {
                    Text("Tap again to delete")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .padding(.horizontal, 14)
                        .frame(height: 36)
                        .background(Theme.failed, in: Capsule())
                        .contentShape(.capsule)
                }
                .buttonStyle(.pressable(scale: 0.88))
                .accessibilityLabel(Text("Tap again to delete"))
                .accessibilityIdentifier("goal.delete")
            } else {
                Button(action: deleteTapped) {
                    Image(systemName: "trash")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.failed)
                        .frame(width: 36, height: 36)
                        .background(Color(.tertiarySystemFill), in: Circle())
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.pressable(scale: 0.88))
                .accessibilityLabel(Text("Delete goal"))
                .accessibilityIdentifier("goal.delete")
            }
        }
    }

    private func actionButton(
        systemImage: String,
        tint: Color,
        label: String,
        identifier: String,
        action: @escaping () -> Void,
    ) -> some View {
        Button {
            lightTaps += 1
            action()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 36, height: 36)
                .background(Color(.tertiarySystemFill), in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.pressable(scale: 0.88))
        .accessibilityLabel(Text(label))
        .accessibilityIdentifier(identifier)
    }

    /// The first tap arms the confirmation; the second deletes.
    private func deleteTapped() {
        if confirmingDelete {
            lightTaps += 1
            confirmingDelete = false
            onDelete()
        } else {
            warningTaps += 1
            withMizarAnimation(.mizarSnappy) { confirmingDelete = true }
        }
    }

    private var elapsed: String {
        let end = goal.phase == .active ? now : goal.updatedAt
        return SessionGoalDuration.text(from: goal.createdAt, to: end)
    }

    private var phaseLabel: String {
        switch goal.phase {
        case .active: String(localized: "Goal in progress")
        case .paused: String(localized: "Goal paused")
        case .blocked: String(localized: "Goal blocked")
        case .complete: String(localized: "Goal complete")
        }
    }

    private var phaseIcon: String {
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

// MARK: - Plan

/// The plan's steps, in order, read-only.
struct SessionPlanCard: View {
    let plan: SessionPlan

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.caption.weight(.semibold))
                Text("Plan")
                    .font(.footnote.weight(.semibold))
                Spacer(minLength: 0)
                Text(String(
                    format: String(localized: "%lld of %lld done"),
                    plan.completedCount,
                    plan.steps.count,
                ))
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            if plan.steps.count > 6 {
                ScrollView {
                    steps
                }
                .frame(maxHeight: 220)
            } else {
                steps
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidCard(radius: Theme.Radius.lg)
        .accessibilityIdentifier("plan.card")
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(plan.steps.enumerated()), id: \.element.id) { index, step in
                stepRow(step)
                    .accessibilityIdentifier("plan.step.\(index)")
            }
        }
    }

    private func stepRow(_ step: SessionPlanStep) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            icon(for: step.status)
            Text(step.content)
                .font(font(for: step.status))
                .foregroundStyle(color(for: step.status))
                .strikethrough(step.status == .completed)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
        }
    }

    @ViewBuilder
    private func icon(for status: SessionPlanStepStatus) -> some View {
        switch status {
        case .completed:
            glyph("checkmark.circle.fill", color: AnyShapeStyle(Theme.running))
        case .inProgress:
            if reduceMotion {
                glyph("circle.dotted", color: AnyShapeStyle(Theme.accentText))
            } else {
                glyph("circle.dotted", color: AnyShapeStyle(Theme.accentText))
                    .symbolEffect(.pulse)
            }
        case .pending:
            glyph("circle", color: AnyShapeStyle(.tertiary))
        }
    }

    private func glyph(_ name: String, color: AnyShapeStyle) -> some View {
        Image(systemName: name)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(color)
    }

    private func font(for status: SessionPlanStepStatus) -> Font {
        switch status {
        case .completed: .subheadline
        case .inProgress: .subheadline.weight(.semibold)
        case .pending: .subheadline
        }
    }

    private func color(for status: SessionPlanStepStatus) -> Color {
        switch status {
        case .completed: Color.secondary
        case .inProgress: .primary
        case .pending: .primary
        }
    }
}
