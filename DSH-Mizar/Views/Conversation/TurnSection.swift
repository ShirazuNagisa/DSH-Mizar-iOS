//
//  TurnSection.swift
//  DSH-Mizar
//
//  One turn's prompt, folded process, answer, and activity summary.
//

import SwiftUI
import MizarKit

/// Which of a turn's items are its process.
///
/// The turn's last agent message is the summary -- what the turn is read by --
/// and it stays on the page. Everything the agent said before it is how the
/// turn got there, and it is folded away behind the row that says how long
/// the turn took.
///
/// The host sends one message per finished turn, so this is empty for most
/// turns and the row stays a plain line. A turn that carried more than one
/// gets the fold, the same one the live stream uses.
enum ConversationProcess {
    /// The ids of the items that are the process.
    static func items(in items: [ConversationItem]) -> Set<String> {
        func isAgent(_ item: ConversationItem) -> Bool {
            if case .message(_, .assistant, _, _) = item { return true }
            return false
        }
        guard let summary = items.lastIndex(where: isAgent) else { return [] }
        return Set(items[..<summary].filter(isAgent).map(\.id))
    }
}

/// One turn: the prompt, the row that says how it is going, and the answer.
struct TurnSection: View {
    let turn: ConversationTurn
    /// The session this turn belongs to, for the paid activity feed.
    let sessionId: String
    /// The answer currently being typed, when it belongs to this turn.
    var typingAnswerId: String?
    /// Called when that answer's reveal begins.
    var onAnswerTypingStarted: (String) -> Void = { _ in }
    /// Whether the live stream below the list owns this turn's body.
    var suppressBody = false
    /// The process text the relay delivered for this turn, when it has some.
    var stashProcess: StashedReplay?
    /// Whether this row is built, reported to the screen without the index.
    var onRealized: (String, Bool, Int) -> Void = { _, _, _ in }

    /// Which appearance of this row the parent should believe.
    ///
    /// The report is deferred out of the layout pass, so an appear and a
    /// disappear can reach the parent out of order (a row staged at the top by
    /// the initial placement is built, removed and built again). A monotonic
    /// number assigned at the moment of the event -- not when the Task runs --
    /// lets the parent keep the last one that actually happened.
    @State private var realizationSequence = 0

    /// Whether the turn's process is on screen.
    ///
    /// A finished turn keeps its answer and folds the process away: the
    /// status lines and the narration that came before it are one tap away,
    /// behind the line that says how long the turn took. The same rule the
    /// live stream follows, so a turn looks the same whether it was watched
    /// or read back.
    @State private var showsProcess = false

    private func reportRealized(_ built: Bool) {
        realizationSequence &+= 1
        let sequence = realizationSequence
        Task { @MainActor in
            index.setRealized(turn.id, built, for: sessionId)
            onRealized(turn.id, built, sequence)
        }
    }
    @Environment(TurnIndex.self) private var index
    @Environment(PreviewCenter.self) private var preview
    @Environment(ShellState.self) private var shell
    @Environment(SidePlaneState.self) private var plane
    @Environment(\.horizontalSizeClass) private var sizeClass

    /// A status-less group of notices: a settlement that woke an idle parent,
    /// or an orphan notice at the end of a page. It gets its lines, not a
    /// "turn finished" header.
    private var isNoticeOnly: Bool {
        turn.prompts.isEmpty && !turn.steps.isEmpty && turn.steps.allSatisfy { item in
            if case .notice = item { return true }
            return false
        }
    }

    /// A body row: what the stream owns when this turn is live.
    private func isAssistantMessage(_ item: ConversationItem) -> Bool {
        if case .message(_, .assistant, _, _) = item { return true }
        return false
    }


    /// Whether the item is part of the agent's work, which is where the
    /// activity row belongs, rather than an operator prompt.
    private func isStep(_ item: ConversationItem) -> Bool {
        switch item {
        case .message(_, .assistant, _, _), .message(_, .system, _, _), .failure, .notice:
            return true
        case .message(_, .user, _, _):
            return false
        }
    }

