//
//  ConversationImageTests.swift
//  MizarKitTests
//
//  The phone's half of a picture in an answer: which paths it will fetch, what
//  it refuses before spending a frame, and how the bytes come back.
//
//  The wire is faked here on purpose. `FileReader` is already tested against a
//  scripted bridge, so these tests are about the *policy* on top of it: the
//  extension and media type gate, the size ceiling checked before a read, and
//  the failure a reader can act on when the host says no.
//

import Foundation
import Testing

@testable import MizarKit

struct ConversationImageTests {
    // MARK: - Policy

    @Test("only pictures this client draws are accepted by extension")
    func extensionGate() {
        #expect(ConversationImagePolicy.accepts(path: "docs/shot.png"))
        #expect(ConversationImagePolicy.accepts(path: "docs/shot.JPG"))
        #expect(ConversationImagePolicy.accepts(path: "shots/a.webp"))
        #expect(ConversationImagePolicy.accepts(path: "shots/a.gif"))
        #expect(!ConversationImagePolicy.accepts(path: "docs/report.pdf"))
        #expect(!ConversationImagePolicy.accepts(path: "docs/notes"))
        #expect(!ConversationImagePolicy.accepts(path: "Makefile"))
    }

    @Test("the size ceiling has a bottom as well as a top")
    func sizeGate() {
        #expect(ConversationImagePolicy.accepts(bytes: 0))
        #expect(ConversationImagePolicy.accepts(bytes: 1))
        #expect(ConversationImagePolicy.accepts(bytes: ConversationImagePolicy.maximumBytes))
        #expect(!ConversationImagePolicy.accepts(bytes: ConversationImagePolicy.maximumBytes + 1))
    }

    @Test("a fragment is not part of the path that is read")
    func fragmentIsDropped() {
        let target = ConversationImageTarget(path: "docs/shot.png#L3")
        #expect(target.lookupPath == "docs/shot.png")
    }

    @Test("a network picture is not a local file")
    func remoteIsNotLocal() {
        #expect(!ConversationImageTarget(path: "https://example.com/a.png").isLocal)
        #expect(ConversationImageTarget(path: "file:///tmp/a.png").isLocal)
        #expect(ConversationImageTarget(path: "C:/shots/a.png").isLocal)
        #expect(ConversationImageTarget(path: "docs/a.png").isLocal)
    }

    @Test("the target a block names, and nothing for prose")
    func targetFromBlock() {
        let target = ConversationImageTarget(block: .image(alt: "图", path: "a.png"))
        #expect(target == ConversationImageTarget(path: "a.png", alt: "图"))
        #expect(ConversationImageTarget(block: .paragraph("a.png")) == nil)
    }

    @Test("host codes map to what a reader can act on")
    func failureMapping() {
        #expect(ConversationImageFailure(code: "FILE_UNKNOWN") == .missing)
        #expect(ConversationImageFailure(code: "FILE_FORBIDDEN") == .forbidden)
        #expect(ConversationImageFailure(code: "FILE_TOO_LARGE") == .tooLarge)
        #expect(ConversationImageFailure(code: "NOT_IMPLEMENTED") == .oldPlugin)
        #expect(ConversationImageFailure(code: "PREVIEW_LOCKED") == .locked)
        #expect(ConversationImageFailure(code: "NO_CONNECTION") == .offline)
        #expect(ConversationImageFailure(code: "SOMETHING_NEW") == .unreadable)
    }

    // MARK: - Fetching

    /// A bridge whose `file.stat` and `file.read` answer from one body.
    private func bridge(
        body: Data,
        mediaType: String = "image/png",
        name: String = "shot.png",
        statError: String? = nil,
        readError: String? = nil,
        recorded: Recorder = Recorder(),
    ) -> ConversationImageFetcher {
        let reader = FileReader { method, payload in
            switch method {
            case "file.stat":
                await recorded.note("stat")
                if let statError {
                    throw MizarError(code: statError, message: statError)
                }
                return .object([
                    "path": payload["path"] ?? .string(""),
                    "name": .string(name),
                    "byteSize": .number(Double(body.count)),
                    "modifiedAt": .number(1_760_000_000_000),
                    "mediaType": .string(mediaType),
                    "previewable": .bool(true),
                ])
            case "file.read":
                await recorded.note("read")
                if let readError {
                    throw MizarError(code: readError, message: readError)
                }
                let offset = Int(payload["offset"]?.numberValue ?? 0)
                let length = Int(payload["length"]?.numberValue ?? 0)
                let slice = body.subdata(in: offset..<min(body.count, offset + length))
                return .object([
                    "offset": .number(Double(offset)),
                    "length": .number(Double(slice.count)),
                    "byteSize": .number(Double(body.count)),
                    "data": .string(slice.base64EncodedString()),
                    "eof": .bool(offset + slice.count >= body.count),
                ])
            default:
                throw MizarError(code: "NOT_IMPLEMENTED", message: method)
            }
        }
        return ConversationImageFetcher(reader: reader)
    }

    @Test("a picture comes back whole, in slices, with its facts")
    func happyPath() async throws {
        // Larger than one slice, so the loop has to ask twice.
        let body = Data(repeating: 0x41, count: FileReader.chunkBytes + 700)
        let recorded = Recorder()
        let fetcher = bridge(body: body, recorded: recorded)
        let payload = try await fetcher.fetch(
            sessionId: "s1",
            target: ConversationImageTarget(path: "shots/chart.png"),
        )
        #expect(payload.data == body)
        #expect(payload.byteSize == body.count)
        #expect(payload.mediaType == "image/png")
        #expect(payload.name == "shot.png")
        #expect(await recorded.events == ["stat", "read", "read"])
    }

