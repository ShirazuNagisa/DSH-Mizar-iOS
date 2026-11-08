//
//  InteractionsView.swift
//  DSH-Mizar
//
//  What the agent is waiting for.
//
//  This is the screen the app exists for. An agent that needs a decision is
//  stopped until it gets one, so a request that arrives while the operator is
//  away is the difference between a working session and a stalled one.
//
//  The requests dock above the composer, where the thumb already is. They used
//  to sit at the top of the conversation -- and a conversation opens at its
//  bottom, so in any session long enough to matter the one thing waiting on the
//  operator was a screen's scroll away. Docked, it is in front of them the
//  moment the session opens, and the conversation reads underneath.
//
//  One card at a time, with the others stacked behind it, because a decision is
//  made one at a time; "Next" moves through the deck. Typing tucks the deck into
//  a small pill so the field has the room, and tapping the pill brings it back.
//
//  Two rules shape the cards:
//
//    - **The decision is made with the information, not after it.** The tool,
//      the reason and the session are on the card, because approving something
//      you cannot see is not approving it.
//    - **Only `allowed-once` grants anything.** There is deliberately no "always
//      allow": a grant that outlives its request is a permission change, and
//      those belong in the permission picker where they are visible and
//      reversible.
//

import SwiftUI
import MizarKit

/// The deck of pending requests, docked above the composer.
struct InteractionsDock: View {
    /// Whether the composer has the keyboard, which tucks the deck away.
    let composerFocused: Bool
    /// Puts the keyboard away, for a tap on the tucked pill.
    var onExpand: () -> Void = {}
    /// The tallest the dock may grow before its card scrolls.
    var maxHeight: CGFloat = 320

    @Environment(AppModel.self) private var model
    /// Read in the body, so the tucked pill's pulse holds while a drawer
    /// moves: those frames belong to the card.
    @Environment(\.drawersStill) private var drawersStill
    /// The card in front, by id.
    @State private var frontId: String?
    /// Brief "done" notes, one per answered card.
    @State private var confirmations: [Confirmation] = []
    /// How tall each card's content is, so the card can be exactly that tall.
    @State private var contentHeights: [String: CGFloat] = [:]

    struct Confirmation: Identifiable, Equatable {
        let id = UUID()
        let text: String
        let allowed: Bool
    }

    /// One pending request, of either kind.
    enum Card: Identifiable, Equatable {
        case approval(PendingApproval)
        case question(PendingQuestion)

        var id: String {
            switch self {
            case .approval(let approval): "a." + approval.id
            case .question(let question): "q." + question.id
            }
        }

        var sessionId: String? {
            switch self {
            case .approval(let approval): approval.sessionId
            case .question(let question): question.sessionId
            }
        }
    }

    private var cards: [Card] {
        guard let pending = model.pending else { return [] }
        return pending.approvals.map(Card.approval) + pending.questions.map(Card.question)
    }

    private var front: Card? {
        let all = cards
        return all.first { $0.id == frontId } ?? all.first
    }

    var body: some View {
        let all = cards
        VStack(spacing: 8) {
            ForEach(confirmations) { note in
                ConfirmationCapsule(note: note)
                    .transition(
                        AsymmetricTransition(
                            insertion: PopTransition(scale: 0.6),
                            removal: RiseTransition(distance: -18, blur: 6),
                        ),
                    )
            }

            if !all.isEmpty {
                if composerFocused {
                    tucked(count: all.count)
                        .transition(.blurReplace.combined(with: .scale(0.9, anchor: .bottom)))
                } else if let front {
                    deck(front: front, all: all)
                        .transition(.rise(distance: 24, blur: 8))
                }
            }
        }
        .padding(.horizontal, 10)
        .animation(.mizarSmooth, value: all.map(\.id))
        .animation(.mizarSmooth, value: composerFocused)
        .animation(.mizarBouncy, value: confirmations)
        .animation(.mizarSmooth, value: frontId)
    }

    // MARK: - Tucked

