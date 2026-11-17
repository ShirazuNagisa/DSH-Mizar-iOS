//
//  ComposerTokensTests.swift
//  MizarKitTests
//
//  The token scanner is the one part of the composer's pills that has no view:
//  it decides what is a command, what is prose, and when the palette's hint is
//  allowed to appear. Everything the editor does with the answer — attachments,
//  capsules, truncation — is only drawing.
//

import Foundation
import Testing
@testable import MizarKit

@Suite("Composer tokens")
struct ComposerTokensTests {
    private let names = ["goal", "plan", "grilling", "grill", "icon-draw"]

    @Test func aTokenAtTheStartIsFound() {
        let tokens = ComposerTokens.scan("/goal ", names: names)
        #expect(tokens.count == 1)
        #expect(tokens.first?.name == "goal")
        #expect(tokens.first?.range == NSRange(location: 0, length: 5))
        #expect(tokens.first?.literal == "/goal")
    }

    @Test func aTokenAfterWhitespaceIsFound() {
        let text = "please /plan this"
        let tokens = ComposerTokens.scan(text, names: names)
        #expect(tokens.map(\.name) == ["plan"])
        #expect(tokens.first?.range == NSRange(location: 7, length: 5))
    }

    @Test func aTokenAtTheEndWithoutTrailingSpaceIsFound() {
        let tokens = ComposerTokens.scan("/goal", names: names)
        #expect(tokens.count == 1)
    }

    @Test func aSlashInsideAWordIsNotAToken() {
        #expect(ComposerTokens.scan("see/goal now", names: names).isEmpty)
        #expect(ComposerTokens.scan("a/b", names: ["b"]).isEmpty)
    }

    @Test func aLongerWordIsNotAToken() {
        // `/goals` and `/goal,` are words nobody defined; pill-ing them would
        // claim the host understands something it does not.
        #expect(ComposerTokens.scan("/goals ", names: names).isEmpty)
        #expect(ComposerTokens.scan("/goal, then", names: names).isEmpty)
    }

    @Test func theLongestNameWinsAtOnePosition() {
        // `/grill-me` must not be read as `/grill` plus prose.
        let tokens = ComposerTokens.scan("/grill-me and /grill", names: ["grill", "grill-me"])
        #expect(tokens.map(\.name) == ["grill-me", "grill"])
        #expect(tokens.first?.range == NSRange(location: 0, length: 9))
    }

    @Test func severalTokensAreFoundInOrder() {
        let tokens = ComposerTokens.scan("/goal then /plan and /icon-draw", names: names)
        #expect(tokens.map(\.name) == ["goal", "plan", "icon-draw"])
        #expect(tokens.map(\.range.location) == [0, 11, 21])
    }

    @Test func anyWhitespaceSeparatesWords() {
        #expect(ComposerTokens.scan("/goal\n", names: names).count == 1)
        #expect(ComposerTokens.scan("\t/goal", names: names).count == 1)
        #expect(ComposerTokens.scan("前 /goal", names: names).count == 1)
        // An ideographic space is whitespace too.
        #expect(ComposerTokens.scan("\u{3000}/goal", names: names).count == 1)
    }

    @Test func emptyAndUnknownTextIsEmpty() {
        #expect(ComposerTokens.scan("", names: names).isEmpty)
        #expect(ComposerTokens.scan("/nope ", names: names).isEmpty)
        #expect(ComposerTokens.scan("/goal ", names: []).isEmpty)
    }

    @Test func aLoneSlashIsRecognisedAtTheCaret() {
        #expect(ComposerTokens.isLoneSlashToken("/", caret: 1))
        #expect(ComposerTokens.isLoneSlashToken("hi /", caret: 4))
        #expect(ComposerTokens.isLoneSlashToken("/ goal", caret: 1))
        #expect(ComposerTokens.isLoneSlashToken("\n/", caret: 2))
    }

    @Test func aSlashWithMoreTextIsNotLone() {
        #expect(!ComposerTokens.isLoneSlashToken("/g", caret: 2))
        #expect(!ComposerTokens.isLoneSlashToken("/goal", caret: 5))
        #expect(!ComposerTokens.isLoneSlashToken("/", caret: 0))
        #expect(!ComposerTokens.isLoneSlashToken("", caret: 0))
        // `a/` is not a word start.
        #expect(!ComposerTokens.isLoneSlashToken("a/", caret: 2))
        // The caret after the space following the slash has left the token.
        #expect(!ComposerTokens.isLoneSlashToken("/ ", caret: 2))
    }

    @Test func theCaretPositionIsUTF16() {
        // An emoji is two UTF-16 units; a caret after `😀 /` is at 4.
        let text = "😀 /"
        #expect(ComposerTokens.isLoneSlashToken(text, caret: (text as NSString).length))
        let tokens = ComposerTokens.scan("😀 /goal ", names: names)
        #expect(tokens.first?.range == NSRange(location: 3, length: 5))
    }
}
