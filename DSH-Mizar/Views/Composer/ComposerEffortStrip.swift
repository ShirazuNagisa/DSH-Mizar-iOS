//
//  ComposerEffortStrip.swift
//  DSH-Mizar
//
//  The thinking levels, laid over the composer's field.
//
//  The levels used to live inside the model picker: two windows deep for a
//  choice that changes mid-conversation far more often than the model does.
//  They are one track now, in the place the operator is already looking --
//  the composer -- and the model itself has moved out to a drawer behind this
//  strip's title.
//
//  The strip is an overlay rather than a replacement: the field stays where it
//  is, blurred and out of reach, so the track arrives out of the model capsule
//  it came from and goes back into it. Its resting height is the resting
//  field's 98 points (12 + 26 + 8 + 44 + 8), so nothing around it moves.
//

import MizarKit
import SwiftUI

/// The thinking levels for the session's model, and the way to the drawer.
///
/// Reads the catalogue from the environment, because a snapshot has none; the
/// drawing is ``ComposerEffortStripBody``, which does not.
struct ComposerEffortStrip: View {
    let sessionId: String
    let stats: SessionStatsFrame?
    let onClose: () -> Void
    let onOpenDrawer: () -> Void

    @Environment(AppModel.self) private var model
    /// The stop the operator picked but the host has not accepted yet.
    ///
    /// Drawn ahead of the level in force so a committed drag does not snap back
    /// while the request is in the air; cleared on refusal, which is what puts
    /// the knob back on the old stop.
    @State private var pendingIndex: Int?
    /// Why the last switch was refused, shown in the title row for two seconds.
    @State private var failure: String?
    /// Whether a switch is on its way, so a second drag cannot overtake it.
    @State private var committing = false

    /// The route this session will actually use. See ``agreedModelSelection``.
    private var selection: ModelSelection? {
        agreedModelSelection(
            chosen: model.chosenModelSelection(for: sessionId),
            reported: stats?.model,
            fallback: model.modelCatalog?.defaultSelection,
        )
    }

    /// The catalogue's row for that route, when the catalogue has one.
    private var option: ModelOption? {
        guard let selection else { return nil }
        return model.modelCatalog?.providers.first { $0.id == selection.provider }?
            .models.first { $0.id == selection.model }
    }

    private var efforts: [ReasoningEffortOption] { option?.efforts ?? [] }

    /// The level the resolved route is on, or the model's default when the
    /// route does not name one.
    private var inForceEffort: String? { selection?.reasoningEffort ?? option?.defaultEffort }

    private var selectedIndex: Int {
        pendingIndex ?? efforts.firstIndex { $0.id == inForceEffort } ?? 0
    }

    /// The model's name, or the catalogue's absence said plainly.
    private var modelName: String {
        option?.name ?? selection?.model ?? String(localized: "Model")
    }

    /// The level's name, capitalised like the pill's when the catalogue has no
    /// row for the id the host reported.
    private var effortName: String? {
        guard let inForceEffort else { return nil }
        return efforts.first { $0.id == inForceEffort }?.name ?? inForceEffort.capitalized
    }

    var body: some View {
        ComposerEffortStripBody(
            modelName: modelName,
            effortName: effortName,
            efforts: efforts,
            selectedIndex: selectedIndex,
            loading: model.modelCatalog == nil,
            failure: failure,
            enabled: model.isConnected,
            onTitle: onOpenDrawer,
            onCommit: commit,
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .task { await model.loadCatalogs() }
    }

    private func commit(_ index: Int) {
        guard let selection, efforts.indices.contains(index), !committing else { return }
        let effort = efforts[index].id
        guard effort != inForceEffort else { return }
        pendingIndex = index
        committing = true
        Task {
            let accepted = await model.setModel(
                provider: selection.provider, model: selection.model,
                effort: effort, sessionId: sessionId,
            )
            committing = false
            if accepted {
                pendingIndex = nil
                try? await Task.sleep(for: .milliseconds(350))
                onClose()
            } else {
                withMizarAnimation(.mizarSnappy) { pendingIndex = nil }
                failure = model.problem ?? String(localized: "Could not switch")
                try? await Task.sleep(for: .seconds(2))
                failure = nil
            }
        }
    }
}

/// The strip's drawing: a title that opens the drawer and the level track.
///
/// A plain view with no environment, so the snapshot suite can render it from
/// fixture data.
struct ComposerEffortStripBody: View {
    let modelName: String
    let effortName: String?
    let efforts: [ReasoningEffortOption]
    let selectedIndex: Int
    let loading: Bool
    let failure: String?
    let enabled: Bool
    let onTitle: () -> Void
    let onCommit: (Int) -> Void

