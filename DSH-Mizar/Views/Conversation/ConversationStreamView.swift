//
//  ConversationStreamView.swift
//  DSH-Mizar
//
//  One turn's live stream: the status lines it passed through, the bodies it
//  wrote between them, and the answer it settled on.
//
//  Three shapes, one component:
//
//  - just sent: a single line saying the model is thinking, and a clock;
//  - working: the status line and every body produced so far, with a hairline
//    and the clock under them -- the live footer;
//  - settled: the clock is replaced by the header above the hairline ("已完成，
//    用时 2 分 14 秒"), and the blocks below it are the transcript.
//
//  The divider is what tells the two halves apart: above it is what the turn
//  has produced, below it is what the turn is still doing. Nothing crosses it
//  while the turn runs, and when the turn ends the footer leaves and the header
//  takes the divider's other side.
//
//  A settled turn shows its answer and folds the rest away. The status lines
//  and the narration that came before the answer are the process: how the turn
//  got there, not what it was for. They stay one tap away -- the header is the
//  way back to them -- instead of sitting between the reader and the answer.
//
//  This view owns no state of the stream: the accumulator does, because the
//  same blocks must survive the row scrolling out of a lazy stack and coming
//  back. It only decides how a block reads.
//

import SwiftUI
import MizarKit

/// The turn's stream, drawn.
struct ConversationStreamView: View {
    let sessionId: String
    /// The blocks, oldest first.
    let stream: TurnStream
    /// The turn this stream belongs to, once the host has recorded it.
    ///
    /// `nil` for the first moments after a send: the prompt is on screen, the
    /// host has not answered with a turn yet, and the toolbar has nothing to
    /// act on.
    let turn: ConversationTurn?
    /// When the turn began, from the host's clock when it has said.
    let startedAt: Date?
    /// When it ended, from the host's clock. `nil` while it runs.
    let endedAt: Date?
    /// Whether the turn is still running, as the screen above believes.
    let running: Bool
    /// Whether bodies should type themselves in.
    let typing: Bool
    /// Called before a reveal's first character.
    let onTypingStarted: () -> Void
    /// Called when a reveal ends or its row goes away.
    let onTypingStopped: () -> Void
    /// A fixed instant for the footer's clock, for snapshots and previews.
    ///
    /// `nil` in the app: the clock is a `TimelineView` and ticks by itself.
    var now: Date? = nil
    /// The answer the history holds, when the stream did not carry one.
    ///
    /// A host without a journal (or a frame that was lost) can end a turn with
    /// status lines and no body. The history still has the answer, and hiding
    /// it would be worse than drawing it without the status lines above it.
    var fallbackAnswer: String? = nil
    /// Whether the folded-away process starts on screen.
    ///
    /// The app never asks for this -- a settled turn opens folded, and the
    /// reader opens the process by tapping the header. A snapshot asks for it,
    /// so both shapes of a settled turn can be looked at.
    var startsExpanded: Bool = false

    init(
        sessionId: String,
        stream: TurnStream,
        turn: ConversationTurn?,
        startedAt: Date?,
        endedAt: Date?,
        running: Bool,
        typing: Bool,
        onTypingStarted: @escaping () -> Void,
        onTypingStopped: @escaping () -> Void,
        now: Date? = nil,
        fallbackAnswer: String? = nil,
        startsExpanded: Bool = false,
    ) {
        self.sessionId = sessionId
        self.stream = stream
        self.turn = turn
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.running = running
        self.typing = typing
        self.onTypingStarted = onTypingStarted
        self.onTypingStopped = onTypingStopped
        self.now = now
        self.fallbackAnswer = fallbackAnswer
        self.startsExpanded = startsExpanded
        _showsProcess = State(initialValue: startsExpanded)
    }

    /// Whether the folded-away process is on screen.
    ///
    /// The reader's answer to "show me the whole turn": the header is the way
    /// in and out of it. It is not remembered between turns -- a new turn is a
    /// new piece of paper, and it opens folded.
    @State private var showsProcess = false
    /// How many blocks are folded behind "更早的过程".
    @State private var unfoldedPrefix = false
    /// The one block that has already been typed, so scrolling away and back
    /// does not type it a second time.
    @State private var typedBlockId: Int?

