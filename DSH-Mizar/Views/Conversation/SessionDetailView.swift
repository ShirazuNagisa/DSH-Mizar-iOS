//
//  SessionDetailView.swift
//  DSH-Mizar
//
//  One session: the conversation, what is waiting on the operator, and
//  somewhere to type.
//

import SwiftUI
import MizarKit

/// A session: what is waiting, what it has cost, and somewhere to type.
///
/// The order is deliberate. Pending requests sit above usage because an agent
/// blocked on a decision is more urgent than a number, and the composer is
/// pinned to the bottom where the keyboard expects it.
struct SessionDetailView: View {
    let sessionId: String
    /// Internal hosted-test observation seam, nil in production. Delivers the
    /// same state binding the composer's real expand/collapse control changes.
    var onComposerBindingAvailable: ((Binding<Bool>) -> Void)? = nil
    /// Internal read-only hosted-test observation, nil in production; this
    /// callback cannot bypass the placement reveal gate.
    var onPlacementChanged: ((InitialPlacement) -> Void)? = nil
    /// Internal read-only hosted-test geometry, in the conversation coordinate space.
    var onConversationContentBottomChanged: ((CGFloat) -> Void)? = nil
    var onComposerFrameChanged: ((CGRect) -> Void)? = nil

    @Environment(AppModel.self) private var model
    @Environment(TurnIndex.self) private var turnIndex
    @Environment(ShellState.self) private var shell
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var stats: SessionStatsFrame?
    /// The host-reported state for this session, when it reports one.
    @State private var liveState: SessionState?
    @State private var liveStateStale = false
    @State private var liveStateText = ""
    /// The action in progress, for the present-tense line.
    @State private var liveRunning: ProcessCategory?
    /// What this segment has finished, for the frozen heading.
    @State private var liveDone: Set<ProcessCategory> = []
    /// The session `stats` was read for.
    ///
    /// The shell keys this page per session (`.id(sessionId)`), so the state
    /// belongs to the session it was filled from; this tag is the defence
    /// behind that. The figures are now deliberately never blanked by a read
    /// that fails -- that is what made them vanish on the way into a session --
    /// so without the tag a failed read would leave the *previous* session's
    /// title, model and context on screen instead, which is worse than blank.
    @State private var statsSessionId: String?
    @State private var loading = true
    @State private var showingModelPicker = false
    @State private var showingContextDetail = false
    @State private var showingCommands = false
    @State private var showingPermissionPicker = false
    @State private var items: [ConversationItem] = []
    /// The session `items` and `turns` belong to, for the same reason as
    /// ``statsSessionId``: the shell keys this page per session, and the tag
    /// is the defence behind it -- a read that returns nothing must not be
    /// able to throw away what is on screen, and a page from one session must
    /// never be drawn under another's grouping.
    @State private var conversationSessionId: String?
    /// The same conversation grouped into turns, when the host gave turn numbers.
    @State private var turns: [ConversationTurn] = []

    /// Answers this screen has already started typing (or chosen not to type).
    ///
    /// A lazy row that scrolls out of the stack is destroyed, and the answer it
    /// held would otherwise be a new arrival again when it comes back. One
    /// entry per answer, for the life of the screen.
    @State private var settledAnswerIds: Set<String> = []
    @State private var loadingConversation = true
    /// Whether this appearance has already jumped to the newest message.
    ///
    /// Once per appearance, not once per load: scrolling to the bottom after a
    /// page of *older* messages arrives would undo the scroll that asked for it.
    /// Set by the initial placement (see ``InitialPlacement``) once the first
    /// frame is in position, and read by the composer's corrections as "the
    /// operator has been put at the newest message at least once".
    @State private var didReachBottom = false
    /// What has been typed, held here because the command button writes to it.
    @State private var draft = ""
    /// The write waiting for the typing to pause.
    @State private var draftSaveTask: Task<Void, Never>?
    /// Whether the field has the keyboard. Owned here so a tap on the
    /// conversation can put it away.
    @State private var composerFocused = false
    /// How tall the floating composer is, measured rather than guessed, so the
    /// scroll content reserves exactly the room it covers.
    @State private var composerHeight: CGFloat = 130
    /// The last resting reservation, not the screen-height expanded composer.
    /// Until measured, reuse the existing initial composer height.
    @State private var composerReservedHeight: CGFloat?
    @State private var collapsedComposerHeight: CGFloat?
    /// Dock and stack overhead, measured against the shell in one layout pass.
    @State private var collapsedComposerExtra: CGFloat?
    /// Whether a load of this screen is already running.
    @State private var reloading = false
    /// Whether something asked for a load while one was running.
    @State private var reloadWanted = false
    /// Whether a reload the operator asked for by hand is in flight.
    ///
    /// `reloading` cannot answer this: it is true for the load the screen makes
    /// on appearance too, so a toolbar button driven by it would show a spinner
    /// at the moment the screen opens -- reporting a refresh nobody asked for.
    /// This is the narrower claim: someone tapped the control and it has not
    /// answered yet.
    @State private var refreshing = false
    /// Whether the "cannot reach the desktop" note is out.
    @State private var showingUnreachable = false
    /// Where the conversation is on its way to its first position.
    ///
    /// The page used to reveal the conversation at whatever offset a new
    /// `ScrollView` starts at -- the top -- and move it to the newest message
    /// once the load had finished, which is why a session with a cached
    /// history opened showing its oldest turns and jumped a moment later. The
    /// placement is now a precondition of display: the message area stays
    /// gated until the geometry says the newest turn is in view. See
    /// ``InitialPlacement``.
    @State private var placement: InitialPlacement = .waitingForContent
    /// Which round of placement is running, as part of the placement task's
    /// identity. Bumped when a conversation is committed to a page that has
    /// not been placed yet -- including one whose first read failed, so a
    /// late answer still gets its first frame at the bottom.
    @State private var placementRound = 0
    /// The signed distance from the newest message: positive when it is still
    /// below the viewport, negative when the page sits past the end of the
    /// content. The placement's acceptance test, because a page parked *under*
    /// the content is the one failure a clamped distance reads as "at the
    /// bottom" -- and it is the shape the black conversation used to open in.
    @State private var placementGeometry: ConversationPlacementGeometry?
    /// Bumped when something was just sent, to move the view to it.
    @State private var newMessageArrived = 0
    /// Messages sent and not yet read back from the host.
    @State private var outgoing: [OutgoingMessage] = []
    /// The text of the last send, on its way from the field to the conversation.
    @State private var flight: Flight?
    /// Whether the operator has scrolled well away from the newest message.
    @State private var farFromBottom = false
    /// Messages that arrived below while the operator was reading further up.
    @State private var unseen = 0
    /// How many pieces of this screen are reading the conversation right now.
    ///
    /// The single-flight lock, and it has to be one lock rather than a flag per
    /// caller: `reload()` and the poll after a send are two loops that both want
    /// the same read, and "is it busy" tested by each of them in turn is a
    /// question two of them can answer "no" to before either starts. Whoever
    /// increments first owns the socket; everyone else waits for zero.
    @State private var conversationLoads = 0
    /// The turn the conversation has been reduced to, for the length of a long
    /// jump. See ``jump(to:proxy:)``.
    @State private var stagedTurn: String?
    /// Whether the composer is opened out into its tall, focused-input form.
    /// Owned here because the overlay's layout -- the dock, the jump button,
    /// the room the conversation reserves -- all answer to it.
    @State private var composerExpanded = false
    /// How far the newest message is below what is on screen, and how tall the
    /// viewport is. Tracked continuously so the way-back button can tell a
    /// nudge from a journey -- a long way back takes the same travelling
    /// transition a long turn jump takes, not an animated scroll across rows
    /// nobody asked to see.
    @State private var distanceFromBottom: CGFloat = 0
    @State private var scrollViewportHeight: CGFloat = 0
    /// Whether a finger has the conversation, or let go of it and it is still
    /// coasting or bouncing. Every correction below stands down while it does:
    /// an instant scroll in the middle of a bounce is the page jumping out
    /// from under the thumb instead of springing back.
    @State private var userScrolling = false
    /// Which bottom seek is current, so a later one takes over from an
    /// earlier one instead of the two of them aiming in turns.
    @State private var bottomSeek = 0
    /// Whether the composer's expand or collapse animation is still playing.
    /// While it is, the bottom anchor and the composer-height correction are
    /// suspended -- see `defaultScrollAnchor` below.
    @State private var composerAnimating = false
    /// How far the page is faded out while a long jump plays, and how far it has
    /// been shifted on its way there.
    ///
    /// These two *are* the animation of a jump. A jump across forty turns is
    /// thousands of points of travel, and animating that makes the phone build
    /// and throw away every row along the way -- work spent on frames nobody
    /// asked to see. So the scroll itself is instantaneous and invisible, and
    /// what the eye is given instead is the page leaving in the direction of the
    /// turn and arriving from the other side.
    @State private var jumpFade: Double = 1
    @State private var jumpShift: CGFloat = 0
    /// Whether a jump is playing, so the conversation stops taking taps.
    @State private var jumping = false
    /// Which jump is current, so a second one tapped while the first is still
    /// playing takes over instead of the two of them taking turns.
    @State private var jumpGeneration = 0

    /// The figures for the session on screen, or nothing.
    ///
    /// The shell keys this page per session (`.id(sessionId)`), so the state
    /// belongs to the session it was filled from; the tag is the belt to that
    /// braces. A read that returns nothing must not be able to draw another
    /// session's model name, and a session that has not answered yet shows
    /// nothing rather than somebody else's.
    private var shownStats: SessionStatsFrame? {
        statsSessionId == sessionId ? stats : nil
    }

    /// The conversation for the session on screen, or nothing. See ``shownStats``.
    private var shownItems: [ConversationItem] {
        conversationSessionId == sessionId ? items : []
    }

    /// The same, grouped into turns.
    private var shownTurns: [ConversationTurn] {
        conversationSessionId == sessionId ? turns : []
    }

    /// Whether the lazy stack has built the newest turn.
    ///
    /// The bottom of a lazy conversation is only where the stack *estimates*
    /// it is until the rows down there exist: a turn here can be one line or
    /// thirty screens, and an aim at the end of the page against estimated
    /// heights lands in space the stack has not filled -- the blank page that
    /// a swipe or two by hand used to fix. Being at the bottom is only
    /// believed once the newest turn is built. A flat list has no turn to ask
    /// about and goes by the geometry alone.
    private var newestIsBuilt: Bool {
        guard let newest = shownTurns.last?.id else { return true }
        return turnIndex.sessionId == sessionId && turnIndex.realized.contains(newest)
    }

    /// What changes when something arrives at the end of the conversation --
    /// a new turn, or an answer in the last one -- and not when an older page
    /// arrives at the top.
    private var newestContent: NewestContent {
        NewestContent(
            turn: shownTurns.last?.id,
            steps: shownTurns.last?.steps.count ?? 0,
            item: shownItems.last?.id,
        )
    }

