//
//  MarkdownBlocks.swift
//  MizarKit
//
//  A message body, cut into the blocks a conversation screen draws.
//
//  The iOS client used to hand `AttributedString(markdown:options:.full)` to
//  `Text`, and that loses the message's shape: `.full` puts paragraphs, list
//  items, headings and tables into `presentationIntent`, while the characters
//  themselves come back with no line breaks at all -- measured, "第一行\n第二行"
//  parses to "第一行 第二行". `Text` renders characters and inline attributes, not
//  block intents, so a model's summary arrived as one long run-on paragraph:
//  lists lost their bullets, headings their size, and a table became
//  "列A列B12".
//
//  So the blocks are cut here, where they can be tested without a screen, and
//  each one is drawn by the view that knows how. The rules are deliberately the
//  narrow set agent replies actually use -- headings, lists, quotes, fenced
//  code, rules and GFM tables -- and every line is preserved: soft wraps are
//  treated as the line breaks they look like, which is what a reader expects
//  from a chat transcript.
//
//  Nothing here can throw. A half-streamed answer is the ordinary case -- an
//  unterminated fence is a message still arriving, not a parse failure -- so an
//  unclosed fence takes the rest of the text as code and everything else
//  degrades to a paragraph.
//

import Foundation

/// How one table column lines up, from the separator row.
public enum MarkdownTableAlignment: Sendable, Equatable {
    case leading
    case center
    case trailing
}

/// A GFM table: a header row, body rows, and one alignment per column.
public struct MarkdownTable: Sendable, Equatable {
    public let header: [String]
    public let rows: [[String]]
    public let alignments: [MarkdownTableAlignment]

    public init(header: [String], rows: [[String]], alignments: [MarkdownTableAlignment]) {
        self.header = header
        self.rows = rows
        self.alignments = alignments
    }

    /// The alignment of one column, defaulting to leading when the separator
    /// named fewer columns than the header has.
    ///
    /// - Parameter column: the column index.
    /// - Returns: the alignment to draw with.
    public func alignment(at column: Int) -> MarkdownTableAlignment {
        guard column >= 0, column < alignments.count else { return .leading }
        return alignments[column]
    }
}

/// One item of a list.
public struct MarkdownListItem: Sendable, Equatable {
    /// What to draw in front: `•` for a bullet, `1.` for an ordered item.
    public let marker: String
    /// Leading spaces in the source, for nesting.
    public let indent: Int
    /// The item's text, without its marker.
    public let text: String

    public init(marker: String, indent: Int, text: String) {
        self.marker = marker
        self.indent = indent
        self.text = text
    }
}

/// One block of a message.
public enum MarkdownBlock: Sendable, Equatable {
    /// Prose. Lines are joined with `\n`, because the line breaks a model wrote
    /// are breaks a reader expects to see.
    case paragraph(String)
    /// A heading, with its level as written (`#` is 1).
    case heading(level: Int, text: String)
    /// Consecutive list items.
    case list([MarkdownListItem])
    /// A block quote, its lines joined with `\n`.
    case quote(String)
    /// A fenced code block. An unterminated fence runs to the end of the text.
    case code(language: String?, text: String)
    /// A GFM table.
    case table(MarkdownTable)
    /// A horizontal rule.
    case divider

    /// An image the model wrote on its own line.
    ///
    /// Only a paragraph made *entirely* of image references becomes these: the
    /// desktop draws a standalone Markdown image as a preview and leaves an
    /// image inside a sentence as text, because a picture cannot sit in the
    /// middle of a line without either shrinking to nothing or breaking the
    /// paragraph. `alt` is what the model meant it to say -- the caption a
    /// reader gets when the picture cannot be loaded; `path` is whatever it
    /// wrote, still relative to the session's workspace more often than not.
    case image(alt: String?, path: String)
}

