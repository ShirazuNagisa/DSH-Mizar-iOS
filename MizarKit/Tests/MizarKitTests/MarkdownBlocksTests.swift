//
//  MarkdownBlocksTests.swift
//  MizarKitTests
//
//  The block parser behind the conversation screen.
//
//  The bug it replaces: `.full` Markdown parsing put the shape of a message into
//  `presentationIntent` and left the characters with no line breaks, so a
//  summary arrived as one run-on paragraph and a table as "列A列B12". These
//  tests pin the shape that was lost -- line breaks, lists, headings, quotes,
//  code and tables -- with the blocks the view draws them from.
//

import Foundation
import Testing

@testable import MizarKit

struct MarkdownBlocksTests {
    @Test("line breaks inside a paragraph survive")
    func paragraphKeepsLines() {
        let blocks = MarkdownBlocks.parse("第一行\n第二行")
        #expect(blocks == [.paragraph("第一行\n第二行")])
    }

    @Test("a blank line separates paragraphs")
    func blankLineSplitsParagraphs() {
        let blocks = MarkdownBlocks.parse("第一段\n\n第二段")
        #expect(blocks == [.paragraph("第一段"), .paragraph("第二段")])
    }

    @Test("CRLF is read as a line break, not as characters")
    func crlfIsNormalised() {
        let blocks = MarkdownBlocks.parse("一\r\n二")
        #expect(blocks == [.paragraph("一\n二")])
    }

    @Test("headings carry their level")
    func headings() {
        #expect(MarkdownBlocks.parse("# 标题") == [.heading(level: 1, text: "标题")])
        #expect(MarkdownBlocks.parse("### 三级") == [.heading(level: 3, text: "三级")])
    }

    @Test("a body that is only a heading is still a heading")
    func headingAtTheStart() {
        // The gate this parser is reached through used to look for "\n# ", so a
        // short reply that was a heading and nothing else never got parsed and
        // was drawn with its hashes visible.
        #expect(MarkdownBlocks.parse("# 结论") == [.heading(level: 1, text: "结论")])
    }