    /// How close to the newest message counts as reading it, for keeping the
    /// page there as the content under it changes.
    static let pinnedDistance: CGFloat = 40

    /// The coordinate space the send's flight is measured in.
    static let space = "session.detail"
    /// The very end of the page, below the room left for the composer.
    static let endAnchor = "session.end"

    /// How far from the newest message the placement accepts as "at the
    /// bottom", in points. A hair rather than zero: the composer's reserved
    /// room and rounding at non-integral display scales leave a fraction of a
    /// point between the anchor and the end of the content.
    static let placementTolerance: CGFloat = 4
    /// How many re-aims the placement may spend before offering a retry.
    /// This bounds active correction, not acceptance: a later geometry update
    /// can still reveal the conversation after these attempts are exhausted.
    static let placementAttempts = 32
    /// The spacing between those re-aims, in milliseconds.
    static let placementAttemptSpacing = 32

    /// Whether the message area may be shown and touched: the initial
    /// placement has settled, or there was nothing to settle.
    ///
    /// The gate is the message area alone -- the title, the composer, the
    /// sidebar and the refresh entry answer as usual while a page is being
    /// placed. Freezing the whole app to hide a first-frame flicker would be
    /// a worse trade than the flicker.
    private var placementRevealed: Bool {
        placement.isRevealed
    }

