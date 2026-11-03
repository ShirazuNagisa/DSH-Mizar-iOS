//
//  SubagentBoard.swift
//  DSH-Mizar
//
//  The middle page of the drawer's plane: every agent this session delegated
//  work to, one row each.
//
//  The rows are a census, not a door. A delegated child is the agent's own
//  bookkeeping -- it exists so the operator can see *who is doing the work*,
//  and for now that is all this page claims: the child's state (running,
//  finished, interrupted), how long it has taken, and what it has spent.
//  Nothing on a row opens anything.
//
//  Where the figures come from is the same trio every other screen reads, and
//  no new method is asked for:
//
//    - the session **list**, which already carries every child and its
//      `running` flag -- the app has always received these rows and simply
//      filtered them out of the sidebar;
//    - the child's **conversation page**, read once per child into the same
//      cache the parent's uses, because the log is the only authority on when
//      a turn began and how it ended -- and so the only authority on "how
//      long" and "interrupted or finished". The one thing this page needs that
//      a conversation screen does not is the child's `parentSessionId`: the
//      host does not address a delegated child as a session, so the read is
//      refused with `session/agent-busy` unless the parent comes with it (see
//      `AppModel.messages`);
//    - the child's **usage frame**, for the tokens.
//
//  The reads are one at a time, per child, and only for the open session's
//  children. The app never synced subagent pages before -- deliberately, in
//  bulk -- and this page keeps that bargain: it asks for a handful of pages
//  when an operator is looking at them, not for every child of every session
//  on a refresh nobody is watching.
//

import SwiftUI
import MizarKit

/// One delegated child, as this page can state it.
///
/// Every field stays optional for the same reason the host's own frames do: a
/// value the phone has not read is not a zero. A child whose page has not
/// arrived yet shows its name and nothing else, and fills in as the reads
/// land -- which is honest, and a beat later is also invisible.
struct SubagentSnapshot: Equatable {
    /// What the child is doing, or `nil` while nothing has been read. `nil`
    /// draws a hollow node, the same promise the conversation's own loading
    /// state makes.
    var status: SubagentStatus?
    /// Time already measured in finished turns before the one running now.
    var spent: TimeInterval?
    /// When the turn now running began. `nil` unless the child is running --
    /// the row counts from this, against a clock, without asking the host.
    var runningSince: Date?
    /// Billed tokens, input and output together. `nil` when the meter has not
    /// been read -- never a zero standing in for "unknown".
    var tokens: Int?
    /// The best name available: the host's own title, else the first line the
    /// child was asked to do, else nothing and the row falls back to its
    /// number.
    var name: String?

    /// Read a child's snapshot off the phone's own stores.
    ///
    /// - Parameters:
    ///   - row: the child's row in the session list.
    ///   - cached: the child's conversation page, when one is held.
    ///   - frame: the child's usage frame, when one has been read.
    init(row: SessionRow, cached: CachedConversation?, frame: SessionStatsFrame?) {
        // Settled first, exactly as the conversation screen and the island
        // settle theirs: a cache can hold a run a later turn has disproved,
        // and a row built on it would report a state the log has moved past.
        let turns = settlingStaleRuns(in: cached?.turns ?? [])
        let open = turns.last { $0.isRunning }

        // The list's word first -- the host is watching the child directly --
        // then the log's. The two agree in every case that matters; where the
        // page is stale (an open turn the host has since ended) the next read
        // brings the `turn/end` that settles it.
        if row.running || open != nil {
            status = .running
            runningSince = open?.beganAt
        } else if let last = turns.last(where: { $0.turn != nil }) {
            // Anything that is not `completed` counts as interrupted -- the
            // same safe direction the turn index takes: an unknown reason
            // shown as finished is a lie, shown as interrupted is cautious.
            status = last.failed ? .interrupted : .done
        } else {
            // No turns at all. A page that came back confirms the child ran
            // and produced no turn -- over, without ever being running. No
            // page is no evidence, and the row says nothing yet.
            status = cached == nil ? nil : .done
        }

        // Finished turns only, and only ends the log itself wrote: an end
        // inferred from a later turn is an upper bound, and a duration taken
        // from it would be presented as a measurement. The turn index makes
        // the same refusal.
        let finished = turns.filter { !$0.isRunning }
        spent = finished.compactMap { $0.spent(asOf: Date()) }.reduce(0, +)
        tokens = frame?.tokenUsage.map { $0.billedInputTokens + $0.outputTokens }
        name = Self.name(from: frame, turns: turns)
    }

    private static func name(from frame: SessionStatsFrame?, turns: [ConversationTurn]) -> String? {
        if let title = frame?.title, !title.isEmpty { return localizeKnownHostTitle(title) }
        for turn in turns {
            if let line = turn.promptLine { return line }
        }
        return nil
    }

    /// DSH names delegated children "Background subagent <name>" on the host.
    /// Those titles are data, not UI copy -- but this one prefix is a product
    /// label, and leaving it in English in a Chinese app is the report. Keep the
    /// child's own suffix, translate only the prefix.
    static func localizeKnownHostTitle(_ raw: String) -> String {
        let prefix = "Background subagent"
        guard raw.hasPrefix(prefix) else { return raw }
        let suffix = raw.dropFirst(prefix.count)
        return String(localized: "Background subagent") + suffix
    }
}

