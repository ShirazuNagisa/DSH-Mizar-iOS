//
//  ConversationView.swift
//  DSH-Mizar
//
//  What was said, and how long the agent took over it.
//
//  Two voices, drawn differently on purpose. The operator's words are a bubble
//  in the accent, on the right: short, theirs, and easy to find when scrolling
//  back for "what did I ask". The agent's answer is not a bubble at all -- it is
//  the page, full width, set like text to be read, because that is what it is:
//  long, structured, and the reason the screen exists.
//
//  A turn is drawn, not folded. The host sends a *summary* of each turn -- the
//  prompt, the turn's markers, and the model's last message -- with the per-step
//  narration left out entirely, so there is nothing to expand: the row says how
//  it went and the answer sits under it.
//
//  A failed turn gets the most prominent treatment of anything here. It is the
//  one state where the agent looks busy and is in fact doing nothing.
//

import SwiftUI
import MizarKit

struct ConversationView: View {
    /// The session on screen. Needed by the running-turn row: the paid
    /// full-detail feed is read per session, and a view that only held the
    /// conversation could not ask for it.
    let sessionId: String
    let items: [ConversationItem]
    /// Set when the lazy stack has lost every row on this page; render the
    /// whole page eagerly instead.
    var forceEager: Bool = false
    /// The conversation grouped into turns. Empty when the host sent no turn
    /// numbers, in which case the flat list is drawn instead.
    var turns: [ConversationTurn] = []
    /// A turn to draw on its own, while a long jump to it is being staged.
    ///
    /// The conversation is lazy: a row a few screens away has been thrown away,
    /// and a row that has been thrown away has no frame for `scrollTo` to aim
    /// at. Drawing just the turn asked for -- at the top of the content, where a
    /// lazy stack always builds -- is what puts it back in the hierarchy long
    /// enough for the scroll to find it. See
    /// `SessionDetailView/jump(to:proxy:)`.
    var stagedTurn: String?
    let loading: Bool
    /// Why the conversation is empty, when it is empty because the read failed.
    var failure: String?
    /// Called when the top of the conversation comes into view, to fetch what
    /// came before.
    ///
    /// `nil` means the question could not be asked right now -- no connection
    /// yet, the cache not written yet, a page already in flight. `0` means the
    /// host was asked and has nothing older. The distinction is the whole point:
    /// the two were conflated, so a single badly-timed attempt ended the list
    /// permanently.
    var onLoadOlder: (() async -> Int?)?
    /// Whether the older-page row may ask by itself yet.
    ///
    /// False while the screen is still putting the conversation at its newest
    /// message: the row is drawn then, so that the screen's reveal changes
    /// nothing in the stack, but where it is on screen means nothing until the
    /// page has been placed. Part of the asking task's identity, so a row that
    /// was in view all along asks the moment it may.
    var historyReady = true
    /// The turn whose body is being drawn by the live stream below this list.
    ///
    /// The stream owns the status lines, bodies and toolbar of one turn while
    /// the screen holds them; drawing the same answer from the history too
    /// would show it twice. The prompt is still drawn here, because it is the
    /// bubble the stream hangs under.
    var suppressedTurnId: String?

    /// The answer currently being typed, decided by the screen above.
    ///
    /// `nil` for every answer that was already part of the conversation when it
    /// opened. The detail screen owns the decision because it owns the load: it
    /// knows which page was the conversation's first, which is what makes "this
    /// answer arrived while the operator was watching" answerable at all.
    var typingAnswerId: String?
    /// Called when that answer's reveal begins, before the first character.
    var onAnswerTypingStarted: (String) -> Void = { _ in }
    /// Whether a turn's row is built, for the screen's placement.
    var onTurnRealized: (String, Bool, Int) -> Void = { _, _, _ in }

    @State private var loadingOlder = false
    @State private var exhausted = false
    @State private var olderRowVisible = false
    /// Pages fetched automatically since this row came on screen.
    ///
    /// The sentinel sits at the very top of the log and older messages are
    /// inserted *below* it, so it never leaves the screen and never re-appears.
    /// Re-driving on `items.count` keeps it asking, and the counter is what
    /// stops it from draining a fifty-page history in one go while the operator
    /// is looking at the top of it.
    @State private var automaticPages = 0
    private static let automaticPageLimit = 3
    /// Below the last row, and where the view scrolls on open.
    static let bottomAnchor = "conversation.bottom"

