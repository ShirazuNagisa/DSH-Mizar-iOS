//
//  MessageMarkdown.swift
//  DSH-Mizar
//
//  A cheap check for whether a message should be parsed as Markdown.
//

import Foundation

/// Whether a message body is worth drawing as blocks.
///
/// Cheap and deliberately narrow: a false negative shows backticks, a false
/// positive costs one parse. The line-anchored markers are checked per line
/// rather than by substring -- `"\n# "` never matched a body that *was* a
/// heading, which is the common case of a short reply.
enum MessageMarkdown {
    static func looksLikeMarkdown(_ text: String) -> Bool {
        if text.contains("**") || text.contains("`") || text.contains("](") || text.contains("|") {
            return true
        }
        return text.split(separator: "\n", omittingEmptySubsequences: true).contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("# ") || trimmed.hasPrefix("> ") || trimmed.hasPrefix("```") {
                return true
            }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                return true
            }
            return trimmed.range(of: #"^\d{1,3}[.)]\s"#, options: .regularExpression) != nil
        }
    }
}
