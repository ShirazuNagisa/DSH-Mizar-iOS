//
//  MarkdownMessage.swift
//  DSH-Mizar
//
//  A model's answer, drawn block by block.
//
//  `Text` cannot draw the shape of a Markdown message. Given an
//  `AttributedString` parsed with `.full`, it renders characters and inline
//  attributes only: the paragraphs, list items, headings and tables live in
//  `presentationIntent`, and the characters themselves come back with no line
//  breaks -- measured, "第一行\n第二行" parses to "第一行 第二行". So a summary
//  arrived as one run-on paragraph, a list lost its bullets, and a table became
//  "列A列B12".
//
//  `MizarKit.MarkdownBlocks` cuts the message into blocks; this draws them.
//  Inline styling (bold, italic, code, links) is still the system's own
//  parser -- one line at a time, where it cannot swallow a line break.
//

import SwiftUI
import MizarKit
import UIKit

/// What to do when a link in a message points at a file on the computer.
///
/// Carried in the environment rather than passed down through the typewriter:
/// the typewriter redraws its blocks frame by frame while an answer arrives, and
/// a closure in its initialiser would change identity on every one of those
/// frames. The environment is read once by the block view that actually draws
/// the links.
private struct OpenDeliveredFileKey: EnvironmentKey {
    static let defaultValue: (@MainActor (String) -> Void)? = nil
}

extension EnvironmentValues {
    /// Called with the path when a tapped link names a file the app can preview.
    var openDeliveredFile: (@MainActor (String) -> Void)? {
        get { self[OpenDeliveredFileKey.self] }
        set { self[OpenDeliveredFileKey.self] = newValue }
    }
}

/// A message body drawn as the blocks it is made of.
struct MarkdownMessage: View {
    /// The raw text, kept for VoiceOver: what is read is what was said, not the
    /// rendering of it.
    private let source: String
    private let blocks: [MarkdownBlock]

    init(_ source: String) {
        self.source = source
        self.blocks = MarkdownBlocks.parse(source)
    }

    var body: some View {
        MarkdownBlocksView(blocks: blocks)
            .textSelection(.enabled)
            // The whole message, not the rendering of it -- and, for a reveal,
            // not only the part that has been typed. An answer must be readable
            // by VoiceOver, and findable by a test, while it is still arriving.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(source)
    }
}

/// A message's blocks, drawn.
///
/// Kept apart from ``MarkdownMessage`` so the typewriter can draw the same
/// blocks cut down to what has been typed, frame after frame, without parsing
/// the Markdown again on every one of them. The parse happens once when the
/// message arrives; a reveal only moves the boundary.
struct MarkdownBlocksView: View {
    let blocks: [MarkdownBlock]

