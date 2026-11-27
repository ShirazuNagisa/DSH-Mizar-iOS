//
//  ModelDrawer.swift
//  DSH-Mizar
//
//  The model, chosen from the bottom of the screen.
//
//  The picker used to be a popover hanging off the composer's model capsule:
//  a second window, with its own list chrome, for a choice that is really one
//  of a handful of routes. The capsule now opens the thinking strip, and the
//  strip's title opens this: the catalogue as one column of rows, rising from
//  the bottom edge and leaving the same way.
//
//  A drag anywhere on the handle or the header pulls it down and away; a tap
//  on the dim closes it too, because both are the same "not this after all".
//

import MizarKit
import SwiftUI

/// The catalogue, as a drawer.
///
/// Reads its catalogue from the environment; ``ModelDrawerRow`` does not, so a
/// snapshot can own the row.
struct ModelDrawer: View {
    let sessionId: String
    let stats: SessionStatsFrame?
    let onClose: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// The model whose switch is in the air, by id: its row draws a spinner and
    /// every other row waits.
    @State private var applying: String?
    /// Why the last switch was refused. The drawer stays open so it can be read.
    @State private var switchError: String?
    /// How far the panel has been pulled down by the finger.
    @State private var dragOffset: CGFloat = 0
    @Namespace private var tick
    /// Where an assistive reader starts: the drawer's own heading.
    @AccessibilityFocusState private var titleFocused: Bool

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

    private var inForceEffort: String? { selection?.reasoningEffort ?? option?.defaultEffort }

    private var modelName: String {
        option?.name ?? selection?.model ?? String(localized: "Model")
    }

    private var effortName: String? {
        guard let inForceEffort else { return nil }
        return option?.efforts.first { $0.id == inForceEffort }?.name ?? inForceEffort.capitalized
    }

    /// `DeepSeek V4 Pro · High`, as the current line says it.
    private var detail: String {
        effortName.map { "\(modelName) · \($0)" } ?? modelName
    }

    var body: some View {
        GeometryReader { container in
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                panel(maxHeight: container.size.height * 0.62)
            }
        }
    }

    private func panel(maxHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            // The handle and the heading are one drag target: they are the
            // part of a sheet a hand reaches for.
            VStack(spacing: 0) {
                Capsule()
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 36, height: 5)
                    .padding(.top, 8)

                HStack {
                    Text("Model")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityFocused($titleFocused)
                    Spacer(minLength: 0)
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 30, height: 30)
                            .background(Color(.tertiarySystemFill), in: Circle())
                            .frame(width: 44, height: 44)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.pressable)
                    .accessibilityLabel(Text("Close"))
                    .accessibilityIdentifier("model.drawer.close")
                }
                .padding(.horizontal, 20)
                .padding(.top, 10)
                .padding(.bottom, 4)
            }
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { value in
                        dragOffset = value.translation.height
                    }
                    .onEnded { value in
                        if value.translation.height > 120 || value.predictedEndTranslation.height > 240 {
                            onClose()
                        } else {
                            withMizarAnimation(.mizarSnappy) { dragOffset = 0 }
                        }
                    },
            )

            // What is in force, said once. A single `Text`, not three pieces:
            // the identifier on it is what the UI suite reads.
            Text(String(format: String(localized: "Current: %@"), detail))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
                .accessibilityIdentifier("model.current.\(selection?.model ?? "")")

            if let switchError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.waiting)
                    Text(switchError)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
                .transition(.rise)
                .accessibilityIdentifier("model.error")
            }

            if model.modelCatalog == nil {
                // Nothing read yet: say so where the rows will be, rather than
                // leaving an empty panel that reads as "no models".
                ProgressView()
                    .padding(.vertical, 40)
                    .frame(maxWidth: .infinity)
            } else {
                catalogue
            }
        }
        .frame(maxWidth: sizeClass == .regular ? 560 : .infinity)
        .frame(maxHeight: maxHeight)
        .glassEffect(
            .regular,
            in: RoundedRectangle(cornerRadius: Theme.Radius.drawer, style: .continuous),
        )
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
        .offset(y: max(0, dragOffset))
        .accessibilityAddTraits(.isModal)
        .onAppear { titleFocused = true }
    }

    /// The catalogue's rows, at their own height when they fit and scrolling
    /// inside the cap when they do not.
    ///
    /// `ViewThatFits` is what makes the short catalogue short: the panel's cap
    /// is 62% of the screen, and a drawer two rows tall drawn at that cap is a
    /// sheet of empty glass.
    @ViewBuilder
    private var catalogue: some View {
        ViewThatFits(in: .vertical) {
            rows
            ScrollView(.vertical) {
                rows
            }
            .scrollIndicators(.hidden)
        }
    }

    private var rows: some View {
        LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(model.modelCatalog?.providers ?? []) { provider in
                Text(provider.name)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 20)
                    .padding(.top, 14)
                    .padding(.bottom, 6)

                ForEach(provider.models) { option in
                    ModelDrawerRow(
                        option: option,
                        isChosen: option.id == selection?.model,
                        isApplying: applying == option.id,
                        tick: tick,
                        action: { choose(option, provider: provider.id) },
                    )
                    .disabled(!model.isConnected || (applying != nil && applying != option.id))
                }
            }

            // A provider that could not be listed is drawn, not hidden: an
            // empty catalogue with no explanation reads as a broken one.
            if let failures = model.modelCatalog?.failures, !failures.isEmpty {
                Text("Unavailable")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 20)
                    .padding(.top, 14)
                    .padding(.bottom, 6)

                ForEach(failures) { failure in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(failure.name)
                            .font(.subheadline)
                        Text(failure.message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                }
            }
        }
        .padding(.bottom, 12)
    }

    /// Switch to `option`, keeping the level in force when the new model takes
    /// it. See ``ModelDrawerChoice``.
    private func choose(_ option: ModelOption, provider: String) {
        guard applying == nil else { return }
        if option.id == selection?.model {
            onClose()
            return
        }
        applying = option.id
        Task {
            let accepted = await model.setModel(
                provider: provider,
                model: option.id,
                effort: ModelDrawerChoice.effort(for: option, keeping: inForceEffort),
                sessionId: sessionId,
            )
            applying = nil
            if accepted {
                switchError = nil
                // Long enough for the tick to be seen where it lands.
                try? await Task.sleep(for: .milliseconds(260))
                onClose()
            } else {
                withMizarAnimation(.mizarSmooth) {
                    switchError = model.problem ?? String(localized: "Could not switch model")
                }
            }
        }
    }
}

