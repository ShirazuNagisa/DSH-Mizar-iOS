//
//  StashReplayStore.swift
//  MizarKit
//
//  The process text a stash bundle carried, kept past the launch that read it.
//
//  A bundle is fetched at cold launch, before any screen exists, and the letter
//  is acknowledged immediately. Without a copy on disk the narration would live
//  only in the memory of whichever model object happened to be alive -- which is
//  exactly the shape of a bug this app has already had once: history that is
//  there when the process starts and gone the next time the operator looks.
//
//  So this is one small JSON file per (host, session), keyed by turn, holding
//  the replay, when the turn ended and which bundle it came from. Seven days,
//  the same lifetime the relay gives the letter.
//
//  The merge rules are pure functions over the values, except for the one write
//  into the conversation cache: a turn the history does not have is synthesized
//  from the bundle, and a turn it does have only gains its process text.
//

import Foundation

/// One turn's process text, as it was pulled from the relay.
public struct StashedReplay: Codable, Sendable, Equatable {
    /// The computer the letter was written for.
    public let hostId: String
    /// The session the turn belongs to.
    public let sessionId: String
    /// The turn number, which is the key within the session.
    public let turn: Int
    /// The desktop process instance that wrote the letter.
    public let epoch: Int
    /// The journal, in the shape the live stream and the history both read.
    public let replay: StreamReplay
    /// When the turn ended, or `nil` for one still running when it was written.
    public let endedAt: Date?
    /// The relay's id for the bundle this came from.
    public let bundleId: String
    /// The bundle's creation time, epoch milliseconds.
    public let createdAt: Int64
    /// When this phone wrote the record, which is what the expiry counts from.
    public let storedAt: Date

    enum CodingKeys: String, CodingKey {
        case turn, epoch, replay, endedAt, createdAt, storedAt
        case hostId, sessionId, bundleId
    }

    public init(
        hostId: String,
        sessionId: String,
        turn: Int,
        epoch: Int,
        replay: StreamReplay,
        endedAt: Date?,
        bundleId: String,
        createdAt: Int64,
        storedAt: Date = Date(),
    ) {
        self.hostId = hostId
        self.sessionId = sessionId
        self.turn = turn
        self.epoch = epoch
        self.replay = replay
        self.endedAt = endedAt
        self.bundleId = bundleId
        self.createdAt = createdAt
        self.storedAt = storedAt
    }

