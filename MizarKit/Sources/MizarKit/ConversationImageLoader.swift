//
//  ConversationImageLoader.swift
//  MizarKit
//
//  A picture a message points at, and the copy this phone keeps of it.
//
//  A transcript is stored on the phone; a picture in it was not, so losing the
//  computer took the pictures with it -- the text was still there and the answer
//  had holes in it. The fix is the one the preview page already makes for
//  delivered files: the bytes go into the same on-disk cache, under the same key
//  (computer, session, path), with the same rules -- written atomically, bounded
//  by a byte budget, disposable from the settings screen.
//
//  What is cached is the *file*, and freshness is decided by asking the host,
//  not by trusting the copy:
//
//    - online, the host says size and modification time; a copy that matches is
//      drawn without a second transfer;
//    - online, a copy that does not match is replaced;
//    - offline, the copy is drawn anyway. That is the whole point: the answer is
//      still readable, and the picture in it is still the picture it showed.
//
//  A refusal is not "offline": a path the host says is missing, outside the
//  session, or not a picture is not served from a copy that may be exactly what
//  was refused.
//

import Foundation

/// Reading a picture, from the phone's own copy when it has one.
public struct ConversationImageLoader: Sendable {
    /// One picture, ready to be decoded.
    public struct Loaded: Sendable, Equatable {
        /// The file's bytes.
        public let data: Data
        /// The size the host reported, or the size of the copy.
        public let byteSize: Int
        /// The modification time the host reported, or `0` for a copy read
        /// without asking.
        public let modifiedAt: Double
        /// The file's own name.
        public let name: String
        /// Whether this came off the phone instead of the link.
        public let fromCache: Bool

        public init(data: Data, byteSize: Int, modifiedAt: Double, name: String, fromCache: Bool) {
            self.data = data
            self.byteSize = byteSize
            self.modifiedAt = modifiedAt
            self.name = name
            self.fromCache = fromCache
        }
    }

    private let hostId: String
    private let fetcher: ConversationImageFetcher?
    private let cache: FilePreviewCache

    /// - Parameters:
    ///   - hostId: the computer the session belongs to, which scopes the cache.
    ///   - fetcher: how to reach it, or `nil` when this phone has no socket: the
    ///     copy on disk is then the only thing there is.
    ///   - cache: where the bytes are kept.
    public init(hostId: String, fetcher: ConversationImageFetcher?, cache: FilePreviewCache) {
        self.hostId = hostId
        self.fetcher = fetcher
        self.cache = cache
    }

    /// The cache key for one picture.
    ///
    /// - Parameters:
    ///   - sessionId: the session the message belongs to.
    ///   - target: the picture.
    /// - Returns: the key the preview page would use for the same file.
    public func key(sessionId: String, target: ConversationImageTarget) -> PreviewCacheKey {
        PreviewCacheKey(hostId: hostId, sessionId: sessionId, path: target.lookupPath)
    }

    /// Load a picture.
    ///
    /// - Parameters:
    ///   - sessionId: the session whose workspace the path is resolved in.
    ///   - target: the picture the message asked for.
    ///   - progress: fraction read, for the placeholder.
    /// - Returns: the bytes, and whether they came off the phone.
    /// - Throws: ``ConversationImageFailure``, or `CancellationError`.
    public func load(
        sessionId: String,
        target: ConversationImageTarget,
        progress: (@Sendable (Double) -> Void)? = nil,
    ) async throws -> Loaded {
        let key = key(sessionId: sessionId, target: target)
        guard let fetcher else {
            // No socket at all: the copy is the picture, or there is none.
            return try await cached(key, target: target)
        }

        let facts: FileFacts
        do {
            facts = try await fetcher.facts(sessionId: sessionId, target: target)
        } catch let failure as ConversationImageFailure {
            guard Self.isTransient(failure) else { throw failure }
            // The computer is unreachable: draw what this phone already has.
            return try await cached(key, target: target)
        }

        if let copy = await readCached(key, matching: facts, target: target) {
            return copy
        }
        let payload = try await fetcher.bytes(
            sessionId: sessionId,
            target: target,
            facts: facts,
            progress: progress,
        )
        // A cache that cannot be written is not a failure: the picture is on
        // screen either way, and the next launch asks again.
        await cache.store(payload.data, for: key, facts: facts)
        return Loaded(
            data: payload.data,
            byteSize: payload.byteSize,
            modifiedAt: payload.modifiedAt,
            name: payload.name,
            fromCache: false,
        )
    }

    /// The phone's copy, without asking the computer anything.
    ///
    /// - Parameters:
    ///   - sessionId: the session the message belongs to.
    ///   - target: the picture.
    /// - Returns: the copy, when there is one.
    /// - Throws: ``ConversationImageFailure/offline`` when there is not.
    public func cachedCopy(sessionId: String, target: ConversationImageTarget) async throws -> Loaded {
        try await cached(key(sessionId: sessionId, target: target), target: target)
    }

    // MARK: - The cache

    private func cached(_ key: PreviewCacheKey, target: ConversationImageTarget) async throws -> Loaded {
        guard let url = await cache.cached(key) else { throw ConversationImageFailure.offline }
        return try await Self.loaded(url, key: key, cache: cache, target: target)
    }

    private func readCached(
        _ key: PreviewCacheKey,
        matching facts: FileFacts,
        target: ConversationImageTarget,
    ) async -> Loaded? {
        guard let url = await cache.cached(key, matching: facts) else { return nil }
        return try? await Self.loaded(url, key: key, cache: cache, target: target)
    }

    /// Read a cached file off the disk, with the metadata stored beside it.
    ///
    /// - Parameters:
    ///   - url: the file.
    ///   - key: which file it is.
    ///   - cache: the cache it came from, for the entry.
    ///   - target: the picture, for the name when there is no entry.
    /// - Returns: the bytes.
    /// - Throws: ``ConversationImageFailure/unreadable`` when the copy cannot be
    ///   read, which is the cache's problem and not the link's.
    private static func loaded(
        _ url: URL,
        key: PreviewCacheKey,
        cache: FilePreviewCache,
        target: ConversationImageTarget,
    ) async throws -> Loaded {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            throw ConversationImageFailure.unreadable
        }
        let entry = await cache.entry(for: key)
        return Loaded(
            data: data,
            byteSize: entry?.byteSize ?? data.count,
            modifiedAt: entry?.modifiedAt ?? 0,
            name: entry?.name ?? (target.lookupPath as NSString).lastPathComponent,
            fromCache: true,
        )
    }

    /// Whether a failure means "not now" rather than "not ever".
    ///
    /// - Parameter failure: what went wrong.
    /// - Returns: whether the copy on disk should be drawn instead.
    static func isTransient(_ failure: ConversationImageFailure) -> Bool {
        switch failure {
        case .offline, .locked, .oldPlugin, .unreadable:
            true
        case .missing, .forbidden, .tooLarge, .notAnImage:
            false
        }
    }
}