    var body: some View {
        let items = ConversationNoticeFold.fold(turn.orderedItems)
        // When the live stream owns this turn's body, it owns the answer, not
        // the conversation's own rows: a steering message and a settlement
        // notice are still history the stream never carried. Hiding the whole
        // body made those rows appear only when the screen was reopened.
        let visible = suppressBody ? items.filter { !isAssistantMessage($0) } : items
        // A running turn's clock is not history: it belongs at the end of the
        // page, under whatever the operator has sent since. Drawing it in the
        // turn's own row put "DeepSeeking for 84 min" above the next prompt
        // whenever a later message existed. The tail draws it instead.
        let showsSummary = !suppressBody && !isNoticeOnly && !turn.isRunning
        let summaryIndex = visible.firstIndex(where: isStep) ?? visible.count
        // The turn's process: the agent's own messages before the last one.
        // The last one is the summary the turn is read by, and it stays.
        let process = ConversationProcess.items(in: visible)

        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(visible.enumerated()), id: \.element.id) { index, item in
                if showsSummary, index == summaryIndex {
                    TurnActivitySummary(
                        turn: turn,
                        sessionId: sessionId,
                        showsProcess: !process.isEmpty,
                        processExpanded: showsProcess,
                        onToggleProcess: {
                            withMizarAnimation(.mizarSmooth) { showsProcess.toggle() }
                        },
                    )
                }
                if process.contains(item.id) {
                    // The process is folded away by default and comes back
                    // with the same small settle the live stream uses.
                    if showsProcess {
                        ConversationRow(
                            item: item,
                            isLastPrompt: false,
                            typing: false,
                            onTypingStarted: { onAnswerTypingStarted(item.id) },
                        )
                        .transition(.rise(distance: 6, blur: 0))
                    }
                } else {
                    ConversationRow(
                        item: item,
                        isLastPrompt: item.id == turn.prompts.last?.id,
                        typing: item.id == typingAnswerId,
                        onTypingStarted: { onAnswerTypingStarted(item.id) },
                    )
                    .transition(.rise(distance: 14, blur: 6))
                }
            }

            // No step (a prompt-only turn): the row still belongs after the
            // prompt, not above it.
            if showsSummary, summaryIndex >= visible.count {
                TurnActivitySummary(
                    turn: turn,
                    sessionId: sessionId,
                    showsProcess: !process.isEmpty,
                    processExpanded: showsProcess,
                    onToggleProcess: {
                        withMizarAnimation(.mizarSmooth) { showsProcess.toggle() }
                    },
                )
            }

            if !suppressBody, let stashProcess {
                // The narration the computer wrote while this phone was away.
                // Drawn as history, not as a stream: there is no clock, no
                // typewriter and no changing status line, because this is
                // something that already happened.
                ReplayedProcess(blocks: stashProcess.processBlocks)
            }

            if !suppressBody {
                // The files this turn declared, between the answer and its actions:
                // the prose says what was done, the card is what was produced, and
                // the toolbar belongs to the message. Drawn whether or not the turn
                // ended with text, because a turn that only produced a file still
                // produced something.
                DeliveredFilesRow(turn: turn, sessionId: sessionId)

                if turn.endSeq != nil, !turn.isRunning, !turn.isEndInferred,
                   let response = turn.steps.last(where: { item in
                       if case .message(_, .assistant, let text, _) = item { return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                       return false
                   }),
                   case .message(_, .assistant, let text, let at) = response {
                    TurnResponseToolbar(turn: turn, sessionId: sessionId, text: text, at: at)
                }
            }
        }
        // A link in the prose that names a file on the computer opens the same
        // A link in the prose that names a file on the computer opens the same
        // preview a card does. Set here, around the whole turn, because the
        // links are drawn deep inside the typewriter and the handler needs this
        // turn's session.
        .environment(\.openDeliveredFile) { path in
            reveal(
                DeliveredFile(path: path),
                in: sessionId,
                preview: preview,
                shell: shell,
                plane: plane,
                compact: sizeClass != .regular,
            )
        }
        // A picture in prose names a path relative to *this* turn's workspace;
        // the row that loads it needs to know which session that is.
        .environment(\.conversationSessionId, sessionId)
        .animation(.mizarSmooth, value: turn.steps.count)
        // Arrived at from the index: a soft light behind the turn, once.
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                .fill(Color.accentColor.opacity(index.glowing == turn.id ? 0.1 : 0))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(index.glowing == turn.id ? 0.35 : 0), lineWidth: 1)
                }
                .padding(.horizontal, -10)
                .padding(.vertical, -8)
                .allowsHitTesting(false)
        }
        // Which turns are on screen, for the index's "you are here" -- and
        // which ones the conversation has built at all. The two differ: a row
        // scrolled far enough away is destroyed, and the index asks before it
        // tries to scroll to one, because a scroll to a row that no longer
        // exists goes nowhere. See ``TurnIndex/travels(to:)``.
        // These mutate an `@Observable` the screen also reads. Running them
        // synchronously from a scroll-visibility callback meant the lazy stack
        // could invalidate itself in the middle of placing its rows; defer to
        // the next runloop, and `TurnIndex` drops no-op writes.
        .onAppear { reportRealized(true) }
        .onScrollVisibilityChange(threshold: 0.25) { visible in
            Task { @MainActor in index.setVisible(turn.id, visible, for: sessionId) }
        }
        .onDisappear {
            reportRealized(false)
            Task { @MainActor in index.setVisible(turn.id, false, for: sessionId) }
        }
    }
}