    var body: some View {
        ScrollViewReader { proxy in
            // The gated scroll view and the furniture are two views on
            // purpose. The gate quiets the message area with
            // `allowsHitTesting`, and a modifier applied *before* an overlay
            // covers the overlay with it -- the composer would stop answering
            // while a page is being placed, which is the one thing the gate
            // must not do.
            conversationScroll(proxy: proxy)
                .task(id: PlacementKey(sessionId: sessionId, round: placementRound)) {
                    await placeInitially(proxy: proxy)
                }
                // The composer floats over the conversation instead of sitting under
                // it. A bar in its own row clips the message behind it at a hard
                // edge; floating, the content runs underneath and reads through the
                // glass.
                .overlay(alignment: .bottom) {
                    bottomStack(proxy: proxy)
                }
                .task(id: sessionId) { await watchLiveState() }
                // On an iPad with the index column put away, the turns stay at the
                // edge as a rail to scrub.
                .overlay(alignment: .trailing) {
                    if sizeClass == .regular, !shell.indexPinnedVisible {
                        TurnRail()
                            .padding(.vertical, 90)
                            .padding(.bottom, composerHeight)
                            .padding(.trailing, 6)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .animation(.mizarSmooth, value: shell.indexPinnedVisible)
                .overlay(alignment: .topLeading) {
                    if let flight {
                        FlightGhost(flight: flight)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
        }
        .coordinateSpace(.named(Self.space))
        .onAppear { onComposerBindingAvailable?($composerExpanded) }
        .onChange(of: placement, initial: true) { _, value in onPlacementChanged?(value) }
        .navigationTitle(shownStats?.title ?? String(localized: "Session"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // A subtitle with the workspace, under the session's own title.
            // The session's title, with its workspace and how many turns it
            // has under it -- and a button: the turn index comes out of it, the
            // way a document's outline comes out of its name.
            ToolbarItem(placement: .principal) {
                Button {
                    shell.toggleTrailing(compact: sizeClass != .regular)
                } label: {
                    VStack(spacing: 0) {
                        Text(shownStats?.title ?? String(localized: "Session"))
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .contentTransition(.opacity)
                        HStack(spacing: 4) {
                            if let workspace {
                                Text(workspace)
                            }
                            if !shownTurns.isEmpty {
                                if workspace != nil { Text(verbatim: "·") }
                                Text("\(shownTurns.count) turns")
                                    .contentTransition(.numericText())
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 7, weight: .heavy))
                                    .rotationEffect(.degrees(indexIsOut ? 180 : 0))
                            }
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                    .padding(.horizontal, 10)
                    .contentShape(.rect)
                }
                .buttonStyle(.pressable(scale: 0.96))
                .animation(.mizarSmooth, value: shownStats?.title)
                .animation(.mizarBouncy, value: indexIsOut)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(String(format: String(localized: "Turns, %lld"), shownTurns.count)))
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("session.turnIndex")
            }
            ToolbarItem(placement: .topBarTrailing) {
                // A session that has gone quiet is the reason this screen is
                // open at all; pulling the conversation down is invisible, and
                // the composer sits on top of it.
                Button {
                    // Nothing to read without a socket: the note comes out of
                    // the button instead of a glyph that would only turn.
                    guard model.isConnected else {
                        showingUnreachable = true
                        return
                    }
                    Task {
                        refreshing = true
                        await reload()
                        refreshing = false
                    }
                } label: {
                    // The same glyph the sidebar's refresh wears: a ring while
                    // the read is on the socket, a check when it lands, the
                    // arrow between. There is no window here to reopen -- a
                    // reload of one conversation is over in a round trip -- so
                    // the control is only ever the three states.
                    RefreshGlyph.live(running: refreshing, fraction: nil, size: 16)
                }
                .disabled(refreshing)
                .accessibilityLabel(Text("Refresh"))
                .accessibilityIdentifier("session.refresh")
                .mizarPopover(isPresented: $showingUnreachable, arrowEdge: .top) {
                    RefreshUnreachableNote()
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingPermissionPicker = true
                } label: {
                    Label(permissionLabel, systemImage: permissionSymbol)
                        .foregroundStyle(permissionTint)
                        .contentTransition(.symbolEffect(.replace))
                }
                .accessibilityIdentifier("session.permissions")
                .mizarPopover(isPresented: $showingPermissionPicker, arrowEdge: .top) {
                    PermissionPickerView(
                        sessionId: sessionId,
                        current: resolvedPermission,
                        onApplied: { await refreshStatsFromCache() },
                    )
                }
            }
        }
        .task(id: sessionId) {
            // A different session is a different conversation, and the typewriter
            // state belongs to the one that was on screen.
            settledAnswerIds = []
            // What was typed here last time and never sent. Read before the
            // first frame the field draws, so the paragraph is simply there
            // rather than appearing a moment after the screen does.
            draft = DraftStore.text(for: sessionId)
            // A session just started from the home screen arrives with its first
            // prompt already sent: put it where it will land, and watch for the
            // host to record it, exactly as for a send from this screen.
            if let first = model.pendingFirstPrompt.removeValue(forKey: sessionId) {
                outgoing.append(OutgoingMessage(text: first, landed: true))
                Task { await refreshAfterSend(first) }
            }
            // Once per appearance. Coming back to a session should land at its
            // newest message again; a pull-to-refresh should not.
            didReachBottom = false
            await reload()
        }
        .onDisappear {
            // The turns leave with the screen: this drops only the page's
            // evidence, which stops a poll that was up for a conversation nobody
            // is looking at any more.
            model.noteConversationTurns([], for: sessionId)
            turnIndex.withdraw(sessionId: sessionId)
            // The last keystrokes, written now rather than by the debounce that
            // this screen is about to take with it.
            draftSaveTask?.cancel()
            DraftStore.save(draft, for: sessionId)
        }
        .onChange(of: draft) { _, _ in
            scheduleDraftSave()
        }
        .onChange(of: shownStats?.title) { _, title in
            turnIndex.publish(sessionId: sessionId, title: title, turns: shownTurns)
        }
        .onChange(of: model.runningPollTicks) { _, _ in
            // The model's poll found a new session list; the turn rows live here,
            // so the cache is re-read for the running row to become the finished
            // one without a tap.
            Task { await refreshConversationForRunningPoll() }
        }
        .onChange(of: model.deliveredPrompts[sessionId]) { _, delivered in
            // A message that was held for the end of a turn has gone. Draw it
            // the way a send from the field is drawn, and follow it down: the
            // bar disappeared when it left, so without this the operator's own
            // words would be missing until the next read landed.
            //
            // Taken, not merely read: one screen draws one delivery. See
            // ``AppModel/acknowledgeDeliveredPrompt(_:)``.
            guard let delivered else { return }
            model.acknowledgeDeliveredPrompt(delivered)
            launch(delivered.text)
            Task { await refreshAfterSend(delivered.text) }
        }
        .onChange(of: scenePhase) { _, phase in
            // Ask again when the operator comes back: suspending cancels whatever
            // was in flight, and this screen had no way to notice.
            guard phase == .active, !reloading else { return }
            Task { await reload() }
        }
        .onChange(of: showingPermissionPicker) { _, showing in
            // The window closes on a switch the host took and on one it refused
            // alike, and after either the bar should be drawn from the newest
            // frame the app has rather than from the one read before the window
            // opened. A refusal keeps the window up, so this is the operator's
            // own dismissal; it changes nothing when nothing changed.
            guard !showing else { return }
            Task { await refreshStatsFromCache() }
        }
    }

    /// The conversation's scroll view, gated until its first position is known.
    ///
    /// The gate is opacity, hit-testing and the accessibility tree together,
    /// and nothing is removed: the layout stays in the tree because there has
    /// to be something laid out before there is a position to place, and a
    /// lightweight placeholder stands in for what is being placed. The reveal
    /// is a change of one flag, so the first frame an operator can read is the
    /// one the geometry has already accepted.
    private func conversationScroll(proxy: ScrollViewProxy) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                conversation

                // The running turn's own line, at the end of the conversation
                // rather than above the composer: the answer is about to land
                // here, and the place to watch is the place it will arrive.
                if !liveDone.isEmpty || liveStateText.isEmpty == false || liveRunning != nil {
                    LiveTurnBlock(
                        running: liveRunning,
                        done: liveDone,
                        text: liveStateText,
                    )
                    .padding(.top, 10)
                }

                // What was just sent, drawn where it will land before the
                // host has recorded it. Hidden from the accessibility tree:
                // the conversation's own copy, read back from the host, is
                // the proof the message arrived -- this is only the promise.
                ForEach(outgoing) { message in
                    PendingBubble(text: message.text, visible: message.landed)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { frame in
                            land(message.id, at: frame)
                        }
                        .padding(.top, 14)
                        .transition(.opacity)
                }

                // Room for the floating composer and the dock, as content
                // rather than as a margin: a margin is ignored when the
                // conversation is shorter than the screen, and the newest
                // turn sat under the dock on an iPad. The anchor is the true
                // end of the page -- below the stand-ins for anything sent.
                //
                // An expanded composer is the size of the screen; reserving
                // that as content would park the conversation a page above
                // its own end, so the reservation stays at the resting
                // height while the composer is open. It also stays there
                // while the composer is *becoming* open or closed: at the
                // start of a collapse the measured height is still a
                // screenful, and reserving it would grow the page by a
                // screen and then shrink it back over the animation --
                // the bounce that made a collapse feel broken.
                Color.clear
                    .frame(height: (composerReservedHeight ?? composerHeight) + 16)
                    .id(Self.endAnchor)
                    .onGeometryChange(for: CGFloat.self) { geometry in
                        geometry.frame(in: .named(Self.space)).minY
                    } action: { bottom in
                        onConversationContentBottomChanged?(bottom)
                    }
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
        }
        // A conversation is read from the bottom, and it stays pinned there
        // as the composer and the dock change height.
        //
        // Two roles, answering to two different moments. `.initialOffset` is
        // the first frame's intent: a cached page is often laid out before
        // anything has *changed* size -- which is exactly why the page used
        // to open at the top and jump a moment later, since the `.sizeChanges`
        // role never fired for it. `.sizeChanges` then keeps the page at the
        // bottom as the composer, the dock and the rows settle their heights.
        //
        // Neither role is trusted alone, and that is the lesson of the black
        // conversation this screen once opened with: an anchor applied against
        // content that had not arrived left the scroll view parked in the
        // empty space under the page. The initial placement is what makes the
        // anchor safe to use -- the message area is gated until the geometry
        // says the newest turn is in view, so a first layout that lands wrong
        // is corrected rather than shown, and the overshoot correction below
        // stays live as the backstop.
        //
        // Suspended while a jump plays. A long jump swaps the whole list
        // for one staged turn and back, and each swap is a size change:
        // with the anchor live, every swap yanks the page to the bottom,
        // the jump's own `scrollTo` pulls it back to the turn, and the two
        // take turns for as long as the rows are settling -- the shudder
        // seen at the end of a jump to the newest turn.
        //
        // Also suspended while the composer grows or shrinks. Collapsing
        // the expanded composer hands back a screenful of height: every
        // intermediate size change fired the bottom anchor as an instant
        // jump while the composer's own animation was still easing, and
        // the instant jumps and the easing fought the whole way down --
        // the shudder that followed every collapse.
        //
        // And suspended while the operator is scrolling. The rows a scroll
        // brings into view are built as it goes, at heights that differ from
        // the stack's estimates, and every one of them is a size change: held
        // to the bottom, each re-measure moved the page under the thumb, and a
        // scroll towards the newest message was pulled back again and again.
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(jumping || composerAnimating || userScrolling ? nil : .bottom, for: .sizeChanges)
        .onScrollPhaseChange { _, phase in
            // Whatever the finger set going: a drag, the coast after it, and
            // the spring back from past either end. Not `.animating`, which
            // is this screen's own scrolls.
            userScrolling = phase == .tracking || phase == .interacting || phase == .decelerating
            if userScrolling { bottomSeek &+= 1 }
        }
        // Dragging the conversation puts the keyboard away, which is what
        // every messaging app does and what a thumb already expects.
        .scrollDismissesKeyboard(.interactively)
        // A long jump dips the page rather than travelling it. Applied to
        // the scroll view and not to the screen, so the composer and the
        // rail stay where they are while the conversation moves under
        // them: what is travelling is the page, not the furniture.
        .opacity(placementRevealed ? jumpFade : 0)
        .offset(y: jumpShift)
        .allowsHitTesting(placementRevealed && !jumping)
        .accessibilityHidden(!placementRevealed)
        .scrollEdgeEffectStyle(.soft, for: .bottom)
        .refreshable { await reload() }
        .onScrollGeometryChange(for: Bool.self) { geometry in
            let distance = geometry.contentSize.height - (geometry.visibleRect.maxY - geometry.contentInsets.bottom)
            return distance > max(320, geometry.containerSize.height * 0.8)
        } action: { _, far in
            withMizarAnimation(.mizarBouncy) {
                farFromBottom = far
                if !far { unseen = 0 }
            }
        }
        // …and the mirror case: past the end of the content rather than
        // short of it. That is where the first layout sometimes parks the
        // page, and what a few swipes by hand fixed.
        //
        // Initial placement owns the hidden page and has a bounded correction
        // budget. Once revealed, correct only on entering an overshoot, not on
        // every changing offset: a failed correction must not scroll forever.
        // Insets belong to the raw visible rect, not to conversation content.
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.visibleRect.minY + geometry.contentInsets.top - geometry.contentSize.height > 2
        } action: { _, overshoot in
            // A jump owns the position until it lands: its staged turn is
            // deliberately a short page, which reads as past the end, and
            // correcting then is a second scroll fighting the first.
            //
            // Nor while the operator is scrolling: past the end is also where
            // a bounce goes, and an instant scroll there is the page jumping
            // back instead of springing back.
            guard overshoot, placement == .ready, !jumping, !composerAnimating, !userScrolling, !shownItems.isEmpty else { return }
            reachBottomNow(proxy)
        }
        // How far the operator is from the newest message, kept current so
        // the way-back button can choose between a scroll and a journey.
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentSize.height - (geometry.visibleRect.maxY - geometry.contentInsets.bottom)
        } action: { _, distance in
            distanceFromBottom = max(0, distance)
        }
        // The placement's acceptance test: the same distance, kept signed.
        // Positive when the newest message is still below the viewport,
        // negative when the page sits past the end of the content -- the one
        // shape the clamped distance above reports as "at the bottom", and
        // the shape the black conversation used to open in.
        .onScrollGeometryChange(for: ConversationPlacementGeometry.self) { geometry in
            ConversationPlacementGeometry(
                contentHeight: geometry.contentSize.height,
                viewportHeight: geometry.containerSize.height,
                visibleMinY: geometry.visibleRect.minY,
                visibleMaxY: geometry.visibleRect.maxY,
                topInset: geometry.contentInsets.top,
                bottomInset: geometry.contentInsets.bottom
            )
        } action: { _, geometry in
            placementGeometry = geometry
            // A late success is still valid after the bounded re-aim budget.
            // Accept it without starting another scroll or network read.
            finishInitialPlacement()
        }
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.containerSize.height
        } action: { _, height in
            scrollViewportHeight = height
        }
        .onChange(of: newMessageArrived) { _, _ in
            // A jump owns the position until it lands; a send mid-jump is
            // picked up by the jump's own final aim instead.
            guard !jumping else { return }
            Task { @MainActor in
                await Task.yield()
                guard !Task.isCancelled, placementRevealed else { return }
                withMizarAnimation(.mizarSmooth) {
                    proxy.scrollTo(Self.endAnchor, anchor: .bottom)
                }
            }
        }
        .onChange(of: composerHeight) { _, _ in
            // The dock arriving or the field growing is the bottom moving
            // up; a reader who was at the bottom stays at it.
            guard !jumping, !composerAnimating, !userScrolling, !farFromBottom, didReachBottom else { return }
            withMizarAnimation(.mizarSmooth) {
                proxy.scrollTo(Self.endAnchor, anchor: .bottom)
            }
        }
        .onChange(of: composerExpanded) { _, expanded in
            // While the composer trades places with its expanded self the
            // bottom corrections stand down (see `defaultScrollAnchor`);
            // when the move has played out, a reader who was at the bottom
            // is put back at it once, exactly.
            composerAnimating = true
            Task { @MainActor in
                do {
                    try await Task.sleep(for: .milliseconds(600))
                } catch { return }
                guard !Task.isCancelled else { return }
                composerAnimating = false
                guard !expanded, !jumping, !farFromBottom, didReachBottom else { return }
                proxy.scrollTo(Self.endAnchor, anchor: .bottom)
            }
        }
        .onChange(of: turnIndex.jumpCount) { _, _ in
            // A turn chosen in the index: go there, then let it glow once
            // so the eye finds it.
            guard turnIndex.sessionId == sessionId, let target = turnIndex.jumpTarget else { return }
            Task { await jump(to: target, proxy: proxy) }
        }
        .onChange(of: shownItems.count) { old, new in
            // Something new arrived below while the operator was reading
            // further up: count it on the way-back button. Not while the
            // initial placement is running -- before it has settled, "below
            // the viewport" is where the page is by construction, not a
            // message that arrived while somebody was reading.
            if farFromBottom, placementRevealed, new > old, old > 0 { unseen += new - old }
        }
        .onChange(of: newestContent) { _, _ in
            holdAtBottom(proxy: proxy)
        }
        // The placement waits for the newest turn to be built as well as for
        // the geometry; this is the other half arriving last.
        .onChange(of: newestIsBuilt) { _, _ in
            finishInitialPlacement()
        }
        // Tapping the conversation puts the keyboard away. On a tap catcher
        // behind the content, not a gesture on the scroll view: as a
        // simultaneous gesture on the container it swallowed taps meant for
        // the controls drawn on top of it.
        .background {
            Color.clear
                .contentShape(.rect)
                .onTapGesture { composerFocused = false }
        }
        .overlay {
            if !placementRevealed {
                placementPlaceholder
            }
        }
    }

    /// What the message area shows while the initial placement runs.
    ///
    /// The conversation stays laid out underneath. Positioning failure offers
    /// a local retry, separately from the network failure state in the log.
    @ViewBuilder
    private var placementPlaceholder: some View {
        if placement == .positioningFailed {
            ContentUnavailableView {
                Label("Could not position the conversation", systemImage: "arrow.up.and.down")
            } description: {
                Text("Your messages are loaded. Try showing the latest message again.")
            } actions: {
                Button("Retry") {
                    placementRound += 1
                    placement = .placing(generation: placementRound)
                }
                .accessibilityIdentifier("session.placement.retry")
            }
            .accessibilityIdentifier("session.placement.failed")
        } else {
            ProgressView()
                .controlSize(.regular)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityHidden(true)
        }
    }

    /// The conversation itself.
    ///
    /// A property rather than an expression inline in `body`: the view takes
    /// enough parameters and closures that naming it keeps the body's type
    /// checker inside its budget.
    private var conversation: some View {
        // The older-page row asks by itself while it is on screen. Before the
        // initial placement has settled there is no such thing as "on screen"
        // -- the page sits at the top by construction until it is placed --
        // so the question is not asked until the placement says where the
        // conversation starts.
        //
        // The row is drawn all the same, and only its asking waits. It used to
        // be left out until the placement settled, which made the reveal an
        // insertion at the very top of a lazy stack scrolled to its very
        // bottom -- and the stack answered that by throwing away the rows on
        // screen and building nothing in their place: the blank page that
        // opened a session, until a swipe made it look again.
        let canReadHistory = placement == .ready || placement == .navigating
        let onLoadOlder: () async -> Int? = {
            guard !Task.isCancelled, placement == .ready || placement == .navigating else { return nil }
            let arrived = await model.loadOlder(sessionId: sessionId)
            guard !Task.isCancelled else { return nil }
            // Re-read what is on screen; the page was folded into the
            // cache, and the cache is what the screen draws from after a
            // successful fetch.
            if let arrived, arrived > 0,
               let cached = await model.cachedConversation(for: sessionId) {
                guard !Task.isCancelled else { return nil }
                items = cached.items
                show(turns: cached.turns ?? [])
            }
            return arrived
        }
        return ConversationView(
            sessionId: sessionId,
            items: shownItems,
            turns: shownTurns,
            stagedTurn: stagedTurn,
            loading: loadingConversation,
            failure: shownItems.isEmpty ? model.conversationError : nil,
            onLoadOlder: onLoadOlder,
            historyReady: canReadHistory,
            typingAnswerId: typingAnswerId,
            onAnswerTypingStarted: noteAnswerTypingStarted,
        )
    }

    /// The dock, the way back to the newest message, and the composer.
    private func bottomStack(proxy: ScrollViewProxy) -> some View {
        GeometryReader { container in
            VStack(spacing: 8) {
                Spacer(minLength: 0)
                // The way back is hidden while a jump plays -- the conversation
                // is already on its way somewhere -- and while the composer is
                // expanded or moving between its two sizes, when there is no
                // conversation in view to return to. Also hidden while the
                // initial placement runs: the page is at the top by
                // construction until it is placed, and "far from bottom" then
                // describes the placement, not the operator.
                if placementRevealed, farFromBottom, !jumping, !composerExpanded, !composerAnimating {
                    JumpToLatest(unseen: unseen) {
                        returnToLatest(proxy: proxy)
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 16)
                    .transition(.pop)
                }
                VStack(spacing: 8) {
                    // The dock leaves while the composer is expanded: the open
                    // field is the whole height of the screen, and a queue of
                    // pending requests above it is the opposite of the focus
                    // the expansion is for.
                    if !composerExpanded {
                        InteractionsDock(
                            composerFocused: composerFocused,
                            onExpand: { composerFocused = false },
                            maxHeight: max(160, container.size.height * 0.34),
                        )
                    }
                    // The message waiting for the running turn, directly above
                    // the field and a little narrower than it. It leaves with
                    // the expanded composer for the same reason the dock does,
                    // and it comes and goes through the field's top edge --
                    // see ``FromBelowTransition``.
                    if !composerExpanded, let held = model.pendingPrompt(for: sessionId) {
                        PendingPromptBar(
                            prompt: held,
                            onSend: { await sendHeldPrompt() },
                            onReturn: { returnHeldPrompt() },
                            onDelete: { deleteHeldPrompt() },
                        )
                        // Slightly narrower than the composer's own slab, which
                        // insets itself by ten points on each side.
                        .padding(.horizontal, 18)
                        .transition(.fromBelow)
                    }
                    ComposerView(
                        sessionId: sessionId,
                        stats: shownStats,
                        text: $draft,
                        focused: $composerFocused,
                        expanded: $composerExpanded,
                        showingModel: $showingModelPicker,
                        showingContext: $showingContextDetail,
                        showingCommands: $showingCommands,
                        onWillSend: { text in launch(text) },
                        onSent: { sent in await refreshAfterSend(sent) },
                        onSendFailed: { text in withdraw(text) },
                        onCollapsedHeightChanged: { height in
                            collapsedComposerHeight = height
                            if let extra = collapsedComposerExtra {
                                composerReservedHeight = height + extra
                            }
                        },
                    )
                    // Expanded, the composer fills the overlay up to just under
                    // the title; at rest it wraps its content.
                    .frame(maxHeight: composerExpanded ? .infinity : nil)
                }
                // One animation for the held prompt's arrival and departure, and
                // only that value drives it: the bar's height is part of this
                // stack, so the room it takes and the room handed back move with
                // the same spring as the surface itself.
                .animation(Motion.pick(.mizarSmooth), value: model.pendingPrompt(for: sessionId)?.id)
                .overlayPreferenceValue(ComposerShellBoundsKey.self) { shellBounds in
                    GeometryReader { stack in
                        Color.clear
                            .onGeometryChange(for: CGFloat?.self) { _ in
                                guard !composerExpanded, !composerAnimating,
                                      let shell = shellBounds.shell,
                                      let chrome = shellBounds.chrome,
                                      let fieldHeight = shellBounds.fieldHeight,
                                      let insets = shellBounds.insets else { return nil }
                                let shellHeight = stack[shell].height
                                let target = fieldHeight + stack[chrome].height + insets
                                guard target.isFinite, target > 0, shellHeight.isFinite,
                                      abs(shellHeight - target) <= 0.5 else { return nil }
                                let extra = stack.size.height - shellHeight
                                return extra.isFinite && extra >= 0 ? extra : nil
                            } action: { extra in
                                guard !composerExpanded, !composerAnimating, let extra else { return }
                                collapsedComposerExtra = extra
                                if let height = collapsedComposerHeight {
                                    composerReservedHeight = height + extra
                                }
                            }
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    if !composerExpanded && !composerAnimating && collapsedComposerHeight == nil {
                        composerReservedHeight = height
                    }
                    composerHeight = height
                }
                .onGeometryChange(for: CGRect.self) { geometry in
                    geometry.frame(in: .named(Self.space))
                } action: { frame in
                    onComposerFrameChanged?(frame)
                }
            }
        }
    }

    /// Back to the newest message.
    ///
    /// Two ways, the same choice a turn jump makes. Close enough to see, an
    /// animated scroll says where the bottom is. A long way back -- the
    /// threshold mirrors the turn index's `animatedReach`: past a couple of
    /// screens the rows along the way do not exist, and animating across them
    /// is work spent on frames nobody asked to see -- is *travelled*, the same
    /// dip and arrive a long turn jump uses.
    ///
    /// - Parameter proxy: the conversation's scroll view.
    private func returnToLatest(proxy: ScrollViewProxy) {
        guard distanceFromBottom > max(600, scrollViewportHeight * 2) else {
            withAnimation(Motion.pick(.mizarSmooth)) {
                proxy.scrollTo(Self.endAnchor, anchor: .bottom)
            } completion: {
                // The spring aimed at where the end was when it started; the
                // rows it brought into view may have moved the end since.
                holdAtBottom(proxy: proxy)
            }
            return
        }
        Task { await travelToBottom(proxy: proxy) }
    }

    /// The long way back to the newest message: the page dips, the scroll
    /// jumps with no animation at all, and the page arrives from above.
    ///
    /// The same staging as ``travel(to:anchor:proxy:generation:)``, for the
    /// newest turn: the bottom anchor is always in the hierarchy, but where it
    /// is, from a long way up, is an estimate. `jumping` runs throughout: it
    /// suspends the bottom anchor and the corrections that would fight the
    /// jump for the whole of the move.
    private func travelToBottom(proxy: ScrollViewProxy) async {
        jumpGeneration &+= 1
        let generation = jumpGeneration
        if jumping {
            jumpFade = 1
            jumpShift = 0
            jumping = false
        }
        jumping = true
        // The newest message is below: the content leaves upwards, as it would
        // have moved had the operator swiped all the way there.
        withAnimation(Motion.pick(.easeIn(duration: 0.1))) {
            jumpFade = 0.08
            jumpShift = Motion.reduced ? 0 : -30
        }
        try? await Task.sleep(for: .milliseconds(140))
        guard isCurrentJump(generation) else {
            jumping = false
            return
        }
        // Not an aim at the end of the page. From a long way up, everything
        // between here and the end is estimated, the end of a long
        // conversation can be tens of thousands of points of estimate away
        // from where the rows really end, and an aim at it landed in space the
        // stack had built nothing for: the blank page that a few swipes by
        // hand used to fix. So the newest turn is staged first -- drawn alone,
        // at the top of the content, where a lazy stack always builds it --
        // and the scroll is aimed at the built row, exactly as a long turn
        // jump does (see ``travel(to:anchor:proxy:generation:)``). The rest of
        // the conversation comes back with the row still built and on screen.
        await stageNewest(proxy: proxy) { isCurrentJump(generation) }
        // Then down to the true end, below the room left for the composer, and
        // until the geometry says it is there.
        await seekBottom(proxy: proxy, attempts: 24) { isCurrentJump(generation) }
        guard isCurrentJump(generation) else {
            jumping = false
            return
        }

        jumpShift = Motion.reduced ? 0 : 18
        withAnimation(Motion.pick(.mizarSmooth)) {
            jumpFade = 1
            jumpShift = 0
        }
        try? await Task.sleep(for: .milliseconds(220))
        jumping = false
        // The rows whose heights settled while the page was arriving. Not
        // through `holdAtBottom`: that one refuses when the page is far from the
        // bottom, and far from the bottom is exactly where a bad landing leaves
        // it -- so the correction that exists for this case was the one that
        // never ran, and the page stayed in the empty space below the rows.
        bottomSeek &+= 1
        let seek = bottomSeek
        await settleLayout()
        await seekBottom(proxy: proxy, attempts: 16) {
            bottomSeek == seek && placement == .ready && !jumping && !composerAnimating && !userScrolling
        }
    }

    /// The workspace this session belongs to, for the subtitle.
    private var workspace: String? {
        model.workspaceGroups.first { $0.sessions.contains { $0.sessionId == sessionId } }?.title
    }

    // MARK: - Sending

    /// Put a message in flight: an optimistic bubble at the bottom of the
    /// conversation, and a ghost of the text lifting out of the field towards
    /// it.
    /// Write the draft down, one keystroke burst at a time.
    ///
    /// Debounced rather than per-character: the defaults database is not the
    /// place for sixty writes a second, and nothing is lost by a third of a
    /// second's delay -- the screen going away writes the last one by hand.
    private func scheduleDraftSave() {
        draftSaveTask?.cancel()
        let text = draft
        let id = sessionId
        draftSaveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            DraftStore.save(text, for: id)
        }
    }

    private func launch(_ text: String) {
        let message = OutgoingMessage(text: text)
        let fly = !farFromBottom && !Motion.reduced && ComposerGeometry.shared.field != .zero
        withMizarAnimation(.mizarSmooth) {
            outgoing.append(OutgoingMessage(id: message.id, text: text, landed: !fly))
        }
        if fly {
            flight = Flight(id: message.id, text: text, from: ComposerGeometry.shared.field)
        }
        newMessageArrived += 1
    }

    /// The stand-in has a place on screen; send the ghost to it.
    ///
    /// Not on the first frame it is given: the conversation is still settling
    /// against its bottom anchor as the stand-in arrives, so the first frame is
    /// where it was for an instant rather than where it stays. A beat later, the
    /// latest frame is the destination.
    private func land(_ id: UUID, at frame: CGRect) {
        let frames = FlightFrames.shared
        frames.frames[id] = frame
        guard let current = flight, current.id == id, current.to == nil,
              !frames.scheduled.contains(id) else { return }
        frames.scheduled.insert(id)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(70))
            frames.scheduled.remove(id)
            guard var current = flight, current.id == id,
                  let destination = frames.frames[id], destination.width > 0 else { return }
            current.to = destination
            flight = current
            withAnimation(Motion.pick(.mizarSmooth)) {
                current.progress = 1
                flight = current
            } completion: {
                if let index = outgoing.firstIndex(where: { $0.id == id }) {
                    outgoing[index].landed = true
                }
                if flight?.id == id { flight = nil }
                frames.frames[id] = nil
            }
        }
    }

    /// The host refused it: the text is back in the field, so take the promise
    /// back too.
    private func withdraw(_ text: String) {
        withMizarAnimation(.mizarSmooth) {
            outgoing.removeAll { $0.text == text }
            if flight?.text == text { flight = nil }
        }
    }

    /// The host's copy has arrived; the stand-in goes.
    private func settle(_ text: String) {
        outgoing.removeAll { $0.text == text }
        if flight?.text == text { flight = nil }
        DraftStore.clear(sessionId)
    }

    // MARK: - The held prompt

    /// Hand the held prompt over now, as guidance into the running turn.
    ///
    /// The model takes the prompt out of the pending map before the request goes
    /// out, so the bar has already left by the time this returns. The accepted
    /// delivery is what draws the sent message -- see the observation in the
    /// body -- which is also the path the automatic hand-over takes at the end
    /// of the turn.
    private func sendHeldPrompt() async {
        await model.sendPendingPrompt(for: sessionId, as: .steer)
    }

    /// Put the held prompt back in the field and let the bar go.
    ///
    /// Appended, not substituted: the operator may have started the next thought
    /// while this one waited, and replacing it would be a silent loss. The
    /// keyboard comes back with the text, because that is where the caret is
    /// going.
    private func returnHeldPrompt() {
        guard let held = model.takePendingPrompt(for: sessionId) else { return }
        withMizarAnimation(.mizarSmooth) {
            draft = draft.isEmpty ? held.text : draft + "\n" + held.text
            composerFocused = true
        }
    }

    /// Throw the held prompt away.
    ///
    /// No confirmation: it never left the phone, and the words are one undo away
    /// only in the field -- which is exactly why the bar has a return key next
    /// to this one.
    private func deleteHeldPrompt() {
        withMizarAnimation(.mizarSmooth) {
            model.discardPendingPrompt(for: sessionId)
        }
    }

    /// Put the conversation's turns on screen, and tell the model whether one is
    /// running.
    ///
    /// The model cannot see this screen's `@State`, but the running poll's start
    /// condition needs this evidence as much as the session list does: after a
    /// send, and on a launch with a stored list, the page can be the newer
    /// answer. Every assignment of `turns` goes through here, so no read path
    /// can put a running turn on screen without saying so.
    ///
    /// The turns are settled here before they are drawn, and that is the last
    /// line of a policy the model and the views share: the agent ends a turn
    /// before starting the next, so a turn with a later turn after it cannot be
    /// running. A page the phone skipped can leave the cache holding exactly
    /// that shape, and a cache written before the model learned to repair it is
    /// only ever this screen's to fix -- so the rule is applied at draw time as
    /// well as at write time. It is the same pure function, so the two cannot
    /// disagree.
    ///
    /// - Parameter incoming: the turns the screen is about to draw.
    private func show(turns incoming: [ConversationTurn]) {
        let turns = settlingStaleRuns(in: incoming)
        self.turns = turns
        conversationSessionId = sessionId
        model.noteConversationTurns(turns, for: sessionId)
        turnIndex.publish(sessionId: sessionId, title: shownStats?.title, turns: turns)
    }

    /// Whether the turn index is out, for the title's chevron.
    private var indexIsOut: Bool {
        sizeClass == .regular ? shell.indexPinnedVisible : shell.trailingOpen
    }

    // MARK: - The initial placement

    /// Start the initial placement, if this page has not been placed yet.
    ///
    /// Called the moment a conversation is committed to the page -- the cached
    /// copy first, the host's answer when it lands. The first of the two is
    /// what the operator's first frame is drawn from, and the placement is
    /// what makes that frame the bottom of the conversation rather than the
    /// top of it.
    ///
    /// A page whose first read failed is re-armed rather than left settled: a
    /// late answer deserves the same first frame the first one would have had.
    private func beginInitialPlacementIfNeeded() {
        let nextRound = placementRound + 1
        if placement.beginIfNeeded(generation: nextRound) {
            placementRound = nextRound
        }
    }

    /// Settle a page nothing was ever committed to.
    ///
    /// An empty session and a first read that failed are both answers: the
    /// content *is* the empty state or the failure card, and gating it would
    /// hold a spinner over a screen that has already replied. Called from
    /// `load()` when the read answered with nothing, and from `reload()` once
    /// it has run out of attempts; a retry that lands content re-arms the
    /// placement instead of settling.
    private func settleUnplacedWithoutContent() {
        guard placement == .waitingForContent else { return }
        placement = model.conversationError == nil ? .empty : .failed
    }

    /// Put the conversation at its newest message before it is shown, and
    /// reveal it once the geometry says it is there.
    ///
    /// The task's identity carries the round, so a conversation committed
    /// while an earlier placement was still running takes over cleanly, and a
    /// page going away cancels the correction rather than leaving it to
    /// scroll a view that is gone. Re-aims have a finite budget, but acceptance
    /// stays live in the geometry callback after that budget expires. Slower
    /// layout must not permanently hide a successfully positioned conversation.
    ///
    /// - Parameter proxy: the conversation's scroll view.
    /// Follow the host's state channel for this session.
    ///
    /// The channel is a push, but the connection is an actor: this view cannot
    /// subscribe to it without another layer, so it samples once a second. A
    /// state that changes is redrawn within a heartbeat, which is the pace the
    /// channel itself uses.
    private func watchLiveState() async {
        while !Task.isCancelled {
            if let snapshot = await model.liveState(for: sessionId) {
                liveState = snapshot.state
                liveStateStale = snapshot.stale
                liveStateText = snapshot.text
                if let state = snapshot.state {
                    // A terminal state closes the segment; the next thing the
                    // host says starts a new one.
                    if !state.isBusy && !state.carriesText {
                        if state == .completed || state == .failed || state == .paused {
                            liveDone = []
                            liveRunning = nil
                            liveStateText = ""
                            liveState = nil
                        }
                    } else if let category = ProcessCategory.from(state: state) {
                        // Present tense while it runs; past tense once a later
                        // state replaces it. The line is the answer to "what is
                        // it doing", so it only ever says one thing at a time.
                        if let previous = liveRunning { liveDone.insert(previous) }
                        liveRunning = category
                    }
                }
            } else {
                liveState = nil
                liveStateStale = false
                liveStateText = ""
                liveDone = []
                liveRunning = nil
            }
            // A stream is worth watching closely; a resting state is not.
            let interval: Duration = liveState?.carriesText == true ? .milliseconds(250) : .seconds(1)
            try? await Task.sleep(for: interval)
        }
    }

    private func placeInitially(proxy: ScrollViewProxy) async {
        // Only a committed conversation has a bottom to place against. The
        // empty and failed terminals reveal at commit; there is nothing here
        // for them to do.
        guard !Task.isCancelled, case .placing(let generation) = placement, !shownItems.isEmpty else { return }
        // One turn of the runloop is not enough: a row exists after the
        // runloop has taken the update, and a scroll asked for before that has
        // nothing to place against.
        await settleLayout()
        guard !Task.isCancelled, placement == .placing(generation: generation) else { return }

        // The anchors have the first frame's intent; these aims are the
        // fine-tune for rows that settle their heights after it, and they must
        // not inherit an animation from whatever transaction is running -- the
        // sidebar closing is the one that used to carry the initial position.
        // Hidden content cannot be dragged away by a reader, so the whole
        // budget is the seek's.
        //
        // The first frame's anchor can land, like the long way back, on an
        // end the stack has built nothing for. Then the newest turn is staged
        // first, as it is there.
        if !newestIsBuilt {
            await stageNewest(proxy: proxy) { placement == .placing(generation: generation) }
        }
        if await seekBottom(proxy: proxy, attempts: Self.placementAttempts, while: {
            placement == .placing(generation: generation)
        }) {
            finishInitialPlacement()
            return
        }
        // Do not reveal an unverified position. Keep a stable, actionable
        // placeholder; retrying positioning does not launch another network read.
        guard !Task.isCancelled, placement == .placing(generation: generation) else { return }
        placement = .positioningFailed
    }

    /// Reveal the placed conversation, once.
    private func finishInitialPlacement() {
        guard !Task.isCancelled, !shownItems.isEmpty, newestIsBuilt,
              placement.finishIfPositioned(placementGeometry, tolerance: Self.placementTolerance) else { return }
        // The one-shot claim the composer's corrections read: the placement
        // *is* the appearance's jump to the newest message.
        didReachBottom = true
    }

    /// Scroll to the end now, without the one-shot guard.
    ///
    /// Used by the correction that finds the page parked past the end of the
    /// content: there the question is not "has this happened before" but "get
    /// back onto the conversation".
    private func reachBottomNow(_ proxy: ScrollViewProxy) {
        Task { @MainActor in
            // One turn of the runloop, so the lazy stack has laid the rows out
            // and there is something to scroll to.
            await Task.yield()
            guard !Task.isCancelled, placement == .ready, !jumping, !composerAnimating, !userScrolling else { return }
            proxy.scrollTo(Self.endAnchor, anchor: .bottom)
        }
    }

    /// Put the page at its newest message, and keep aiming until it is there.
    ///
    /// One aim is not an arrival. A lazy stack places what it has not built at
    /// estimated heights, so an aim at the end of the page lands where the
    /// estimate puts the end; the rows down there are then built at their real
    /// heights, the end moves, and the page is left above it -- or below it,
    /// in space nothing was drawn into. So the aim is repeated until the
    /// geometry says the page is at the bottom with the newest turn built.
    ///
    /// That converges from close by, where the estimates are few. From a long
    /// way up it does not: each aim corrects only the rows it lands on, and
    /// the end of a long conversation can be tens of thousands of points of
    /// estimate away from where the rows really end. The long way back stages
    /// the newest turn first for that reason -- see ``travelToBottom(proxy:)``.
    ///
    /// Always at the end anchor, which is outside the lazy stack. An aim at the
    /// newest turn itself, from a page that has not built it, made the stack
    /// lay out every turn on the way there: seconds of a frozen screen on a
    /// long conversation.
    ///
    /// No animation: this is a correction, and the moves are small once the
    /// first has landed.
    ///
    /// - Parameters:
    ///   - proxy: the conversation's scroll view.
    ///   - attempts: how many aims it may spend.
    ///   - wanted: whether the seek is still wanted, asked after every aim.
    /// - Returns: whether the page arrived.
    @discardableResult
    private func seekBottom(proxy: ScrollViewProxy, attempts: Int, while wanted: () -> Bool) async -> Bool {
        var transaction = Transaction()
        transaction.animation = nil
        transaction.disablesAnimations = true
        for _ in 0..<attempts {
            withTransaction(transaction) {
                proxy.scrollTo(Self.endAnchor, anchor: .bottom)
            }
            // A sleep that came back nil is a cancellation.
            guard (try? await Task.sleep(for: .milliseconds(Self.placementAttemptSpacing))) != nil,
                  !Task.isCancelled, wanted() else { return false }
            if newestIsBuilt,
               placementGeometry?.isAtBottom(tolerance: Self.placementTolerance) == true {
                return true
            }
        }
        return false
    }

    /// Bring the newest turn into the stack and the page to it, from wherever
    /// the page is: the newest turn drawn alone first, at the top of the
    /// content, where a lazy stack always builds it; the scroll aimed at it;
    /// then the rest of the conversation put back, with the row still built
    /// and on screen, and the scroll aimed at it again.
    ///
    /// Nothing to do when the turn is already built, or for a flat list.
    ///
    /// - Parameters:
    ///   - proxy: the conversation's scroll view.
    ///   - wanted: whether the move is still wanted.
    private func stageNewest(proxy: ScrollViewProxy, while wanted: () -> Bool) async {
        guard !newestIsBuilt, let newest = shownTurns.last?.id else { return }
        var transaction = Transaction()
        transaction.animation = nil
        transaction.disablesAnimations = true
        withTransaction(transaction) { stagedTurn = newest }
        await settleLayout()
        guard wanted() else {
            stagedTurn = nil
            return
        }
        withTransaction(transaction) { proxy.scrollTo(newest, anchor: .bottom) }
        await settleLayout()
        withTransaction(transaction) {
            stagedTurn = nil
            proxy.scrollTo(newest, anchor: .bottom)
        }
        await settleLayout()
    }

    /// Keep a reader who is at the newest message there, as what is under it
    /// changes: the host's answer replacing the cached page, a new turn, an
    /// answer arriving in the last one.
    ///
    /// The size-change anchor is the first line of this and usually enough;
    /// this is the second, for the rows whose real heights arrive a frame
    /// after the change. Never while the operator is scrolling, and never for
    /// a reader who has scrolled away.
    private func holdAtBottom(proxy: ScrollViewProxy) {
        guard placement == .ready, !jumping, !composerAnimating, !userScrolling,
              distanceFromBottom <= Self.pinnedDistance else { return }
        bottomSeek &+= 1
        let seek = bottomSeek
        Task { @MainActor in
            await settleLayout()
            await seekBottom(proxy: proxy, attempts: 8) {
                bottomSeek == seek && placement == .ready && !jumping && !composerAnimating && !userScrolling
            }
        }
    }

    /// Go to a turn chosen in the index.
    ///
    /// Two ways there, and which one is right is decided by whether the
    /// conversation still has the turn built. A turn within reach is scrolled to
    /// with the same spring every other move on this screen uses. One that is
    /// not -- because a lazy stack throws away what is more than a screen or two
    /// away -- is *travelled* to, and that is the fix for a real report: a turn
    /// could be listed in the index, be tapped, and simply not be shown, because
    /// the row it named had been destroyed and a scroll to a row that does not
    /// exist goes nowhere.
    ///
    /// - Parameters:
    ///   - target: the turn to show.
    ///   - proxy: the conversation's scroll view.
    private func jump(to target: String, proxy: ScrollViewProxy) async {
        jumpGeneration &+= 1
        let generation = jumpGeneration
        // A jump still playing when this one was asked for leaves the page
        // dipped and half-way through a swap. Put it back first: the two must
        // not take turns holding the fade.
        if jumping {
            jumpFade = 1
            jumpShift = 0
            jumping = false
        }
        // A turn this screen does not hold -- an index from a session that has
        // just been replaced, or a turn whose page has not arrived. There is
        // nothing to show and nothing to say.
        guard turnIndex.turns.contains(where: { $0.id == target }) else { return }
        // Explicit navigation owns the scroll position from this point. Cancel
        // the initial bottom placement before its next awaited correction.
        placementRound += 1
        placement = .navigating
        // A beat for the card to start coming back on a phone, so the jump is
        // seen rather than finished behind it.
        try? await Task.sleep(for: .milliseconds(sizeClass == .regular ? 0 : 140))
        guard isCurrentJump(generation) else { return }

        let anchor = UnitPoint(x: 0.5, y: 0.08)
        guard turnIndex.travels(to: target) else {
            withMizarAnimation(.mizarSmooth) {
                proxy.scrollTo(target, anchor: anchor)
            }
            try? await Task.sleep(for: .milliseconds(320))
            guard isCurrentJump(generation) else { return }
            turnIndex.glow(target)
            return
        }
        await travel(to: target, anchor: anchor, proxy: proxy, generation: generation)
    }

    /// Undo a jump that was overtaken before it could land.
    ///
    /// Every early exit from ``travel(to:anchor:proxy:generation:)`` has to put
    /// the page back the way it found it. The dimming and the shift are what
    /// make the jump read as travel, and a jump that never lands must not leave
    /// them behind: an eight-percent-opacity conversation is a screen that
    /// answers to nothing, and the operator has no way to know a tap was
    /// overtaken.
    private func abortJump() {
        jumping = false
        withAnimation(Motion.pick(.easeOut(duration: 0.18))) {
            jumpFade = 1
            jumpShift = 0
        }
    }

    /// The long way: dip the page, put the turn back in the conversation, jump
    /// with no animation at all, and come back up with the turn under the eye.
    ///
    /// The order is the whole trick. A row that is not in the hierarchy cannot be
    /// scrolled to, so the turn asked for is drawn *alone* first -- at the top of
    /// the content, where a lazy stack always builds it, whatever the offset --
    /// and only then is the scroll asked for. The rest of the conversation comes
    /// back in the same update as the final scroll, while the row is still built
    /// and still on screen, so the anchor holds as everything above it is put
    /// back. The neighbours the operator is most likely to flip to next are the
    /// two turns drawn with it; everything beyond them is the lazy stack's own
    /// business, exactly as it is anywhere else in the conversation.
    ///
    /// - Parameters:
    ///   - target: the turn to show.
    ///   - anchor: where the turn should sit once it is there.
    ///   - proxy: the conversation's scroll view.
    ///   - generation: which jump this is, so a later tap takes over cleanly.
    private func travel(
        to target: String,
        anchor: UnitPoint,
        proxy: ScrollViewProxy,
        generation: Int,
    ) async {
        // Which way the page would have gone, so the dip carries it: a turn
        // above the operator brings the content down, as scrolling up does.
        let direction = turnIndex.direction(to: target)
        jumping = true
        // Fast enough that the page is gone before the swap below, slow enough
        // to read as leaving rather than as blinking.
        withAnimation(Motion.pick(.easeIn(duration: 0.1))) {
            jumpFade = 0.08
            jumpShift = Motion.reduced ? 0 : direction * 30
        }
        try? await Task.sleep(for: .milliseconds(140))
        guard isCurrentJump(generation) else {
            // Somebody else owns the page now. Give the dimming back before
            // leaving: this returned with `jumpFade` still at eight percent,
            // and a conversation at eight percent opacity with a shifted
            // content offset is a screen that looks frozen -- which is exactly
            // how "tapping a turn sometimes freezes the app" was reported.
            abortJump()
            return
        }

        stagedTurn = target
        await settleLayout()
        guard isCurrentJump(generation) else {
            stagedTurn = nil
            abortJump()
            return
        }
        proxy.scrollTo(target, anchor: .top)

        // The conversation back, and the scroll re-aimed in the same update:
        // the row is built and on screen at this instant, so the anchor holds
        // while the turns above it are put back.
        await settleLayout()
        stagedTurn = nil
        proxy.scrollTo(target, anchor: anchor)
        await settleLayout()
        // A second aim, for the update the first one may have raced. Harmless
        // when the first landed: it is the position the view is already at.
        proxy.scrollTo(target, anchor: anchor)

        // Arriving from the far side, so the dip reads as travel rather than as
        // a screen that blinked.
        jumpShift = Motion.reduced ? 0 : -direction * 18
        withAnimation(Motion.pick(.mizarSmooth)) {
            jumpFade = 1
            jumpShift = 0
        }
        turnIndex.glow(target)
        try? await Task.sleep(for: .milliseconds(220))
        jumping = false
        // And then make sure it really is there. Putting the conversation back
        // moves the rows above the target from estimates to real heights, and a
        // row that is a screen tall can move the anchor by more than the
        // screenful it was aimed at -- the page ends up above the turn, in the
        // space the stack had not drawn yet. A few aims at the same row, once
        // the layout has stopped moving, is what puts it under the eye.
        await correctJumpLanding(to: target, anchor: anchor, proxy: proxy, generation: generation)
    }

    /// Aim at a turn again until the page is showing it.
    ///
    /// Only for the jump that is still current, and only a handful of times: a
    /// row that will not settle is a row that is still being built, and the
    /// conversation's own bottom correction will pick it up from there.
    ///
    /// - Parameters:
    ///   - target: the turn that should be on screen.
    ///   - anchor: where it should sit.
    ///   - proxy: the conversation's scroll view.
    ///   - generation: which jump this is.
    private func correctJumpLanding(
        to target: String,
        anchor: UnitPoint,
        proxy: ScrollViewProxy,
        generation: Int,
    ) async {
        for _ in 0..<6 {
            guard isCurrentJump(generation), !userScrolling else { return }
            if turnIndex.visible.contains(target) { return }
            var transaction = Transaction()
            transaction.animation = nil
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                proxy.scrollTo(target, anchor: anchor)
            }
            await settleLayout()
        }
    }

    /// Let the lazy stack build and lay out what it was just given.
    ///
    /// A scheduler yield is not enough: a row exists after the runloop has taken
    /// the update, and a `scrollTo` asked for before that turn has nothing to
    /// place.
    private func settleLayout() async {
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(16))
    }

    /// Whether a jump is still the one the operator is waiting for.
    private func isCurrentJump(_ generation: Int) -> Bool {
        jumpGeneration == generation
    }

    /// Reload the conversation after a send, allowing for the host's lag.
    ///
    /// The host accepts a prompt and records it a moment later, so reading the
    /// log once straight after a send returns a page without the message in it.
    /// Before this, a sent message simply did not appear until the operator
    /// pulled to refresh -- the send worked, the screen did not say so. Found by
    /// a smoke assertion that counts the message in the log rather than trusting
    /// the `accepted` flag.
    ///
    /// Through the same gate as ``reload()``, and that is not tidiness. This was
    /// a second load of the same session on the same socket, started from outside
    /// the gate: send a message while the screen is reloading -- one tap on a
    /// screen that reloads on appearance, on a return to the foreground and on a
    /// pull -- and the pair interleaves exactly as ``reload()`` documents, each
    /// one's failed request reconnecting out from under the other.
    ///
    /// - Parameter sent: the text that was accepted.
    private func refreshAfterSend(_ sent: String) async {
        for _ in 0..<8 {
            // Claimed rather than merely waited for. Waiting and then reading
            // leaves a window in which the reload this waited for can start, and
            // that window is the whole bug.
            guard await takeConversationReadLock() else { return }
            // Synced rather than merely read. `conversation(for:)` returns the
            // flat list, and the screen draws *turns* whenever the host gave
            // turn numbers -- so a message that arrived only in the flat list
            // was a message that did not appear. It went unnoticed because the
            // stored conversation, from a previous visit, happened to contain an
            // equivalent prompt: pull-to-refresh fixed it, and a fresh install
            // did not need fixing.
            // Only a page with something in it replaces what is on screen: a
            // sync that failed returns an empty list, and assigning that over a
            // conversation the operator is reading is the same erasure this
            // screen just stopped doing to its figures.
            let synced = await model.syncConversation(for: sessionId)
            conversationLoads -= 1
            let cached = await model.cachedConversation(for: sessionId)
            withMizarAnimation(.mizarSmooth) {
                if !synced.items.isEmpty {
                    items = synced.items
                    conversationSessionId = sessionId
                }
                if let cached {
                    show(turns: cached.turns ?? [])
                }
            }
            // The page carries the context figure on every refresh, so the
            // bar's occupancy ring and its popover move with the turn instead
            // of waiting for the next full load. Put it up whether or not the
            // sent text has landed yet: the figure is this reply's, and the
            // send poll is the first refresh that runs after a prompt.
            if let frame = synced.stats {
                stats = frame
                statsSessionId = sessionId
            }
            let arrived = shownItems.contains { item in
                if case .message(_, .user, let text, _) = item { return text == sent }
                return false
            }
            if arrived {
                // What was just typed is at the bottom, and a sent message that
                // lands below the fold reads as a send that did not happen.
                settle(sent)
                newMessageArrived += 1
                return
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        // Not read back in time. The host has it -- it said so -- and the next
        // read will draw it; the stand-in does not get to stay as if it were
        // the record.
        withMizarAnimation(.mizarSmooth) { settle(sent) }
    }

    /// Refresh the conversation rows on a running-poll tick.
    ///
    /// The model's tick has already re-read the session list; this is the screen
    /// taking the second half of it. Only the conversation page is fetched, and
    /// that page also carries the current context figure -- so a tick costs one
    /// conversation page, never an extra stats read, and the occupancy ring and
    /// its breakdown still move with the running turn.
    ///
    /// **Skipped, not queued.** A load already in flight owns the socket, and a
    /// tick that joined a queue behind it would be a second load stacked on the
    /// one the queue was for. The next tick asks again in ten seconds; a dropped
    /// tick is a delay, and a stacked one is the interleaved pair ``reload()``
    /// describes.
    private func refreshConversationForRunningPoll() async {
        guard scenePhase == .active,
              !reloading,
              !model.isSyncing,
              model.selectedSessionId == sessionId,
              // A drawer mid-flight owns the frames; this tick is skipped
              // like any busy one, and the next asks again.
              !shell.isDragging,
              !shell.isSettling,
              claimConversationReadIfIdle()
        else { return }
        defer { conversationLoads -= 1 }
        // Through the cache, like every other read of this conversation: the
        // turns are what the screen draws, and they are written beside the page
        // by `syncConversation`.
        let synced = await model.syncConversation(for: sessionId)
        let cached = await model.cachedConversation(for: sessionId)
        // The same rule `reload()` and the poll after a send follow: only a page
        // that came back may replace one already on screen. Animated, because
        // this is the moment a running turn becomes a finished one and its
        // answer rises into place.
        withMizarAnimation(.mizarSmooth) {
            if !synced.items.isEmpty {
                items = synced.items
                conversationSessionId = sessionId
            }
            if let cached {
                show(turns: cached.turns ?? [])
            }
        }
        // The context figure above the composer, from the same page. This is the
        // tick that keeps it live while a turn runs: the token-meter projection
        // moves with every model request, and the page carries the current
        // occupancy rather than a figure frozen at the last full load.
        if let frame = synced.stats {
            stats = frame
            statsSessionId = sessionId
        }
    }

    /// Take the conversation read lock only if it is free.
    ///
    /// The poll's half of the gate. ``takeConversationReadLock()`` waits, which
    /// is right for the poll after a send -- its whole job is to see the sent
    /// message arrive -- and wrong for a tick that comes round again in ten
    /// seconds: waiting here would make the tick a queued second load, and
    /// skipping later is indistinguishable from never having tried.
    ///
    /// - Returns: whether the lock was taken. The caller must release it.
    private func claimConversationReadIfIdle() -> Bool {
        guard conversationLoads == 0 else { return false }
        conversationLoads += 1
        return true
    }

    /// Take the conversation read lock, waiting for whoever holds it.
    ///
    /// Two callers, one lock. `reload()` runs on appearance, on a return to the
    /// foreground and on a pull; this poll runs after every send. Both are loops,
    /// and a loop that checks "is anyone reading" and then starts reading is not
    /// exclusion -- two of them can check before either has started. The claim is
    /// this one method: a single `MainActor` step that decides and increments
    /// together, which is the only place either caller may start from.
    ///
    /// Bounded, because a read that never comes back must not leave a send's
    /// refresh waiting for ever. After the deadline it takes the lock anyway:
    /// its own reads then fail on their own terms, which is a worse answer than
    /// waiting but a better one than a poll that never runs again.
    ///
    /// - Returns: whether the lock was taken. `false` only when the task was
    ///   cancelled while waiting -- the screen is going away and there is nothing
    ///   left to refresh. A caller that gets `false` must not release the lock:
    ///   it never took it, and decrementing here is how a counter-style lock ends
    ///   up negative and stops excluding anybody.
    private func takeConversationReadLock() async -> Bool {
        while conversationLoads > 0 {
            // The yields come first and only once: SwiftUI starts a reload in a
            // Task, and a claim made before that Task has run would see an idle
            // screen and start the second read this exists to prevent.
            await Task.yield()
            await Task.yield()
            guard conversationLoads > 0 else { break }
            let waitedLongEnough = ContinuousClock.now.advanced(by: .seconds(20))
            // One sleep at a time, with the deadline re-measured: the lock is
            // held for the length of a network round trip, and giving up on a
            // slow computer while it is about to release would be a second reader
            // rather than a patient one.
            while conversationLoads > 0, ContinuousClock.now < waitedLongEnough {
                // Cancellation is the session going away, and there is nothing
                // left to refresh when it has.
                guard (try? await Task.sleep(for: .milliseconds(50))) != nil else { return false }
            }
        }
        conversationLoads += 1
        return true
    }

    // MARK: - The typewriter's gate

    /// How long after a turn finished its answer may still be typed.
    ///
    /// The reveal stands in for a voice that has just finished talking, so it
    /// plays only while the answer is fresh: a session viewed within a minute
    /// of the turn completing plays it; a session opened later is a record
    /// being read, and records appear as records -- instantly. Typing an answer
    /// that finished hours ago presents a turn long over as one that finished
    /// while you watched, and that is the lie this window closes.
    private static let typewriterFreshness: TimeInterval = 60

    /// The answer currently being typed, if any.
    ///
    /// Only the newest answer can be typed, and only while it is fresh: its own
    /// timestamp -- the host's record of when the turn ended -- has to be within
    /// ``typewriterFreshness`` of now. Freshness is read off the answer, not off
    /// what this phone has fetched: a page pulled in just now can be carrying
    /// an answer that finished last night, and that answer is history.
    ///
    /// The decision freezes the moment the row draws: the answer is recorded as
    /// started (``noteAnswerTypingStarted``), so a later redraw or the minute
    /// running out cannot turn a voice back into history, and a row that first
    /// appears after the minute is simply the message, whole.
    ///
    /// Reduce Motion is the one switch that turns the reveal off entirely: a
    /// reader who asked for less motion gets the answer, not a slower one.
    private var typingAnswerId: String? {
        guard !reduceMotion else { return nil }
        guard let newest = shownItems.last(where: { item in
            if case .message(_, .assistant, _, _) = item { return true }
            return false
        }), !settledAnswerIds.contains(newest.id),
            Self.previewTypesNewestAnswer
                || Date().timeIntervalSince(newest.at) <= Self.typewriterFreshness
        else { return nil }
        return newest.id
    }

    /// Record that an answer's reveal has begun.
    ///
    /// Called from the row before its first character. From here on the answer
    /// is drawn by the typewriter's own state, so a parent redraw cannot restart
    /// it, and a row rebuilt after scrolling cannot start it again.
    ///
    /// - Parameter answerId: the item id of the answer being typed.
    private func noteAnswerTypingStarted(_ answerId: String) {
        settledAnswerIds.insert(answerId)
    }

    /// Whether the Debug launch argument asked for the effect on open.
    ///
    /// The demo replays the newest answer whatever its age -- the point is to
    /// watch (and capture) the reveal without waiting for a live turn to
    /// finish -- so the gate skips the freshness check for it.
    private static var previewTypesNewestAnswer: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-mizarTypewriterDemo")
        #else
        false
        #endif
    }

    /// The permission preset in force, as the app and the host agree on it.
    ///
    /// The stats frame is what the host last *reported*, and after a switch this
    /// phone has made it is older than the app's own record of what the host
    /// accepted. `AppModel` resolves the two, so the shield in the bar and the
    /// picker behind it cannot disagree -- and a refused switch leaves the old
    /// preset in force on both.
    private var resolvedPermission: String? {
        model.permissionPreset(for: sessionId, reported: shownStats?.permissionPreset)
    }

    /// The permission preset, as a word rather than a raw value.
    ///
    /// Through the catalogue's own rows when the host has listed this preset,
    /// so the bar and the picker behind it cannot disagree -- and through the
    /// app's own names when the catalogue has not been read yet, which is the
    /// case on the first frame of a session. A preset nobody has a name for
    /// reads as its value, which is what the host called it.
    private var permissionLabel: String {
        guard let preset = resolvedPermission else { return String(localized: "Permissions") }
        if let option = model.permissionCatalog?.options.first(where: { $0.value == preset }) {
            return option.title
        }
        return PermissionOption.title(for: preset) ?? preset
    }

    /// The shield, shaped by how much the session may do.
    private var permissionSymbol: String {
        switch resolvedPermission {
        case "read-only": "lock.shield"
        case "danger-full-access": "exclamationmark.shield.fill"
        default: "checkmark.shield"
        }
    }

    /// Neutral for read-only, the accent for workspace writes, amber for full
    /// access: the one place a dangerous setting stays visible.
    private var permissionTint: Color {
        switch resolvedPermission {
        case "workspace-write": .accentColor
        case "danger-full-access": Theme.waiting
        default: .primary
        }
    }

    /// Re-read the figures the toolbar is drawn from, after the permission
    /// picker has been used.
    ///
    /// The switch itself is local by the time the call returns -- the app keeps
    /// the accepted preset and the cache holds the newer frame -- but the frame
    /// on screen is the one read before the popover opened. Reading the cache
    /// again is one local read with no request behind it, so the shield is right
    /// without the screen fetching the whole session over again.
    private func refreshStatsFromCache() async {
        guard let known = await model.cachedStats(for: sessionId) else { return }
        stats = known
        statsSessionId = sessionId
    }

    /// Refresh everything the screen shows.
    ///
    /// Not re-entrant, and that is load-bearing rather than tidy. Three things
    /// call this -- the screen appearing, the app returning to the foreground,
    /// and a pull-to-refresh -- and they overlap freely. Two overlapping loads
    /// interleave on one socket: the first one's failed request reconnects,
    /// which replaces the connection the second one is using, whose request then
    /// fails too and reconnects again.
    ///
    /// Measured from the host's side, that pair sustained itself: a fresh
    /// WebSocket every few seconds, each one re-downloading the same 244 KB
    /// page, `session.stats` printing twice for every `session.messages`, and no
    /// answer ever settling on screen. Every request the computer received was
    /// answered correctly, which is why this looked like "cannot connect" while
    /// the connection was in fact fine.
    private func reload() async {
        if reloading {
            // Remembered rather than dropped. The guard has to exist -- two
            // loads interleaving on one socket is what produced a fresh
            // WebSocket every few seconds -- but a request that arrived while
            // one was running used to be discarded, which is a screen that
            // ignores the operator asking it to refresh.
            reloadWanted = true
            return
        }
        reloading = true
        defer { reloading = false }

        var landed = await load()
        // A read that did not land, on a connection that is up, is worth asking
        // about again -- twice more, and the second attempt is the one that
        // matters most.
        //
        // The first request after a launch lands while the socket is still
        // settling; a reconnect holds `connection` at nil for anything from a
        // second to ten, and a read asked for during that window fails without
        // the host ever hearing about it. This screen used to have one retry
        // conditioned on the figures being *blank*, and the figures are no longer
        // blanked by a failure (see `load`), so the condition follows what the
        // reads actually did rather than what is drawn. A failure with the
        // connection down is a different thing and is left alone -- `reconnect`
        // is already working on it.
        for _ in 0..<2 where model.phase == .ready && !landed {
            try? await Task.sleep(for: .milliseconds(700))
            landed = await load()
        }
        while reloadWanted {
            reloadWanted = false
            await load()
        }
        // Out of attempts with nothing ever committed: the page has its
        // terminal state. A session that answered with nothing settled as
        // empty inside `load()`; this is the read that never came back, and
        // the failure card is the content -- a message area held transparent
        // for ever is the one answer that is never right.
        settleUnplacedWithoutContent()
    }

    /// One pass over everything this screen draws.
    ///
    /// Writes only what a read actually produced, and that rule is the whole
    /// point of this function. Every value here was assigned unconditionally
    /// once, so a read that failed -- or a socket that answered nothing while it
    /// was reconnecting -- took the title, the model and the context figure off
    /// the screen together, having drawn them from the cache a moment earlier.
    /// Reported exactly that way: "刚点进去一个会话，然后该会话的标题、正在使用的
    /// 模型、上下文用量显示全部消失", repaired by leaving the session and coming
    /// back. A screen that has an answer and loses it is worse than one that
    /// never had it.
    ///
    /// One pass holds ``conversationLoads`` for the whole of its conversation
    /// read, so the poll after a send cannot read the same session alongside it.
    /// Claimed through ``takeConversationReadLock()`` rather than by incrementing
    /// here, and released by the `defer` below so that an early return cannot
    /// leave it held -- a leaked lock is a screen that never loads again.
    ///
    /// - Returns: whether every read landed. The caller asks again when one did
    ///   not -- a failure is not fatal here, it just is not an answer.
    @discardableResult
    private func load() async -> Bool {
        // Claimed, not re-checked: the one place either caller may start from,
        // and it is a single step so that two callers cannot both see an idle
        // screen before either of them starts. `false` is the screen being torn
        // down, and a `defer` below is only installed once the lock is held.
        guard await takeConversationReadLock() else { return false }
        defer { conversationLoads -= 1 }
        loading = true
        loadingConversation = true
        // The phone's own copy first. It is instant, it is there when the
        // network is not, and the fetch below replaces it when it lands.
        if let cached = await model.cachedConversation(for: sessionId), !cached.items.isEmpty {
            items = cached.items
            show(turns: cached.turns ?? [])
            loadingConversation = false
            // The first frame's source, and the placement's trigger: the
            // message area is gated from here until the geometry says the
            // newest turn is in view.
            beginInitialPlacementIfNeeded()
        }
        // The last known figures, drawn before the network is asked. Without
        // this the bar was blank until a read came back, and stayed blank
        // whenever one did not -- the model name and the context percentage
        // appeared and disappeared from one visit to the next.
        if let known = await model.cachedStats(for: sessionId) {
            stats = known
            statsSessionId = sessionId
        }
        // One after the other, deliberately. The two reads are independent, and
        // they were run together once -- which is how one dropped request became
        // two overlapping loads over a single socket, each reconnecting out from
        // under the other. They share one connection, so they take it in turn.
        let freshStats = await model.stats(for: sessionId)
        // `statsError` is how a *read* is told apart from a session that has no
        // usage yet: both come back as no frame, and only the first is worth
        // asking about again.
        let statsLanded = model.statsError == nil
        if let freshStats {
            stats = freshStats
            statsSessionId = sessionId
        }
        // Synced rather than merely read: the result is folded into the cache,
        // so what is on screen and what is on disk are the same thing.
        let conversationResult = await model.syncConversation(for: sessionId)
        // The page's context figure landed after the stats read above and comes
        // from the same read that named the page's cut, so it is the fresher of
        // the two -- and it arrives even when the stats read did not.
        if let frame = conversationResult.stats {
            stats = frame
            statsSessionId = sessionId
        }
        // Only replace what is on screen when there is something to replace it
        // with. A read that failed returns the cache rather than nothing, but a
        // cache can be empty on a first visit -- and assigning that over a
        // populated screen is what "pull to refresh loses my history" was.
        let fresh = conversationResult.items
        if !fresh.isEmpty {
            items = fresh
            conversationSessionId = sessionId
            // The host's answer is also a first frame's source: with no cache
            // this is the first content the page has, and the placement runs
            // against it exactly as it does against the cached copy.
            beginInitialPlacementIfNeeded()
        }
        // The cache again, for the turns: the page was just folded into it.
        //
        // Read and written together with the tag, and that is not tidiness. A
        // page and its grouping are one answer: assigning session B's page while
        // `turns` still holds session A's -- which a failed cache read here used
        // to do -- draws A's rows under B, a conversation that never existed.
        // When the cache does not answer, keep the grouping only if it is
        // already this session's, and drop it if it belongs to another.
        if let cached = await model.cachedConversation(for: sessionId) {
            show(turns: cached.turns ?? [])
        } else if conversationSessionId != sessionId {
            turns = []
        }
        loading = false
        loadingConversation = false
        await model.refreshInteractions()
        // A read that answered with nothing is an empty session, and that is
        // an answer: the empty state is the content, and it is settled here
        // rather than after the retries -- an empty session should not wait
        // for a load that has already replied.
        //
        // A read that *failed* says nothing either way yet: `reload()` asks
        // again, and settles this page only once it has run out of attempts.
        // Showing the failure card on the first failure would flash it over
        // a session that answers a moment later.
        if model.conversationError == nil {
            settleUnplacedWithoutContent()
        }
        // The conversation counts as landed only when this session is the one
        // drawn: an empty page for a session nobody has typed into yet is an
        // answer, but an empty page on a screen showing another session's rows
        // means the read did not arrive.
        return statsLanded && conversationSessionId == sessionId
    }
}

