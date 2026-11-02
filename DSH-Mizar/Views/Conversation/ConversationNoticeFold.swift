//
//  ConversationNoticeFold.swift
//  DSH-Mizar
//
//  The host's notices arrive as long English sentences, one record each. They
//  are the conversation talking about itself, not something anybody said, so
//  the phone shows a short localized line and folds a burst of the same family
//  into one -- ten subagents starting together is one line, not ten.
//

import Foundation
import MizarKit

/// Localized copy and burst folding for `notice` records.
enum ConversationNoticeFold {
    /// A burst is notices of one family within this many seconds of the first.
    static let window: TimeInterval = 5

    /// Replace recognised notices with localized phrases and fold bursts.
    ///
    /// Only consecutive notices fold: a message or a tool row between two
    /// notices is a different moment and keeps them apart.
    static func fold(_ items: [ConversationItem]) -> [ConversationItem] {
        var out: [ConversationItem] = []
        var index = 0
        while index < items.count {
            guard case .notice(let id, let text, let at) = items[index] else {
                out.append(items[index])
                index += 1
                continue
            }
            let kind = ConversationNoticeClassifier.kind(of: text)
            guard kind != .other else {
                out.append(items[index])
                index += 1
                continue
            }

            var kinds = [kind]
            var end = index + 1
            while end < items.count {
                guard case .notice(_, let nextText, let nextAt) = items[end] else { break }
                let next = ConversationNoticeClassifier.kind(of: nextText)
                guard next != .other, next.category == kind.category,
                      nextAt.timeIntervalSince(at) <= window else { break }
                kinds.append(next)
                end += 1
            }

            let phrase = phrase(for: kinds) ?? text
            // The id is the first notice's id whether or not the burst has
            // grown: changing it when the second member arrives would destroy
            // and rebuild the row, replaying its entrance for every notice.
            out.append(.notice(id: id, text: phrase, at: at))
            index = end
        }
        return out
    }

    /// The one short line for a group of notices, or `nil` when the family is
    /// unknown and the host's text should be kept.
    static func phrase(for kinds: [ConversationNoticeKind]) -> String? {
        guard let first = kinds.first else { return nil }
        if kinds.count == 1 {
            return singular(first)
        }
        if kinds.contains(where: { $0 != first }) {
            switch first.category {
            case .job: return String(localized: "Background tasks updated")
            case .subagent: return String(localized: "Background subagents updated")
            case .compaction: return singular(.compaction)
            case .other: return nil
            }
        }
        switch first {
        case .compaction: return singular(.compaction)
        case .jobStarted: return String(localized: "Multiple background tasks started")
        case .jobFinished: return String(localized: "Multiple background tasks finished")
        case .jobStopped: return String(localized: "Multiple background tasks stopped")
        case .subagentStarted: return String(localized: "Multiple background subagents started")
        case .subagentFinished: return String(localized: "Multiple background subagents finished")
        case .subagentMessage: return String(localized: "Multiple messages from subagents")
        case .other: return nil
        }
    }

    private static func singular(_ kind: ConversationNoticeKind) -> String? {
        switch kind {
        case .compaction: return String(localized: "Conversation context compacted")
        case .jobStarted: return String(localized: "Background task started")
        case .jobFinished: return String(localized: "Background task finished")
        case .jobStopped: return String(localized: "Background task stopped")
        case .subagentStarted: return String(localized: "Background subagent started")
        case .subagentFinished: return String(localized: "Background subagent finished")
        case .subagentMessage: return String(localized: "Message from a subagent")
        case .other: return nil
        }
    }
}
