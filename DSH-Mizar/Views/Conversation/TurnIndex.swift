//
//  TurnIndex.swift
//  DSH-Mizar
//
//  The conversation's table of contents: one row per turn, the way a desktop
//  agent lists them down the side of a long session.
//
//  On a phone it is the sidebar's mirror image -- drag the conversation to the
//  left, or tap its title, and it comes out on the right while the conversation
//  steps aside as a card. On an iPad it is a column of its own, and when that
//  column is put away a slim rail of ticks stays at the conversation's edge to
//  scrub through the turns without opening anything.
//
//  Four small things it does that a plain list would not:
//
//    - **It knows where you are.** The turns on screen in the conversation are
//      bracketed on the index's timeline, and the bracket moves as you scroll,
//      so the turns being read are lit at a glance. The stream itself opens
//      at its newest turn -- the bottom -- because the turn somebody opens the
//      index to look at is the one that just ran, not the first one they ever
//      sent.
//    - **It shows where the time went.** Under each prompt a hairline bar is as
//      long as the turn took, against the longest turn in the session: the one
//      that ran for twenty minutes is visible from across the room.
//    - **It lands softly.** A tap closes it, scrolls the conversation to that
//      turn, and lets the turn glow once so the eye finds it. A turn the
//      conversation has long since thrown away is *travelled* to rather than
//      scrolled to: see ``TurnIndex/travels(to:)``.
//    - **It filters to what went wrong.** One tap narrows it to the turns that
//      did not finish -- the ones worth going back to.
//
//  The conversation publishes into ``TurnIndex``; the shell, which owns the
//  drawers, draws it. Neither holds the other.
//

import SwiftUI
import MizarKit

/// What the open conversation has, and where the operator is in it.
@MainActor
@Observable
final class TurnIndex {
    /// The session the turns belong to.
    private(set) var sessionId: String?
    private(set) var title: String?
    private(set) var turns: [ConversationTurn] = []
    /// The turns on screen in the conversation right now.
    private(set) var visible: Set<String> = []
    /// The turns the conversation has built at all, on screen or not.
    ///
    /// Not the same set as ``visible``, and the difference is the whole reason
    /// this exists: a lazy stack keeps about a screenful either side of the
    /// viewport and throws the rest away, so a row the operator scrolled past a
    /// minute ago has been destroyed. A destroyed row has no frame, and a scroll
    /// to a row with no frame goes nowhere -- which is how a turn could be listed
    /// here, be tapped, and refuse to be shown.
    private(set) var realized: Set<String> = []
    /// The turn the operator asked to go to, and a count that makes asking
    /// for the same one twice a second request.
    private(set) var jumpTarget: String?
    private(set) var jumpCount = 0
    /// The turn that should glow, having just been jumped to.
    private(set) var glowing: String?

    func publish(sessionId: String, title: String?, turns: [ConversationTurn]) {
        if self.sessionId != sessionId {
            visible = []
            realized = []
            glowing = nil
        }
        self.sessionId = sessionId
        self.title = title
        if self.turns != turns { self.turns = turns }
    }

    func withdraw(sessionId: String) {
        guard self.sessionId == sessionId else { return }
        self.sessionId = nil
        turns = []
        visible = []
        realized = []
        title = nil
    }

    /// Mark a turn visible, only for the session this index currently holds.
    ///
    /// Turn ids restart at 1 in every session, and these calls are deferred out
    /// of the layout pass now; without the session check a row from the session
    /// the operator just left could land in the new session's set and make the
    /// index believe a row was built when it was not.
    func setVisible(_ id: String, _ isVisible: Bool, for session: String? = nil) {
        if let session, session != sessionId { return }
        if isVisible {
            guard !visible.contains(id) else { return }
            visible.insert(id)
        } else {
            guard visible.contains(id) else { return }
            visible.remove(id)
        }
    }