    /// Where a tapped local link goes, when this screen has somewhere to send it.
    @Environment(\.openDeliveredFile) private var openDeliveredFile
    /// Dark mode draws links in white, the accent colour, which is the same
    /// colour as body text there. An underline is the only thing left that says
    /// "this is a file that opens".
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm + 2) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // One place decides what a link does, and it decides for every link in
        // the message. A model writes file references as Markdown links --
        // measured over 290 session logs, `[x](<Sources/App/A.swift#L12>)` and
        // `[x](/absolute/path.pdf)`, never a `file://` URL -- so a plain
        // `Text` link sent them to Safari, which cannot open a path on the
        // computer and silently did nothing. A previewable one now opens the
        // drawer's preview page instead.
        .environment(\.openURL, OpenURLAction { url in
            if let path = LocalFileLink.path(in: url),
               PreviewKind(fileName: path).isPreviewable,
               let openDeliveredFile {
                openDeliveredFile(path)
                return .handled
            }
            // A path on the computer this app cannot draw, or a scheme nothing
            // here understands: swallowed rather than handed to Safari, which
            // would offer to search the web for a file name.
            if url.scheme == nil || url.scheme?.lowercased() == "file" {
                return .discarded
            }
            return .systemAction
        })
    }

    // MARK: - Blocks

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let text):
            inline(text)
                .fixedSize(horizontal: false, vertical: true)

        case .heading(let level, let text):
            inline(text)
                .font(headingFont(level))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, level <= 2 ? 4 : 2)

        case .list(let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(item.marker)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 18, alignment: .trailing)
                        inline(item.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    // Nested items keep their own indent; the marker column is
                    // shared so a numbered list lines up on the dot.
                    .padding(.leading, CGFloat(item.indent) * 6)
                }
            }

        case .quote(let text):
            // The bar is an overlay on the text rather than a sibling in an
            // HStack: a shape has no height of its own, so as a sibling it
            // stretches to whatever the row is offered -- measured, a quote
            // drew a full-screen vertical line.
            inline(text)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 13)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(Color.primary.opacity(0.18))
                        .frame(width: 3)
                }

        case .code(let language, let text):
            codeBlock(language: language, text: text)

        case .table(let table):
            tableView(table)

        case .divider:
            Rectangle()
                .fill(Color.primary.opacity(0.12))
                .frame(height: 0.5)
                .padding(.vertical, 2)
        }
    }

    // MARK: - Parts

    /// One line (or paragraph) of inline Markdown.
    ///
    /// Inline-only, preserving whitespace: emphasis, code spans and links are
    /// styled, and every newline inside the run stays a newline. A string the
    /// system parser refuses is drawn verbatim rather than dropped.
    private func inline(_ string: String) -> Text {
        inlineMarkdown(string, underlinePreviewLinks: colorScheme == .dark)
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1, 2: .title3.weight(.semibold)
        case 3, 4: .headline
        default: .subheadline.weight(.semibold)
        }
    }

    private func codeBlock(language: String?, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let language, !language.isEmpty {
                Text(language.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                // An empty fence still needs a line's height, or the block
                // collapses to a border with nothing inside it.
                Text(text.isEmpty ? " " : text)
                    .font(.system(.callout, design: .monospaced))
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            // A horizontal ScrollView is greedy in both directions unless told
            // otherwise; without this the block took the whole screen's height.
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(2)
        .background(
            Color.primary.opacity(0.05),
            in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous),
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5),
        )
    }

    /// A GFM table, as a grid that scrolls sideways when it is wider than the
    /// column of text it sits in.
    ///
    /// The grid is split out into ``MarkdownTableGrid`` because the horizontal
    /// scroller is what made cells truncate: a `ScrollView` proposes an
    /// unspecified width, `Grid` measured every cell as one line, and the
    /// `maxWidth` clamp then left the text with a single line to draw in. The
    /// grid measures its own columns and gives each a definite width, so a cell
    /// that does not fit wraps and its row grows.
    private func tableView(_ table: MarkdownTable) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            MarkdownTableGrid(table: table)
        }
        // Same reason as the code block: a horizontal scroll view left to
        // itself takes the height it is offered, which in a conversation row is
        // the rest of the screen.
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - The table grid

/// A GFM table's grid, without the scroller around it.
///
/// Inside a horizontal `ScrollView` the grid is measured with an unspecified
/// width, and a `Text` given one reports its single-line size. Clamping that
/// with a flexible frame left every row one line tall, so a long cell was cut
/// off with an ellipsis. A definite width per column is what makes the text
/// wrap instead: the width its own text asks for, clamped to the band the
/// flexible frame used to express, so short tables keep the widths they had.
///
/// Split out from the view above for the snapshot suite as well:
/// `ImageRenderer` draws a `Grid` and draws nothing inside a `ScrollView`, so
/// this is the largest piece of the table that can be pinned as a reference.
struct MarkdownTableGrid: View {
    let table: MarkdownTable

    /// The band a column may occupy. The same numbers the old flexible frame
    /// used, so a short table does not change size.
    private static let minWidth: CGFloat = 84
    private static let maxWidth: CGFloat = 220

