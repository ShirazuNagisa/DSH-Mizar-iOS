//
//  ConversationImageStore.swift
//  DSH-Mizar
//
//  The pictures inside answers: where their bytes come from, and what is kept.
//
//  A message carries a path and nothing else (see `MizarKit.ConversationImage`).
//  This is the app half: read the file over the bridge, decode it off the main
//  actor with the same pixel budget the preview page uses, and keep a few of
//  them so scrolling back through a conversation does not re-read the computer.
//
//  Deliberately *not* an observable singleton. A row that asked for picture A
//  must not be redrawn because picture B arrived twelve rows further down, which
//  is what a dictionary in an `@Observable` would do to every row on screen. The
//  store answers a question; the row keeps the answer in its own `@State`.
//
//  Reads are shared, though: two rows showing the same picture -- a message that
//  quotes an earlier one, or a row that comes back after being scrolled away --
//  await the same task instead of reading the file twice.
//

import Foundation
import MizarKit
import UIKit

/// What one inline picture is right now.
enum ConversationImagePhase: Equatable {
    /// Nothing has been asked for yet.
    case idle
    /// The bytes are on their way, or being decoded.
    case loading
    /// A drawable bitmap.
    case loaded(ConversationImageStore.Picture)
    /// Nothing to draw, and why.
    case failed(ConversationImageFailure)
}

/// Reads, decodes and caches the pictures a conversation refers to.
@MainActor
final class ConversationImageStore {
    /// A decoded picture, kept small enough to draw a column.
    struct Picture: Equatable {
        /// The bitmap, already downsampled to ``ImagePreviewPolicy/maxThumbnailPixels``.
        let image: UIImage
        /// The file's own pixel size, for the caption and the aspect box.
        let pixelSize: CGSize
        /// What the host said the file weighs.
        let byteSize: Int
        /// The file's name, for the lightbox.
        let name: String
        /// The alt text the message gave, kept for VoiceOver.
        let alt: String?

        /// Identity is the bitmap: two loads of the same file are the same
        /// picture for layout purposes, and `UIImage` is not `Equatable`.
        static func == (lhs: Picture, rhs: Picture) -> Bool {
            lhs.image === rhs.image
                && lhs.pixelSize == rhs.pixelSize
                && lhs.byteSize == rhs.byteSize
                && lhs.name == rhs.name
                && lhs.alt == rhs.alt
        }
    }

    /// How many decoded pictures are kept.
    ///
    /// A phone scrolls a conversation, not a gallery: the answers on screen and
    /// a screenful behind it is the working set. Past this the oldest goes,
    /// because a picture that is scrolled back to is one more `file.read`, and
    /// holding every screenshot of a long session is how a chat app gets killed.
    private static let capacity = 24

    /// The most decoded bytes kept, as a second ceiling.
    ///
    /// A 24-megapixel picture is 96 MiB decoded; twenty-four of those is not a
    /// cache, it is a leak. Bytes are estimated from the pixel size the bitmap
    /// was *made* at, not the file size, because that is what is held.
    private static let byteBudget = 96 * 1_048_576

    private var reader: FileReader?
    private var hostId = ""
    /// Keyed by host, session and path: two computers can have the same path.
    private var cache: [String: Picture] = [:]
    /// Least recently used first.
    private var order: [String] = []
    /// Pictures that are not there, and why.
    ///
    /// A failure is an answer too. Without this, a row rebuilt while its load was
    /// in flight came back as a fresh view with nothing remembered, started the
    /// load again, and -- if that task was cancelled by the rebuild -- sat on the
    /// placeholder for ever. The failure is dropped when the row is retried.
    private var failures: [String: ConversationImageFailure] = [:]
    private var decodedBytes = 0
    /// Loads in flight, so two rows showing one picture read it once.
    private var inFlight: [String: Task<Picture, Error>] = [:]

    // MARK: - Wiring

    /// Point the store at a computer.
    ///
    /// - Parameters:
    ///   - hostId: the computer's identity, which scopes the cache.
    ///   - call: how to dispatch one bridge method.
    func attach(hostId: String, call: @escaping FileReader.Call) {
        self.hostId = hostId
        reader = FileReader(call: call)
    }

    /// Whether a bridge is attached. A row shown before the shell connects draws
    /// its failure sentence instead of waiting forever.
    var isReady: Bool { reader != nil }

    // MARK: - Reading

