//
//  AgentSkills.swift
//  MizarKit
//
//  What the computer's agents can be told to do, and what the phone remembers.
//
//  A skill is a directory with a `SKILL.md` in it, and the desktop reads one set
//  per agent engine. The phone does not parse any of it: the host deduplicates
//  the three engines, folds whitespace, truncates and fingerprints, and sends a
//  delta against the list the phone already holds. This file is the phone's half
//  of that contract -- the wire shapes, the merge rule, and the per-machine cache.
//
//  The cache exists for the same reason the session index does: the operator
//  opens the command palette while a socket is opening, or on a train with no
//  signal, and a list that only exists in memory is a list that is empty exactly
//  when it would be useful. It is kept per host id, because two computers do not
//  share a skills directory and a list drawn under the wrong name is worse than
//  no list at all.
//

import Foundation

// MARK: - The wire shapes

/// One skill, as the host reports it.
///
/// `id` is the deduplicated name and is what the composer matches on. `name`
/// and `id` are the same today (frontmatter name, else directory name), and are
/// kept separate because the host is allowed to make them differ later.
///
/// `fingerprint` is the host's "this content has changed" mark -- FNV-1a over
/// name and description, not mtime -- so a `touch` does not look like an edit.
/// The phone only compares it; it never computes one.
public struct AgentSkill: Codable, Sendable, Equatable, Identifiable {
    /// The deduplicated skill name, and the token the composer matches.
    public let id: String
    /// What to show.
    public let name: String
    /// One line, whitespace-folded and at most 600 characters.
    public let description: String
    /// The host's change mark. Equal means "do not send this back".
    public let fingerprint: String
    /// Which engine's directory this copy came from, when the host says.
    public let engine: String?

    public init(
        id: String,
        name: String,
        description: String,
        fingerprint: String,
        engine: String? = nil,
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.fingerprint = fingerprint
        self.engine = engine
    }
}

/// One engine's contribution to a scan, for explaining an incomplete answer.
///
/// Present so a host that could not read one directory can say which, without
/// failing the whole request. The phone does not draw these today; it only
/// carries them through the response shape.
public struct AgentSkillEngineStatus: Decodable, Sendable, Equatable {
    /// The engine's wire name: `dsh`, `claude`, `codex`.
    public let id: String
    /// How many skills that directory yielded, when the scan got that far.
    public let count: Int?
    /// Why the directory could not be read, when it could not.
    public let error: String?
}

/// The host's answer to `skill.catalog`.
///
/// Only new or changed skills are in ``skills``. ``removed`` names ids the phone
/// sent in `known` that the host no longer has, and is empty when ``complete`` is
/// false -- an incomplete scan cannot tell "deleted" from "not read".
public struct AgentSkillDelta: Decodable, Sendable {
    /// New skills plus skills whose fingerprint changed.
    public let skills: [AgentSkill]
    /// Ids the phone holds that no longer exist on the computer.
    ///
    /// Decoded with a default because the field is emptied by the host rather
    /// than omitted, but a delta without it should still read as "nothing was
    /// removed" rather than failing the whole sync.
    public let removed: [String]
    /// Whether every engine's directory was read without error and nothing was
    /// cut off. When false, the phone must not delete anything.
    public let complete: Bool
    /// When the host scanned, in milliseconds since the Unix epoch.
    public let scannedAt: Int64
    /// What each scanned engine contributed, for an incomplete scan's reason.
    public let engines: [AgentSkillEngineStatus]
    /// Whether a size or count limit cut the list short.
    ///
    /// Optional on the wire: it was the last field added, and an older host that
    /// never truncates is indistinguishable from one that omitted it.
    public let truncated: Bool

    /// Memberwise initializer for the merge's tests.
    init(
        skills: [AgentSkill] = [],
        removed: [String] = [],
        complete: Bool = true,
        scannedAt: Int64 = 0,
        engines: [AgentSkillEngineStatus] = [],
        truncated: Bool = false,
    ) {
        self.skills = skills
        self.removed = removed
        self.complete = complete
        self.scannedAt = scannedAt
        self.engines = engines
        self.truncated = truncated
    }

    private enum CodingKeys: String, CodingKey {
        case skills, removed, complete, scannedAt, engines, truncated
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.skills = try values.decode([AgentSkill].self, forKey: .skills)
        self.removed = try values.decodeIfPresent([String].self, forKey: .removed) ?? []
        self.complete = try values.decode(Bool.self, forKey: .complete)
        self.scannedAt = try values.decode(Int64.self, forKey: .scannedAt)
        self.engines = try values.decodeIfPresent([AgentSkillEngineStatus].self, forKey: .engines) ?? []
        self.truncated = try values.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
    }
}

/// Everything the phone knows about one computer's skills, on disk and in memory.
///
/// `scannedAt` is milliseconds since the epoch because that is what the host
/// sends and what the cache file records; the app converts to `Date` at its own
/// edge so the stored shape cannot drift by a time zone or a rounding rule.
public struct AgentSkillCatalog: Codable, Sendable, Equatable {
    /// The machine these belong to.
    public var hostId: String
    /// The host's scan time, in milliseconds since the Unix epoch.
    public var scannedAt: Int64
    /// Whether the scan that produced this was complete.
    public var complete: Bool
    /// The skills, deduplicated by the host.
    public var skills: [AgentSkill]

    public init(hostId: String, scannedAt: Int64, complete: Bool, skills: [AgentSkill]) {
        self.hostId = hostId
        self.scannedAt = scannedAt
        self.complete = complete
        self.skills = skills
    }
}