    /// What the settled turn shows: the answer, and the process behind it.
    private var fold: StreamFold.Plan {
        StreamFold.plan(blocks: stream.blocks, live: live, expanded: showsProcess)
    }

    private var hasContent: Bool { !stream.blocks.isEmpty }

    /// Whether the live footer still belongs on screen.
    ///
    /// The stream's own terminal state wins over the screen's: a turn the
    /// history has not caught up with yet is over the moment the host said so.
    private var live: Bool {
        !stream.finished && running
    }

    private var header: StreamHeader? {
        if stream.finished {
            return StreamHeader(state: stream.endState, endedAt: endedAt, startedAt: startedAt)
        }
        guard let turn, !turn.isRunning else { return nil }
        return StreamHeader(
            state: turn.failed ? .failed : .completed,
            endedAt: turn.endedAt,
            startedAt: turn.startedAt,
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if live {
                runningStream
                    .transition(SettleTransition())
            } else {
                settledStream
                    .transition(SettleTransition())
            }
        }
        // The turn ending is the one moment the page reorganises itself: the
        // footer leaves, the header takes the divider's other side, and the
        // process folds away. It is a cross-fade, not a jump -- and a short
        // one, because two different texts in the same place for half a
        // second read as two pages at once.
        .animation(Motion.pick(.mizarSnappy), value: live)
    }

    /// While the turn works: everything it has produced, the divider, and the
    /// clock that says it is still going.
    private var runningStream: some View {
        VStack(alignment: .leading, spacing: 0) {
            blocks
            if hasContent {
                StreamHairline()
                    .padding(.top, 12)
            }
            // The clock is a claim that somebody is watching the turn run.
            // Once the link is gone the claim is false: the turn may still be
            // running on the computer, but this phone has stopped
            // seeing it, so the line says what is actually true.
            if stream.disconnected {
                StreamNote(text: String(localized: "The connection to the computer was lost."))
                    .padding(.top, 12)
            } else {
                StreamClock(startedAt: startedAt, now: now)
                    .padding(.top, 12)
            }
        }
    }