/// The three states a child can be in, with the colours the app already uses
/// for exactly these meanings.
enum SubagentStatus: Equatable {
    case running
    case done
    case interrupted

    var label: Text {
        switch self {
        case .running: Text("Running", tableName: SidePlaneTable.name)
        case .done: Text("Done")
        case .interrupted: Text("Interrupted", tableName: SidePlaneTable.name)
        }
    }

    var tint: Color {
        switch self {
        case .running: .accentColor
        case .done: Theme.running
        case .interrupted: Theme.waiting
        }
    }
}

enum SubagentFormat {
    /// "940", "12.4k", "3.08M" -- a figure to be scanned, not audited; the
    /// exact count is the host's to say and the usage screen's to show.
    static func tokens(_ count: Int) -> String {
        if count < 1000 { return String(count) }
        if count < 1_000_000 { return String(format: "%.1fk", Double(count) / 1000) }
        return String(format: "%.2fM", Double(count) / 1_000_000)
    }
}

/// The subagents page of the plane.
struct SubagentBoard: View {
    @Environment(AppModel.self) private var model
    @Environment(TurnIndex.self) private var index

    /// Whether the plane is showing this page. The reads wait for it. The app
    /// never synced a subagent's page in bulk -- deliberately -- and this page
    /// keeps that bargain by asking only while an operator is looking at it:
    /// mounted is not the same as read, and a session opened on the phone
    /// should not quietly fetch its children's pages before anyone has turned
    /// to this tab.
    var focused: Bool

    /// What each child has said so far, by session id.
    @State private var snapshots: [String: SubagentSnapshot] = [:]
    /// Children whose conversation page has been asked for at least once, so
    /// a child that legitimately has no turns is not re-read on every tick.
    @State private var pagesRequested: Set<String> = []
    /// Whether a read pass is on the socket, and whether another one was
    /// asked for while it ran -- the same single-flight shape the
    /// conversation screen keeps.
    @State private var loading = false
    @State private var reloadWanted = false

    /// The session's delegated children, in the host's own order.
    ///
    /// Not re-sorted: the list is what the host says, newest activity first,
    /// and a child whose activity touches is moved by the same hand that
    /// moves every other row in this app.
    private var subagents: [SessionRow] {
        model.subagents(of: index.sessionId)
    }

    /// Air between the drawer's floating control and the first row: the
    /// control's top inset, its own height, and a beat of air after it.
    private static let listContentTop: CGFloat = 58

    var body: some View {
        Group {
            if subagents.isEmpty {
                empty
            } else {
                list
            }
        }
        // Centred while there is nothing to list, top-aligned the moment there
        // is: an empty page whose one sentence hangs under the floating control
        // reads as a page that failed to load the rest of itself, and the middle
        // of the page is where a "nothing here" belongs.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: subagents.isEmpty ? .center : .top)
        .background(Theme.sidebarBackground)
        .animation(.mizarSmooth, value: subagents.map(\.sessionId))
        // A new session is a different set of children: everything this page
        // held belongs to the one that was open. The id is `nil` while the
        // page is not showing, so turning away also takes the in-flight reads
        // with it -- the same cancellation a screen leaving gets.
        .task(id: focused ? index.sessionId : nil) {
            guard focused else { return }
            snapshots = [:]
            pagesRequested = []
            await refresh()
        }
        .onChange(of: subagents.map(\.sessionId)) { _, _ in
            guard focused else { return }
            Task { await refresh() }
        }
        .onChange(of: model.runningPollTicks) { _, _ in
            guard focused else { return }
            Task { await refresh() }
        }
    }

    // MARK: The rows