/// Where a page's conversation is on its way to its first position.
///
/// The screen used to reveal the conversation at whatever offset a new
/// `ScrollView` starts at -- the top -- and move it to the newest message once
/// the load had finished, so a session with a cached history opened showing
/// its oldest turns and jumped a moment later, the wait growing with the
/// network. The placement is now a precondition of display: the message area
/// stays gated until the geometry says the newest turn is in view, which makes
/// the first frame an operator can read the one that is already at the bottom.
enum InitialPlacement: Equatable {
    /// The page is up and nothing has been committed to it yet.
    case waitingForContent
    /// A conversation has been committed and the placement is running. The
    /// generation is the round, so a correction belonging to an earlier
    /// commit cannot settle a later one.
    case placing(generation: Int)
    /// The newest turn is in view; the message area is live.
    case ready
    /// Explicit turn navigation has taken ownership from initial placement.
    case navigating
    /// The session has no messages: there is no bottom to place against and
    /// nothing to gate.
    case empty
    /// The first read failed with nothing cached: the failure card is the
    /// content, and holding it back would be a spinner for ever.
    case failed
    /// Loaded content whose local placement did not converge. Offer retry.
    case positioningFailed

    /// A content commit (including refresh) may retry an unplaced page, but
    /// never takes position back from a reader or explicit turn navigation.
    @discardableResult
    mutating func beginIfNeeded(generation: Int) -> Bool {
        switch self {
        case .waitingForContent, .empty, .failed, .positioningFailed:
            self = .placing(generation: generation)
            return true
        case .placing, .ready, .navigating:
            return false
        }
    }