    private func tucked(count: Int) -> some View {
        Button(action: onExpand) {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(Theme.waiting)
                    .symbolEffect(.pulse, options: .repeat(.continuous), isActive: drawersStill)
                Text(count == 1 ? String(localized: "1 request waiting") : String(format: String(localized: "%lld requests waiting"), count))
                    .font(.subheadline.weight(.semibold))
                Image(systemName: "chevron.up")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .frame(height: 38)
            .contentShape(.capsule)
            .liquidCapsule(interactive: true)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("interactions.tucked")
    }

    // MARK: - Deck

    private func deck(front: Card, all: [Card]) -> some View {
        let behind = all.filter { $0.id != front.id }.prefix(2)
        return ZStack(alignment: .top) {
            // The cards behind, as edges peeking over the top of the one in
            // front: there is more, and roughly how much.
            ForEach(Array(behind.enumerated()), id: \.element.id) { depth, card in
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .fill(.clear)
                    .frame(height: 40)
                    .glassEffect(.regular.tint(tint(for: card).opacity(0.25)), in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                    .scaleEffect(1 - CGFloat(depth + 1) * 0.05, anchor: .top)
                    .offset(y: -CGFloat(depth + 1) * 7)
                    .opacity(1 - Double(depth) * 0.35)
                    .zIndex(-Double(depth + 1))
                    .accessibilityHidden(true)
            }

            cardView(front, index: all.firstIndex(of: front) ?? 0, count: all.count)
                .id(front.id)
                .transition(
                    AsymmetricTransition(
                        insertion: RiseTransition(distance: -10, blur: 6),
                        removal: PopTransition(scale: 0.86),
                    ),
                )
                .zIndex(1)
        }
        .padding(.top, behind.isEmpty ? 0 : CGFloat(behind.count) * 7)
    }

    @ViewBuilder
    private func cardView(_ card: Card, index: Int, count: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if count > 1 || card.sessionId != model.selectedSessionId {
                deckHeader(card: card, index: index, count: count)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
            }
            // Scrolls only once it is taller than the dock may be, and is
            // exactly as tall as its content until then: measured, because a
            // scroll view has no height of its own to offer.
            ScrollView {
                Group {
                    switch card {
                    case .approval(let approval):
                        ApprovalCard(approval: approval) { allowed in
                            confirm(allowed ? String(format: String(localized: "Allowed %@"), ToolNames.localized(approval.toolName))
                                            : String(format: String(localized: "Rejected %@"), ToolNames.localized(approval.toolName)),
                                    allowed: allowed)
                        }
                    case .question(let question):
                        QuestionCard(question: question) {
                            confirm(String(localized: "Answer sent"), allowed: true)
                        }
                    }
                }
                .padding(16)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    contentHeights[card.id] = height
                }
            }
            .defaultScrollAnchor(.top)
            .defaultScrollAnchor(.top, for: .sizeChanges)
            .scrollBounceBehavior(.basedOnSize)
            // A card taller than the dock fades out at its lower edge, so
            // "there is more below" is visible rather than a clean cut that
            // reads as the end of the card.
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            .scrollIndicators(.visible)
            .frame(height: min(contentHeights[card.id] ?? 180, maxHeight))
        }
        .glassEffect(.regular.tint(tint(for: card).opacity(0.08)), in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(tint(for: card).opacity(0.28), lineWidth: 0.75)
                .allowsHitTesting(false)
        }
    }

    private func deckHeader(card: Card, index: Int, count: Int) -> some View {
        HStack(spacing: 8) {
            if let sessionId = card.sessionId, sessionId != model.selectedSessionId {
                // A request from another session is still this operator's to
                // answer -- the agent there is stopped too -- but it should say
                // whose it is.
                Label {
                    Text(model.titles[sessionId] ?? String(sessionId.prefix(8)))
                        .lineLimit(1)
                } icon: {
                    Image(systemName: "arrow.turn.down.right")
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if count > 1 {
                Text("\(index + 1) of \(count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .contentTransition(.numericText())
                Button {
                    let all = cards
                    let next = all[(index + 1) % all.count]
                    frontId = next.id
                } label: {
                    HStack(spacing: 3) {
                        Text("Next")
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.bold))
                    }
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(.fill.tertiary, in: Capsule())
                    .contentShape(.capsule)
                }
                .buttonStyle(.pressable)
                .accessibilityIdentifier("interactions.next")
            }
        }
    }

    private func tint(for card: Card) -> Color {
        switch card {
        case .approval: Theme.waiting
        case .question: Theme.question
        }
    }

    private func confirm(_ text: String, allowed: Bool) {
        let note = Confirmation(text: text, allowed: allowed)
        confirmations.append(note)
        Task {
            try? await Task.sleep(for: .milliseconds(1700))
            confirmations.removeAll { $0.id == note.id }
        }
    }
}

/// "Allowed write_file", for a moment, where the card was.
private struct ConfirmationCapsule: View {
    let note: InteractionsDock.Confirmation

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: note.allowed ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(note.allowed ? Theme.running : Theme.failed)
                .symbolEffect(.bounce, value: note.id)
            Text(note.text)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .frame(height: 38)
        .liquidCapsule()
        .mizarFeedback(note.allowed ? .success : .warning, trigger: note.id)
    }
}