    var body: some View {
        let widths = Self.columnWidths(for: table)
        Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(table.header.indices, id: \.self) { column in
                    tableCell(
                        table.header[column],
                        alignment: table.alignment(at: column),
                        isHeader: true,
                        fill: Color.primary.opacity(0.06),
                        width: widths[column],
                    )
                }
            }
            ForEach(table.rows.indices, id: \.self) { row in
                GridRow {
                    ForEach(table.header.indices, id: \.self) { column in
                        tableCell(
                            table.rows[row][column],
                            alignment: table.alignment(at: column),
                            isHeader: false,
                            fill: row.isMultiple(of: 2) ? .clear : Color.primary.opacity(0.03),
                            width: widths[column],
                        )
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5),
        )
    }

    // MARK: - Measuring

    /// How wide each column is, from the widest thing it has to hold.
    ///
    /// Measured with the same text style the cells are drawn in, so Dynamic
    /// Type and CJK widths are the layout engine's answer rather than a count
    /// of characters. Inline markup is stripped exactly as ``inlineMarkdown``
    /// strips it; bold runs measure a hair narrow, which only wraps a line
    /// earlier and never truncates one.
    ///
    /// - Parameter table: the table.
    /// - Returns: one width per column, in the 84...220 band.
    static func columnWidths(for table: MarkdownTable) -> [CGFloat] {
        let body = UIFont.preferredFont(forTextStyle: .callout)
        let header = UIFont.systemFont(ofSize: body.pointSize, weight: .semibold)
        return table.header.indices.map { column in
            var widest = measuredWidth(of: table.header[column], font: header)
            for row in table.rows where column < row.count {
                widest = max(widest, measuredWidth(of: row[column], font: body))
            }
            return min(max((widest + 2).rounded(.up), minWidth), maxWidth)
        }
    }

    private static func measuredWidth(of markdown: String, font: UIFont) -> CGFloat {
        let plain = (try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace),
        )).map { String($0.characters) } ?? markdown
        return (plain as NSString).size(withAttributes: [.font: font]).width
    }

    // MARK: - One cell

    private func tableCell(
        _ text: String,
        alignment: MarkdownTableAlignment,
        isHeader: Bool,
        fill: Color,
        width: CGFloat,
    ) -> some View {
        inlineMarkdown(text)
            .font(isHeader ? .callout.weight(.semibold) : .callout)
            .multilineTextAlignment(alignment.tableTextAlignment)
            .frame(width: width, alignment: alignment.tableAlignment)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(fill)
            // Row and column lines, drawn inside the cell so the grid needs no
            // divider rows of its own.
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.primary.opacity(0.10))
                    .frame(height: 0.5)
            }
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                    .frame(width: 0.5)
            }
    }
}

// MARK: - Inline Markdown

/// One line (or paragraph) of inline Markdown.
///
/// Shared by the block renderer and the table grid. Inline-only, preserving
/// whitespace: emphasis, code spans and links are styled, and every newline
/// inside the run stays a newline. A string the system parser refuses is drawn
/// verbatim rather than dropped.
private func inlineMarkdown(_ string: String, underlinePreviewLinks: Bool = false) -> Text {
    if var attributed = try? AttributedString(
        markdown: string,
        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace),
    ) {
        if underlinePreviewLinks {
            // File links are the app's accent colour. In dark mode the accent
            // is white, so the link and the sentence look identical; the
            // underline is the affordance, not decoration.
            let ranges = attributed.runs.compactMap { run -> Range<AttributedString.Index>? in
                guard let link = run.link,
                      let path = LocalFileLink.path(in: link),
                      PreviewKind(fileName: path).isPreviewable else { return nil }
                return run.range
            }
            for range in ranges {
                attributed[range].underlineStyle = .single
            }
        }
        return Text(attributed)
    }
    return Text(string)
}

private extension MarkdownTableAlignment {
    var tableAlignment: Alignment {
        switch self {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    var tableTextAlignment: TextAlignment {
        switch self {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}