    /// Ask for the page before this one, once.
    private func fetchOlder(_ fetch: () async -> Int?, automatic: Bool = false) async {
        guard !Task.isCancelled, !loadingOlder else { return }
        if automatic, !historyReady || !olderRowVisible || automaticPages >= Self.automaticPageLimit { return }
        if automatic { automaticPages += 1 }
        loadingOlder = true
        defer { loadingOlder = false }
        let arrived = await fetch()
        guard !Task.isCancelled else { return }
        // Only a definite answer ends the list. `nil` leaves `exhausted` alone
        // so the next appearance -- or the operator's tap -- asks again.
        if arrived == 0 { exhausted = true }
    }

    /// What is drawn while a jump is staged: the turn asked for, first, and the
    /// couple after it.
    ///
    /// First, because a lazy stack builds what the content *starts* with
    /// whatever the scroll offset is -- and that row has to exist before it can
    /// be scrolled to. The couple after it come along so that flipping on down
    /// from the turn is as immediate as flipping down from anywhere else. The
    /// turns *before* it cannot come with it: they would push it off the top of
    /// a content that begins where the operator is going, and they arrive a
    /// frame later with the rest of the conversation.
    private var staged: [ConversationTurn] {
        guard let stagedTurn,
              let start = turns.firstIndex(where: { $0.id == stagedTurn })
        else { return [] }
        return Array(turns[start...min(turns.count - 1, start + 2)])
    }

    /// The turns actually drawn: the conversation, or the staged window when
    /// there is one.
    private var drawnTurns: [ConversationTurn] {
        staged.isEmpty ? turns : staged
    }

    /// Pages with only a handful of turns are laid out eagerly.
    ///
    /// The lazy stack can drop every row from a short page during a staged
    /// jump; the scroll offset then sits at the bottom of content with nothing
    /// built there -- a blank conversation that needs a swipe. Eager layout is
    /// cheap for a page this small and cannot lose the rows.
    private var usesEagerStack: Bool {
        if forceEager { return true }
        if turns.isEmpty { return items.count <= 40 }
        return turns.count <= 6
    }

    var body: some View {
        Group {
            if usesEagerStack {
                VStack(alignment: .leading, spacing: 14) {
                    conversationRows
                }
            } else {
                LazyVStack(alignment: .leading, spacing: 14) {
                    conversationRows
                }
            }
        }
    }

