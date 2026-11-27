//
//  ConversationRow.swift
//  DSH-Mizar
//
//  One item in a conversation, and the leaf views that draw each kind.
//

import SwiftUI
import UIKit
import MizarKit

/// One item, drawn by kind.
struct ConversationRow: View {
    let item: ConversationItem
    /// Whether this row's answer should be typed onto the page.
    var typing: Bool = false
    /// Called when typing that answer starts.
    var onTypingStarted: () -> Void = {}

    var body: some View {
        switch item {
        case .message(let id, .user, let text, _):
            UserBubble(
                messageId: id,
                text: text,
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
    /// Whether the words may be selected with the system selection UI.
    ///
    /// A user bubble answers `false`: it opens the select-in-place editor from
    /// its own menu instead, and two selection surfaces for one bubble is one
    /// too many.
    var selectable: Bool = true

    var body: some View {
        if MessageMarkdown.looksLikeMarkdown(text) {
            MarkdownMessage(text)
        } else if selectable {
            Text(text)
                .textSelection(.enabled)
        } else {
            Text(text)
        }
    }
}

/// The operator's words.
private struct UserBubble: View {
    @Environment(\.messageMenuPresenter) private var presenter
    @Environment(\.messageMenuActiveId) private var activeId
    @Environment(\.selectingMessageId) private var selectingId
    @Environment(\.endMessageSelection) private var endSelection

    /// Which message this bubble is, so the menu can name it back.
    let messageId: String
    let text: String
    /// What this phone sent with the prompt, above the words.
    ///
    /// The computer's record carries the text alone, so an attachment that
    /// went with it would otherwise vanish the moment the screen reloaded --
    /// the operator sees the photo go up and then nothing.
    var attachments: [DeliveredAttachment] = []

    /// Whether a finger is holding the bubble down.
    @State private var pressing = false
    /// How many holds have completed, which is what plays the haptic.
    @State private var presses = 0
    /// Where the bubble was laid out, read once when it is held.
    @State private var frameBox = MessageFrameBox()

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
        bubbleBody
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(SessionDetailView.space)) } action: { frameBox.frame = $0 }
            .scaleEffect(pressing ? 0.97 : 1)
            .animation(pressing ? .easeOut(duration: 0.08) : .mizarBouncy, value: pressing)
            .opacity(activeId == messageId ? 0 : 1)
            .onLongPressGesture(minimumDuration: 0.35, maximumDistance: 10) {
                presses += 1
                presenter.open(MessageMenuRequest(id: messageId, text: text, frame: frameBox.frame))
            } onPressingChanged: { pressing = $0 }
            .mizarFeedback(.impact(weight: .medium), trigger: presses)
            .accessibilityAction(named: Text("Copy")) { UIPasteboard.general.string = text }
            .accessibilityAction(named: Text("Select Text")) { presenter.select(messageId) }
            // The row is full width and the bubble sits at its trailing edge,
            // so what is lifted and measured is the bubble, not the row.
            .frame(maxWidth: .infinity, alignment: .trailing)
    }

    /// The bubble's look: the words, padded, on the accent colour.
    private var bubbleBody: some View {
        HStack(spacing: 0) {
            bubbleText
                .foregroundStyle(Theme.onAccent)
                .tint(Theme.onAccent)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background {
                    RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                        .fill(Color.accentColor.gradient)
                }
        }
    }

    /// The words: plain, or an editor that lets the whole message be selected
    /// where it sits.
    @ViewBuilder
    private var bubbleText: some View {
        if selectingId == messageId {
            SelectableBubbleText(text: text, onEnd: endSelection)
        } else {
            MessageText(text: text, selectable: false)
        }
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
