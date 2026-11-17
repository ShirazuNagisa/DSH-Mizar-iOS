//
//  ComposerTokens.swift
//  MizarKit
//
//  Where the composer's pills are.
//
//  A command or a skill is typed as a literal — `/goal`, `/grilling` — and the
//  field draws it as a capsule. The pill is only a rendering: what is sent, what
//  is stored as the draft and what the host parses are exactly the characters
//  typed. Keeping that true is what keeps this file a pure function over a
//  string: the editor asks where the tokens are, and nothing else in the app
//  needs to know that the field draws attachments at all.
//
//  Two rules decide what counts:
//
//  - A token starts a word: the beginning of the text, or just after
//    whitespace. `/goal` inside `see/goal` is prose, not a command.
//  - A token ends a word too: the end of the text, or just before whitespace.
//    `/goals` and `/goal,` are words nobody defined, and pill-ing them would
//    claim the agent understands something it does not.
//
//  Ranges are UTF-16, because that is what `UITextView` and `NSRange` speak; a
//  caller that wants characters should convert at its own edge.
//

import Foundation

/// One recognised `/token` in the composer's text.
public struct ComposerToken: Equatable, Sendable {
    /// The name without its slash: `goal`, `grilling`.
    public let name: String
    /// Where the whole `/name` sits in the text, in UTF-16 units.
    public let range: NSRange

    public init(name: String, range: NSRange) {
        self.name = name
        self.range = range
    }

    /// The characters the token stands for, which is exactly what is sent.
    public var literal: String { "/" + name }
}

/// Finding the pill-able tokens in a draft.
public enum ComposerTokens {
    /// The slash that begins a token.
    private static let slash = unichar(0x2F)

    /// Every `/token` in `text`, in order, given the names the composer knows.
    ///
    /// - Parameters:
    ///   - text: the draft as typed.
    ///   - names: token names without the slash, e.g. `["goal", "grilling"]`.
    ///     Duplicates and empty strings are ignored.
    /// - Returns: non-overlapping tokens, left to right. An unknown name is not
    ///   a token at all, so it stays plain text.
    public static func scan(_ text: String, names: [String]) -> [ComposerToken] {
        let source = text as NSString
        guard source.length > 0 else { return [] }
        // Longest first, so `/grill-me` wins over a hypothetical `/grill` at the
        // same position instead of leaving `-me` behind as prose.
        let candidates = Array(Set(names.filter { !$0.isEmpty })).sorted {
            $0.count == $1.count ? $0 < $1 : $0.count > $1.count
        }
        guard !candidates.isEmpty else { return [] }

        var tokens: [ComposerToken] = []
        var index = 0
        while index < source.length {
            guard source.character(at: index) == slash,
                  startsWord(at: index, in: source)
            else {
                index += 1
                continue
            }
            var matched = false
            for name in candidates {
                let literal = "/" + name
                let length = (literal as NSString).length
                let end = index + length
                guard end <= source.length else { continue }
                let range = NSRange(location: index, length: length)
                guard source.compare(literal, options: [], range: range) == .orderedSame else {
                    continue
                }
                // The character after the name: the end of the text or
                // whitespace. Anything else (`/goals`, `/goal,`) is a word this
                // palette has never heard of.
                guard end == source.length || isWhitespace(source.character(at: end)) else {
                    continue
                }
                tokens.append(ComposerToken(name: name, range: range))
                index = end
                matched = true
                break
            }
            if !matched { index += 1 }
        }
        return tokens
    }

    /// Whether the caret sits directly after a lone `/` that starts a word.
    ///
    /// This is what makes the palette's hint appear while typing: the token
    /// being typed is exactly a slash, not yet a name. It goes away the moment
    /// a second character is typed, the slash is deleted, or the caret leaves
    /// the token.
    ///
    /// - Parameters:
    ///   - text: the draft as typed.
    ///   - caret: the insertion point, in UTF-16 units.
    /// - Returns: whether the text immediately around the caret is a lone `/`.
    public static func isLoneSlashToken(_ text: String, caret: Int) -> Bool {
        let source = text as NSString
        guard caret > 0, caret <= source.length else { return false }
        // The slash the caret follows.
        guard source.character(at: caret - 1) == slash else { return false }
        // It has to start the word: beginning of the text or whitespace before.
        if caret - 1 > 0, !isWhitespace(source.character(at: caret - 2)) {
            return false
        }
        // And nothing may continue the word after the caret.
        if caret < source.length, !isWhitespace(source.character(at: caret)) {
            return false
        }
        return true
    }

    // MARK: - Characters

    /// Whether position `index` begins a word.
    private static func startsWord(at index: Int, in source: NSString) -> Bool {
        index == 0 || isWhitespace(source.character(at: index - 1))
    }

    /// Whether a UTF-16 unit is whitespace.
    ///
    /// `whitespacesAndNewlines` rather than `== " "`: a token pasted after a
    /// newline, a tab or an ideographic space is still a word. Public because
    /// the editor repeats this one test when it replaces a trigger slash.
    public static func isWhitespace(_ character: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(character) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }
}