    @Test("a missing file is missing, not a crash")
    func missingFile() async {
        let fetcher = bridge(body: Data(), statError: "FILE_UNKNOWN")
        await #expect(throws: ConversationImageFailure.missing) {
            try await fetcher.fetch(sessionId: "s1", target: ConversationImageTarget(path: "a.png"))
        }
    }

    @Test("a path outside the workspace is refused as forbidden")
    func forbiddenFile() async {
        let fetcher = bridge(body: Data(), statError: "FILE_FORBIDDEN")
        await #expect(throws: ConversationImageFailure.forbidden) {
            try await fetcher.fetch(sessionId: "s1", target: ConversationImageTarget(path: "a.png"))
        }
    }

    @Test("a file over the ceiling is refused before a byte is read")
    func tooLargeIsRefusedBeforeReading() async throws {
        let body = Data(repeating: 0x41, count: ConversationImagePolicy.maximumBytes + 1)
        let recorded = Recorder()
        let fetcher = bridge(body: body, recorded: recorded)
        await #expect(throws: ConversationImageFailure.tooLarge) {
            try await fetcher.fetch(sessionId: "s1", target: ConversationImageTarget(path: "a.png"))
        }
        #expect(await recorded.events == ["stat"])
    }

    @Test("a text file the model pointed at is not a picture")
    func notAnImage() async {
        let fetcher = bridge(body: Data("hello".utf8), mediaType: "text/plain", name: "a.txt")
        await #expect(throws: ConversationImageFailure.notAnImage) {
            try await fetcher.fetch(sessionId: "s1", target: ConversationImageTarget(path: "a.txt"))
        }
    }

    @Test("pictures are free on a local network, paid over the relay, and never on the direct path")
    func accessRule() {
        // Paid, whatever the link: theirs.
        #expect(InlinePictureAccess.isEntitled(isPaid: true, isLocalNetwork: false, isDirectPath: false, isLocalAgent: false))
        // Free on the operator's own wires: the relay is not carrying anything.
        #expect(InlinePictureAccess.isEntitled(isPaid: false, isLocalNetwork: true, isDirectPath: false, isLocalAgent: false))
        // Free over the relay: the bytes are the project's bandwidth, so no.
        #expect(!InlinePictureAccess.isEntitled(isPaid: false, isLocalNetwork: false, isDirectPath: false, isLocalAgent: false))
        // The direct path carries no files for anybody, paid included.
        #expect(!InlinePictureAccess.isEntitled(isPaid: true, isLocalNetwork: false, isDirectPath: true, isLocalAgent: false))
        #expect(!InlinePictureAccess.isEntitled(isPaid: false, isLocalNetwork: true, isDirectPath: true, isLocalAgent: false))
        // The on-device agent has no file RPC to serve a picture from.
        #expect(!InlinePictureAccess.isEntitled(isPaid: true, isLocalNetwork: true, isDirectPath: false, isLocalAgent: true))
    }

    @Test("a network URL is refused without touching the bridge")
    func remoteIsNotFetched() async throws {
        let recorded = Recorder()
        let fetcher = bridge(body: Data(repeating: 1, count: 8), recorded: recorded)
        await #expect(throws: ConversationImageFailure.notAnImage) {
            try await fetcher.fetch(
                sessionId: "s1",
                target: ConversationImageTarget(path: "https://example.com/a.png"),
            )
        }
        #expect(await recorded.events.isEmpty)
    }

    @Test("a slice the host could not cut is unreadable")
    func stalledSlice() async {
        let fetcher = bridge(body: Data(repeating: 1, count: 8), readError: "FILE_SLICE_STALLED")
        await #expect(throws: ConversationImageFailure.unreadable) {
            try await fetcher.fetch(sessionId: "s1", target: ConversationImageTarget(path: "a.png"))
        }
    }

    // MARK: - Reveal

    @Test("a picture is not typed onto the page, and waits for the text before it")
    func revealHoldsPictures() {
        let blocks: [MarkdownBlock] = [
            .paragraph("做完了。"),
            .image(alt: "图", path: "a.png"),
        ]
        #expect(MarkdownReveal.characterCount(blocks) == 4)
        #expect(MarkdownReveal.blocks(blocks, visibleCharacters: 0).isEmpty)
        #expect(MarkdownReveal.blocks(blocks, visibleCharacters: 2) == [.paragraph("做完")])
        #expect(MarkdownReveal.blocks(blocks, visibleCharacters: 4) == blocks)
    }

    @Test("a picture at the very end appears once the reveal finishes")
    func revealFinishesWithThePicture() {
        let blocks: [MarkdownBlock] = [.image(alt: nil, path: "a.png")]
        #expect(MarkdownReveal.characterCount(blocks) == 0)
        #expect(MarkdownReveal.blocks(blocks, visibleCharacters: 0).isEmpty)
    }
}

/// Records what the fake bridge was asked for, in order.
actor Recorder {
    private(set) var events: [String] = []

    func note(_ event: String) {
        events.append(event)
    }
}
