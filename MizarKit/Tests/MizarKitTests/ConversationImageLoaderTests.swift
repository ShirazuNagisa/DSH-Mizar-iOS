//
//  ConversationImageLoaderTests.swift
//  MizarKitTests
//
//  The picture this phone keeps, and when it uses it.
//
//  The transcript is stored on the phone, so the pictures in it have to be: a
//  phone that loses the computer keeps the words and had been losing the
//  pictures, which left holes in answers that used to have screenshots. What
//  these tests pin is the rule around the copy -- drawn without a transfer when
//  the host agrees it is current, drawn without a host at all when there is one,
//  and never drawn when the host says the file is not there.
//

import Foundation
import Testing

@testable import MizarKit

@Suite("Conversation pictures on disk")
struct ConversationImageLoaderTests {
    /// A cache in a folder of its own, so one test cannot see another's bytes.
    private func temporaryCache() -> FilePreviewCache {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mizar-image-tests-\(UUID().uuidString)", isDirectory: true)
        return FilePreviewCache(directory: directory)
    }

    /// A bridge that can be online, offline, or refusing, and counts its calls.
    private final class Bridge: @unchecked Sendable {
        enum Mode {
            case online
            /// The computer cannot be reached.
            case offline
            /// The computer answered: this file is not there.
            case refused
        }

        var mode: Mode = .online
        var body: Data
        var mediaType = "image/png"
        var byteSize: Int?
        var modifiedAt: Double = 1_760_000_000_000
        private(set) var stats = 0
        private(set) var reads = 0

        init(body: Data) {
            self.body = body
        }

        func call(_ method: String, _ payload: JSONValue) async throws -> JSONValue? {
            switch method {
            case "file.stat":
                stats += 1
                switch mode {
                case .offline:
                    throw MizarError(code: "NO_CONNECTION", message: "not connected")
                case .refused:
                    throw MizarError(code: "FILE_UNKNOWN", message: "no such file")
                case .online:
                    return .object([
                        "path": payload["path"] ?? .string(""),
                        "name": .string("survey.png"),
                        "byteSize": .number(Double(byteSize ?? body.count)),
                        "modifiedAt": .number(modifiedAt),
                        "mediaType": .string(mediaType),
                        "previewable": .bool(true),
                    ])
                }
            case "file.read":
                reads += 1
                if case .offline = mode {
                    throw MizarError(code: "NO_CONNECTION", message: "not connected")
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
    }

    private func loader(_ bridge: Bridge, cache: FilePreviewCache) -> ConversationImageLoader {
        ConversationImageLoader(
            hostId: "host-1",
            fetcher: ConversationImageFetcher(reader: FileReader(call: bridge.call)),
            cache: cache,
        )
    }

    private let target = ConversationImageTarget(path: "shots/survey.png", alt: "A survey")

    @Test("the first read is stored, and the second is the phone's own")
    func secondLookDoesNotReadAgain() async throws {
        let bridge = Bridge(body: Data(repeating: 0x11, count: 900))
        let cache = temporaryCache()
        let loader = loader(bridge, cache: cache)

        let first = try await loader.load(sessionId: "s1", target: target)
        #expect(!first.fromCache)
        #expect(first.data.count == 900)
        #expect(bridge.reads == 1)

        let second = try await loader.load(sessionId: "s1", target: target)
        #expect(second.fromCache)
        #expect(second.data == first.data)
        // One `stat` per look -- that is how a stale copy is caught -- and no
        // second transfer.
        #expect(bridge.stats == 2)
        #expect(bridge.reads == 1)
    }

    @Test("a computer that is gone still draws the picture it already sent")
    func offlineDrawsTheCopy() async throws {
        let bridge = Bridge(body: Data(repeating: 0x22, count: 700))
        let cache = temporaryCache()
        let loader = loader(bridge, cache: cache)
        _ = try await loader.load(sessionId: "s1", target: target)
        #expect(bridge.reads == 1)

        bridge.mode = .offline
        let offline = try await loader.load(sessionId: "s1", target: target)
        #expect(offline.fromCache)
        #expect(offline.data.count == 700)
        #expect(bridge.reads == 1)
        // The name still reads like a file rather than a cache hash.
        #expect(offline.name == "survey.png")
    }

    @Test("with no socket and no copy there is nothing to draw")
    func offlineWithoutACopyFails() async {
        let bridge = Bridge(body: Data(repeating: 0x33, count: 10))
        bridge.mode = .offline
        let loader = loader(bridge, cache: temporaryCache())
        await #expect(throws: ConversationImageFailure.offline) {
            try await loader.load(sessionId: "s1", target: target)
        }
    }

    @Test("a file the host says is gone is not served from an old copy")
    func refusalIsNotAnOfflineReplay() async throws {
        let bridge = Bridge(body: Data(repeating: 0x44, count: 300))
        let cache = temporaryCache()
        let loader = loader(bridge, cache: cache)
        _ = try await loader.load(sessionId: "s1", target: target)

        bridge.mode = .refused
        await #expect(throws: ConversationImageFailure.missing) {
            try await loader.load(sessionId: "s1", target: target)
        }
    }

    @Test("a changed file replaces the copy instead of showing yesterday's")
    func staleCopyIsReplaced() async throws {
        let bridge = Bridge(body: Data(repeating: 0x55, count: 200))
        let cache = temporaryCache()
        let loader = loader(bridge, cache: cache)
        _ = try await loader.load(sessionId: "s1", target: target)

        bridge.body = Data(repeating: 0x66, count: 220)
        bridge.modifiedAt += 60_000
        let fresh = try await loader.load(sessionId: "s1", target: target)
        #expect(!fresh.fromCache)
        #expect(fresh.data.count == 220)
        #expect(bridge.reads == 2)
    }

    @Test("a loader with no bridge at all reads only what is on the phone")
    func noSocketReadsTheCopy() async throws {
        let cache = temporaryCache()
        let bridge = Bridge(body: Data(repeating: 0x77, count: 64))
        _ = try await loader(bridge, cache: cache).load(sessionId: "s1", target: target)

        let offlineLoader = ConversationImageLoader(hostId: "host-1", fetcher: nil, cache: cache)
        let copy = try await offlineLoader.load(sessionId: "s1", target: target)
        #expect(copy.fromCache)
        #expect(copy.data.count == 64)
    }
}