// MARK: - Merging a delta

/// Fold a delta into what is held.
///
/// Deliberately a pure function: the merge is the one part of syncing whose
/// failure is silent -- a wrong answer puts a deleted skill back in the palette,
/// or drops a live one -- so it is tested without a socket, a host or a disk.
public enum AgentSkillMerge {
    /// Fold one delta into a catalog.
    ///
    /// The rules, in order:
    /// - a skill in the delta replaces the held entry with the same id;
    /// - ids named in `removed` are dropped;
    /// - **nothing is removed when `complete` is false**: an unread directory is
    ///   not a deleted skill, and a truncated list is not a shorter one;
    /// - an id in `removed` that is not held is ignored;
    /// - the result is sorted by id, so the same inputs always produce the same
    ///   array (and therefore the same `changed` answer).
    ///
    /// `changed` describes the **skills**, not the metadata: `scannedAt` and
    /// `complete` are updated on every merge, but an answer whose fingerprints
    /// all match is not a reason to rewrite the cache file.
    ///
    /// - Parameters:
    ///   - catalog: what the phone holds.
    ///   - delta: the host's answer.
    /// - Returns: the folded catalog, and whether its skills changed.
    public static func merge(
        _ catalog: AgentSkillCatalog,
        delta: AgentSkillDelta,
    ) -> (AgentSkillCatalog, changed: Bool) {
        var byId: [String: AgentSkill] = [:]
        // By hand rather than `Dictionary(uniqueKeysWithValues:)`: a duplicate
        // id in a stored or hostile answer must not crash the app. Later entries
        // win, which is the rule the host applies to its own three engines.
        for skill in catalog.skills { byId[skill.id] = skill }
        for skill in delta.skills { byId[skill.id] = skill }
        if delta.complete {
            for id in delta.removed { byId.removeValue(forKey: id) }
        }
        let skills = byId.values.sorted { $0.id < $1.id }

        var merged = catalog
        merged.scannedAt = delta.scannedAt
        merged.complete = delta.complete
        merged.skills = skills
        return (merged, changed: skills != catalog.skills)
    }
}

// MARK: - The cache

/// The skills, on disk, one file per computer.
///
/// `Application Support/MizarSkills/<hostId>.json`, the same directory-and-atomic-
/// write convention as `FileSessionIndexStore`. The host id arrives over the
/// wire, so it is escaped before it becomes a path; unlike the session index the
/// rule is stricter -- only ASCII letters, digits and `-` survive -- because a
/// host id has never needed anything else.
public struct FileAgentSkillStore: Sendable {
    private let directory: URL

    /// - Parameter directory: where to keep it, or `nil` for Application Support.
    public init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.directory = base.appendingPathComponent("MizarSkills", isDirectory: true)
        }
    }

    /// The file name for one host.
    ///
    /// The host id is a wire value, not a name this app chose, so it can contain
    /// a slash or a `..`. Everything outside `[A-Za-z0-9-]` becomes `_`, and an
    /// id that sanitizes to nothing is filed under `unknown` rather than `.json`.
    static func sanitizedHostId(_ hostId: String) -> String {
        let safe = hostId.replacingOccurrences(
            of: "[^A-Za-z0-9-]",
            with: "_",
            options: .regularExpression,
        )
        return safe.isEmpty ? "unknown" : safe
    }

    /// The file for one host.
    private func url(for hostId: String) -> URL {
        directory.appendingPathComponent("\(Self.sanitizedHostId(hostId)).json")
    }

    /// Read what is stored for a host.
    ///
    /// A missing file, an unreadable one and a file for a different host all
    /// read as `nil`: a cache that cannot be read is a cache that does not
    /// exist, not a failure worth showing over a working network. `throws` is
    /// kept for the one case a caller might want to distinguish -- a file that
    /// exists but cannot be opened -- and callers that do not are expected to
    /// use `try?`.
    public func load(hostId: String) throws -> AgentSkillCatalog? {
        let url = url(for: hostId)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard let catalog = try? JSONDecoder().decode(AgentSkillCatalog.self, from: data) else { return nil }
        // A file written for another machine is not this machine's list. It
        // cannot normally happen, but two computers' cache files are one
        // escaping rule apart and the wrong list here would be drawn as fact.
        return catalog.hostId == hostId ? catalog : nil
    }

    /// Replace what is stored for a host.
    ///
    /// Atomic: a half-written file reads as absent, and absent means the palette
    /// waits for the network rather than drawing a truncated list.
    public func save(_ catalog: AgentSkillCatalog) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(catalog)
        try data.write(to: url(for: catalog.hostId), options: .atomic)
    }

    /// Forget a host, when the operator unpairs from it.
    ///
    /// Silent on failure: the file is a cache, and a cache that will not delete
    /// must not make "forget this computer" fail.
    public func delete(hostId: String) {
        try? FileManager.default.removeItem(at: url(for: hostId))
    }
}

// MARK: - Capability

extension HostPlugin {
    /// Whether this computer implements `skill.catalog`.
    ///
    /// The capability is independent of the connection's engine scope: a host
    /// that has the method advertises it whichever agent the token is bound to.
    /// A missing `plugin` object is an older host and reads as unsupported, which
    /// is the same answer as an old host that answers `NOT_IMPLEMENTED` later.
    public var supportsAgentSkills: Bool {
        id == "dsh-mizar" && capabilities.contains("agent.skills.v1")
    }
}