// MARK: - Approval

/// One approval.
struct ApprovalCard: View {
    let approval: PendingApproval
    /// Called once the host has taken the answer, with whether it was a grant.
    var onAnswered: (Bool) -> Void = { _ in }

    @Environment(AppModel.self) private var model
    @Environment(\.locale) private var locale
    @State private var answering: ApprovalOutcome?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "hand.raised.fill")
                    .font(.headline)
                    .foregroundStyle(Theme.waiting)
                    .symbolEffect(.wiggle, options: .nonRepeating, value: approval.id)
                // The identifier is protocol data, not a name. `ToolNames` maps
                // the tools this app knows to words in the operator's language.
                Text("Wants to run \(ToolNames.localized(approval.toolName))")
                    .font(.headline)
                    .foregroundStyle(Theme.waiting)
            }

            if let reason = approval.reasonText(preferring: locale.identifier) {
                Text(reason)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let sessionId = approval.sessionId {
                Text(sessionId)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            HStack(spacing: 10) {
                Button(role: .destructive) {
                    Task { await answer(.rejected) }
                } label: {
                    buttonLabel("Reject", busy: answering == .rejected)
                }
                .buttonStyle(.glass)
                .tint(Theme.failed)
                .accessibilityIdentifier("approval.reject")

                Button {
                    Task { await answer(.allowedOnce) }
                } label: {
                    buttonLabel("Allow once", busy: answering == .allowedOnce)
                        // The prominent style fills with the accent; the label
                        // has to be the ink that goes on the accent, which is
                        // near-black in both appearances now that the light
                        // accent is bright cyan. Reject keeps its tint's colour.
                        .foregroundStyle(Theme.onAccent)
                }
                .buttonStyle(.glassProminent)
                .accessibilityIdentifier("approval.allowOnce")
            }
            .controlSize(.large)
            .disabled(answering != nil)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.mizarSnappy, value: answering)
    }

    private func buttonLabel(_ title: LocalizedStringKey, busy: Bool) -> some View {
        ZStack {
            Text(title).opacity(busy ? 0 : 1)
            if busy { ProgressView().controlSize(.small) }
        }
        .frame(maxWidth: .infinity)
    }

    private func answer(_ outcome: ApprovalOutcome) async {
        answering = outcome
        await model.answerApproval(approval, outcome: outcome)
        answering = nil
        onAnswered(outcome == .allowedOnce)
    }
}

// MARK: - Questions

/// One question batch.
///
/// Answers accumulate locally and are submitted together: the host matches a
/// batch by its call id, and sending one answer per question would leave the
/// agent waiting on the rest.
struct QuestionCard: View {
    let question: PendingQuestion
    var onAnswered: () -> Void = {}

    @Environment(AppModel.self) private var model
    @State private var selections: [String: Set<String>] = [:]
    @State private var custom: [String: String] = [:]
    @State private var submitting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(question.questions) { item in
                QuestionBody(
                    item: item,
                    selected: binding(for: item.id),
                    custom: customBinding(for: item.id),
                )
            }