    var body: some View {
        VStack(spacing: 8) {
            Button(action: onTitle) {
                // A refusal takes the row: the level did not change, and the
                // sentence has to say so where the operator is looking.
                if let failure {
                    Text(failure)
                        .font(.subheadline)
                        .foregroundStyle(Theme.failed)
                        .lineLimit(1)
                } else {
                    HStack(spacing: 6) {
                        Text(modelName)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if let effortName {
                            Text(effortName)
                                .font(.headline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .buttonStyle(.plain)
            .frame(height: 26)
            .accessibilityIdentifier("model.strip.title")
            .accessibilityLabel("\(modelName), \(effortName ?? "")")
            .accessibilityHint(Text("Choose a model"))

            track
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var track: some View {
        if loading {
            ZStack {
                Capsule().fill(Color(.tertiarySystemFill))
                ProgressView().controlSize(.small)
            }
            .frame(height: EffortSlider.height)
        } else if efforts.isEmpty {
            ZStack {
                Capsule().fill(Color(.tertiarySystemFill))
                Text("This model has no thinking levels")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(height: EffortSlider.height)
        } else {
            EffortSlider(
                efforts: efforts,
                selectedIndex: selectedIndex,
                enabled: enabled,
                onCommit: onCommit,
            )
        }
    }
}

/// The thinking levels as stops on one track: drag or tap, and the knob
/// lands on the nearest stop when the finger lifts.
struct EffortSlider: View {
    let efforts: [ReasoningEffortOption]
    let selectedIndex: Int
    var enabled: Bool = true
    let onCommit: (Int) -> Void

    static let height: CGFloat = 44
    static let knobInset: CGFloat = 4
    static let dot: CGFloat = 6

    /// Where the knob is while a finger holds it; nil at rest.
    @State private var dragX: CGFloat?
    /// The stop under the finger, for the haptic and the dots.
    @State private var hovered: Int?

    var body: some View {
        GeometryReader { geo in
            let radius = Self.height / 2
            let count = efforts.count
            let step = count > 1 ? (geo.size.width - 2 * radius) / CGFloat(count - 1) : 0
            let centre: (Int) -> CGFloat = { radius + CGFloat($0) * step }
            let nearest: (CGFloat) -> Int = { x in
                guard count > 1 else { return 0 }
                return min(count - 1, max(0, Int(((x - radius) / step).rounded())))
            }
            let shown = hovered ?? selectedIndex
            let knobX = dragX ?? (count > 1 ? centre(shown) : geo.size.width / 2)

            ZStack(alignment: .leading) {
                Capsule().fill(Color(.tertiarySystemFill))
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: count > 1 ? knobX + radius : geo.size.width)
                ForEach(efforts.indices, id: \.self) { index in
                    Circle()
                        .fill(index < shown ? Theme.onAccent.opacity(0.55) : Color.secondary.opacity(0.6))
                        .frame(width: Self.dot, height: Self.dot)
                        .position(x: centre(index), y: radius)
                        .opacity(index == shown || count < 2 ? 0 : 1)
                }
                Circle()
                    .fill(Theme.onAccent)
                    .shadow(color: .black.opacity(0.18), radius: 4, y: 1)
                    .frame(width: Self.height - 2 * Self.knobInset, height: Self.height - 2 * Self.knobInset)
                    .position(x: knobX, y: radius)
            }
            .contentShape(.capsule)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard enabled, count > 1 else { return }
                        let x = min(max(value.location.x, centre(0)), centre(count - 1))
                        dragX = x
                        hovered = nearest(x)
                    }
                    .onEnded { value in
                        guard enabled, count > 1 else { return }
                        let index = nearest(min(max(value.location.x, centre(0)), centre(count - 1)))
                        // The parent sets its pending index inside onCommit, so the
                        // knob's resting place is already the new stop when it snaps.
                        onCommit(index)
                        withMizarAnimation(.mizarSnappy) {
                            dragX = nil
                            hovered = nil
                        }
                    },
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Thinking"))
            .accessibilityChildren {
                HStack(spacing: 0) {
                    ForEach(efforts.indices, id: \.self) { index in
                        Button(efforts[index].name) { onCommit(index) }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .accessibilityIdentifier("effort.step.\(efforts[index].id)")
                            .accessibilityAddTraits(index == selectedIndex ? .isSelected : [])
                    }
                }
            }
        }
        .frame(height: Self.height)
        .opacity(enabled ? 1 : 0.45)
        .mizarFeedback(.selection, trigger: hovered) { old, new in old != nil && new != nil && old != new }
    }
}

// MARK: - Coming and going

/// The strip growing out of the model capsule, and shrinking back into it.
///
/// The anchor is the capsule's centre as a fraction of the field: 8 + 32 + 6 +
/// 32 + 6 + about 40 of label, over 382. Under Reduce Motion only the fade is
/// left, so nothing travels and nothing blurs.
struct EffortStripTransition: Transition {
    func body(content: Content, phase: TransitionPhase) -> some View {
        EffortStripEffect(identity: phase.isIdentity) { content }
    }
}

private struct EffortStripEffect<Wrapped: View>: View {
    let identity: Bool
    @ViewBuilder var wrapped: Wrapped
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let still = identity || reduceMotion
        wrapped
            .opacity(identity ? 1 : 0)
            .scaleEffect(
                x: still ? 1 : 0.3,
                y: still ? 1 : 0.6,
                anchor: UnitPoint(x: 0.31, y: 0.85),
            )
            .blur(radius: still ? 0 : 6)
    }
}

extension Transition where Self == EffortStripTransition {
    static var effortStrip: EffortStripTransition { EffortStripTransition() }
}
