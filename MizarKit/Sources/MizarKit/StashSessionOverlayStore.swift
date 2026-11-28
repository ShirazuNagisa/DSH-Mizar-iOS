//
//  StashSessionOverlayStore.swift
//  MizarKit
//
//  Sessions the phone learned from the offline stash but the host has not listed
//  yet. Kept beside the replay cache, not in SessionIndex.
//

import Foundation

/// One inferred list row, keyed by `(hostId, sessionId)` in storage.
public struct StashSessionOverlayEntry: Codable, Sendable, Equatable {
    public let sessionId: String
    /// Last activity, epoch milliseconds (same unit as ``SessionRow/updatedAt``).
    public let updatedAt: Double
    /// Title derived from the replayed answer's first non-empty line.
    public let title: String
    /// When this phone wrote the record; expiry counts from here.
    public let storedAt: Date

    public init(sessionId: String, updatedAt: Double, title: String, storedAt: Date = Date()) {
        self.sessionId = sessionId
        self.updatedAt = updatedAt
        self.title = title
        self.storedAt = storedAt
    }
}

/// Rows the session list may draw when the host index does not name them yet.
public enum StashSessionOverlay {
    /// Truncate inferred titles to this length (desktop session ids allow 80).
    public static let titleCharacterLimit = 80

    /// First non-empty line of the answer body, truncated for the sidebar.
    public static func title(fromAnswerBody body: String) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = trimmed
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
            ?? trimmed
        guard firstLine.count > titleCharacterLimit else { return firstLine }
        return String(firstLine.prefix(titleCharacterLimit))
    }

    /// Build a list row from one overlay entry.
    public static func sessionRow(for entry: StashSessionOverlayEntry) -> SessionRow {
        SessionRow(
            sessionId: entry.sessionId,
            updatedAt: entry.updatedAt,
            running: false,
            blank: false,
            agentAvailable: true,
            cwd: nil,
            title: entry.title,
        )
    }

    /// Host rows plus overlay rows the host does not already show, newest first.
    public static func mergedList(host: [SessionRow], overlay: [SessionRow]) -> [SessionRow] {
        let hostIds = Set(host.map(\.sessionId))
        let extra = overlay.filter { !hostIds.contains($0.sessionId) }
        return (host + extra).sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Overlay candidates from one decrypted bundle.
    ///
    /// Only ended turns with answer text count, and only for sessions the host
    /// list does not already name.
    public static func entries(
        from bundle: StashBundle,
        excludingHostSessionIds hostSessionIds: Set<String>,
        storedAt: Date = Date(),
    ) -> [StashSessionOverlayEntry] {
        var latest: [String: (updatedAt: Double, title: String)] = [:]
        for turn in bundle.turns {
            guard turn.endedAt > 0, !turn.sessionId.isEmpty else { continue }
            guard !hostSessionIds.contains(turn.sessionId) else { continue }
            guard let body = turn.bodyText else { continue }
            let title = title(fromAnswerBody: body)
            let updatedAt = Double(turn.endedAt)
            if let existing = latest[turn.sessionId], existing.updatedAt >= updatedAt { continue }
            latest[turn.sessionId] = (updatedAt, title)
        }
        return latest.map { sessionId, value in
            StashSessionOverlayEntry(
                sessionId: sessionId,
                updatedAt: value.updatedAt,
                title: value.title,
                storedAt: storedAt,
            )
        }
    }
}

/// On-disk overlay beside ``StashReplayStore``.
public actor StashSessionOverlayStore {
    private let directory: URL
    private let lifetime: TimeInterval

    public init(directory: URL? = nil, lifetime: TimeInterval = 7 * 24 * 60 * 60) {
        if let directory {
            self.directory = directory
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.directory = base.appendingPathComponent("MizarStash", isDirectory: true)
                .appendingPathComponent("overlay", isDirectory: true)
        }
        self.lifetime = lifetime
    }

    private func url(for hostId: String) -> URL {
        let safe = hostId.replacingOccurrences(
            of: "[^A-Za-z0-9._-]",
            with: "_",
            options: .regularExpression,
        )
        let name = safe.isEmpty ? "unnamed" : safe
        return directory.appendingPathComponent("\(name).json")
    }

    public func load(hostId: String) async -> [StashSessionOverlayEntry] {
        let cutoff = Date().addingTimeInterval(-lifetime)
        return read(hostId: hostId).filter { $0.storedAt > cutoff }
    }

    /// Drop sessions the host now lists, and entries past their lifetime.
    public func prune(hostId: String, knownSessionIds: Set<String>) async -> [StashSessionOverlayEntry] {
        let cutoff = Date().addingTimeInterval(-lifetime)
        var entries = read(hostId: hostId).filter { $0.storedAt > cutoff }
        let before = entries.count
        entries.removeAll { knownSessionIds.contains($0.sessionId) }
        if entries.count != before || read(hostId: hostId).count != entries.count {
            write(entries, hostId: hostId)
        }
        return entries
    }

    public func upsert(hostId: String, newEntries: [StashSessionOverlayEntry]) async -> [StashSessionOverlayEntry] {
        guard !newEntries.isEmpty else { return await load(hostId: hostId) }
        let cutoff = Date().addingTimeInterval(-lifetime)
        var entries = read(hostId: hostId).filter { $0.storedAt > cutoff }
        for entry in newEntries {
            entries.removeAll { $0.sessionId == entry.sessionId }
            entries.append(entry)
        }
        write(entries, hostId: hostId)
        return entries
    }

    public func remove(hostId: String) async {
        try? FileManager.default.removeItem(at: url(for: hostId))
    }

    private func read(hostId: String) -> [StashSessionOverlayEntry] {
        guard let data = try? Data(contentsOf: url(for: hostId)) else { return [] }
        return (try? JSONDecoder().decode([StashSessionOverlayEntry].self, from: data)) ?? []
    }

    private func write(_ entries: [StashSessionOverlayEntry], hostId: String) {
        do {
            let file = url(for: hostId)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true,
            )
            let data = try JSONEncoder().encode(entries)
            try data.write(to: file, options: .atomic)
        } catch {
            // Overlay rows are optional chrome; a failed write is not fatal.
        }
    }
}