            Button {
                Task { await submit() }
            } label: {
                ZStack {
                    Text(question.isPlanReview ? "Approve plan" : "Send answers")
                        .opacity(submitting ? 0 : 1)
                    if submitting { ProgressView().controlSize(.small) }
                }
                .foregroundStyle(Theme.onAccent)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(!isComplete || submitting)
            .animation(.mizarSnappy, value: isComplete)
            .accessibilityIdentifier("question.submit")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            // Pre-select what the question already marks as default, so the
            // common case is one tap rather than reading every option.
            for item in question.questions where item.options.count == 1 {
                selections[item.id] = [item.options[0].label]
            }
        }
    }

    /// Whether every question has something to send.
    private var isComplete: Bool {
        question.questions.allSatisfy { item in
            !(selections[item.id] ?? []).isEmpty
                || !(custom[item.id] ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private func binding(for id: String) -> Binding<Set<String>> {
        Binding(get: { selections[id] ?? [] }, set: { selections[id] = $0 })
    }

    private func customBinding(for id: String) -> Binding<String> {
        Binding(get: { custom[id] ?? "" }, set: { custom[id] = $0 })
    }

    private func submit() async {
        submitting = true
        let answers = question.questions.map { item in
            let typed = (custom[item.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return QuestionAnswer(
                id: item.id,
                selected: Array(selections[item.id] ?? []),
                custom: typed.isEmpty ? nil : typed,
            )
        }
        await model.answerQuestion(question, answers: answers)
        submitting = false
        onAnswered()
    }
}

/// One question and its options.
private struct QuestionBody: View {
    let item: QuestionItem
    @Binding var selected: Set<String>
    @Binding var custom: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let header = item.header {
                Text(header)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.question)
                    .textCase(.uppercase)
            }
            Text(item.question)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            if let detail = item.detail {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 6) {
                ForEach(item.options, id: \.label) { option in
                    let isOn = selected.contains(option.label)
                    Button {
                        withMizarAnimation(.mizarSnappy) { toggle(option.label) }
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            ChoiceMark(isOn: isOn, multiple: item.multiSelect)
                                .padding(.top, 1)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.label)
                                    .foregroundStyle(.primary)
                                if let description = option.description {
                                    Text(description)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background {
                            RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                                .fill(isOn ? Theme.question.opacity(0.14) : Color.primary.opacity(0.04))
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                                .strokeBorder(isOn ? Theme.question.opacity(0.45) : .clear, lineWidth: 1)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.pressable(scale: 0.98))
                    .mizarFeedback(.selection, trigger: isOn)
                }
            }

            TextField("Or type your own answer", text: $custom, axis: .vertical)
                .lineLimit(1...4)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
        }
    }

    private func toggle(_ label: String) {
        if item.multiSelect {
            if selected.contains(label) { selected.remove(label) } else { selected.insert(label) }
        } else {
            // Single-select replaces rather than accumulates, which is what the
            // radio promises.
            selected = selected.contains(label) ? [] : [label]
        }
    }
}

/// A radio or a checkbox whose mark springs in.
private struct ChoiceMark: View {
    let isOn: Bool
    let multiple: Bool

    var body: some View {
        ZStack {
            shape
                .strokeBorder(isOn ? Theme.question : Color.secondary.opacity(0.5), lineWidth: 1.6)
            shape
                .fill(Theme.question)
                .scaleEffect(isOn ? 1 : 0.3)
                .opacity(isOn ? 1 : 0)
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .heavy))
                .foregroundStyle(.white)
                .scaleEffect(isOn ? 1 : 0.2)
                .opacity(isOn ? 1 : 0)
        }
        .frame(width: 20, height: 20)
        .animation(.mizarBouncy, value: isOn)
        .accessibilityHidden(true)
    }

    private var shape: AnyInsettableShape {
        multiple
            ? AnyInsettableShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            : AnyInsettableShape(Circle())
    }
}

/// Any insettable shape, so a radio and a checkbox can share one view.
struct AnyInsettableShape: InsettableShape {
    private let base: @Sendable (CGRect) -> Path
    private let inset: CGFloat
    private let makeInset: @Sendable (CGFloat) -> AnyInsettableShape

    init<S: InsettableShape>(_ shape: S) {
        base = { shape.path(in: $0) }
        inset = 0
        makeInset = { AnyInsettableShape(shape.inset(by: $0)) }
    }

    func path(in rect: CGRect) -> Path { base(rect) }

    func inset(by amount: CGFloat) -> AnyInsettableShape { makeInset(amount) }
}

private extension PendingQuestion {
    /// Whether this batch is a plan awaiting approval.
    var isPlanReview: Bool {
        questions.contains { $0.intent?.isPlanReview == true }
    }
}