    @ViewBuilder
    private var conversationRows: some View {

            // Not while a jump is staged: the row sits at the very top and
            // would ask for a page of history the screen is in the middle of
            // leaving.
            if !exhausted, let onLoadOlder, !items.isEmpty, staged.isEmpty {
                loadOlderRow(onLoadOlder)
            }

            if loading && items.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.top, 80)
            } else if items.isEmpty, let failure {
                // Not "this session has no messages": that is a statement about
                // the operator's session, made out of a request that never came
                // back -- and on a phone that is ordinary.
                ContentUnavailableView {
                    Label("Could not load the conversation", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(failure)
                }
                .transition(.rise)
            } else if items.isEmpty {
                ContentUnavailableView(
                    "Nothing yet",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("This session has no messages."),
                )
                .transition(.rise)
            } else if turns.isEmpty {
                ForEach(ConversationNoticeFold.fold(items)) { item in
                    ConversationRow(
                        item: item,
                        isLastPrompt: false,
                        typing: item.id == typingAnswerId,
                        onTypingStarted: { onAnswerTypingStarted(item.id) },
                    )
                    .id(item.id)
                    .transition(.rise)
                }
            } else {
                // One list either way, narrowed to the staged turn while a jump
                // is playing: the same `ForEach` with the same identities, so
                // the row being jumped to is *kept* across the swap rather than
                // destroyed and built again.
                ForEach(drawnTurns) { turn in
                    TurnSection(
                        turn: turn,
                        sessionId: sessionId,
                        typingAnswerId: typingAnswerId,
                        onAnswerTypingStarted: onAnswerTypingStarted,
                        suppressBody: turn.id == suppressedTurnId,
                        onRealized: onTurnRealized,
                    )
                    // An explicit id, not merely the ForEach identity: the
                    // screen scrolls to turn ids from a lazy stack, and a target
                    // that only exists as a diffing identity is not guaranteed
                    // to be in `ScrollViewReader`'s table.
                    .id(turn.id)
                    .transition(.rise)
                }
            }

            // Where the view scrolls to on open.
            Color.clear
                .frame(height: 1)
                .id(Self.bottomAnchor)
    }

    /// The top of the list, where older messages arrive.
    ///
    /// Always a visible row, never a bare spinner: a spinner whose appearance
    /// was the only trigger went quiet for good the first time it returned
    /// without fetching. A row that can be tapped cannot fail that way.
    private func loadOlderRow(_ onLoadOlder: @escaping () async -> Int?) -> some View {
        Button {
            Task { await fetchOlder(onLoadOlder) }
        } label: {
            HStack(spacing: 6) {
                if loadingOlder {
                    ProgressView().controlSize(.mini)
                        .transition(.pop)
                } else {
                    Image(systemName: "arrow.up")
                        .font(.caption2.weight(.bold))
                        .transition(.pop)
                }
                Text("Load earlier messages")
                    .font(.caption.weight(.medium))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .frame(height: 30)
            .liquidCapsule(interactive: true)
            .animation(.mizarSnappy, value: loadingOlder)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("conversation.loadOlder")
        // Lazy construction is not visibility. Only a row actually intersecting
        // the scroll viewport may ask automatically, including after first placement.
        .onScrollVisibilityChange(threshold: 0.5) { visible in
            olderRowVisible = visible
            if !visible { automaticPages = 0 }
        }
        .task(id: OlderPageTrigger(itemCount: items.count, visible: olderRowVisible, ready: historyReady)) {
            guard olderRowVisible, !Task.isCancelled else { return }
            await fetchOlder(onLoadOlder, automatic: true)
        }
        .onDisappear {
            olderRowVisible = false
            automaticPages = 0
        }
    }
}

/// One turn: the prompt, the row that says how it is going, and the answer.
private struct TurnSection: View {
    let turn: ConversationTurn
    /// The session this turn belongs to, for the paid activity feed.
    let sessionId: String
    /// The answer currently being typed, when it belongs to this turn.
    var typingAnswerId: String?
    /// Called when that answer's reveal begins.
    var onAnswerTypingStarted: (String) -> Void = { _ in }
    /// Whether the live stream below the list owns this turn's body.
    var suppressBody = false
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

    var body: some View {
        let steps = ConversationNoticeFold.fold(turn.steps)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(turn.prompts.enumerated()), id: \.element.id) { index, item in
                ConversationRow(item: item, isLastPrompt: index == turn.prompts.count - 1)
            }

            // Prompt, row, answer -- and the row does not move. The answer was
            // once drawn above the row and once hidden inside it; both made the
            // row jump or hid the one thing a monitoring app must show. The paid
            // full-detail area is added *below* the row for the same reason:
            // opening it must never move or replace the status row.
            //
            // A turn the live stream below the list owns draws none of this:
            // the stream has the same answer already, plus the status lines the
            // history never carried. See ``ConversationStreamView``.
            if !suppressBody {
                TurnActivitySummary(turn: turn, sessionId: sessionId)

                ForEach(steps) { item in
                    ConversationRow(
                        item: item,
                        isLastPrompt: false,
                        typing: item.id == typingAnswerId,
                        onTypingStarted: { onAnswerTypingStarted(item.id) },
                    )
                    .transition(.rise(distance: 14, blur: 6))
                }
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

/// "DeepSeeking for 2 min 14 s", "Completed in 2 min 14 s", or why it did not.
private struct TurnSummary: View {
    let turn: ConversationTurn
    /// Whether the row offers the paid detail, so a chevron shows that there is
    /// more behind it. Off for free accounts and for turns with no detail.
    var showsChevron = false
    /// Which way the chevron points, and where the detail is going.
    var expanded = false

    var body: some View {
        HStack(spacing: 7) {
            // The state, as a glyph that changes rather than appears: the mark
            // turning while it works, settling into a tick when it is done.
            ZStack {
                if turn.isRunning {
                    MizarStar(ink: 17, motion: .running)
                        .transition(.pop)
                } else if turn.isEndInferred {
                    // A later turn proves this one is over, but the log never
                    // said how. A hollow tick rather than a filled one: the row
                    // may not claim a completion the host did not report.
                    Image(systemName: "checkmark.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .symbolRenderingMode(.hierarchical)
                        .transition(.pop)
                } else {
                    Image(systemName: turn.failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(turn.failed ? Theme.waiting : Theme.running)
                        .symbolRenderingMode(.hierarchical)
                        .transition(.pop)
                }
            }
            // The running mark is 17 points of ink, and its box is that over
            // the design margin (about 24); the column is wide enough that the
            // arms do not crowd the headline.
            .frame(width: 20, height: 20)

            headline
            Spacer(minLength: 8)
            // Only when the log actually said. A turn whose markers were trimmed
            // away by the pager shows no number rather than a zero it would be
            // counted as -- "no steps" is a claim this row cannot make.
            // No step count and no disclosure: the host no longer streams the
            // per-step detail this row used to open, so the number and the
            // chevron would be an invitation to nothing.
            if showsChevron {
                // A chevron that turns rather than swaps: the row is the same
                // row open and shut, and the glyph saying so should be the same
                // glyph. Rotated, not replaced, so no second element appears.
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .animation(.mizarSnappy, value: expanded)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 2)
        .animation(.mizarBouncy, value: turn.isRunning)
        .animation(.mizarSnappy, value: turn.stepCount)
        // One small tap when a turn the operator is watching finishes. Only on
        // the change, never on the first draw of a finished turn -- and never
        // for a turn settled from a missing record, which nobody just watched.
        .mizarFeedback(.success, trigger: turn.isRunning) { old, new in
            old && !new && !turn.failed && !turn.isEndInferred
        }
    }

    /// The state of the turn, and for a running one a clock that moves.
    ///
    /// One `Text` -- the headline is the row's whole statement, and it is read
    /// as one sentence. Ticked locally rather than by asking the computer: the host
    /// already said when the turn started.
    @ViewBuilder private var headline: some View {
        if turn.isRunning, turn.beganAt != nil {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                // Through `elapsed(asOf:)`, which clamps at zero: the start came
                // off the host's clock and `context.date` is the phone's.
                let running = turn.elapsed(asOf: context.date) ?? 0
                // No shimmer here. The sweep is a repeating keyframe animation
                // that re-masks its text every frame, and this text lives in
                // the conversation's LazyVStack: a stack measured it while the
                // mask was animating, and the text-layout attribute looped
                // (100% CPU, memory climbing). The clock still ticks and its
                // digits still transition; the decoration is not worth a
                // layout fight inside a lazy row.
                // A plain text, updated once a second: no numeric transition
                // and no animation. The animated variant kept the row's text
                // layout attribute in play inside the lazy stack -- the same
                // failure class as the shimmer removed above, only at 1 Hz.
                // Monospaced digits keep the width from stepping.
                Text(String(format: String(localized: "DeepSeeking for %@"), Self.spell(running)))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        } else {
            Text(staticHeadline)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .contentTransition(.interpolate)
        }
    }

    /// The headline for a turn whose text does not change.
    private var staticHeadline: String {
        // A turn with a number and no end is running; this case is reached when
        // it also has no start to measure from.
        if turn.isRunning { return String(localized: "DeepSeeking") }
        // A turn whose end record never arrived, but which a later turn proves
        // is over. No duration: the end this row was given is an upper bound,
        // not a measurement, and a figure here would read as one.
        if turn.isEndInferred { return String(localized: "Ended") }
        if turn.failed {
            return turn.duration.map {
                String(format: String(localized: "Unfinished after %@"), Self.spell($0))
            } ?? String(localized: "Unfinished")
        }
        return turn.duration.map {
            String(format: String(localized: "Completed in %@"), Self.spell($0))
        } ?? String(localized: "Completed")
    }

    /// Minutes and seconds, because that is the unit a turn is measured in.
    static func spell(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return String(format: String(localized: "%lld s"), total) }
        return String(format: String(localized: "%lld min %lld s"), total / 60, total % 60)
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

/// One item, drawn by kind.
private struct ConversationRow: View {
    let item: ConversationItem
    /// Whether this is the last of the operator's messages before the agent
    /// answers, which is the bubble that carries the tail.
    let isLastPrompt: Bool
    /// Whether this row's answer should be typed onto the page.
    var typing: Bool = false
    /// Called when typing that answer starts.
    var onTypingStarted: () -> Void = {}

    var body: some View {
        switch item {
        case .message(_, .user, let text, _):
            UserBubble(
                text: text,
                tail: isLastPrompt,
                attachments: DeliveredAttachments.attachments(for: text),
            )
        case .message(_, .assistant, let text, _):
            AgentText(text: text, typing: typing, onTypingStarted: onTypingStarted)
        case .message(_, .system, let text, _):
            SystemNote(text: text)
        case .failure(_, let message, let at):
            FailureCard(message: message, at: at)
        case .notice(_, let text, _):
            ConversationNotice(text: text)
        }
    }
}

/// The conversation talking about itself, centred in the stream.
///
/// A compaction is the one event in a session that changes what the operator is
/// looking at without anybody having said anything: the history above it is now
/// a summary. It is drawn as a line between the messages rather than as a card,
/// because it is not part of the conversation -- it is a note about it, and the
/// desktop draws it the same way.
private struct ConversationNotice: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(.quaternary)
                .frame(height: 1)
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .semibold))
                Text(text)
                    .font(.caption)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Rectangle()
                .fill(.quaternary)
                .frame(height: 1)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("conversation.notice")
    }

    /// The family's glyph: a compaction is about the history, a task runs on a
    /// terminal, a subagent is another worker.
    private var symbol: String {
        let lower = text.lowercased()
        if lower.contains("compact") || text.contains("压缩") {
            return "arrow.down.right.and.arrow.up.left"
        }
        if lower.contains("task") || text.contains("任务") {
            return "terminal"
        }
        if lower.contains("subagent") || text.contains("子代理") {
            return "person.2"
        }
        return "arrow.down.right.and.arrow.up.left"
    }
}

// MARK: - Messages

/// Whether a message body is worth drawing as blocks.
///
/// Cheap and deliberately narrow: a false negative shows backticks, a false
/// positive costs one parse. The line-anchored markers are checked per line
/// rather than by substring -- `"\n# "` never matched a body that *was* a
/// heading, which is the common case of a short reply.
enum MessageMarkdown {
    static func looksLikeMarkdown(_ text: String) -> Bool {
        if text.contains("**") || text.contains("`") || text.contains("](") || text.contains("|") {
            return true
        }
        return text.split(separator: "\n", omittingEmptySubsequences: true).contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("# ") || trimmed.hasPrefix("> ") || trimmed.hasPrefix("```") {
                return true
            }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                return true
            }
            return trimmed.range(of: #"^\d{1,3}[.)]\s"#, options: .regularExpression) != nil
        }
    }
}

/// Selectable text: blocks when the body is Markdown, one run of text otherwise.
///
/// The block form carries the raw text as its accessibility label, so what
/// VoiceOver reads -- and what a test finds -- is what was said, not the
/// rendering of it.
private struct MessageText: View {
    let text: String

    var body: some View {
        if MessageMarkdown.looksLikeMarkdown(text) {
            MarkdownMessage(text)
        } else {
            Text(text)
                .textSelection(.enabled)
        }
    }
}

/// The operator's words.
private struct UserBubble: View {
    let text: String
    /// Whether the corner nearest the answer tightens, the quiet tail that says
    /// "this is the message that was answered".
    let tail: Bool
    /// What this phone sent with the prompt, above the words.
    ///
    /// The computer's record carries the text alone, so an attachment that
    /// went with it would otherwise vanish the moment the screen reloaded --
    /// the operator sees the photo go up and then nothing.
    var attachments: [DeliveredAttachment] = []

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 56)
            VStack(alignment: .trailing, spacing: 6) {
                if !attachments.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(attachments) { attachment in
                            HStack(spacing: 4) {
                                Image(systemName: attachment.isImage ? "photo" : "doc")
                                    .font(.system(size: 10, weight: .semibold))
                                Text(attachment.label)
                                    .font(.caption2)
                                    .lineLimit(1)
                            }
                            .foregroundStyle(Theme.onAccent.opacity(0.85))
                            .padding(.horizontal, 8)
                            .frame(height: 22)
                            .background(Theme.onAccent.opacity(0.12), in: Capsule())
                        }
                    }
                    .accessibilityIdentifier("message.attachments")
                }
                bubble
            }
        }
    }

    private var bubble: some View {
        HStack(spacing: 0) {
            MessageText(text: text)
                .foregroundStyle(Theme.onAccent)
                .tint(Theme.onAccent)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background {
                    UnevenRoundedRectangle(
                        topLeadingRadius: Theme.Radius.lg,
                        bottomLeadingRadius: Theme.Radius.lg,
                        bottomTrailingRadius: tail ? 6 : Theme.Radius.lg,
                        topTrailingRadius: Theme.Radius.lg,
                        style: .continuous,
                    )
                    .fill(Color.accentColor.gradient)
                }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// The agent's answer: the page, not a bubble.
private struct AgentText: View {
    let text: String
    /// Whether this answer is being typed onto the page as it arrives.
    var typing: Bool = false
    /// Called when that reveal begins.
    var onTypingStarted: () -> Void = {}

    var body: some View {
        TypewriterMessage(text: text, typing: typing, onStarted: onTypingStarted)
            .font(.body)
            .lineSpacing(4)
            .foregroundStyle(.primary)
            // A readable measure on a wide screen; edge to edge on a phone.
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 2)
    }
}

/// What the system said, as an aside.
private struct SystemNote: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("system")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            MessageText(text: text)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
    }
}