    /// Acceptance outlives the active scroll budget; it never issues a scroll.
    @discardableResult
    mutating func finishIfPositioned(_ geometry: ConversationPlacementGeometry?, tolerance: CGFloat) -> Bool {
        switch self {
        case .placing, .positioningFailed:
            guard geometry?.isAtBottom(tolerance: tolerance) == true else { return false }
            self = .ready
            return true
        default:
            return false
        }
    }

    /// Whether the message area may be shown and touched.
    var isRevealed: Bool {
        switch self {
        case .ready, .navigating, .empty, .failed: return true
        case .waitingForContent, .placing, .positioningFailed: return false
        }
    }
}

/// The end of a conversation, as something `onChange` can watch.
private struct NewestContent: Equatable {
    var turn: String?
    var steps: Int
    var item: String?
}

/// One round of initial placement, as something a `.task(id:)` can watch.
///
/// The session is in the key as well as the round: the shell already keys the
/// page per session, and a key that names the session makes the placement task
/// one the page's own lifetime owns -- cancelled when the page leaves, rather
/// than a saved handle somebody has to remember to release.
private struct PlacementKey: Equatable {
    var sessionId: String
    var round: Int
}

/// Acceptance uses valid measured geometry, never an unmeasured default zero.
struct ConversationPlacementGeometry: Equatable {
    var contentHeight: CGFloat
    var viewportHeight: CGFloat
    var visibleMinY: CGFloat
    var visibleMaxY: CGFloat
    var topInset: CGFloat = 0
    var bottomInset: CGFloat = 0

    func isAtBottom(tolerance: CGFloat) -> Bool {
        guard contentHeight.isFinite, viewportHeight.isFinite,
              visibleMinY.isFinite, visibleMaxY.isFinite,
              topInset.isFinite, bottomInset.isFinite,
              contentHeight > 0, viewportHeight > 0, visibleMaxY > visibleMinY else { return false }
        // ScrollGeometry's raw visible rect includes content/safe-area insets.
        // Use the usable interval consistently, including for short pages;
        // containerSize and the raw visible rect are not interchangeable.
        let usableMinY = visibleMinY + topInset
        let usableMaxY = visibleMaxY - bottomInset
        let usableHeight = usableMaxY - usableMinY
        guard usableHeight.isFinite, usableHeight > 0 else { return false }
        if abs(contentHeight - usableMaxY) <= tolerance { return true }
        // A short, top-aligned conversation is already entirely visible.
        // A viewport wholly below the content must not pass this branch.
        return contentHeight <= usableHeight + tolerance
            && usableMinY <= tolerance && usableMaxY >= contentHeight - tolerance
    }
}