    private var list: some View {
        ScrollView {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(subagents.enumerated()), id: \.element.id) { offset, row in
                        SubagentRow(
                            number: offset + 1,
                            row: row,
                            snapshot: snapshots[row.sessionId],
                            now: context.date,
                        )
                        .id(row.sessionId)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 24)
            }
        }
        .scrollIndicators(.hidden)
        .scrollEdgeEffectStyle(.soft, for: .vertical)
        // The rows begin below the drawer's floating segmented control, and
        // every row after the first travels beneath its glass on the way
        // past -- the margin is content, not a bar the scroll stops at.
        .contentMargins(.top, Self.listContentTop, for: .scrollContent)
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Image(systemName: "square.stack.3d.up")
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text("No subagents yet", tableName: SidePlaneTable.name)
                .font(.headline)
            Text("Agents this session delegates work to are listed here.", tableName: SidePlaneTable.name)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
    }

    // MARK: Reading the children

    /// Bring every child's snapshot up to date.
    ///
    /// Single-flight, with a wanted flag: a poll tick that lands while a pass
    /// is on the socket asks for another pass instead of starting one beside
    /// it -- the same shape the conversation screen keeps, for the same
    /// reason. Two passes interleaved on one socket is the failure the
    /// conversation reload once taught this app about.
    private func refresh() async {
        if loading {
            reloadWanted = true
            return
        }
        loading = true
        await load()
        while reloadWanted {
            reloadWanted = false
            await load()
        }
        loading = false
    }

    private func load() async {
        let children = subagents
        // The host has not answered a list yet, so there is nothing to read
        // and nothing to ask: every request below would be a guess at session
        // ids the phone has not been given.
        guard !children.isEmpty, model.sessionsAreKnown else { return }
        for row in children {
            if Task.isCancelled { return }
            await read(row)
        }
    }

    /// Read one child: its page, when the page can have changed, and its
    /// usage frame, when the figures can have.
    private func read(_ row: SessionRow) async {
        let held = await model.cachedConversation(for: row.sessionId)
        let heldTurns = settlingStaleRuns(in: held?.turns ?? [])
        // Three reasons a page is worth asking for: never asked for; the child
        // is running, so the page is growing; or the page still holds a turn
        // as open while the list says the child has stopped -- the one shape
        // that means the phone's copy is behind the log. Everything else is
        // cache-only, so a finished child costs a file read per tick and not
        // a round trip.
        let pageStale = heldTurns.contains { $0.isRunning }
        let neverRead = (held?.turns?.isEmpty != false) && !pagesRequested.contains(row.sessionId)
        var pageArrived = false
        if row.running || pageStale || neverRead {
            pagesRequested.insert(row.sessionId)
            let synced = await model.syncConversation(for: row.sessionId)
            pageArrived = !synced.items.isEmpty
        }
        let cached = pageArrived
            ? await model.cachedConversation(for: row.sessionId)
            : held

        // The frame the phone holds first; the host only where the figures can
        // have moved -- never read, the child still running, or a page that
        // just arrived and so may have spent more. A finished child's frame is
        // read once and then kept, like every other stored frame.
        var frame = await model.cachedStats(for: row.sessionId)
        if frame == nil || row.running || pageArrived {
            frame = await model.stats(for: row.sessionId)
        }

        let snapshot = SubagentSnapshot(row: row, cached: cached, frame: frame)
        if snapshots[row.sessionId] != snapshot {
            withMizarAnimation(.mizarSmooth) {
                snapshots[row.sessionId] = snapshot
            }
        }
    }
}

/// One delegated child, as a row.
private struct SubagentRow: View {
    let number: Int
    let row: SessionRow
    let snapshot: SubagentSnapshot?
    /// The instant the ticking figures are measured to. The list owns the
    /// clock, like the turn index does: one ticker per page, not per row.
    let now: Date

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            node
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(name)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 10)
                    tokens
                }
                meta
            }
            .padding(.vertical, 11)
        }
        .padding(.horizontal, 8)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("subagent.row.\(row.sessionId)")
    }

    private var name: String {
        if let name = snapshot?.name, !name.isEmpty { return name }
        return String(format: String(localized: "Subagent %lld", table: SidePlaneTable.name), number)
    }

    /// The same visual language as the turn index's nodes: the brand star for
    /// running, a filled dot for finished, the orange mark for something that
    /// did not finish. Nothing here is a button -- the census does not open
    /// doors yet.
    @ViewBuilder private var node: some View {
        switch snapshot?.status {
        case .running:
            MizarStar(ink: 17, motion: .running)
                .padding(.top, 12)
        case .done:
            Circle()
                .fill(Theme.running.opacity(0.85))
                .frame(width: 9, height: 9)
                .padding(.top, 14)
        case .interrupted:
            Image(systemName: "exclamationmark")
                .font(.system(size: 8, weight: .black))
                .foregroundStyle(.white)
                .frame(width: 13, height: 13)
                .background(Theme.waiting, in: Circle())
                .padding(.top, 12)
        case nil:
            Circle()
                .strokeBorder(Color.secondary.opacity(0.4), lineWidth: 1.5)
                .frame(width: 9, height: 9)
                .padding(.top, 14)
        }
    }

    /// What it cost, right-aligned on the title line where a figure belongs.
    @ViewBuilder private var tokens: some View {
        if let tokens = snapshot?.tokens {
            HStack(spacing: 3) {
                Text(SubagentFormat.tokens(tokens))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("Tokens")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.tertiary)
        }
    }

    private var meta: some View {
        HStack(spacing: 6) {
            if let status = snapshot?.status {
                status.label
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(status.tint)
            }
            if let time {
                Text(TurnIndexFormat.spell(time))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }

    /// How long the child has taken: counting while it runs, settled once it
    /// has stopped. Nothing while nothing has been read -- a dash here would
    /// be a measurement taken from no evidence.
    private var time: TimeInterval? {
        guard let snapshot else { return nil }
        if snapshot.status == .running {
            guard let since = snapshot.runningSince else { return nil }
            return snapshot.spent.map { $0 + max(0, now.timeIntervalSince(since)) }
                ?? max(0, now.timeIntervalSince(since))
        }
        return snapshot.spent.flatMap { $0 > 0 ? $0 : nil }
    }
}
