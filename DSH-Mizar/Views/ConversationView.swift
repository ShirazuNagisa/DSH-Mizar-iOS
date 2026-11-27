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
        // A staged jump draws only the newest turn (or three) so a real row
        // exists to scroll to. That window must be eager even when the full
        // conversation is not: it is a handful of rows, and a lazy window whose
        // one enormous turn has not been built is exactly the blank first
        // frame this staging exists to prevent.
        if !staged.isEmpty { return true }
        let rows = turns.isEmpty ? items.count : turns.reduce(0) { $0 + $1.items.count }
        // The lazy rows can be evicted during a staged jump; the recovery may
        // rebuild them eagerly, but only while that is still cheaper than the
        // freeze it is recovering from.
        if forceEager { return rows <= 80 }
        return Self.canUseEagerStack(turnCount: turns.count, rowCount: rows)
    }

    /// Whether the page is small enough to lay out eagerly.
    ///
    /// The old rule was `turns.count <= 6`, which described a four-turn
    /// conversation with 123 rows and 196k characters as small. It built every
    /// Markdown block at once; the long-session launch and the drawer swipe
    /// paid for it. `forceEager` cannot override this: on a long page it is
    /// not a recovery, it is the same freeze.
    static func canUseEagerStack(turnCount: Int, rowCount: Int) -> Bool {
        if turnCount == 0 { return rowCount <= 40 }
        return turnCount <= 6 && rowCount <= 40
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

private struct OlderPageTrigger: Equatable {
    var itemCount: Int
    var visible: Bool
    var ready: Bool
}
