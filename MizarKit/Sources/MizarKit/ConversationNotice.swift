//
//  ConversationNotice.swift
//  MizarKit
//
//  The host writes a few events about the conversation itself -- a compaction,
//  a background job settling, a subagent reporting back -- as `notice` records
//  whose text is whatever the harness wrote. The phone draws them as one
//  centred line, but the harness text is long and English. This classifies it
//  so the app can show a short, localized phrase and fold a burst into one
//  line.
//

import Foundation

/// What a `notice` record is about.
public enum ConversationNoticeKind: Sendable, Equatable {
    case compaction
    case jobStarted
    case jobFinished
    case jobStopped
    case subagentStarted
    case subagentFinished
    case subagentMessage
    /// Anything the classifier does not recognise. The text is kept as-is.
    case other

    /// The family used for folding a burst. Different actions in one family
    /// still fold into a single "updated" line.
    public enum Category: Sendable, Equatable {
        case compaction
        case job
        case subagent
        case other
    }

    public var category: Category {
        switch self {
        case .compaction: .compaction
        case .jobStarted, .jobFinished, .jobStopped: .job
        case .subagentStarted, .subagentFinished, .subagentMessage: .subagent
        case .other: .other
        }
    }
}

/// Classify the harness's notice text.
///
/// The host's projection keeps only `data.text`; the source kind that would
/// make this exact (`tool-jobs`, `subagent-settled`, `user-approval`, ...) is
/// not on the wire. These prefixes and words are the stable part of the
/// settlement and job notices; an unrecognised text falls back to `.other`
/// and is drawn unchanged, which is the safe failure.
public enum ConversationNoticeClassifier {
    /// A turn body is re-evaluated many times while the page lays out and the
    /// list scrolls. Classification is a pile of substring scans; repeating it
    /// for the same notice was measurable (about a tenth of a second in one
    /// long-session launch). The text is the key, the answer is pure.
    private final class CachedKind {
        let kind: ConversationNoticeKind
        init(_ kind: ConversationNoticeKind) { self.kind = kind }
    }

    nonisolated(unsafe) private static let cache: NSCache<NSString, CachedKind> = {
        let cache = NSCache<NSString, CachedKind>()
        cache.countLimit = 2048
        return cache
    }()

    public static func kind(of text: String) -> ConversationNoticeKind {
        let key = text as NSString
        if let cached = cache.object(forKey: key) { return cached.kind }
        let kind = classify(text)
        cache.setObject(CachedKind(kind), forKey: key)
        return kind
    }

    private static func classify(_ text: String) -> ConversationNoticeKind {
        let lower = text.lowercased()

        // A notice body is free text; require the harness's own phrase rather
        // than any mention of compaction.
        if lower.contains("context compacted") || lower.contains("compaction") {
            return .compaction
        }

        if lower.contains("sent a message") || lower.contains("message from a subagent") {
            return .subagentMessage
        }

        if lower.hasPrefix("background subagent") {
            if lower.contains("finished") || lower.contains("completed")
                || lower.contains("stopped") || lower.contains("aborted")
                || lower.contains("no further work") {
                return .subagentFinished
            }
            if lower.contains("started") || lower.contains("spawned") || lower.contains("launched") {
                return .subagentStarted
            }
            // A bare settlement line is the common shape the harness emits
            // after a child finishes; a start is a tool event, not this notice.
            return .subagentFinished
        }

        if lower.hasPrefix("agent ") {
            if lower.contains("started") || lower.contains("spawned") || lower.contains("launched") {
                return .subagentStarted
            }
            if lower.contains("finished") || lower.contains("completed")
                || lower.contains("stopped") || lower.contains("aborted") {
                return .subagentFinished
            }
            return .other
        }

        if lower.hasPrefix("background job") {
            if lower.contains("stopped") || lower.contains("killed")
                || lower.contains("failed") || lower.contains("cancelled")
                || lower.contains("canceled") {
                return .jobStopped
            }
            if lower.contains("finished") || lower.contains("completed")
                || lower.contains("done") || lower.contains("exit code") {
                return .jobFinished
            }
            if lower.contains("started") || lower.contains("running") {
                return .jobStarted
            }
            // The start notice can be just the family and the job id; the
            // completion carries "finished"/"exit code" and is matched above.
            return .jobStarted
        }

        return .other
    }
}