    /// After the turn ended: the header, the divider, and the answer.
    ///
    /// The process is folded away behind the header. It comes back when the
    /// header is tapped, and goes away again when it is tapped a second time.
    private var settledStream: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let header {
                headerRow(header)
                    .padding(.bottom, 10)
            }
            if hasContent {
                StreamHairline()
                    .padding(.bottom, 12)
            }
            if fold.showsProcess, !fold.process.isEmpty {
                blockList(fold.process, foldable: true)
                    .transition(.rise(distance: 6, blur: 0))
            }
            if let summary = fold.summary {
                body(summary, latestBodyId: latestBodyId)
            }
            if !fold.after.isEmpty {
                blockList(fold.after, foldable: false)
            }
            if !hasAnswerBody, let fallbackAnswer, !fallbackAnswer.isEmpty {
                // No typed reveal: this answer arrived with the history, not
                // with the stream, and the typewriter belongs to the moment
                // it lands.
                TypewriterMessage(text: fallbackAnswer, typing: false)
                    .padding(.top, 8)
            }
            if stream.truncated {
                StreamNote(text: String(localized: "Earlier process was omitted."))
                    .padding(.top, 8)
            }
            if let note {
                StreamNote(text: note)
                    .padding(.top, 10)
            }
            if let turn, turn.endSeq != nil, let toolbarText {
                DeliveredFilesRow(turn: turn, sessionId: sessionId)
                    .padding(.top, 12)
                TurnResponseToolbar(
                    turn: turn,
                    sessionId: sessionId,
                    text: toolbarText,
                    at: endedAt ?? turn.endedAt ?? startedAt ?? .now,
                )
                .padding(.top, 4)
            }
        }
    }

    /// The header line.
    ///
    /// When there is a process folded away behind it, the line is the way back
    /// to it: a tap unfolds the process, and the mark at the end of the line
    /// says which way it goes. Without a process the line says only what the
    /// turn was, and says nothing about a tap that would do nothing.
    @ViewBuilder private func headerRow(_ header: StreamHeader) -> some View {
        if fold.canExpand {
            Button {
                withMizarAnimation(.mizarSmooth) { showsProcess.toggle() }
            } label: {
                header.label(expanded: showsProcess, expandable: true)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("conversation.stream.header")
            .accessibilityLabel(Text(header.title))
            .accessibilityHint(Text(showsProcess
                ? String(localized: "Hide the process")
                : String(localized: "Show the process")))
        } else {
            header.label(expanded: false, expandable: false)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("conversation.stream.header")
        }
    }

    /// The system line under the transcript: why it stopped, or that the link
    /// did.
    private var note: String? {
        if stream.disconnected {
            return String(localized: "The connection to the computer was lost.")
        }
        switch stream.endState {
        case .paused:
            return String(localized: "You interrupted this turn.")
        case .failed:
            return String(localized: "This turn stopped because of an error.")
        default:
            return nil
        }
    }

    /// What the copy button copies: the settled answer, or the last body the
    /// turn produced when it stopped without one.
    private var toolbarText: String? {
        if let final = stream.blocks.last(where: { $0.kind == .body && $0.isFinal }), !final.text.isEmpty {
            return final.text
        }
        if let last = stream.blocks.last(where: { $0.kind == .body }), !last.text.isEmpty {
            return last.text
        }
        return fallbackAnswer
    }

    /// Whether the stream itself produced any body at all.
    private var hasAnswerBody: Bool {
        stream.blocks.contains { $0.kind == .body && !$0.text.isEmpty }
    }

    // MARK: - Blocks

    /// The whole stream, oldest first.
    @ViewBuilder private var blocks: some View {
        blockList(stream.blocks, foldable: true)
    }

    /// One section's blocks: the fold control, then the blocks themselves.
    ///
    /// The same drawing for the running stream and for the unfolded process,
    /// so the process that comes back is the process that was there.
    @ViewBuilder private func blockList(_ blocks: [StreamBlock], foldable: Bool) -> some View {
        let lastId = stream.blocks.last?.id
        let latestBody = latestBodyId
        VStack(alignment: .leading, spacing: 10) {
            if foldable, foldedCount(in: blocks) > 0, !unfoldedPrefix {
                Button {
                    withMizarAnimation(.mizarSnappy) { unfoldedPrefix = true }
                } label: {
                    Text(String(format: String(localized: "Earlier %lld steps"), foldedCount(in: blocks)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("conversation.stream.unfold")
            }

            ForEach(visible(blocks)) { block in
                switch block.kind {
                case .status:
                    let isLive = live && block.id == lastId
                    StreamStatusLine(
                        states: block.states,
                        running: isLive,
                        waiting: isLive ? stream.waiting : nil,
                        current: isLive ? stream.current : nil,
                    )
                case .body:
                    body(block, latestBodyId: latestBody)
                }
            }
        }
    }

    /// The blocks of one section, with the oldest folded away when there are
    /// too many of them.
    private func visible(_ blocks: [StreamBlock]) -> [StreamBlock] {
        guard blocks.count > Self.foldedLimit, !unfoldedPrefix else { return blocks }
        return Array(blocks.suffix(Self.foldedLimit))
    }

    /// How many blocks the fold is hiding.
    private func foldedCount(in blocks: [StreamBlock]) -> Int {
        max(0, blocks.count - visible(blocks).count)
    }

    /// The last body, the only one that may start a reveal.
    ///
    /// A replay can deliver a whole turn at once. Starting every block's
    /// typewriter in the same frame is a storm of schedules and hidden layouts
    /// for text nobody is waiting on -- the earlier bodies are history by then.
    private var latestBodyId: Int? {
        stream.blocks.last(where: { $0.kind == .body })?.id
    }

    @ViewBuilder private func body(_ block: StreamBlock, latestBodyId: Int?) -> some View {
        if block.text.isEmpty {
            EmptyView()
        } else {
            // Every body is typed, middle or final. The transport delivers the
            // last answer *before* the turn ends, so a body that is later
            // promoted to "final" has already been read as narration; retyping
            // it at that moment is what made the page collapse and play the
            // same paragraph twice. The promotion changes ink and size only.
            TypewriterMessage(
                text: block.text,
                typing: typing && block.id == latestBodyId && typedBlockId != block.id,
                onStarted: {
                    typedBlockId = block.id
                    onTypingStarted()
                },
                onStopped: onTypingStopped,
            )
            .font(.body)
            .foregroundStyle(.primary)
            .accessibilityIdentifier(block.isFinal ? "conversation.stream.answer" : "conversation.stream.narration")
        }
    }

    /// How many blocks stay out before the oldest collapse.
    private static let foldedLimit = 40
}

/// The page changing from the running turn to the settled one.
///
/// The old page leaves before the new one arrives. A plain cross-fade puts
/// two different texts in the same place for the length of the fade -- the
/// narration and the header, one on top of the other -- and that reads as two
/// pages at once. Here the running page is gone in a fifth of a second and
/// the settled one comes up behind it, so the moment reads as one page
/// turning over.
struct SettleTransition: Transition {
    func body(content: Content, phase: TransitionPhase) -> some View {
        content
            .opacity(phase.isIdentity ? 1 : 0)
            .animation(animation(for: phase), value: phase)
    }

    private func animation(for phase: TransitionPhase) -> Animation? {
        switch phase {
        case .identity:
            return nil
        case .willAppear:
            // The settled page arrives after the running one has gone.
            return .easeIn(duration: 0.26).delay(0.10)
        case .didDisappear:
            return .easeOut(duration: 0.18)
        @unknown default:
            return nil
        }
    }
}

/// How a turn's blocks are folded once it has settled.
///
/// Pure, so the rule can be pinned without a screen: while the turn runs
/// everything it has produced is on the page, and once it has settled only the
/// answer is, with the process behind the header.
enum StreamFold {
    /// What the stream draws.
    struct Plan: Equatable {
        /// The blocks before the answer: the status lines and the narration.
        var process: [StreamBlock]
        /// The answer the turn settled on.
        var summary: StreamBlock?
        /// The blocks after the answer. Rare -- but the order is the order.
        var after: [StreamBlock]
        /// Whether there is a process to bring back.
        var canExpand: Bool
        /// Whether the process is on screen.
        var showsProcess: Bool
    }

    /// The plan for a stream.
    ///
    /// - Parameters:
    ///   - blocks: the stream's blocks, oldest first.
    ///   - live: whether the turn is still running.
    ///   - expanded: whether the reader has asked for the process.
    static func plan(blocks: [StreamBlock], live: Bool, expanded: Bool) -> Plan {
        guard !live, let index = summaryIndex(in: blocks) else {
            // Running: everything the turn has produced is on the page, and
            // there is no answer yet to fold the rest away behind.
            return Plan(
                process: blocks,
                summary: nil,
                after: [],
                canExpand: false,
                showsProcess: true,
            )
        }
        let process = Array(blocks[..<index])
        return Plan(
            process: process,
            summary: blocks[index],
            after: Array(blocks[(index + 1)...]),
            canExpand: !process.isEmpty,
            showsProcess: expanded,
        )
    }

    /// The index of the turn's answer: the last body the host marked final.
    private static func summaryIndex(in blocks: [StreamBlock]) -> Int? {
        blocks.lastIndex { $0.kind == .body && $0.isFinal && !$0.text.isEmpty }
    }
}

/// "已完成，用时 2 分 14 秒" / "已中断，用时 18 秒".
private struct StreamHeader {
    let state: SessionState?
    let endedAt: Date?
    let startedAt: Date?

    private var interrupted: Bool {
        state == .failed || state == .paused
    }

    private var duration: TimeInterval? {
        guard let startedAt, let endedAt else { return nil }
        return max(0, endedAt.timeIntervalSince(startedAt))
    }

    /// The line's text.
    var title: String {
        guard let duration else {
            if interrupted { return String(localized: "Interrupted") }
            return String(localized: "Completed")
        }
        if interrupted {
            return String(format: String(localized: "Interrupted after %@"), StreamDuration.spell(duration))
        }
        return String(format: String(localized: "Completed in %@"), StreamDuration.spell(duration))
    }

    /// The line, with a disclosure mark when a process is folded behind it.
    @MainActor
    func label(expanded: Bool, expandable: Bool) -> some View {
        HStack(spacing: 7) {
            Image(systemName: interrupted ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(interrupted ? Theme.waiting : Theme.running)
                .symbolRenderingMode(.hierarchical)
                .frame(width: 20, height: 20)
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
            if expandable {
                // The mark points at the way the process goes: right while it is
                // folded away, down once it is there.
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .animation(Motion.pick(.mizarSnappy), value: expanded)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// The live footer: a mark turning, and the clock it keeps.
private struct StreamClock: View {
    let startedAt: Date?
    /// A fixed instant, when a snapshot needs the clock to stand still.
    var now: Date? = nil

    var body: some View {
        HStack(spacing: 7) {
            MizarRing(ink: 17, motion: .running)
                .frame(width: 20, height: 20)
            if let startedAt, let now {
                label(elapsed: max(0, now.timeIntervalSince(startedAt)))
            } else if let startedAt {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    label(elapsed: max(0, context.date.timeIntervalSince(startedAt)))
                }
            } else {
                Text(String(localized: "DeepSeeking"))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .shimmering()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("conversation.stream.clock")
    }

    private func label(elapsed: TimeInterval) -> some View {
        Text(String(format: String(localized: "DeepSeeking for %@"), StreamDuration.spell(elapsed)))
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
            // This is the same running headline that carried the old sweep
            // before the stream was rebuilt: it is the clock the whole live
            // footer is named after, not the finished turn above it.
            .shimmering()
            .contentTransition(.numericText(countsDown: false))
            .animation(.mizarSnappy, value: Int(elapsed))
    }
}

/// One line of the state machine, running or settled.
private struct StreamStatusLine: View {
    @Environment(\.colorScheme) private var colorScheme
    let states: [SessionState]
    /// Whether this is the line that is still changing.
    let running: Bool
    /// A question or an approval the turn is waiting on, when it is.
    let waiting: SessionState?
    /// The state happening now, when this line is live.
    let current: SessionState?

    private var text: String {
        if running, let waiting {
            return StreamWording.running(waiting)
        }
        if running, let current {
            return StreamWording.running(current)
        }
        return StreamWording.completion(states)
    }

    /// The glyph the state machine's current (or last) category implies.
    private var category: ProcessCategory? {
        if let waiting, let category = ProcessCategory.from(state: waiting) { return category }
        if let current, let category = ProcessCategory.from(state: current) { return category }
        return states.compactMap(ProcessCategory.from).last
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let symbol = category?.symbol {
                Image(systemName: symbol)
                    .font(.subheadline.weight(.medium))
            }
            Text(text)
                .font(.subheadline.weight(running ? .medium : .regular))
                // In dark mode the accent is white, i.e. the body colour: a
                // quiet underline is what still says "this line is the app's
                // live voice", not another paragraph.
                .underline(running && colorScheme == .dark)
        }
        .foregroundStyle(running ? Theme.accentText : Color.secondary)
        // The live state machine keeps the old left-to-right sweep: this line
        // is the one thing on the page that is still doing something, and a
        // settled status line must not keep moving. The line is outside the
        // conversation's lazy stack, so the mask animation cannot drag a lazy
        // layout through a text-measurement loop.
        .shimmering(active: running)
        .contentTransition(.opacity)
        .animation(.snappy(duration: 0.18), value: text)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(running ? "conversation.stream.status.running" : "conversation.stream.status")
    }
}

/// The hairline between what the turn produced and what it is doing.
private struct StreamHairline: View {
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Rectangle()
            .fill(.secondary.opacity(0.16))
            .frame(height: 1 / max(displayScale, 1))
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true)
    }
}

/// A centred system line, the same voice as a conversation notice.
private struct StreamNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, alignment: .center)
            .accessibilityIdentifier("conversation.stream.note")
    }
}

/// How a duration reads: seconds under a minute, minutes and seconds after.
enum StreamDuration {
    static func spell(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return String(format: String(localized: "%lld s"), total) }
        return String(format: String(localized: "%lld min %lld s"), total / 60, total % 60)
    }
}

/// The words a state turns into.
///
/// Running states keep the protocol's own name ("思考推理中"); a settled segment
/// is said in the past tense ("已完成分析并执行了命令"), because by then it is
/// something the turn did rather than something it is doing.
enum StreamWording {
    static func running(_ state: SessionState) -> String {
        // The protocol carries both languages; the app's own language picks.
        Locale.current.language.languageCode?.identifier == "en" ? state.english : state.text
    }

    static func completion(_ states: [SessionState]) -> String {
        var seen: [ProcessCategory] = []
        for state in states {
            guard let category = ProcessCategory.from(state: state) else { continue }
            if seen.last != category { seen.append(category) }
        }
        return ProcessWording.compose(Set(seen))
    }
}
