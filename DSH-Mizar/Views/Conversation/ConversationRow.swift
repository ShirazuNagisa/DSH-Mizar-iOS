//
//  ConversationRow.swift
//  DSH-Mizar
//
//  One item in a conversation, and the leaf views that draw each kind.
//

import SwiftUI
import MizarKit

/// One item, drawn by kind.
struct ConversationRow: View {
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
    /// The gate that holds a reveal while a drawer moves.
    @Environment(\.drawerGate) private var drawerGate
    let text: String
    /// Whether this answer is being typed onto the page as it arrives.
    var typing: Bool = false
    /// Called when that reveal begins.
    var onTypingStarted: () -> Void = {}

    var body: some View {
        TypewriterMessage(text: text, typing: typing, gate: drawerGate, onStarted: onTypingStarted)
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
