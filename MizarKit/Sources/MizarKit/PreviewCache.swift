//
//  PreviewCache.swift
//  MizarKit
//
//  The delivered files this phone has already read, kept on disk.
//
//  A preview is a read of a file that lives on another machine, over a link that
//  may be a relay on the other side of the world. Opening the same report three
//  times in an evening should cost one transfer, not three — so the bytes stay.
//
//  What is cached is the *file*, not the decision to show it: every open still
//  asks the host for the file's size and modification time (`file.stat`, one
//  small frame) and re-downloads when they moved. A cache that trusted its own
//  copy would show yesterday's report under today's name, which is worse than
//  being slow.
//
//  Three rules, each of which is a bug if dropped:
//
//    - **Atomic.** Written to a temporary name and moved into place, so a phone
//      killed mid-write leaves no half file that decodes as a corrupt document.
//    - **Bounded.** 256 MiB, oldest first. The cache exists to save a transfer,
//      not to fill the operator's storage, and the settings screen shows the
//      number so it is never a mystery.
//    - **Disposable.** `clear()` is a first-class operation: nothing else refers
//      to these files, and everything in here can be fetched again.
//

import CryptoKit
import Foundation

/// What one cached file is, and which file it is.
public struct PreviewCacheKey: Hashable, Sendable {
    /// The computer it came from: the same path on two computers is two files.
    public let hostId: String
    /// The session it was read in: the path is relative to that session's
    /// working directory, so two sessions can mean two different files.
    public let sessionId: String
    /// The path as the model wrote it.
    public let path: String

    public init(hostId: String, sessionId: String, path: String) {
        self.hostId = hostId
        self.sessionId = sessionId
        self.path = path
    }
}

/// One cached file's metadata, beside the bytes.
public struct PreviewCacheEntry: Codable, Sendable, Equatable {
    /// The size the host reported when the bytes were stored.
    public let byteSize: Int
    /// The modification time the host reported then.
    public let modifiedAt: Double
    /// When this phone stored it, for eviction order.
    public let storedAt: Date
    /// The file's name at the time, for the settings screen and diagnostics.
    public let name: String

    public init(byteSize: Int, modifiedAt: Double, storedAt: Date, name: String) {
        self.byteSize = byteSize
        self.modifiedAt = modifiedAt
        self.storedAt = storedAt
        self.name = name
    }
}