/// A turn that produced nothing.
///
/// Internal rather than private so the snapshot suite can render it from a
/// fixture (`ComposerLanguageSnapshotTests`), the way `CommandList` is: it owns
/// no environment, and a failure older than twenty seconds never arms the
/// shake, so a fixture renders the resting card.
struct FailureCard: View {
    let message: String
    /// When the turn failed. Only a failure that just happened shakes: one
    /// scrolled back into view is news nobody needs announced twice.
    let at: Date
    @State private var shakes = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("The turn ended without a response", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.failed)
            Text(message)
                .font(.caption)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.failed.opacity(0.09), in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                .strokeBorder(Theme.failed.opacity(0.28), lineWidth: 1)
        }
        // A small shake when it first comes on screen: two swings of four points,
        // the "no" of a head being shaken. Still under Reduce Motion.
        .keyframeAnimator(initialValue: CGFloat(0), trigger: shakes) { content, x in
            content.offset(x: x)
        } keyframes: { _ in
            KeyframeTrack {
                CubicKeyframe(4, duration: 0.07)
                CubicKeyframe(-4, duration: 0.1)
                CubicKeyframe(3, duration: 0.1)
                CubicKeyframe(-2, duration: 0.09)
                CubicKeyframe(0, duration: 0.09)
            }
        }
        .onAppear {
            guard !Motion.reduced, Date().timeIntervalSince(at) < 20 else { return }
            shakes += 1
        }
    }
}