    @Test("consecutive bullets become one list")
    func bulletList() {
        let blocks = MarkdownBlocks.parse("- 一\n- 二")
        #expect(
            blocks == [
                .list([
                    MarkdownListItem(marker: "•", indent: 0, text: "一"),
                    MarkdownListItem(marker: "•", indent: 0, text: "二"),
                ]),
            ],
        )
    }

    @Test("an ordered list keeps its numbers")
    func orderedList() {
        let blocks = MarkdownBlocks.parse("1. 一\n2. 二")
        #expect(
            blocks == [
                .list([
                    MarkdownListItem(marker: "1.", indent: 0, text: "一"),
                    MarkdownListItem(marker: "2.", indent: 0, text: "二"),
                ]),
            ],
        )
    }

    @Test("indentation is kept for nested items")
    func nestedList() {
        let blocks = MarkdownBlocks.parse("- 一\n  - 一点一")
        guard case .list(let items) = blocks.first else {
            Issue.record("expected a list, got \(blocks)")
            return
        }
        #expect(items.count == 2)
        #expect(items[1].indent == 2)
        #expect(items[1].text == "一点一")
    }

    @Test("a quote runs until the first line that is not one")
    func quote() {
        let blocks = MarkdownBlocks.parse("> 引用一\n> 引用二\n正文")
        #expect(blocks == [.quote("引用一\n引用二"), .paragraph("正文")])
    }

    @Test("a fenced block keeps its language and every line")
    func fencedCode() {
        let source = "```swift\nlet x = 1\n\nprint(x)\n```\n后文"
        let blocks = MarkdownBlocks.parse(source)
        #expect(blocks == [.code(language: "swift", text: "let x = 1\n\nprint(x)"), .paragraph("后文")])
    }

    @Test("an unterminated fence takes the rest as code")
    func unterminatedFence() {
        // A reply still arriving ends inside its fence; that is what the reader
        // is watching, not a parse failure.
        let blocks = MarkdownBlocks.parse("```\n还在来")
        #expect(blocks == [.code(language: nil, text: "还在来")])
    }

    @Test("a table is cut into header, rows and alignments")
    func table() {
        let source = """
        | 名称 | 状态 | 备注 |
        |:--|:-:|--:|
        | A | 运行 | 无 |
        | B | 停止 | 有 |
        """
        let blocks = MarkdownBlocks.parse(source)
        guard case .table(let table) = blocks.first, blocks.count == 1 else {
            Issue.record("expected one table, got \(blocks)")
            return
        }
        #expect(table.header == ["名称", "状态", "备注"])
        #expect(table.rows == [["A", "运行", "无"], ["B", "停止", "有"]])
        #expect(table.alignments == [.leading, .center, .trailing])
    }

    @Test("a short row is padded to the header's width")
    func shortRow() {
        let source = """
        | a | b | c |
        |---|---|---|
        | 1 | 2 |
        """
        guard case .table(let table) = MarkdownBlocks.parse(source).first else {
            Issue.record("expected a table")
            return
        }
        #expect(table.rows == [["1", "2", ""]])
    }

    @Test("pipes without a separator are prose, not a table")
    func pipesWithoutSeparator() {
        let source = "a | b 是两种可能\n下一行"
        let blocks = MarkdownBlocks.parse(source)
        #expect(blocks == [.paragraph("a | b 是两种可能\n下一行")])
    }

    @Test("a rule is a rule, and a table separator alone is not a table")
    func divider() {
        #expect(MarkdownBlocks.parse("---") == [.divider])
        #expect(MarkdownBlocks.parse("***") == [.divider])
    }

    @Test("plain text is one paragraph and loses nothing")
    func plainText() {
        let text = "就是一句话"
        #expect(MarkdownBlocks.parse(text) == [.paragraph(text)])
    }

    @Test("a block marker stops the paragraph before it")
    func blockMarkerEndsParagraph() {
        let blocks = MarkdownBlocks.parse("说明:\n- 一\n- 二")
        #expect(
            blocks == [
                .paragraph("说明:"),
                .list([
                    MarkdownListItem(marker: "•", indent: 0, text: "一"),
                    MarkdownListItem(marker: "•", indent: 0, text: "二"),
                ]),
            ],
        )
    }

    @Test("a line that is only an image becomes a picture block")
    func standaloneImage() {
        #expect(
            MarkdownBlocks.parse("![实时活动浅/深与灵动岛](docs/evidence/shot.png)")
                == [.image(alt: "实时活动浅/深与灵动岛", path: "docs/evidence/shot.png")],
        )
    }

    @Test("an image with no alt text keeps a nil caption")
    func imageWithoutAlt() {
        #expect(
            MarkdownBlocks.parse("![](docs/a.png)")
                == [.image(alt: nil, path: "docs/a.png")],
        )
    }

    @Test("a run of images is a run of picture blocks")
    func imageRun() {
        let blocks = MarkdownBlocks.parse("![一](a.png)\n![二](b.jpg)")
        #expect(
            blocks == [
                .image(alt: "一", path: "a.png"),
                .image(alt: "二", path: "b.jpg"),
            ],
        )
    }

    @Test("two images on one line are two blocks")
    func twoImagesOnOneLine() {
        #expect(
            MarkdownBlocks.parse("![](a.png) ![](b.png)")
                == [.image(alt: nil, path: "a.png"), .image(alt: nil, path: "b.png")],
        )
    }

    @Test("an angle-bracketed destination keeps its spaces, a title is dropped")
    func imageDestinationForms() {
        #expect(
            MarkdownBlocks.parse("![图](<docs/some shot.png>)")
                == [.image(alt: "图", path: "docs/some shot.png")],
        )
        #expect(
            MarkdownBlocks.parse("![图](docs/shot.png \"the shot\")")
                == [.image(alt: "图", path: "docs/shot.png")],
        )
    }

    @Test("an image inside a sentence stays prose")
    func inlineImageStaysText() {
        let source = "见下图 ![图](a.png) 里面的按钮"
        #expect(MarkdownBlocks.parse(source) == [.paragraph(source)])
    }

    @Test("an image followed by a caption line is prose")
    func imageWithCaptionLine() {
        let source = "![图](a.png)\n这是说明"
        #expect(MarkdownBlocks.parse(source) == [.paragraph(source)])
    }

    @Test("a picture between paragraphs splits them")
    func imageBetweenParagraphs() {
        let blocks = MarkdownBlocks.parse("前文\n\n![图](a.png)\n\n后文")
        #expect(
            blocks == [
                .paragraph("前文"),
                .image(alt: "图", path: "a.png"),
                .paragraph("后文"),
            ],
        )
    }

    @Test("the image reference parser reads one reference and its length")
    func imageReferenceAt() {
        let parsed = MarkdownBlocks.imageReference(at: "![奖杯](a/b.png) 尾巴")
        #expect(parsed?.reference == MarkdownBlocks.ImageReference(alt: "奖杯", destination: "a/b.png"))
        #expect(parsed?.length == 14)
        #expect(MarkdownBlocks.imageReference(at: "不是图片") == nil)
        #expect(MarkdownBlocks.imageReference(at: "![空]()") == nil)
    }
}