/// The folder the preview cache and its index live in.
///
/// One place, because two types write into it: the files themselves and the
/// index that says which file each session was last showing. A caller that wants
/// to clear everything (a test asking for a first look, a reset) removes this
/// folder rather than guessing at both paths.
public enum PreviewStore {
    /// The folder, under Application Support.
    public static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("MizarPreviews", isDirectory: true)
    }

    /// Delete every cached file and every remembered target.
    public static func wipe() {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// The on-disk cache of delivered files.
public actor FilePreviewCache {
    private let directory: URL
    private let limit: Int

    /// - Parameters:
    ///   - directory: where to keep the files. Defaults to Application Support,
    ///     like the conversation cache: these are the operator's data, not
    ///     documents they manage in the Files app.
    ///   - limit: the most bytes to keep before evicting the oldest.
    public init(directory: URL? = nil, limit: Int = 256 * 1024 * 1024) {
        self.directory = directory ?? PreviewStore.directory
        self.limit = limit
    }

    /// The cached copy of a file, when it still matches what the host reports.
    ///
    /// - Parameters:
    ///   - key: which file.
    ///   - facts: what the host says about it now.
    /// - Returns: the file's URL, or `nil` when there is no copy or it is stale.
    public func cached(_ key: PreviewCacheKey, matching facts: FileFacts) -> URL? {
        let url = fileURL(for: key)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let entry = readEntry(for: key) else { return nil }
        guard entry.byteSize == facts.byteSize, entry.modifiedAt == facts.modifiedAt else { return nil }
        return url
    }

    /// The cached copy of a file, whatever the host would say.
    ///
    /// For the offline case: a phone that cannot reach the computer still shows
    /// what it already read, and says that is what it is doing.
    ///
    /// - Parameter key: which file.
    /// - Returns: the file's URL, or `nil` when nothing is cached.
    public func cached(_ key: PreviewCacheKey) -> URL? {
        let url = fileURL(for: key)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// What the cache knows about a file, whether or not the bytes are still there.
    ///
    /// For a caller that has no host to ask -- a phone whose computer is gone --
    /// and needs the name and size the file had when it was read.
    ///
    /// - Parameter key: which file.
    /// - Returns: the entry the bytes were stored with, or `nil` when there is none.
    public func entry(for key: PreviewCacheKey) -> PreviewCacheEntry? {
        guard FileManager.default.fileExists(atPath: fileURL(for: key).path) else { return nil }
        return readEntry(for: key)
    }

    /// Store a file's bytes.
    ///
    /// - Parameters:
    ///   - data: the bytes.
    ///   - key: which file they are.
    ///   - facts: what the host said about it, recorded so a later `stat` can
    ///     tell whether this copy is still current.
    /// - Returns: where the bytes now live, or `nil` when the write failed —
    ///   which is not an error the operator needs to see, because the preview
    ///   still works from memory.
    @discardableResult
    public func store(_ data: Data, for key: PreviewCacheKey, facts: FileFacts) -> URL? {
        let url = fileURL(for: key)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
            )
            // Temporary name in the same directory, then a rename: a move within
            // one filesystem is atomic, so a reader never sees half a document.
            let temporary = url.appendingPathExtension("partial")
            try data.write(to: temporary, options: .atomic)
            if FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: url)
            }
            try FileManager.default.moveItem(at: temporary, to: url)
            let entry = PreviewCacheEntry(
                byteSize: facts.byteSize,
                modifiedAt: facts.modifiedAt,
                storedAt: .now,
                name: facts.name,
            )
            writeEntry(entry, for: key)
            evictIfNeeded()
            return url
        } catch {
            return nil
        }
    }

    /// How many bytes the cache holds.
    public func totalSize() -> Int {
        entries().reduce(0) { $0 + $1.size }
    }

    /// How many files the cache holds.
    public func fileCount() -> Int {
        entries().count
    }

    /// Delete everything.
    public func clear() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Delete one session's files.
    ///
    /// - Parameter sessionId: the session whose previews to drop.
    public func remove(sessionId: String) {
        let base = directory
        guard let hosts = try? FileManager.default.contentsOfDirectory(atPath: base.path) else { return }
        for host in hosts {
            let session = base
                .appendingPathComponent(host, isDirectory: true)
                .appendingPathComponent(sanitized(sessionId), isDirectory: true)
            try? FileManager.default.removeItem(at: session)
        }
    }

    // MARK: - Paths

    /// Where one file lives.
    ///
    /// The name is a hash of the path plus the file's own name, because the path
    /// is a string from the model and a path built from unvalidated input is how
    /// a cache becomes a directory traversal. The readable half is there so a
    /// person looking at the folder can tell what they are looking at.
    private func fileURL(for key: PreviewCacheKey) -> URL {
        let digest = SHA256.hash(data: Data(key.path.utf8))
        let stamp = digest.map { String(format: "%02x", $0) }.joined().prefix(16)
        let name = sanitized((key.path as NSString).lastPathComponent)
        return directory
            .appendingPathComponent(sanitized(key.hostId), isDirectory: true)
            .appendingPathComponent(sanitized(key.sessionId), isDirectory: true)
            .appendingPathComponent("\(stamp)-\(name)")
    }

    /// The metadata file beside one file.
    private func entryURL(for url: URL) -> URL {
        url.appendingPathExtension("meta.json")
    }

    private func readEntry(for key: PreviewCacheKey) -> PreviewCacheEntry? {
        let url = entryURL(for: fileURL(for: key))
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PreviewCacheEntry.self, from: data)
    }

    private func writeEntry(_ entry: PreviewCacheEntry, for key: PreviewCacheKey) {
        let url = entryURL(for: fileURL(for: key))
        guard let data = try? JSONEncoder().encode(entry) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// One file the cache holds, with its size and when it was stored.
    private struct StoredFile {
        let url: URL
        let size: Int
        let storedAt: Date
    }

    /// Every cached file, newest last.
    private func entries() -> [StoredFile] {
        var found: [StoredFile] = []
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles],
        ) else { return [] }
        for case let url as URL in walker {
            guard url.pathExtension != "json", url.pathExtension != "partial" else { continue }
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            found.append(StoredFile(
                url: url,
                size: values.fileSize ?? 0,
                storedAt: values.contentModificationDate ?? .distantPast,
            ))
        }
        return found.sorted { $0.storedAt < $1.storedAt }
    }

    /// Drop the oldest files until the cache is inside its limit.
    private func evictIfNeeded() {
        var files = entries()
        var total = files.reduce(0) { $0 + $1.size }
        guard total > limit else { return }
        while total > limit, let oldest = files.first {
            try? FileManager.default.removeItem(at: oldest.url)
            try? FileManager.default.removeItem(at: entryURL(for: oldest.url))
            total -= oldest.size
            files.removeFirst()
        }
    }

    /// A path component that cannot escape the cache directory.
    private func sanitized(_ value: String) -> String {
        let safe = value.replacingOccurrences(
            of: "[^A-Za-z0-9._-]",
            with: "_",
            options: .regularExpression,
        )
        // A name of dots is not a name; and an empty component would collapse the
        // path onto its parent.
        let trimmed = safe.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let bounded = String(trimmed.prefix(60))
        return bounded.isEmpty ? "file" : bounded
    }
}