    /// The narration worth drawing: body blocks that are not the turn's answer.
    ///
    /// The final body is left out on purpose. When history already had the turn
    /// the answer on screen is the authoritative copy and drawing the letter's
    /// final text again would show it twice; when history did not, the answer
    /// was synthesized into the turn and appears as its own message. In both
    /// cases what is missing from the page is the narration before it.
    public var processBlocks: [StreamBlock] {
        var stream = TurnStream()
        stream.replace(with: replay)
        return stream.blocks.filter { block in
            block.kind == .body
                && !block.isFinal
                && !block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

/// Where the pulled process text lives.
///
/// One file per (host, session): the records for a conversation are read
/// together, and there are only ever a handful of turns per session.
public actor StashReplayStore {
    private let directory: URL
    /// How long a record survives. The relay's own expiry, so a record cannot
    /// outlive the letter it describes by much.
    private let lifetime: TimeInterval

    /// - Parameters:
    ///   - directory: where to keep the files; Application Support by default.
    ///   - lifetime: how long a record survives, in seconds.
    public init(directory: URL? = nil, lifetime: TimeInterval = 7 * 24 * 60 * 60) {
        if let directory {
            self.directory = directory
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.directory = base.appendingPathComponent("MizarStash", isDirectory: true)
        }
        self.lifetime = lifetime
    }

    /// The file for one (host, session).
    ///
    /// Both ids arrive over the wire, so both are escaped before they become a
    /// path -- the same rule the conversation cache follows: a path built from
    /// unvalidated input is how a cache becomes a directory traversal.
    private func url(hostId: String, sessionId: String) -> URL {
        let safeHost = Self.escaped(hostId)
        let safeSession = Self.escaped(sessionId)
        return directory
            .appendingPathComponent(safeHost, isDirectory: true)
            .appendingPathComponent("\(safeSession).json")
    }

    private static func escaped(_ value: String) -> String {
        let safe = value.replacingOccurrences(
            of: "[^A-Za-z0-9._-]",
            with: "_",
            options: .regularExpression,
        )
        // An id of only illegal characters would become the empty string, and an
        // empty path component is not a file name.
        return safe.isEmpty ? "unnamed" : safe
    }

    /// Store one record, replacing any older record for the same turn.
    ///
    /// - Parameter record: the record to keep.
    public func save(_ record: StashedReplay) async {
        let cutoff = Date().addingTimeInterval(-lifetime)
        var records = read(hostId: record.hostId, sessionId: record.sessionId)
            .filter { $0.storedAt > cutoff }
        records.removeAll { $0.turn == record.turn }
        records.append(record)
        records.sort { $0.turn < $1.turn }
        write(records, hostId: record.hostId, sessionId: record.sessionId)
    }

    /// The records for one session, oldest turn first, expired ones dropped.
    ///
    /// - Parameters:
    ///   - hostId: the computer.
    ///   - sessionId: the session.
    /// - Returns: the records still inside their lifetime.
    public func load(hostId: String, sessionId: String) async -> [StashedReplay] {
        let cutoff = Date().addingTimeInterval(-lifetime)
        return read(hostId: hostId, sessionId: sessionId)
            .filter { $0.storedAt > cutoff }
            .sorted { $0.turn < $1.turn }
    }

    /// One turn's record.
    ///
    /// - Parameters:
    ///   - hostId: the computer.
    ///   - sessionId: the session.
    ///   - turn: the turn number.
    /// - Returns: the record, or `nil`.
    public func load(hostId: String, sessionId: String, turn: Int) async -> StashedReplay? {
        await load(hostId: hostId, sessionId: sessionId).first { $0.turn == turn }
    }

    /// Forget one session, when its history is rewritten or the host leaves.
    ///
    /// - Parameters:
    ///   - hostId: the computer.
    ///   - sessionId: the session.
    public func remove(hostId: String, sessionId: String) async {
        try? FileManager.default.removeItem(at: url(hostId: hostId, sessionId: sessionId))
    }

    /// Forget a whole computer, when the operator unpairs from it.
    ///
    /// - Parameter hostId: the computer.
    public func remove(hostId: String) async {
        try? FileManager.default.removeItem(
            at: directory.appendingPathComponent(Self.escaped(hostId), isDirectory: true),
        )
    }

    private func read(hostId: String, sessionId: String) -> [StashedReplay] {
        guard let data = try? Data(contentsOf: url(hostId: hostId, sessionId: sessionId)) else {
            return []
        }
        return (try? JSONDecoder().decode([StashedReplay].self, from: data)) ?? []
    }

    private func write(_ records: [StashedReplay], hostId: String, sessionId: String) {
        do {
            let file = url(hostId: hostId, sessionId: sessionId)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true,
            )
            let data = try JSONEncoder().encode(records)
            // Atomic, for the same reason the conversation cache writes that
            // way: a half-written file reads as absent, and absent is the one
            // thing this store exists to prevent.
            try data.write(to: file, options: .atomic)
        } catch {
            // Not being able to cache process text is not a failure the operator
            // should see; the turn itself is still on screen.
        }
    }
}

// MARK: - Merging a bundle into the conversation

/// What one bundle did to this phone's copy of a conversation.
public struct StashIngestResult: Sendable, Equatable {
    /// The turns that were synthesized because history did not have them.
    public let synthesized: [ConversationTurn]
    /// The sessions whose cache was written.
    public let sessions: [String]
    /// The process records written, whether or not the turn was synthesized.
    public let records: [StashedReplay]

    public init(
        synthesized: [ConversationTurn] = [],
        sessions: [String] = [],
        records: [StashedReplay] = [],
    ) {
        self.synthesized = synthesized
        self.sessions = sessions
        self.records = records
    }
}

/// Fold a bundle into what this phone already knows.
public enum StashIngest {
    /// Apply one bundle.
    ///
    /// Two branches, one per rule in the wire spec: a turn history does not have
    /// becomes an ended turn whose answer is the bundle's final text; a turn
    /// history does have keeps its own answer and only gains the process text.
    /// A turn that had not ended when it was written never becomes history --
    /// claiming an end the desktop did not write would be a lie about a failed
    /// or interrupted turn -- but its narration is still worth keeping.
    ///
    /// - Parameters:
    ///   - bundle: the decrypted bundle.
    ///   - hostId: the computer it came from.
    ///   - conversations: the conversation cache to fold into.
    ///   - process: the store the process text goes into.
    ///   - now: the instant the record is stamped with, for expiry.
    /// - Returns: what was written.
    @discardableResult
    public static func apply(
        bundle: StashBundle,
        hostId: String,
        conversations: any ConversationCache,
        process: StashReplayStore,
        now: Date = Date(),
    ) async -> StashIngestResult {
        var synthesized: [ConversationTurn] = []
        var records: [StashedReplay] = []
        var sessions: [String] = []
        var synthesizedBySession: [String: [ConversationTurn]] = [:]

        for turn in bundle.turns {
            guard !turn.sessionId.isEmpty, turn.turn >= 0 else { continue }
            let record = StashedReplay(
                hostId: hostId,
                sessionId: turn.sessionId,
                turn: turn.turn,
                epoch: bundle.epoch,
                replay: turn.replay,
                endedAt: turn.endedDate,
                bundleId: bundle.bundleId,
                createdAt: bundle.createdAt,
                storedAt: now,
            )
            // Read the cache for this session once per bundle; the loop is
            // small (a bundle holds at most a handful of turns).
            let cached = await conversations.load(sessionId: turn.sessionId)
            let known = cached?.turns ?? []
            if known.contains(where: { $0.turn == turn.turn }) {
                // History has it: the answer on screen is authoritative.
                records.append(record)
                continue
            }
            if let ended = turn.endedDate, let body = turn.bodyText {
                let synthesizedTurn = Self.turn(for: turn, body: body, endedAt: ended)
                synthesized.append(synthesizedTurn)
                synthesizedBySession[turn.sessionId, default: []].append(synthesizedTurn)
                sessions.append(turn.sessionId)
            }
            records.append(record)
        }

        for record in records {
            await process.save(record)
        }
        for sessionId in Set(sessions) {
            let turns = synthesizedBySession[sessionId] ?? []
            guard !turns.isEmpty else { continue }
            await conversations.update(sessionId: sessionId) { cached in
                let items = turns.flatMap(\.items)
                return CachedConversation(
                    sessionId: sessionId,
                    items: mergeConversations(cached: cached?.items ?? [], fresh: items),
                    throughSeq: cached?.throughSeq,
                    syncedAt: cached?.syncedAt ?? now,
                    hasMore: cached?.hasMore ?? false,
                    turns: mergeTurns(cached: cached?.turns ?? [], fresh: turns),
                    oldestSeq: cached?.oldestSeq,
                    historyCursor: cached?.historyCursor,
                    stats: cached?.stats,
                    deliveredSeq: cached?.deliveredSeq,
                    syncedUpdatedAt: cached?.syncedUpdatedAt,
                )
            }
        }

        return StashIngestResult(
            synthesized: synthesized,
            sessions: Array(Set(sessions)).sorted(),
            records: records,
        )
    }

    /// The ended turn a bundle turn becomes.
    ///
    /// `endedReason` is `completed` rather than a word of our own:
    /// ``ConversationTurn/failed`` treats every reason but `completed` as
    /// unfinished, so anything else would draw a turn that succeeded as a
    /// failure.
    ///
    /// - Parameters:
    ///   - turn: the bundle's turn.
    ///   - body: its answer text.
    ///   - endedAt: when it ended.
    /// - Returns: the turn.
    static func turn(
        for turn: StashBundle.Turn,
        body: String,
        endedAt: Date,
    ) -> ConversationTurn {
        // The id has to be stable across bundles: the same turn can arrive in a
        // later letter, and a bundle-specific id would make the two copies two
        // messages under one turn.
        let item = ConversationItem.message(
            id: "stash-turn-\(turn.turn)",
            role: .assistant,
            text: body,
            at: endedAt,
        )
        return ConversationTurn(
            turn: turn.turn,
            prompts: [],
            steps: [item],
            stepCount: turn.entries.count,
            startedAt: turn.startedDate,
            endedAt: endedAt,
            endedReason: "completed",
        )
    }
}
