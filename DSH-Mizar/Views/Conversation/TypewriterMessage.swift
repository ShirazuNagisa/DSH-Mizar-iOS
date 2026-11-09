//
//  TypewriterMessage.swift
//  DSH-Mizar
//
//  The agent's answer, typed onto the page.
//
//  The host sends a turn's answer once, whole. The desktop shows it arriving
//  token by token while the model writes it, and an answer that appears between
//  one frame and the next reads as a screen that refreshed rather than as a
//  model that finished talking. This is the phone's stand-in for that arrival:
//  ``TypewriterPlan`` decides which character is visible at which moment, and
//  this view draws the message up to that character, every frame, until the
//  message is whole.
//
//  Three rules make it read as a voice rather than as an effect:
//
//    - it draws the *parsed* blocks, cut down, so nothing in the message's
//      markdown syntax crawls across the screen;
//    - it never re-types. The reveal is chosen once, when the row first
//      appears, and the finished state is what every later redraw draws. A
//      message scrolled away and back is the message, not a re-run;
//    - it respects Reduce Motion by not existing -- the caller decides, and a
//      message that would have been typed is simply there.
//
//  The accessibility label is the whole answer from the first frame. A reader
//  using VoiceOver should not have to wait for the clock, and a UI test asking
//  for "the turn's answer" should find it while it is still arriving.
//

import SwiftUI
import MizarKit

/// An answer body that reveals itself character by character when asked to.
struct TypewriterMessage: View {
    /// The answer, as the host sent it.
    let text: String
    /// Whether this appearance of the answer should be typed.
    ///
    /// Decided once by the conversation screen, and only ever `true` for an
    /// answer that arrived while the screen was watching. A message that was
    /// already part of the conversation is never typed again.
    let typing: Bool
    /// Called when the reveal begins, before the first character.
    ///
    /// The conversation screen records the answer as seen here, so a row that
    /// scrolls out of the lazy stack mid-reveal cannot come back and start the
    /// reveal over.
    var onStarted: () -> Void = {}
    /// Called when the reveal ends or the view goes away.
    var onStopped: () -> Void = {}

    /// The message's blocks, parsed once. Empty for a body that is not Markdown.
    @State private var blocks: [MarkdownBlock]
    /// Whether the body is Markdown, and therefore has blocks to cut down.
    @State private var isMarkdown: Bool
    /// The schedule for this message. Deterministic, so a redraw types the same
    /// way; built once, in the initializer.
    @State private var plan: TypewriterPlan
    /// How many characters are visible right now.
    @State private var revealed: Int
    /// Whether the reveal is still running. Also the "draw only part" branch.
    @State private var running: Bool
    /// Whether the shell's drawers are still, read in the body so the hold
    /// tracks them.
    @Environment(\.drawersStill) private var drawersStill
    /// Whether the reveal is holding while a drawer moves.
    ///
    /// The count is derived from the clock, so a hold costs nothing but
    /// time: when the drawers stop, the reveal jumps to where it now is
    /// rather than resuming from where it was held. What the hold buys is
    /// the frames it does not spend -- a drawer dragging the card re-renders
    /// this row's blocks on every character, under the card's mask, shadow
    /// and glass.
    @State private var held = false

    /// A message's parse, kept across the many times a parent re-creates this
    /// view.
    ///
    /// `init` runs on every parent body evaluation, and parsing a long answer is
    /// the expensive part of that -- not the draw. A conversation screen
    /// re-evaluates while its scroll geometry changes, so without this cache a
    /// fast scroll re-parsed every visible answer on every frame and the main
    /// thread never caught up.
    private final class ParsedMessage: NSObject {
        let blocks: [MarkdownBlock]
        let markdown: Bool
        let visible: String
        /// Built once, on the first edit that asks for a reveal.
        ///
        /// The schedule is the other expensive part of `init`, and the flag
        /// that asks for it stays true after the reveal has finished. A parent
        /// that re-evaluates on every scroll tick must not rebuild a table of
        /// thousands of instants for an answer that is already whole.
        lazy var plan = TypewriterPlan(text: visible)

        init(blocks: [MarkdownBlock], markdown: Bool, visible: String) {
            self.blocks = blocks
            self.markdown = markdown
            self.visible = visible
        }
    }

    private static let parsedCache: NSCache<NSString, ParsedMessage> = {
        let cache = NSCache<NSString, ParsedMessage>()
        cache.countLimit = 32
        return cache
    }()

    /// The cached parse of one message.
    private static func parse(_ text: String) -> ParsedMessage {
        let key = text as NSString
        if let cached = parsedCache.object(forKey: key) { return cached }
        let markdown = MessageMarkdown.looksLikeMarkdown(text)
        let blocks = markdown ? MarkdownBlocks.parse(text) : []
        // The plan paces the characters the reveal actually counts: for a
        // Markdown body that is the text inside its blocks, without markers,
        // pipes or fences. See `MarkdownReveal`.
        let visible = markdown ? MarkdownReveal.plainText(blocks) : text
        let parsed = ParsedMessage(blocks: blocks, markdown: markdown, visible: visible)
        parsedCache.setObject(parsed, forKey: key)
        return parsed
    }