/// The running-turn row and, when the advanced feature set is available, its
/// expandable detail.
///
/// This is the one place the full-detail feed meets the screen. It decides what
/// the feature set may see, polls while the turn is running, and renders the
/// detail below the summary row — never in place of it. The summary row is the
/// only thing on this screen that must not move while a turn is in flight: it is
/// where the operator reads "how long has this been going", and opening a detail
/// under it is fine while moving or replacing it is not.
///
/// Locked accounts take the else branch and never start the poll: ``AppModel``
/// refuses the read too, so there are two independent guards against a paid-only
/// method being called without the feature set. A direct link on the operator's
/// own network unlocks the set without a plan: the relay is not carrying that
/// traffic, and the full transfer is exactly the detail the plan is sold for.
private struct TurnActivitySummary: View {
    let turn: ConversationTurn
    let sessionId: String
    /// Whether this turn has a process folded behind the row.
    var showsProcess = false
    /// Whether the process is on screen.
    var processExpanded = false
    /// Called when the row is tapped to fold or unfold the process.
    var onToggleProcess: () -> Void = {}

    @Environment(AppModel.self) private var model
    /// The shell, for the drawer-motion hold: a poll second that lands
    /// mid-drag would re-render this row inside the card the finger moves.
    @Environment(ShellState.self) private var shell
    /// Whether the detail is out. Reset when the turn ends, because there is
    /// nothing left for it to describe.
    @State private var expanded = false

    /// The details for this session, when there are any to show.
    private var entries: [ActivityEntry] {
        // Touch the observable revision before the method read, so the row
        // re-evaluates when a window lands or an older page is prepended.
        _ = model.activityRevision
        return model.activity(for: sessionId) ?? []
    }

    /// Whether the chevron and the detail exist at all.
    ///
    /// All three conditions are about the same idea: the advanced feature set, a
    /// turn that is running, and at least one detail worth opening. A chevron
    /// that opens an empty area is worse than no chevron.
    /// Always false now.
    ///
    /// The per-step detail this row opened was the full-transfer feed, and the
    /// host stopped sending it: the phone draws the same "what is it doing"
    /// answer from the state channel instead (see `LiveTurnBlock`), inline and
    /// without a second network read. A row that offered a drawer over the top
    /// of that would be the same information twice, so there is no drawer.
    private var canExpand: Bool { false }