    /// Mark a turn built, with the same session fence as ``setVisible``.
    func setRealized(_ id: String, _ isRealized: Bool, for session: String? = nil) {
        if let session, session != sessionId { return }
        if isRealized {
            guard !realized.contains(id) else { return }
            realized.insert(id)
        } else {
            guard realized.contains(id) else { return }
            realized.remove(id)
        }
    }

    /// Ask the conversation to show a turn.
    func jump(to id: String) {
        jumpTarget = id
        jumpCount &+= 1
    }

    // MARK: - How far away a turn is

    /// How many turns from the screen a jump is still worth animating.
    ///
    /// A lazy stack builds about a screenful beyond the viewport, and one turn
    /// can be a screenful itself -- so past a few turns the row may simply not
    /// be there, and a scroll to a row that is not there is the bug this
    /// measures against.
    private static let animatedReach = 4

    /// Whether going to `id` has to be travelled rather than animated.
    ///
    /// Two conditions, and they are the same fact seen from both ends. A turn
    /// the conversation has not built cannot be animated *to* -- there is no row
    /// to aim at. A turn that is built but a long way from where the operator is
    /// reading would animate *across* forty rows the stack has to create and
    /// discard on the way, which is work spent on frames nobody asked to see.
    /// Either way the answer is the same: travel.
    ///
    /// - Parameter id: the turn asked for.
    /// - Returns: `true` when the conversation should dip and jump rather than
    ///   scroll.
    func travels(to id: String) -> Bool {
        guard let target = turns.firstIndex(where: { $0.id == id }) else { return false }
        guard realized.contains(id) else { return true }
        let nearest = turns.indices
            .filter { visible.contains(turns[$0].id) }
            .map { abs($0 - target) }
            .min()
        // Nothing on screen to measure from -- a conversation still opening, or
        // a screen that has not published where it is yet. The safe reading is
        // that the turn is far away.
        guard let nearest else { return true }
        return nearest > Self.animatedReach
    }

    /// Which way the page would move to reach `id`.
    ///
    /// `1` for a turn above the operator, which brings the content *down* as
    /// scrolling up does; `-1` for one below. Used by the dip that stands in for
    /// a long scroll.
    ///
    /// - Parameter id: the turn asked for.
    /// - Returns: the vertical direction, in the sense of an offset.
    func direction(to id: String) -> CGFloat {
        guard let target = turns.firstIndex(where: { $0.id == id }),
              let reference = turns.lastIndex(where: { visible.contains($0.id) })
        else { return 1 }
        return target < reference ? 1 : -1
    }

    /// The conversation has arrived at a turn: let it glow, briefly.
    func glow(_ id: String) {
        withMizarAnimation(.mizarSmooth) { glowing = id }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1400))
            if glowing == id { withMizarAnimation(.mizarGentle) { glowing = nil } }
        }
    }
}

// MARK: - What a turn says about itself

extension ConversationTurn {
    /// The operator's words that opened the turn, on one line.
    var promptLine: String? {
        for item in prompts {
            if case .message(_, .user, let text, _) = item {
                let line = text
                    .split(whereSeparator: \.isNewline)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .first { !$0.isEmpty }
                if let line { return line }
            }
        }
        return nil
    }

    /// How long the turn took, or has taken so far.
    ///
    /// Nothing for a turn settled from a missing record: the end it was given is
    /// the next turn's start -- an upper bound, not a reading -- and a number
    /// here would be taken for a measurement on the index's bar and total.
    func spent(asOf now: Date) -> TimeInterval? {
        if isEndInferred { return nil }
        return isRunning ? elapsed(asOf: now) : duration
    }

    /// What kind of row this is, for its colour and its glyph.
    var state: TurnState {
        if isRunning { return .running }
        if isEndInferred { return .ended }
        return failed ? .unfinished : .done
    }
}

enum TurnState {
    case running, done, ended, unfinished

    var tint: Color {
        switch self {
        case .running: .accentColor
        case .done: Theme.running
        case .ended: Color.secondary
        case .unfinished: Theme.waiting
        }
    }
}

// MARK: - The page