    init(
        text: String,
        typing: Bool,
        onStarted: @escaping () -> Void = {},
        onStopped: @escaping () -> Void = {},
    ) {
        self.text = text
        self.typing = typing
        self.onStarted = onStarted
        self.onStopped = onStopped
        let parsed = Self.parse(text)
        // The schedule only matters for a reveal. A message that is drawn
        // instantly -- all of history, every redraw of it -- must not pay for a
        // per-character table it will never read; a long answer's table is
        // thousands of entries, rebuilt on every redraw of its row.
        let plan = typing ? parsed.plan : TypewriterPlan(text: "")
        _blocks = State(initialValue: parsed.blocks)
        _isMarkdown = State(initialValue: parsed.markdown)
        _plan = State(initialValue: plan)
        _revealed = State(initialValue: 0)
        _running = State(initialValue: typing)
    }

    var body: some View {
        Group {
            if running {
                revealing
            } else {
                whole
            }
        }
        .onChange(of: text) { _, newText in
            // A streamed body can grow: the host appends to the same interval.
            // The parsed blocks and the schedule were built for the first
            // chunk; without this the row kept drawing only that chunk while
            // the text property (and VoiceOver) already had the rest.
            let parsed = Self.parse(newText)
            blocks = parsed.blocks
            isMarkdown = parsed.markdown
            if typing { plan = parsed.plan }
            running = false
            revealed = plan.totalCharacters
        }
        .task {
            // A task on the view, not a timer: it starts when the row appears,
            // ends when the message is whole or the row goes away, and it is
            // cancelled with the view. `.task` runs once per appearance, so a
            // redraw of the parent cannot restart a reveal.
            await reveal()
        }
        .onChange(of: drawersStill, initial: true) { _, still in
            held = !still
        }
    }

    // MARK: - Drawing

    /// The message with only the typed part drawn.
    ///
    /// There is deliberately no hidden full-size copy underneath: a second
    /// selectable layout of the same long answer, on every reveal frame, is a
    /// far bigger cost than the height change it used to reserve -- and taps
    /// over two overlapping text views were a way into a TextKit loop. The
    /// scroll screen holds its position while a body is revealing
    /// (`typingBodies`) instead of chasing the growing row.
    @ViewBuilder private var revealing: some View {
        if isMarkdown {
            MarkdownBlocksView(blocks: MarkdownReveal.blocks(blocks, visibleCharacters: revealed))
                .textSelection(.enabled)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(text)
                .accessibilityIdentifier("conversation.answer.typing")
        } else {
            Text(String(text.prefix(revealed)))
                .textSelection(.enabled)
                .accessibilityLabel(text)
                .accessibilityIdentifier("conversation.answer.typing")
        }
    }

    /// The finished message, drawn from the blocks already parsed above.
    ///
    /// Not `MarkdownMessage(text)`: that would parse the Markdown a second time
    /// for the same frame, and this view already holds the parse.
    @ViewBuilder private var whole: some View {
        if isMarkdown {
            MarkdownBlocksView(blocks: blocks)
                .textSelection(.enabled)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(text)
        } else {
            Text(text)
                .textSelection(.enabled)
                .accessibilityLabel(text)
        }
    }

    // MARK: - The reveal

    /// Type the message, one frame at a time, until it is whole.
    ///
    /// The character count is read off the message's clock rather than counted
    /// up: a tick that arrives late does not make the reveal lag behind, it
    /// catches up on the next frame, and the schedule stays the schedule. The
    /// loop stops on the frame the last character appears, then hands the row
    /// over to the finished drawing.
    private func reveal() async {
        guard running else { return }
        onStarted()
        defer { onStopped() }
        let clock = ContinuousClock()
        let start = clock.now
        var last = -1
        while !Task.isCancelled {
            guard running else { break }
            if !held {
                let elapsed = clock.now - start
                let count = plan.revealedCount(after: elapsed)
                if count != last {
                    revealed = count
                    last = count
                }
                if plan.isFinished(after: elapsed) { break }
            }
            // Fourteen milliseconds: sixty-ish frames a second, and no more
            // precision than a phone display can show. The count is derived
            // from elapsed time, so a missed tick costs nothing but a redraw.
            // While the reveal is held it costs nothing at all, so it wakes
            // less often: those frames belong to the card.
            try? await Task.sleep(for: .milliseconds(held ? 60 : 14))
        }
        guard !Task.isCancelled else { return }
        revealed = plan.totalCharacters
        running = false
    }
}
