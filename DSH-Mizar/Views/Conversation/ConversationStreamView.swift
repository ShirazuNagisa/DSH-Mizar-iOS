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

    /// How many blocks are folded behind "更早的过程".
    @State private var unfoldedPrefix = false
    /// The one block that has already been typed, so scrolling away and back
    /// does not type it a second time.
    @State private var typedBlockId: Int?

    /// The blocks the view actually draws, oldest first.
    private var visibleBlocks: [StreamBlock] {
        let blocks = stream.blocks
        guard blocks.count > Self.foldedLimit, !unfoldedPrefix else { return blocks }
        return Array(blocks.suffix(Self.foldedLimit))
    }

    /// How many blocks are hidden behind the fold.
    private var foldedCount: Int {
        max(0, stream.blocks.count - Self.foldedLimit)
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
                blocks
                if hasContent {
                    StreamHairline()
                        .padding(.top, 12)
                }
                // The clock is a claim that somebody is watching the turn run.
                // Once the link is gone the claim is false: the turn may still
                // be running on the computer, but this phone has stopped
                // seeing it, so the line says what is actually true.
                if stream.disconnected {
                    StreamNote(text: String(localized: "The connection to the computer was lost."))
                        .padding(.top, 12)
                } else {
                    StreamClock(startedAt: startedAt, now: now)
                        .padding(.top, 12)
                }
            } else {
                if let header {
                    header
                        .padding(.bottom, 10)
                }
                if hasContent {
                    StreamHairline()
                        .padding(.bottom, 12)
                }
                blocks
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

    @ViewBuilder private var blocks: some View {
        let lastId = stream.blocks.last?.id
        let latestBody = latestBodyId
        VStack(alignment: .leading, spacing: 10) {
            if foldedCount > 0, !unfoldedPrefix {
                Button {
                    withAnimation(.mizarSnappy) { unfoldedPrefix = true }
                } label: {
                    Text(String(format: String(localized: "Earlier %lld steps"), foldedCount))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("conversation.stream.unfold")
            }

            ForEach(visibleBlocks) { block in
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

    /// The last body, the only one that may start a reveal.
    ///
    /// A replay can deliver a whole turn at once. Starting every block's
    /// typewriter in the same frame is a storm of schedules and hidden layouts
    /// for text nobody is waiting on -- the earlier bodies are history by then.
    private var latestBodyId: Int? {
        stream.blocks.last(where: { $0.kind == .body })?.id
    }

    /// The last block, while the turn still works, is the one that changes.
    private func isLiveStatus(_ block: StreamBlock) -> Bool {
        live && block.kind == .status && block.id == stream.blocks.last?.id
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

/// "已完成，用时 2 分 14 秒" / "已中断，用时 18 秒".
private struct StreamHeader: View {
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

    var body: some View {
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
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("conversation.stream.header")
    }

    private var title: String {
        guard let duration else {
            if interrupted { return String(localized: "Interrupted") }
            return String(localized: "Completed")
        }
        if interrupted {
            return String(format: String(localized: "Interrupted after %@"), StreamDuration.spell(duration))
        }
        return String(format: String(localized: "Completed in %@"), StreamDuration.spell(duration))
    }
}

/// The live footer: a mark turning, and the clock it keeps.
private struct StreamClock: View {
    let startedAt: Date?
    /// A fixed instant, when a snapshot needs the clock to stand still.
    var now: Date? = nil

    var body: some View {
        HStack(spacing: 7) {
            MizarStar(ink: 17, motion: .running)
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
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("conversation.stream.clock")
    }

    private func label(elapsed: TimeInterval) -> some View {
        Text(String(format: String(localized: "DeepSeeking for %@"), StreamDuration.spell(elapsed)))
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
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
        .foregroundStyle(running ? Color.accentColor : Color.secondary)
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