/// One route in the drawer: name, description, and a tick when it is in force.
///
/// No environment, so the snapshot suite can render it from fixture data.
struct ModelDrawerRow: View {
    let option: ModelOption
    /// Whether this row is the route in force.
    let isChosen: Bool
    /// Whether this row's switch is in the air.
    let isApplying: Bool
    /// The namespace the tick's matched geometry moves in. One per drawer, so
    /// the tick travels between rows as the choice moves.
    let tick: Namespace.ID
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.name)
                        .font(.body)
                        .fontWeight(isChosen ? .semibold : .regular)
                        .foregroundStyle(.primary)
                    if let description = option.description {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
                if isApplying {
                    ProgressView()
                        .controlSize(.mini)
                } else if isChosen {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.accentText)
                        .matchedGeometryEffect(id: "tick", in: tick)
                        .transition(.pop)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .frame(minHeight: 52)
            .background {
                if isChosen {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.accentColor.opacity(0.10))
                }
            }
            .padding(.horizontal, 8)
            .contentShape(.rect)
        }
        .buttonStyle(.pressable(scale: 0.98, dims: true))
        .accessibilityIdentifier("model.row.\(option.id)")
        .accessibilityAddTraits(isChosen ? .isSelected : [])
    }
}

// MARK: - What a tap means

/// The level a newly chosen model starts on.
enum ModelDrawerChoice {
    /// The level a newly chosen model starts on: the one in force when the new
    /// model accepts it, else the new model's default, else none.
    static func effort(for option: ModelOption, keeping current: String?) -> String? {
        if option.efforts.isEmpty { return nil }
        if let current, option.efforts.contains(where: { $0.id == current }) { return current }
        return option.defaultEffort ?? option.efforts.first?.id
    }
}

// MARK: - Coming and going

/// The drawer rising from the bottom edge, and sinking back into it.
///
/// An offset rather than `.move(edge: .bottom)`: a move still travels under
/// Reduce Motion, and what is wanted there is the fade alone.
struct ModelDrawerTransition: Transition {
    func body(content: Content, phase: TransitionPhase) -> some View {
        ModelDrawerEffect(identity: phase.isIdentity) { content }
    }
}

private struct ModelDrawerEffect<Wrapped: View>: View {
    let identity: Bool
    @ViewBuilder var wrapped: Wrapped
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        wrapped
            .opacity(identity ? 1 : 0)
            .offset(y: identity || reduceMotion ? 0 : 480)
    }
}

extension Transition where Self == ModelDrawerTransition {
    static var modelDrawer: ModelDrawerTransition { ModelDrawerTransition() }
}