    /// What the poll is keyed on: it runs while this turn is running and the
    /// advanced feature set is available, and stops — clearing what it found —
    /// the moment either stops being true. `.task(id:)` cancels and restarts on
    /// a change, which is exactly the lifecycle wanted here. The set is lost on a
    /// route change away from the LAN just as it is on a plan ending, and the
    /// same change stops the poll in both cases.
    private var pollKey: String? {
        // The activity feed is not drawn any more, so nothing polls for it.
        guard false, turn.isRunning, model.advancedFeaturesUnlocked else { return nil }
        return "\(turn.turn ?? -1)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row
            if expanded, canExpand {
                TurnActivityDetail(
                    entries: entries,
                    hasOlder: model.activityHasOlder(for: sessionId),
                    onLoadOlder: { await model.loadOlderActivity(for: sessionId) },
                )
                .padding(.top, 8)
                    // In from under the row and up under it again on the way
                    // out: the detail belongs to the row, and leaving should
                    // look like going back where it came from.
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .top)),
                        removal: .opacity.combined(with: .move(edge: .top)),
                    ))
            }
        }
        .animation(.mizarSmooth, value: expanded)
        .task(id: pollKey) { await poll() }
        .onChange(of: pollKey) { oldKey, newKey in
            // This turn was the one polling, and it is not any more: it ended,
            // the advanced feature set stopped being available, or the view went
            // away. Only this view clears the cache -- a finished turn must not,
            // because the list builds old rows as it scrolls and each of them
            // would wipe the running turn's detail under the operator.
            if oldKey != nil, newKey == nil {
                model.clearActivity(for: sessionId)
            }
        }
        .onChange(of: canExpand) { _, canExpand in
            // The turn ended, or the feature set did. Collapse, so a shut turn
            // cannot leave a detail area floating under a finished row.
            if !canExpand, expanded {
                withAnimation(.mizarSmooth) { expanded = false }
            }
        }
        .onDisappear {
            // Scrolled away or navigated away while it was the running turn: the
            // next appearance starts from a fresh read rather than from a
            // minute-old set of lines. A finished turn's row says nothing here.
            if turn.isRunning {
                model.clearActivity(for: sessionId)
            }
        }
    }

    /// The row itself: a button when there is something to open, plain otherwise.
    ///
    /// A button only for an unlocked running turn with detail. The row's own content
    /// is unchanged in both branches — same glyph, same clock, same count — so a
    /// turn does not look different merely because somebody subscribed.
    @ViewBuilder private var row: some View {
        if canExpand {
            Button {
                withAnimation(.mizarBouncy) { expanded.toggle() }
            } label: {
                TurnSummary(turn: turn, showsChevron: true, expanded: expanded)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("turn.\(turn.id)")
            .accessibilityLabel(expanded
                ? String(localized: "Hide turn details")
                : String(localized: "Show turn details"))
        } else if showsProcess {
            // The row is the way to the process: the turn's own line, with a
            // mark that says the process is behind it.
            Button {
                onToggleProcess()
            } label: {
                TurnSummary(turn: turn, showsChevron: true, expanded: processExpanded)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("turn.\(turn.id).process")
            .accessibilityLabel(processExpanded
                ? String(localized: "Hide the process")
                : String(localized: "Show the process"))
        } else {
            TurnSummary(turn: turn)
                .accessibilityIdentifier("turn.\(turn.id)")
        }
    }

    /// Read the details while the turn runs.
    ///
    /// Every second while the running row is on screen. The detail feed is the
    /// full-transfer view (paid, or open on a LAN link) and a command's output
    /// needs to land while it is still the thing being talked about; one second is the cadence the host's
    /// 256 KiB capped answer was sized for. A failed read changes nothing —
    /// ``AppModel/refreshActivity(for:)`` keeps the last answer on screen.
    /// A second that lands while a drawer is moving is skipped -- the write
    /// would redraw the row in the card mid-drag -- and the next asks again.
    private func poll() async {
        // A finished turn has nothing to read, and clearing is not this view's
        // job when it never started: the change that stopped it clears.
        guard pollKey != nil else { return }
        while !Task.isCancelled {
            if !shell.isDragging, !shell.isSettling {
                await model.refreshActivity(for: sessionId)
            }
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
        }
    }
}

/// Narration a relay letter carried, drawn under the turn it belongs to.
///
/// Deliberately plain: one small line saying where it came from and the text
/// blocks in order. No status lines, no typewriter, no duration -- a replayed
/// turn is history, and the whole reason it is not fed through the live stream
/// is so it cannot be mistaken for one.
private struct ReplayedProcess: View {
    let blocks: [StreamBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // The label is drawn even when the letter carried no narration: it
            // is also how the reader learns that this turn's answer arrived
            // while the computer was offline.
            Label("Replayed", systemImage: "tray.and.arrow.down")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
            ForEach(blocks) { block in
                MarkdownMessage(block.text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 680, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.leading, 2)
        .accessibilityIdentifier("turn.replayed")
        .accessibilityElement(children: .contain)
    }
}