/// The block parser behind the conversation screen.
public enum MarkdownBlocks {
    /// Cut a message into the blocks it draws.
    ///
    /// - Parameter source: the message body, as the host sent it.
    /// - Returns: the blocks, in order. Never empty for non-empty input: text
    ///   that matches nothing becomes a paragraph.
    public static func parse(_ source: String) -> [MarkdownBlock] {
        let lines = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")

        var blocks: [MarkdownBlock] = []
        var index = 0

        while index < lines.count {
            let raw = lines[index]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)

            // A blank line separates blocks and draws nothing itself.
            if trimmed.isEmpty {
                index += 1
                continue
            }

            // Fenced code. The closing fence is optional on purpose: a reply
            // still arriving ends inside its code block, and that is exactly
            // what the reader is watching.
            if trimmed.hasPrefix("```") {
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                index += 1
                while index < lines.count {
                    if lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                        index += 1
                        break
                    }
                    body.append(lines[index])
                    index += 1
                }
                blocks.append(.code(language: language.isEmpty ? nil : language, text: body.joined(separator: "\n")))
                continue
            }

            // A table is a header row followed by a separator row. Checked
            // before headings and lists because "|" wins over every other
            // marker a row could start with.
            if let parsed = table(at: index, in: lines) {
                blocks.append(.table(parsed.table))
                index = parsed.next
                continue
            }

            if let heading = heading(trimmed) {
                blocks.append(.heading(level: heading.level, text: heading.text))
                index += 1
                continue
            }

            if isDivider(trimmed) {
                blocks.append(.divider)
                index += 1
                continue
            }

            // A quote runs until the first line that is not one.
            if trimmed.hasPrefix(">") {
                var quoted: [String] = []
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    guard candidate.hasPrefix(">") else { break }
                    var text = String(candidate.dropFirst())
                    if text.hasPrefix(" ") { text.removeFirst() }
                    quoted.append(text)
                    index += 1
                }
                blocks.append(.quote(quoted.joined(separator: "\n")))
                continue
            }

            // Consecutive list items become one block, so the view can space
            // them as a list rather than as unrelated paragraphs.
            if let first = listItem(raw) {
                var items: [MarkdownListItem] = [first]
                index += 1
                while index < lines.count, let next = listItem(lines[index]) {
                    items.append(next)
                    index += 1
                }
                blocks.append(.list(items))
                continue
            }

            // Everything else is prose, up to a blank line or the next block.
            var paragraph: [String] = []
            while index < lines.count {
                let candidate = lines[index]
                let text = candidate.trimmingCharacters(in: .whitespaces)
                if text.isEmpty || startsBlock(at: index, in: lines) { break }
                paragraph.append(text)
                index += 1
            }
            if paragraph.isEmpty {
                // Unreachable for a non-blank line that matched no block, but
                // an index that does not move is a loop that never ends.
                paragraph.append(trimmed)
                index += 1
            }
            // A paragraph that is nothing but image references is pictures, not
            // prose: the desktop draws a standalone image as a preview, and a
            // run of them stacks. Anything else keeps its text, so `见下图
            // ![](x.png)` is still the sentence the model wrote.
            if let pictures = images(in: paragraph) {
                blocks.append(contentsOf: pictures)
            } else {
                blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            }
        }

        return blocks
    }
}

// MARK: - Block recognition

private extension MarkdownBlocks {
    /// Whether a line begins a block other than a paragraph.
    ///
    /// - Parameters:
    ///   - index: the line to test.
    ///   - lines: every line of the message.
    /// - Returns: whether the paragraph being collected has to stop.
    static func startsBlock(at index: Int, in lines: [String]) -> Bool {
        let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.hasPrefix("```") { return true }
        if heading(trimmed) != nil || isDivider(trimmed) { return true }
        if trimmed.hasPrefix(">") { return true }
        if listItem(lines[index]) != nil { return true }
        if table(at: index, in: lines) != nil { return true }
        return false
    }

    /// A heading: one to six `#`, a space, then the text.
    ///
    /// - Parameter line: one trimmed line.
    /// - Returns: the level and text, or `nil` when it is not a heading.
    static func heading(_ line: String) -> (level: Int, text: String)? {
        let hashes = line.prefix { $0 == "#" }
        guard (1...6).contains(hashes.count) else { return nil }
        let rest = line.dropFirst(hashes.count)
        guard rest.hasPrefix(" ") else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return (hashes.count, text)
    }