/// The turn index, as the plane's first page: drawn in the drawer on a phone
/// and in the column on an iPad.
///
/// The page itself carries no title and no total -- "Turns" and its count
/// moved up into the plane's segmented control, and neither the session's name
/// nor its spent time said anything the conversation's own bar does not. What
/// stays is the page's own floating chrome: the filter on the left and the
/// running turn on the right, glass at the same layer as the control above
/// them, with the timeline travelling beneath both.
struct TurnIndexPanel: View {
    /// Called once a turn has been chosen, so the phone's drawer can close.
    var onPick: () -> Void = {}

    @Environment(TurnIndex.self) private var index
    @Environment(ShellState.self) private var shell
    @State private var onlyUnfinished = false
    /// The session whose timeline has already been put at its newest turn.
    ///
    /// One landing per look. The rows arrive asynchronously -- a session opened
    /// from a cold launch publishes its turns after this page is on screen --
    /// and the operator's own scrolling afterwards belongs to them.
    @State private var landedSession: String?
    /// The row the stream is anchored to, in the sense `.scrollPosition(id:)`
    /// means: setting it moves the stream, and scrolling moves it back.
    @State private var landedTurn: String?
    /// The instant the ticking figures are measured to. The page owns the
    /// clock, like the conversation screen does, so the rows are not a
    /// `TimelineView` and the stack stays the scroll view's own content.
    @State private var now = Date()
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// How tall the list is, and how tall the window showing it is.
    ///
    /// A landing is only wanted when the first is the larger of the two: a list
    /// that fits has no bottom to go to, and asking for one anyway strands it
    /// in the middle of the drawer. Both are measured where they are drawn.
    @State private var contentHeight: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0
    @Namespace private var filter

    /// How far the timeline's content begins below the page's top, so the
    /// first row rests under the floating chrome with air to spare, and every
    /// row after it is free to travel beneath the glass on the way past.
    private static let chromeContentTop: CGFloat = 100

