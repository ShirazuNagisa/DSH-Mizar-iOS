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
//  Space is not shared equally. The newest item keeps its whole sentence, and
//  the older ones give up width first -- their text truncates with an ellipsis
//  while their accessibility label keeps the whole sentence. That is one
//  measurement per item, on one line, rather than a layout per frame: the
//  custom layout below asks each capsule for its natural size, then hands the
//  available width out from the right.
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

    var id: String {
        switch self {
        case .paletteHint: "palette"
        case .git: "git"
        case .receipt(let receipt): "receipt-" + receipt.id.uuidString
        }
    }
}

/// The row of small capsules directly above the composer.
struct ComposerStatusRow: View {
    let items: [ComposerStatusItem]
    var onOpenPalette: () -> Void

    /// The ratio the current text size asks for, so the floor under an old
    /// item's width grows with the words inside it instead of clipping them.
    @ScaledMetric(relativeTo: .subheadline) private var textScale: CGFloat = 1

    var body: some View {
        ComposerStatusLayout(spacing: 8) {
            ForEach(items) { item in
                capsule(for: item)
                    .layoutValue(
                        key: ComposerStatusMinimumWidth.self,
                        value: minimumWidth(for: item) * textScale,
                    )
                    .transition(
                        AsymmetricTransition(
                            insertion: .composerStatusJoin,
                            removal: .opacity,
                        ),
                    )
            }
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
        }
    }

    /// The narrowest an item may become before it is all ellipsis.
    ///
    /// The floor is what the capsule's own padding, glyph and one truncated
    /// word need. The newest item is offered its natural width first, so these
    /// only matter when the row is genuinely too narrow for everything.
    private func minimumWidth(for item: ComposerStatusItem) -> CGFloat {
        switch item {
        case .paletteHint: 78
        case .git: 62
        case .receipt: 64
        }
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
                .truncationMode(.tail)
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

// MARK: - Layout

/// One item's floor, shared with the layout that hands out width.
private struct ComposerStatusMinimumWidth: LayoutValueKey {
    static let defaultValue: CGFloat = 56
}

/// A single centred line of capsules, newest on the right.
///
/// The layout measures every item once, then allocates the available width from
/// the newest backwards. The sum of the widths never exceeds what the row was
/// offered, so the row cannot push its neighbours around when three items meet
/// a narrow screen.
private struct ComposerStatusLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout (),
    ) -> CGSize {
        let plan = plan(available: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: plan.width, height: plan.height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout (),
    ) {
        let plan = plan(available: bounds.width, subviews: subviews)
        // One origin for the whole row, not one per item: the row is a group
        // that stays centred as its members arrive and leave.
        var x = bounds.minX + max(0, (bounds.width - plan.width) / 2)
        for (index, subview) in subviews.enumerated() {
            subview.place(
                at: CGPoint(x: x, y: bounds.midY),
                anchor: .leading,
                proposal: ProposedViewSize(width: plan.widths[index], height: plan.height),
            )
            x += plan.widths[index] + spacing
        }
    }

    private func plan(
        available: CGFloat,
        subviews: Subviews,
    ) -> (widths: [CGFloat], width: CGFloat, height: CGFloat) {
        guard !subviews.isEmpty else { return ([], 0, 0) }

        let natural = subviews.map { $0.sizeThatFits(.unspecified) }
        let gaps = spacing * CGFloat(subviews.count - 1)
        let usable = max(0, available - gaps)
        let naturalWidths = natural.map { max(0, $0.width) }
        var widths = naturalWidths

        if naturalWidths.reduce(0, +) > usable {
            let minimums = subviews.map { max(0, $0[ComposerStatusMinimumWidth.self]) }
            let newest = subviews.count - 1
            let olderFloors = (0..<newest).map { min(minimums[$0], naturalWidths[$0]) }
            let floorTotal = olderFloors.reduce(0, +)
            // Reserve only enough for older capsules to show their ellipsis.
            // If even those floors do not fit, keep the newest as visible as possible.
            let newestWidth = min(naturalWidths[newest], floorTotal <= usable
                ? max(0, usable - floorTotal) : usable)
            widths = Array(repeating: 0, count: subviews.count)
            widths[newest] = newestWidth
            let olderBudget = max(0, usable - newestWidth)
            if floorTotal > olderBudget, floorTotal > 0 {
                for index in 0..<newest {
                    widths[index] = olderFloors[index] * olderBudget / floorTotal
                }
            } else {
                let extra = olderBudget - floorTotal
                let demands = (0..<newest).map { naturalWidths[$0] - olderFloors[$0] }
                let totalDemand = demands.reduce(0, +)
                for index in 0..<newest {
                    widths[index] = olderFloors[index]
                        + (totalDemand > 0 ? min(extra, totalDemand) * demands[index] / totalDemand : 0)
                }
            }
        }

        let total = widths.reduce(0, +) + gaps
        let bounded = available.isFinite ? min(total, max(0, available)) : total
        let height = natural.map(\.height).max() ?? 0
        return (widths, bounded, height)
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