    /// A horizontal rule: three or more of `-`, `*` or `_`, spaces allowed.
    ///
    /// - Parameter line: one trimmed line.
    /// - Returns: whether the line is a rule.
    static func isDivider(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3 else { return false }
        return compact.allSatisfy { $0 == "-" }
            || compact.allSatisfy { $0 == "*" }
            || compact.allSatisfy { $0 == "_" }
    }

    /// One list item, with its marker and nesting.
    ///
    /// - Parameter line: one raw line.
    /// - Returns: the item, or `nil` when the line does not start one.
    static func listItem(_ line: String) -> MarkdownListItem? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }.count
        let body = line.dropFirst(indent)

        if body.hasPrefix("- ") || body.hasPrefix("* ") || body.hasPrefix("+ ") {
            let text = String(body.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            return MarkdownListItem(marker: "•", indent: indent, text: text)
        }

        // Ordered: up to three digits, then "." or ")", then a space. Three
        // digits is enough for a list a message would hold, and the bound keeps
        // a line of digits from being read as one.
        let digits = body.prefix { $0.isNumber }
        guard (1...3).contains(digits.count) else { return nil }
        let rest = body.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        let text = String(rest.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return MarkdownListItem(marker: "\(digits).", indent: indent, text: text)
    }

    /// A GFM table starting at one line, if there is one.
    ///
    /// - Parameters:
    ///   - index: the candidate header row.
    ///   - lines: every line of the message.
    /// - Returns: the table and the first line after it, or `nil`.
    static func table(at index: Int, in lines: [String]) -> (table: MarkdownTable, next: Int)? {
        guard index + 1 < lines.count else { return nil }
        let headerLine = lines[index]
        guard headerLine.contains("|") else { return nil }
        guard let alignments = separatorAlignments(lines[index + 1]) else { return nil }

        let header = cells(in: headerLine)
        guard !header.isEmpty else { return nil }

        var rows: [[String]] = []
        var cursor = index + 2
        while cursor < lines.count {
            let candidate = lines[cursor]
            let trimmed = candidate.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || !candidate.contains("|") { break }
            var row = cells(in: candidate)
            if row.count < header.count {
                row += Array(repeating: "", count: header.count - row.count)
            } else if row.count > header.count {
                row = Array(row.prefix(header.count))
            }
            rows.append(row)
            cursor += 1
        }

        return (MarkdownTable(header: header, rows: rows, alignments: alignments), cursor)
    }

    /// The alignments a separator row names, or `nil` when the line is not one.
    ///
    /// - Parameter line: the line after a candidate header row.
    /// - Returns: one alignment per column.
    static func separatorAlignments(_ line: String) -> [MarkdownTableAlignment]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|") else { return nil }

        let raw = cells(in: trimmed)
        guard !raw.isEmpty else { return nil }

        var alignments: [MarkdownTableAlignment] = []
        for cell in raw {
            let text = cell.trimmingCharacters(in: .whitespaces)
            guard text.contains("-") else { return nil }
            let dashes = text.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            guard !dashes.isEmpty, dashes.allSatisfy({ $0 == "-" }) else { return nil }
            let leading = text.hasPrefix(":")
            let trailing = text.hasSuffix(":")
            if leading, trailing {
                alignments.append(.center)
            } else if trailing {
                alignments.append(.trailing)
            } else {
                alignments.append(.leading)
            }
        }
        return alignments
    }

    /// The cells of one table row, with the outer pipes and padding removed.
    ///
    /// - Parameter line: one raw table row.
    /// - Returns: the trimmed cells.
    static func cells(in line: String) -> [String] {
        var body = line.trimmingCharacters(in: .whitespaces)
        if body.hasPrefix("|") { body.removeFirst() }
        if body.hasSuffix("|") { body.removeLast() }
        return body
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

// MARK: - Images

public extension MarkdownBlocks {
    /// One image reference, as written.
    ///
    /// `![alt](dest)` and `![alt](<dest with spaces> "title")` are the shapes a
    /// model actually writes; the title is dropped because nothing draws it --
    /// the alt text is what a reader is told when the picture cannot be had.
    struct ImageReference: Sendable, Equatable {
        /// The text between the brackets, with surrounding spaces trimmed and
        /// an empty one normalised to `nil`.
        public let alt: String?
        /// What follows in the parentheses: a path or a URL, brackets stripped.
        public let destination: String

        public init(alt: String?, destination: String) {
            self.alt = alt
            self.destination = destination
        }
    }

    /// Read one image reference off the front of a string.
    ///
    /// - Parameter source: a line, trimmed.
    /// - Returns: the reference and the number of characters it took, or `nil`
    ///   when the line does not start with one.
    static func imageReference(at source: String) -> (reference: ImageReference, length: Int)? {
        let characters = Array(source)
        guard characters.count > 4, characters[0] == "!", characters[1] == "[" else { return nil }

        // The alt text: balanced brackets, so an alt that contains one survives.
        var depth = 0
        var close = -1
        var cursor = 1
        while cursor < characters.count {
            let character = characters[cursor]
            if character == "\\" {
                cursor += 2
                continue
            }
            if character == "[" { depth += 1 }
            if character == "]" {
                depth -= 1
                if depth == 0 { close = cursor; break }
            }
            cursor += 1
        }
        guard close > 0, close + 1 < characters.count, characters[close + 1] == "(" else { return nil }

        var alt = String(characters[2..<close]).trimmingCharacters(in: .whitespaces)
        alt = alt.replacingOccurrences(of: "\\]", with: "]")
            .replacingOccurrences(of: "\\[", with: "[")

        // The destination: balanced parentheses, with an optional `"title"`.
        var parens = 0
        var end = -1
        cursor = close + 1
        while cursor < characters.count {
            let character = characters[cursor]
            if character == "\\" {
                cursor += 2
                continue
            }
            if character == "(" { parens += 1 }
            if character == ")" {
                parens -= 1
                if parens == 0 { end = cursor; break }
            }
            cursor += 1
        }
        guard end > close + 2 else { return nil }

        var inside = String(characters[(close + 2)..<end]).trimmingCharacters(in: .whitespaces)
        if inside.hasPrefix("<"),
           let angle = inside.firstIndex(of: ">") {
            inside = String(inside[inside.index(after: inside.startIndex)..<angle])
        } else if let space = inside.firstIndex(where: { $0 == " " || $0 == "\t" }),
                  let quote = inside[space...].firstIndex(where: { $0 == "\"" || $0 == "'" }),
                  space < quote {
            // `dest "title"`: keep the destination, drop the title.
            inside = String(inside[..<space])
        }
        inside = inside.trimmingCharacters(in: .whitespaces)
        guard !inside.isEmpty else { return nil }

        return (ImageReference(alt: alt.isEmpty ? nil : alt, destination: inside), end + 1)
    }

    /// Every image reference a paragraph is made of, when it is made of nothing
    /// else.
    ///
    /// - Parameter lines: the paragraph's trimmed lines.
    /// - Returns: one block per reference, or `nil` when the paragraph carries
    ///   any prose and has to stay text.
    static func images(in lines: [String]) -> [MarkdownBlock]? {
        var found: [MarkdownBlock] = []
        for line in lines {
            var rest = Substring(line)
            var placed = false
            while true {
                rest = rest.drop(while: { $0 == " " || $0 == "\t" })
                guard !rest.isEmpty else { break }
                guard let parsed = imageReference(at: String(rest)) else { break }
                found.append(.image(alt: parsed.reference.alt, path: parsed.reference.destination))
                placed = true
                rest = rest.dropFirst(parsed.length)
            }
            // A line with text beside the picture is prose; so is a line with
            // nothing this parser recognised.
            if !placed || !rest.trimmingCharacters(in: .whitespaces).isEmpty {
                return nil
            }
        }
        return found.isEmpty ? nil : found
    }
}