    /// Whether this page is actually in front of the operator.
    ///
    /// The plane keeps all three pages mounted so a page switch is a
    /// translation rather than a rebuild. That is right for the transition,
    /// but the turn index's one-second clock does not need to run while the
    /// drawer is closed.
    private var isOnScreen: Bool {
        shell.trailingOpen || (sizeClass == .regular && shell.indexPinnedVisible)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Group {
                if index.turns.isEmpty {
                    empty
                } else {
                    timeline
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            chrome
        }
        .background(Theme.sidebarBackground)
        .accessibilityIdentifier("turnIndex.panel")
    }

    // MARK: The floating chrome

    /// The filter, on the left, and the running turn, on the right -- one row
    /// of glass at the same layer as the drawer's segmented control above it.
    /// The timeline scrolls beneath both; that is what the layer is for.
    private var chrome: some View {
        HStack(spacing: 10) {
            filterBar
            Spacer(minLength: 8)
            if let running = index.turns.last(where: \.isRunning) {
                runningChip(running)
                    .transition(.rise)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, SessionSidePlane.FloatingTab.pageChromeTop)
        .animation(.mizarSmooth, value: index.turns.contains(where: \.isRunning))
    }

    /// The running turn, as a capsule of glass ground in the accent: the same
    /// treatment the segmented control gives its chosen segment, and its ink
    /// is the theme's on-accent colour for the same reason -- accent ink on an
    /// accent ground is a chip with no words on it.
    private func runningChip(_ turn: ConversationTurn) -> some View {
        Button {
            pick(turn)
        } label: {
            HStack(spacing: 5) {
                // White ink, because the capsule behind it is the accent.
                MizarStar(ink: 14, motion: .running, palette: .ink(Theme.onAccent))
                Text("Running now")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .liquidSurface(in: Capsule(), tint: Color.accentColor, interactive: true)
        .accessibilityIdentifier("turnIndex.running")
    }

    private var unfinishedCount: Int { index.turns.count { $0.state == .unfinished } }

    /// Two choices on glass, with a highlight that slides between them.
    private var filterBar: some View {
        HStack(spacing: 2) {
            filterButton(String(localized: "All"), selected: !onlyUnfinished) { onlyUnfinished = false }
            filterButton(String(format: String(localized: "Unfinished %lld"), unfinishedCount), selected: onlyUnfinished) {
                onlyUnfinished = true
            }
        }
        .padding(3)
        .liquidCapsule()
    }

    private func filterButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            withMizarAnimation(.mizarSnappy, action)
        } label: {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(selected ? .primary : .secondary)
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background {
                    if selected {
                        Capsule()
                            .fill(Theme.selectionFill)
                            .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
                            .matchedGeometryEffect(id: "filter", in: filter)
                    }
                }
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .mizarFeedback(.selection, trigger: selected)
    }

    // MARK: Timeline

    private var shown: [ConversationTurn] {
        onlyUnfinished ? index.turns.filter { $0.state == .unfinished } : index.turns
    }

    private var timeline: some View {
        ScrollView {
            // No `TimelineView` around the stack: the rows' ticking figures come
            // from one clock this page owns, because the stack has to be the
            // scroll view's own content for `scrollTargetLayout` to make its
            // rows targets. Wrapped, they were not targets, and every landing
            // below was silently dropped.
            let turns = shown
            let longest = max(1, turns.compactMap { $0.spent(asOf: now) }.max() ?? 1)
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(turns.enumerated()), id: \.element.id) { offset, turn in
                    TurnIndexRow(
                        turn: turn,
                        number: number(of: turn),
                        spent: turn.spent(asOf: now),
                        longest: longest,
                        onScreen: index.visible.contains(turn.id),
                        previousOnScreen: offset > 0 && index.visible.contains(turns[offset - 1].id),
                        nextOnScreen: offset < turns.count - 1 && index.visible.contains(turns[offset + 1].id),
                        isFirst: offset == 0,
                        isLast: offset == turns.count - 1,
                        appearDelay: Double(min(offset, 14)) * 0.025,
                    ) {
                        pick(turn)
                    }
                    .id(turn.id)
                }
            }
            // The rows are the scroll's targets, which is what lets
            // ``landedTurn`` move the stream to a row the lazy stack has not
            // built yet: `ScrollViewReader.scrollTo` asks for a frame, and a row
            // outside the realized window has none -- it answered by doing
            // nothing at all, which is how this list kept opening at its first
            // turn.
            .scrollTargetLayout()
            .padding(.horizontal, 12)
            .padding(.bottom, 24)
            // How tall the list is, against how tall the window is: a landing
            // is only wanted when the list is longer than the window. See
            // ``land(again:)``.
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                contentHeight = height
            }
        }
        .scrollIndicators(.hidden)
        .scrollEdgeEffectStyle(.soft, for: .vertical)
        // The first row lands below the floating chrome with air to spare,
        // and every row after it travels beneath the glass on the way
        // past -- the margin is content, not a bar the scroll stops at.
        .contentMargins(.top, Self.chromeContentTop, for: .scrollContent)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            viewportHeight = height
        }
        // The stream opens at its newest turn and keeps the operator's place
        // after that. No auto-centring: a scroll into a lazy stack's not-yet-
        // built region lands on an estimate, and on a session's first open that
        // estimate stranded the stream mid-drawer with a void above and below
        // it. The landing below is aimed at the last row with a bottom anchor,
        // which is the one position a growing list cannot get wrong.
        //
        // Three moments ask for it, and they are the same question asked from
        // three sides: a different session (its own bottom), the rows finally
        // arriving (there was no bottom to land on before), and the drawer
        // opening (the page exists long before anybody looks at it, so the
        // landing that happened at launch is the one nobody saw).
        //
        // `initial: true` on the first two is not decoration: this page is a
        // branch of a conditional -- empty state, or this -- so on a launch the
        // scroll view is *created* at the moment the first turn arrives, and an
        // `onChange` on a freshly created view has nothing to compare against
        // and never fires. That was the whole bug: the landing was written for
        // the change and the change happened before the page existed.
        .scrollPosition(id: $landedTurn, anchor: .bottom)
        .onChange(of: index.sessionId, initial: true) { _, _ in
            landedSession = nil
            land()
        }
        .onChange(of: shown.last?.id, initial: true) { _, _ in land() }
        // The two measurements above arrive after the first attempt: a landing
        // asked for before either is known is refused (see `land`), so the
        // answer to "is there anywhere to scroll to" has to ask again when it
        // changes.
        .onChange(of: contentHeight) { _, _ in land() }
        .onChange(of: viewportHeight) { _, _ in land() }
        .onChange(of: shell.trailingOpen) { _, open in
            guard open else { return }
            land(again: true)
        }
        .task(id: isOnScreen) {
            // One ticker for the page, not one per row: the times under each
            // prompt are the only figures that move on their own. The page is
            // built even while the drawer is shut, and ticking there rebuilt
            // its whole timeline -- and the long session's rows -- once a
            // second for nobody.
            guard isOnScreen else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                now = Date()
            }
        }
    }

    private func number(of turn: ConversationTurn) -> Int {
        turn.turn ?? ((index.turns.firstIndex { $0.id == turn.id } ?? 0) + 1)
    }

    /// Put the timeline at its newest turn.
    ///
    /// The anchor is the bottom rather than a computed offset: the last row is
    /// the one position a list that is still growing cannot get wrong, and the
    /// turn the operator opened the index to find is the one that just ran.
    ///
    /// **Only when there is somewhere to go.** A session with two turns fits in
    /// the window, and asking a lazy stack to put its last row at the bottom of
    /// a list that is shorter than the window does not clamp to the top -- the
    /// scroll lands on an estimate past the end and strands the two rows in the
    /// middle of the drawer, with a void above and below them. So the landing
    /// is a question about heights, and both of them are measured above.
    ///
    /// - Parameter again: whether to land even if this session has already been
    ///   landed once. The drawer opening is that case: the operator is looking
    ///   at the page now, and the landing that happened while it was off screen
    ///   is the one nobody saw. The binding is cleared first and set again on
    ///   the next turn of the runloop, because a write of the value it already
    ///   holds is not a scroll.
    private func land(again: Bool = false) {
        guard let session = index.sessionId, let last = shown.last?.id else { return }
        // Nothing is known until both are measured, and a list that fits has no
        // bottom to land on: its top *is* all of it.
        guard viewportHeight > 0, contentHeight > viewportHeight else { return }
        if again {
            landedSession = session
            landedTurn = nil
            Task { @MainActor in landedTurn = last }
            return
        }
        guard landedSession != session else { return }
        landedSession = session
        landedTurn = last
    }

    private func pick(_ turn: ConversationTurn) {
        index.jump(to: turn.id)
        onPick()
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "list.bullet.indent")
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text("No turns yet")
                .font(.headline)
            Text("Each prompt you send starts one, and it is listed here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.top, Self.chromeContentTop)
    }
}