    /// The picture a message names, from the cache or the computer.
    ///
    /// - Parameters:
    ///   - sessionId: the session whose workspace the path is resolved in.
    ///   - target: the path and alt text the message wrote.
    /// - Returns: the picture, or why it cannot be drawn.
    func picture(
        sessionId: String,
        target: ConversationImageTarget,
    ) async -> Result<Picture, ConversationImageFailure> {
        let key = cacheKey(sessionId: sessionId, target: target)
        if let cached = cache[key] {
            touch(key)
            return .success(cached)
        }
        if let failure = failures[key] {
            return .failure(failure)
        }
        if let running = inFlight[key] {
            do {
                return .success(try await running.value)
            } catch let failure as ConversationImageFailure {
                return .failure(failure)
            } catch {
                return .failure(.unreadable)
            }
        }
        guard let reader else {
            // No reader yet: the shell has not attached, so there is nothing to ask.
            return .failure(.offline)
        }
        let fetcher = ConversationImageFetcher(reader: reader)
        let task = Task<Picture, Error> { [weak self] in
            let payload = try await fetcher.fetch(sessionId: sessionId, target: target)
            let picture = try await Self.decode(payload, alt: target.alt)
            await self?.remember(picture, for: key)
            return picture
        }
        inFlight[key] = task
        defer {
            // The next caller starts a fresh read unless this one succeeded;
            // a failure is worth retrying when the row comes back.
            Task { @MainActor in self.inFlight[key] = nil }
        }
        do {
            return .success(try await task.value)
        } catch let failure as ConversationImageFailure {
            failures[key] = failure
            return .failure(failure)
        } catch is CancellationError {
            // Cancelled by a rebuild, not a verdict on the picture: the next
            // instance asks again rather than inheriting a failure nobody saw.
            return .failure(.unreadable)
        } catch {
            failures[key] = .unreadable
            return .failure(.unreadable)
        }
    }

    /// Drop a picture so the next look re-reads it.
    ///
    /// - Parameters:
    ///   - sessionId: the session the path belongs to.
    ///   - target: the picture.
    func forget(sessionId: String, target: ConversationImageTarget) {
        let key = cacheKey(sessionId: sessionId, target: target)
        if let cached = cache.removeValue(forKey: key) {
            decodedBytes -= Self.decodedCost(cached)
            order.removeAll { $0 == key }
        }
        failures[key] = nil
        inFlight[key]?.cancel()
        inFlight[key] = nil
    }

    /// Empty the cache. Used by tests that start fresh.
    func clear() {
        failures.removeAll()
        cache.removeAll()
        order.removeAll()
        decodedBytes = 0
        for task in inFlight.values { task.cancel() }
        inFlight.removeAll()
    }

    // MARK: - Cache bookkeeping

    private func cacheKey(sessionId: String, target: ConversationImageTarget) -> String {
        "\(hostId)\u{1}\(sessionId)\u{1}\(target.lookupPath)"
    }

    private func remember(_ picture: Picture, for key: String) {
        if let previous = cache[key] {
            decodedBytes -= Self.decodedCost(previous)
            order.removeAll { $0 == key }
        }
        cache[key] = picture
        order.append(key)
        decodedBytes += Self.decodedCost(picture)
        while order.count > Self.capacity || decodedBytes > Self.byteBudget {
            guard let oldest = order.first else { break }
            if let evicted = cache.removeValue(forKey: oldest) {
                decodedBytes -= Self.decodedCost(evicted)
            }
            order.removeFirst()
        }
    }

    private func touch(_ key: String) {
        guard order.last != key else { return }
        order.removeAll { $0 == key }
        order.append(key)
    }

    /// What a decoded picture costs, as an estimate of the bitmap.
    private static func decodedCost(_ picture: Picture) -> Int {
        max(1, Int(picture.pixelSize.width) * Int(picture.pixelSize.height) * 4)
    }

    // MARK: - Decoding

    /// Decode off the main actor, at a size worth drawing.
    ///
    /// - Parameters:
    ///   - payload: the bytes and the host's facts.
    ///   - alt: the message's caption.
    /// - Returns: the bitmap and its real pixel size.
    private static func decode(
        _ payload: ConversationImagePayload,
        alt: String?,
    ) async throws -> Picture {
        try await Task.detached(priority: .userInitiated) {
            try ConversationImageDecoder.decode(payload, alt: alt)
        }.value
    }
}
