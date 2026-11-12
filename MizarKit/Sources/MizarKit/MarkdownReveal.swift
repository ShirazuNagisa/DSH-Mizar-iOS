//
//  MarkdownReveal.swift
//  MizarKit
//
//  A message body with only its first characters visible.
//
//  The typewriter's other half: ``TypewriterPlan`` says how many characters are
//  on screen at a moment, and this cuts the parsed blocks down to exactly that
//  many. Doing it on the *parsed* blocks rather than on the raw Markdown is what
//  keeps the reveal from showing syntax: the message is typed as the text it
//  will be, so a reader never sees `**` or a fence marker crawl across the
//  screen.
//
//  The order characters are counted in is the order they are read in: block by
//  block, and inside a block its text. Markers (`•`, `1.`), table pipes and a
//  code block's language label carry no characters and appear with the first
//  character of what they introduce. ``plainText(_:)`` returns exactly the
//  characters that are counted, in that order, so the plan can pace the same
//  sequence the reveal cuts.
//

import Foundation

/// Cutting a message's blocks down to what has been typed so far.
public enum MarkdownReveal {
    /// Every character the reveal counts, in reading order.
    ///
    /// No separators are inserted between blocks: this is a pacing string, not a
    /// transcript, and adding characters that are not on screen would make the
    /// schedule run ahead of the reveal.
    ///
    /// - Parameter blocks: the message's blocks.
    /// - Returns: the characters that appear on screen, in order.
    public static func plainText(_ blocks: [MarkdownBlock]) -> String {
        fragments(of: blocks).joined()
    }

    /// How many characters the reveal has to get through.
    ///
    /// - Parameter blocks: the message's blocks.
    /// - Returns: the count of visible characters.
    public static func characterCount(_ blocks: [MarkdownBlock]) -> Int {
        fragments(of: blocks).reduce(0) { $0 + $1.count }
    }

    /// The blocks with only the first `visibleCharacters` characters shown.
    ///
    /// - Parameters:
    ///   - blocks: the message's blocks.
    ///   - visibleCharacters: how many characters have been typed. `0` draws
    ///     nothing; a value at or past the message's length returns the blocks
    ///     unchanged, which is also the cheapest path for a finished reveal.
    /// - Returns: the blocks to draw.
    public static func blocks(
        _ blocks: [MarkdownBlock],
        visibleCharacters: Int,
    ) -> [MarkdownBlock] {
        guard visibleCharacters > 0 else { return [] }
        guard visibleCharacters < characterCount(blocks) else { return blocks }

        var remaining = visibleCharacters
        var revealed: [MarkdownBlock] = []
        for block in blocks {
            switch block {
            case .paragraph(let text):
                guard let kept = take(&remaining, from: text) else { return revealed }
                revealed.append(.paragraph(kept))

            case .heading(let level, let text):
                guard let kept = take(&remaining, from: text) else { return revealed }
                revealed.append(.heading(level: level, text: kept))

            case .quote(let text):
                guard let kept = take(&remaining, from: text) else { return revealed }
                revealed.append(.quote(kept))

            case .code(let language, let text):
                guard let kept = take(&remaining, from: text) else { return revealed }
                revealed.append(.code(language: language, text: kept))

            case .list(let items):
                guard remaining > 0 else { return revealed }
                var keptItems: [MarkdownListItem] = []
                for item in items {
                    guard remaining > 0 else { break }
                    let kept = take(noLimit: &remaining, from: item.text)
                    keptItems.append(MarkdownListItem(marker: item.marker, indent: item.indent, text: kept))
                    if remaining == 0 { break }
                }
                if !keptItems.isEmpty { revealed.append(.list(keptItems)) }
                if remaining == 0 { return revealed }

            case .table(let table):
                guard remaining > 0 else { return revealed }
                revealed.append(.table(revealedTable(table, remaining: &remaining)))
                if remaining == 0 { return revealed }

            case .divider:
                // Zero characters, so it costs nothing and is shown once the
                // reveal has reached it.
                if remaining > 0 { revealed.append(.divider) }

            case .image:
                // Also zero characters: a picture is not typed onto the page,
                // and the desktop resolves one only after its message settles.
                // Waiting on the same budget as a divider is what keeps it from
                // appearing ahead of the sentence that introduces it.
                if remaining > 0 { revealed.append(block) }
            }
        }
        return revealed
    }

    // MARK: - Parts

    /// The counted text pieces of a message, in reading order.
    ///
    /// - Parameter blocks: the message's blocks.
    /// - Returns: one string per piece of visible text.
    private static func fragments(of blocks: [MarkdownBlock]) -> [String] {
        blocks.flatMap { block -> [String] in
            switch block {
            case .paragraph(let text), .heading(_, let text), .quote(let text):
                [text]
            case .code(_, let text):
                [text]
            case .list(let items):
                items.map(\.text)
            case .table(let table):
                table.header + table.rows.flatMap { $0 }
            case .divider, .image:
                []
            }
        }
    }

    /// Take as much of one piece of text as the budget allows.
    ///
    /// - Parameters:
    ///   - remaining: the character budget; decremented by what was taken.
    ///   - text: the piece's full text.
    /// - Returns: the visible prefix, or `nil` when the budget is exhausted and
    ///   this block should not be drawn at all.
    private static func take(_ remaining: inout Int, from text: String) -> String? {
        guard remaining > 0 else { return nil }
        let kept = take(noLimit: &remaining, from: text)
        return kept
    }

    /// Take as much of one piece of text as the budget allows, including when
    /// that is all of it.
    ///
    /// A zero-length piece still counts as reached (a list item with no text is
    /// a marker), which is why the caller checks `remaining` around it rather
    /// than here.
    ///
    /// - Parameters:
    ///   - remaining: the character budget; decremented by what was taken.
    ///   - text: the piece's full text.
    /// - Returns: the visible prefix.
    private static func take(noLimit remaining: inout Int, from text: String) -> String {
        let count = min(max(remaining, 0), text.count)
        remaining -= count
        return String(text.prefix(count))
    }

    /// A table with the cells the budget reaches, the rest blank.
    ///
    /// The grid keeps its full width whatever has been typed: a table that
    /// changes its column count as it is typed would jump sideways on every
    /// row, which is the one kind of motion a reader cannot follow.
    ///
    /// - Parameters:
    ///   - table: the full table.
    ///   - remaining: the character budget; decremented by what was taken.
    /// - Returns: the table to draw.
    private static func revealedTable(_ table: MarkdownTable, remaining: inout Int) -> MarkdownTable {
        var header: [String] = []
        for cell in table.header {
            guard remaining > 0 else { break }
            header.append(take(noLimit: &remaining, from: cell))
        }
        while header.count < table.header.count { header.append("") }

        var rows: [[String]] = []
        for row in table.rows {
            guard remaining > 0 else { break }
            var keptRow: [String] = []
            for cell in row {
                guard remaining > 0 else { break }
                keptRow.append(take(noLimit: &remaining, from: cell))
            }
            while keptRow.count < table.header.count { keptRow.append("") }
            rows.append(keptRow)
            if remaining == 0 { break }
        }
        return MarkdownTable(header: header, rows: rows, alignments: table.alignments)
    }
}
