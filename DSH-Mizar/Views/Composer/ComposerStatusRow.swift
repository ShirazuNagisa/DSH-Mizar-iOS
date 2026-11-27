//
//  ComposerStatusRow.swift
//  DSH-Mizar
//
//  The one line above the field that carries the session's small facts.
//
//  Three things can live here, and they are not a toolbar: the Git figures for
//  the session's working tree, the palette's door while a lone `/` is typed,
//  and the receipt that follows a answered question. Each appears and leaves on
//  its own, so the row is ordered by when the operator first saw an item rather
//  than by what kind of thing it is. A new item joins on the right and the row
//  stays centred, which moves the older items left; when one leaves, the rest
//  settle back around the centre.
//
//  Items that do not fit scroll sideways; the edges fade.
//

import SwiftUI
import MizarKit

/// One capsule the composer's status row can show.
enum ComposerStatusItem: Identifiable, Equatable {
    /// The palette's door, while a lone `/` is typed.
    case paletteHint
    /// The session's working-tree figures.
    case git(WorkspaceGitStatus)
    /// The receipt that follows an answered question.
    case receipt(ComposerReceipt)
    /// The field is holding a goal's objective, and there is a way out.
    case goalEditing

    var id: String {
        switch self {
        case .paletteHint: "palette"
        case .git: "git"
        case .receipt(let receipt): "receipt-" + receipt.id.uuidString
        case .goalEditing: "goalEditing"
        }
    }
}

/// The row of small capsules directly above the composer.
struct ComposerStatusRow: View {
    let items: [ComposerStatusItem]
    var onOpenPalette: () -> Void
    var onCancelGoalEdit: () -> Void = {}
    /// Whether the row scrolls. Production does; a snapshot passes `false`
    /// because `ImageRenderer` cannot draw a `ScrollView`.
    var scrolls = true

    var body: some View {
        CapsuleScrollRow(items: items, scrolls: scrolls) { item in
            capsule(for: item)
                .transition(AsymmetricTransition(insertion: .composerStatusJoin, removal: .opacity))
        }
        .animation(Motion.pick(.mizarSmooth), value: items.map(\.id))
        .accessibilityIdentifier("composer.statusRow")
    }

    @ViewBuilder
    private func capsule(for item: ComposerStatusItem) -> some View {
        switch item {
        case .paletteHint:
            CommandPaletteHint(onTap: onOpenPalette)
        case .git(let status):
            WorkspaceGitCapsule(status: status)
        case .receipt(let receipt):
            ReceiptCapsule(receipt: receipt)
        case .goalEditing:
            GoalEditingCapsule(onCancel: onCancelGoalEdit)
        }
    }
}

// MARK: - Editing a goal

/// "Editing goal", with the way back out of it.
struct GoalEditingCapsule: View {
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "pencil").foregroundStyle(.secondary)
            Text("Editing goal").font(.subheadline.weight(.semibold)).lineLimit(1)
            Button(action: onCancel) {
                Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.secondary)
                    .frame(width: 28, height: 28).contentShape(.rect)
            }
            .buttonStyle(.pressable(scale: 0.88))
            .accessibilityLabel(Text("Cancel editing"))
            .accessibilityIdentifier("composer.goalEditing.cancel")
        }
        .composerStatusCapsule()
        .accessibilityIdentifier("composer.goalEditing")
    }
}

// MARK: - Git

/// "43 files +4016 −202", in one glass capsule.
struct WorkspaceGitCapsule: View {
    let status: WorkspaceGitStatus

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.branch")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            (Text(String(format: String(localized: "%lld files"), status.files))
                + Text(verbatim: " +\(status.additions)").foregroundColor(Theme.running)
                + Text(verbatim: " −\(status.deletions)").foregroundColor(Theme.failed))
                .lineLimit(1)
        }
        .font(.subheadline.weight(.semibold))
        .monospacedDigit()
        .composerStatusCapsule()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            Text(String(
                format: String(localized: "%lld files, %lld lines added, %lld lines deleted"),
                status.files,
                status.additions,
                status.deletions,
            )),
        )
        .accessibilityIdentifier("composer.gitStatus")
    }
}

// MARK: - Arriving from the right

/// An item joining the row from the right.
///
/// The row itself stays centred, so the older items slide left as this one
/// lands; a short travel of its own is what makes it read as the new arrival
/// rather than as part of the row that was already there. Under Reduce Motion
/// only the fade is left, and nothing travels.
private struct ComposerStatusJoinTransition: Transition {
    func body(content: Content, phase: TransitionPhase) -> some View {
        ComposerStatusJoinEffect(identity: phase.isIdentity) { content }
    }
}

private struct ComposerStatusJoinEffect<Wrapped: View>: View {
    let identity: Bool
    @ViewBuilder var wrapped: Wrapped

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let still = identity || reduceMotion
        wrapped
            .opacity(identity ? 1 : 0)
            .offset(x: still ? 0 : 14)
            .blur(radius: still ? 0 : 4)
    }
}

extension Transition where Self == ComposerStatusJoinTransition {
    static var composerStatusJoin: ComposerStatusJoinTransition {
        ComposerStatusJoinTransition()
    }
}