/// One turn on the timeline.
private struct TurnIndexRow: View {
    let turn: ConversationTurn
    let number: Int
    let spent: TimeInterval?
    let longest: TimeInterval
    /// Whether the conversation is showing this turn now, and its neighbours:
    /// together they draw the bracket of "where you are".
    let onScreen: Bool
    let previousOnScreen: Bool
    let nextOnScreen: Bool
    let isFirst: Bool
    let isLast: Bool
    let appearDelay: Double
    let action: () -> Void

    @State private var grown = false
    @Environment(ShellState.self) private var shell

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                rail
                VStack(alignment: .leading, spacing: 5) {
                    Text(turn.promptLine ?? String(format: String(localized: "Turn %lld"), number))
                        .font(.subheadline.weight(onScreen ? .semibold : .regular))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    meta
                    bar
                }
                .padding(.vertical, 11)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.sm + 2, style: .continuous)
                    .fill(onScreen ? Theme.selectionFill.opacity(0.7) : .clear)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.pressable(scale: 0.98))
        .animation(.mizarSmooth, value: onScreen)
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text("Shows this turn in the conversation"))
        .accessibilityIdentifier("turnIndex.entry.\(turn.id)")
        // A row built while a drawer is moving waits for it to settle
        // before its bar grows. The stagger animates the bar's *width*,
        // which lays out every growing row on every frame -- and those
        // frames belong to the drawer dragging the conversation card.
        // Once the drawers are still, the stagger plays on its own.
        .onAppear { grow() }
        .onChange(of: shell.isDragging) { _, _ in grow() }
        .onChange(of: shell.isSettling) { _, _ in grow() }
    }

    /// Grow the bar, staggered, once the drawers are still.
    private func grow() {
        guard !grown, !shell.isDragging, !shell.isSettling else { return }
        withAnimation(Motion.pick(.mizarGentle).delay(appearDelay)) { grown = true }
    }

    /// The timeline: a line through every row, a node per turn, and the line
    /// lit where the conversation is.
    private var rail: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                Rectangle()
                    .fill(segment(lit: onScreen && previousOnScreen))
                    .frame(width: onScreen && previousOnScreen ? 2.5 : 1.5, height: 17)
                    .opacity(isFirst ? 0 : 1)
                Rectangle()
                    .fill(segment(lit: onScreen && nextOnScreen))
                    .frame(width: onScreen && nextOnScreen ? 2.5 : 1.5)
                    .frame(maxHeight: .infinity)
                    .opacity(isLast ? 0 : 1)
            }
            node
                .padding(.top, 11)
        }
        .frame(width: 18)
    }

    private func segment(lit: Bool) -> Color {
        lit ? Color.accentColor : Color.secondary.opacity(0.22)
    }

    @ViewBuilder private var node: some View {
        switch turn.state {
        case .running:
            MizarStar(ink: 17, motion: .running)
        case .done:
            Circle()
                .fill(onScreen ? Color.accentColor : Theme.running.opacity(0.85))
                .frame(width: 9, height: 9)
                .overlay {
                    Circle().strokeBorder(Theme.sidebarBackground, lineWidth: 2).padding(-2)
                }
                .scaleEffect(onScreen ? 1.25 : 1)
        case .ended:
            // Over, but the log never said how: a hollow node rather than the
            // filled "done" dot or the orange "unfinished" mark. See
            // ``ConversationTurn/isEndInferred``.
            Circle()
                .strokeBorder(Color.secondary.opacity(0.8), lineWidth: 1.5)
                .frame(width: 9, height: 9)
                .overlay {
                    Circle().strokeBorder(Theme.sidebarBackground, lineWidth: 2).padding(-2)
                }
                .scaleEffect(onScreen ? 1.25 : 1)
        case .unfinished:
            Image(systemName: "exclamationmark")
                .font(.system(size: 8, weight: .black))
                .foregroundStyle(.white)
                .frame(width: 13, height: 13)
                .background(Theme.waiting, in: Circle())
        }
    }

    private var meta: some View {
        HStack(spacing: 6) {
            Text(verbatim: "#\(number)")
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(turn.state.tint)
            if let spent {
                Text(TurnIndexFormat.spell(spent))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            if let steps = turn.stepCount, steps > 0 {
                Text("\(steps) steps")
            }
            if let began = turn.beganAt {
                Text(began, format: .dateTime.hour().minute())
            }
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }

    /// As long as the turn took, against the longest turn in the session.
    private var bar: some View {
        GeometryReader { geometry in
            let share = min(1, max(0.02, (spent ?? 0) / longest))
            Capsule()
                .fill(turn.state.tint.opacity(turn.state == .running ? 0.7 : 0.45).gradient)
                .frame(width: grown ? geometry.size.width * share : 0, height: 3)
        }
        .frame(height: 3)
        .accessibilityHidden(true)
    }
}

enum TurnIndexFormat {
    /// "48 s", "3 min 12 s", "1 h 4 min".
    static func spell(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total < 60 { return String(format: String(localized: "%lld s"), total) }
        if total < 3600 { return String(format: String(localized: "%lld min %lld s"), total / 60, total % 60) }
        return String(format: String(localized: "%lld h %lld min"), total / 3600, (total % 3600) / 60)
    }
}

// MARK: - The iPad rail

/// The index, folded down to a rail of ticks at the conversation's edge.
///
/// For an iPad with the index column put away: one tick per turn, coloured by
/// how it went, with the turns on screen lit. Run a finger -- or the pointer --
/// down it and a callout names the turn under it, with a tick of haptics as it
/// passes each one; let go, or click, and the conversation goes there.
struct TurnRail: View {
    @Environment(TurnIndex.self) private var index
    @State private var hovered: Int?
    @State private var scrubbing = false

    private static let tickHeight: CGFloat = 4
    private static let spacing: CGFloat = 5

    var body: some View {
        let turns = index.turns
        if turns.count > 1 {
            GeometryReader { geometry in
                let height = min(geometry.size.height, CGFloat(turns.count) * (Self.tickHeight + Self.spacing) + 20)
                ZStack(alignment: .trailing) {
                    if let hovered, turns.indices.contains(hovered) {
                        callout(for: turns[hovered], number: turns[hovered].turn ?? hovered + 1)
                            .offset(x: -30, y: tickY(hovered, count: turns.count, height: height) - height / 2)
                            .transition(.pop)
                    }
                    ticks(turns, height: height)
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .trailing)
            }
            .frame(width: 280)
            .animation(.mizarSnappy, value: hovered)
        }
    }

    private func ticks(_ turns: [ConversationTurn], height: CGFloat) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(turns.enumerated()), id: \.element.id) { offset, turn in
                let on = index.visible.contains(turn.id)
                Capsule()
                    .fill(on ? Color.accentColor : turn.state.tint.opacity(turn.state == .done ? 0.35 : 0.8))
                    .frame(width: hovered == offset ? 18 : (on ? 13 : 8), height: Self.tickHeight)
                    .frame(maxHeight: .infinity, alignment: .center)
                    .frame(width: 22, alignment: .trailing)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 6)
        .frame(height: height)
        .glassEffect(.regular.interactive(), in: Capsule())
        .contentShape(.capsule)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    scrubbing = true
                    hovered = tickIndex(at: value.location.y, count: turns.count, height: height)
                }
                .onEnded { value in
                    let picked = tickIndex(at: value.location.y, count: turns.count, height: height)
                    if turns.indices.contains(picked) { index.jump(to: turns[picked].id) }
                    scrubbing = false
                    hovered = nil
                },
        )
        .onContinuousHover { phase in
            guard !scrubbing else { return }
            switch phase {
            case .active(let location):
                hovered = tickIndex(at: location.y, count: turns.count, height: height)
            case .ended:
                hovered = nil
            }
        }
        .mizarFeedback(.selection, trigger: hovered) { _, new in new != nil && scrubbing }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Turns"))
        .accessibilityValue(Text("\(turns.count)"))
        .accessibilityIdentifier("turnIndex.rail")
    }

    private func tickIndex(at y: CGFloat, count: Int, height: CGFloat) -> Int {
        let usable = max(1, height - 20)
        let fraction = min(0.999, max(0, (y - 10) / usable))
        return Int(fraction * CGFloat(count))
    }

    private func tickY(_ offset: Int, count: Int, height: CGFloat) -> CGFloat {
        let usable = height - 20
        return 10 + usable * (CGFloat(offset) + 0.5) / CGFloat(max(1, count))
    }

    private func callout(for turn: ConversationTurn, number: Int) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: "#\(number)")
                .font(.caption.monospacedDigit().weight(.bold))
                .foregroundStyle(turn.state.tint)
            Text(turn.promptLine ?? String(format: String(localized: "Turn %lld"), number))
                .font(.subheadline)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .frame(height: 36)
        .frame(maxWidth: 240, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
        .liquidCapsule()
        .allowsHitTesting(false)
    }
}