// MARK: - Shimmer

extension View {
    /// A band of light sweeping across, for text that is still being worked on.
    ///
    /// Drawn over the content and masked by it, so the content itself -- and
    /// what it says to VoiceOver -- is untouched. While the shell's drawers
    /// move, the sweep holds: those frames belong to the card.
    func shimmering(active: Bool = true) -> some View {
        modifier(Shimmer(active: active))
    }
}

private struct Shimmer: ViewModifier {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Held while a drawer is being dragged or settles: the sweep redraws
    /// -- and re-masks -- every frame it runs, and those frames belong to
    /// the card.
    @Environment(\.drawersStill) private var drawersStill

    func body(content: Content) -> some View {
        if active && !reduceMotion && drawersStill {
            content
                .overlay {
                    GeometryReader { geometry in
                        let width = geometry.size.width
                        LinearGradient(
                            colors: [.clear, Color.accentColor.opacity(0.95), .white.opacity(0.9), Color.accentColor.opacity(0.95), .clear],
                            startPoint: .leading,
                            endPoint: .trailing,
                        )
                        .frame(width: max(40, width * 0.45))
                        .keyframeAnimator(initialValue: CGFloat(0), repeating: true) { band, phase in
                            band.offset(x: -width * 0.45 + phase * width * 1.45)
                        } keyframes: { _ in
                            CubicKeyframe(1, duration: 1.6)
                            LinearKeyframe(1, duration: 0.6)
                        }
                    }
                    .mask(content)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
        } else {
            content
        }
    }
}

private struct OlderPageTrigger: Equatable {
    var itemCount: Int
    var visible: Bool
    var ready: Bool
}
