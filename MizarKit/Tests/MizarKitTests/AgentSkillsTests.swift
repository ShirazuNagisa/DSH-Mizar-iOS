//
//  AgentSkillsTests.swift
//  MizarKitTests
//
//  The merge and the cache that decide what the command palette can offer.
//
//  The merge is the interesting half. It is the only place a delta can do damage
//  quietly: put a deleted skill back, drop a live one, or rewrite the cache on
//  every poll. The store's failure modes are the session index's -- a missing
//  file, a corrupt file, a host id that tries to escape the directory -- for one
//  file per computer.
//

import Foundation
import Testing
@testable import MizarKit

@Suite("Agent skills")
struct AgentSkillsTests {
    private func skill(
        _ id: String,
        fingerprint: String? = nil,
        engine: String? = "dsh",
    ) -> AgentSkill {
        AgentSkill(
            id: id,
            name: id,
            description: "What \(id) does.",
            fingerprint: fingerprint ?? "fp-\(id)",
            engine: engine,
        )
    }

    private func catalog(_ skills: [AgentSkill], hostId: String = "host-1") -> AgentSkillCatalog {
        AgentSkillCatalog(hostId: hostId, scannedAt: 1_763_351_700_123, complete: true, skills: skills)
    }

    private func delta(
        skills: [AgentSkill] = [],
        removed: [String] = [],
        complete: Bool = true,
        scannedAt: Int64 = 1_763_351_760_000,
        truncated: Bool = false,
    ) -> AgentSkillDelta {
        AgentSkillDelta(
            skills: skills,
            removed: removed,
            complete: complete,
            scannedAt: scannedAt,
            truncated: truncated,
        )
    }

    private func directory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mizar-skills-\(UUID().uuidString)")
    }

    // MARK: - Merge

    @Test("new skills are added and the result is sorted by id")
    func mergeAddsAndSorts() {
        let held = catalog([skill("beta")])
        let (merged, changed) = AgentSkillMerge.merge(
            held,
            delta: delta(skills: [skill("charlie"), skill("alpha")]),
        )

        #expect(changed)
        #expect(merged.skills.map(\.id) == ["alpha", "beta", "charlie"])
        #expect(merged.hostId == "host-1")
        #expect(merged.complete)
        #expect(merged.scannedAt == 1_763_351_760_000)
    }

    @Test("a changed fingerprint replaces the held skill in place")
    func mergeReplacesChangedFingerprint() {
        let held = catalog([skill("alpha", fingerprint: "old"), skill("beta")])
        let (merged, changed) = AgentSkillMerge.merge(
            held,
            delta: delta(skills: [skill("alpha", fingerprint: "new")]),
        )

        #expect(changed)
        #expect(merged.skills.map(\.id) == ["alpha", "beta"])
        #expect(merged.skills.first?.fingerprint == "new")
        #expect(merged.skills.last?.fingerprint == "fp-beta")
    }

    @Test("a complete scan removes what the host no longer has")
    func mergeRemovesOnCompleteScan() {
        let held = catalog([skill("alpha"), skill("beta")])
        let (merged, changed) = AgentSkillMerge.merge(held, delta: delta(removed: ["alpha"]))

        #expect(changed)
        #expect(merged.skills.map(\.id) == ["beta"])
    }

    @Test("an incomplete scan never deletes anything")
    func mergeIgnoresRemovalsWhenIncomplete() {
        let held = catalog([skill("alpha"), skill("beta")])
        let (merged, changed) = AgentSkillMerge.merge(
            held,
            delta: delta(removed: ["alpha"], complete: false),
        )

        // An unread directory is not a deleted skill, and a truncated list is
        // not a shorter one.
        #expect(!changed)
        #expect(merged.skills.map(\.id) == ["alpha", "beta"])
        #expect(!merged.complete)
    }

    @Test("a removed id the phone does not hold is ignored")
    func mergeIgnoresUnknownRemovals() {
        let held = catalog([skill("alpha")])
        let (merged, changed) = AgentSkillMerge.merge(held, delta: delta(removed: ["gone"]))

        #expect(!changed)
        #expect(merged.skills.map(\.id) == ["alpha"])
    }

    @Test("matching fingerprints are not a change")
    func mergeWithNoChanges() {
        let held = catalog([skill("alpha"), skill("beta")])
        let (merged, changed) = AgentSkillMerge.merge(
            held,
            delta: delta(skills: [skill("alpha"), skill("beta")]),
        )

        #expect(!changed)
        #expect(merged.skills == held.skills)
    }

    @Test("duplicate ids collapse instead of crashing")
    func mergeCollapsesDuplicateIds() {
        let held = catalog([skill("alpha", fingerprint: "one"), skill("alpha", fingerprint: "two")])
        let (merged, changed) = AgentSkillMerge.merge(held, delta: delta())
        #expect(changed)
        #expect(merged.skills.map(\.id) == ["alpha"])

        let (newer, _) = AgentSkillMerge.merge(
            catalog([skill("alpha", fingerprint: "one")]),
            delta: delta(skills: [
                skill("alpha", fingerprint: "two"),
                skill("alpha", fingerprint: "three"),
            ]),
        )
        #expect(newer.skills.map(\.fingerprint) == ["three"])
    }

    // MARK: - Store

    @Test("one machine's skills survive a restart")
    func storeRoundTrip() throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileAgentSkillStore(directory: dir)
        let stored = catalog([skill("alpha"), skill("beta", engine: nil)])

        try store.save(stored)
        // A new value, as the next launch would build it.
        let read = try #require(try FileAgentSkillStore(directory: dir).load(hostId: "host-1"))

        #expect(read == stored)
        #expect(read.skills.last?.engine == nil)
        #expect(read.scannedAt == 1_763_351_700_123)
    }

    @Test("nothing stored reads as nothing")
    func storeMissingIsNil() throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try FileAgentSkillStore(directory: dir).load(hostId: "host-1") == nil)
    }

    @Test("a corrupt file reads as nothing")
    func storeCorruptIsNil() throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: dir.appendingPathComponent("host-1.json"))
        #expect(try FileAgentSkillStore(directory: dir).load(hostId: "host-1") == nil)
    }

    @Test("a file written for another machine is not this machine's list")
    func storeRefusesAnotherHost() throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileAgentSkillStore(directory: dir)
        try store.save(catalog([skill("alpha")], hostId: "host-2"))
        #expect(try store.load(hostId: "host-1") == nil)
    }

    @Test("forgetting a machine removes its file")
    func storeDelete() throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileAgentSkillStore(directory: dir)
        try store.save(catalog([skill("alpha")]))
        #expect(try store.load(hostId: "host-1") != nil)

        store.delete(hostId: "host-1")
        #expect(try store.load(hostId: "host-1") == nil)
    }

    @Test("a host id that could escape the directory does not")
    func storeSafeFileNames() throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileAgentSkillStore(directory: dir)

        #expect(FileAgentSkillStore.sanitizedHostId("../../etc/passwd") == "______etc_passwd")
        #expect(FileAgentSkillStore.sanitizedHostId("host:1 with spaces") == "host_1_with_spaces")
        #expect(FileAgentSkillStore.sanitizedHostId("29d9-4a1b") == "29d9-4a1b")

        try store.save(catalog([skill("alpha")], hostId: "../../etc/passwd"))
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        // One file, named by the escaped id and nothing else -- no path
        // separator and no second dot that could climb a directory.
        #expect(files == ["______etc_passwd.json"])
        // Still readable back, which makes the escaping a rename rather than a loss.
        #expect(try store.load(hostId: "../../etc/passwd")?.skills.count == 1)
    }

    @Test("an empty host id is filed under unknown")
    func storeEmptyHostId() throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileAgentSkillStore(directory: dir)

        #expect(FileAgentSkillStore.sanitizedHostId("") == "unknown")
        try store.save(catalog([skill("alpha")], hostId: ""))
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(files == ["unknown.json"])
        #expect(try store.load(hostId: "")?.skills.count == 1)
    }

    // MARK: - Decoding

    @Test("the host's full answer decodes")
    func deltaDecodesFullAnswer() throws {
        let json = """
        {
          "skills": [
            {
              "id": "grilling",
              "name": "grilling",
              "description": "Grill the user relentlessly about a plan.",
              "fingerprint": "9f2a",
              "engine": "dsh"
            }
          ],
          "removed": ["handoff"],
          "complete": true,
          "scannedAt": 1763351700123,
          "engines": [
            { "id": "dsh", "count": 60, "error": null },
            { "id": "claude", "count": 0, "error": "permission denied" }
          ],
          "truncated": false
        }
        """
        let delta = try JSONDecoder().decode(AgentSkillDelta.self, from: Data(json.utf8))

        #expect(delta.skills.map(\.id) == ["grilling"])
        #expect(delta.skills.first?.fingerprint == "9f2a")
        #expect(delta.skills.first?.engine == "dsh")
        #expect(delta.removed == ["handoff"])
        #expect(delta.complete)
        #expect(delta.scannedAt == 1_763_351_700_123)
        #expect(delta.engines.map(\.id) == ["dsh", "claude"])
        #expect(delta.engines.first?.count == 60)
        #expect(delta.engines.last?.error == "permission denied")
        #expect(!delta.truncated)
    }

    @Test("the optional fields default instead of failing the sync")
    func deltaDecodesMissingOptionalFields() throws {
        // `truncated` was the last field added; `removed` and `engines` are
        // always sent today but a decoder should not fail the whole answer over
        // an absent empty array.
        let json = """
        { "skills": [], "complete": true, "scannedAt": 1763351700123 }
        """
        let delta = try JSONDecoder().decode(AgentSkillDelta.self, from: Data(json.utf8))

        #expect(delta.skills.isEmpty)
        #expect(delta.removed.isEmpty)
        #expect(delta.engines.isEmpty)
        #expect(!delta.truncated)
    }

    @Test("a truncated answer says so")
    func deltaDecodesTruncated() throws {
        let json = """
        { "skills": [], "removed": [], "complete": false, "scannedAt": 1, "engines": [], "truncated": true }
        """
        let delta = try JSONDecoder().decode(AgentSkillDelta.self, from: Data(json.utf8))
        #expect(delta.truncated)
        #expect(!delta.complete)
    }

    @Test("the capability bit is what decides support")
    func capabilityDecoding() throws {
        let supported = try JSONDecoder().decode(
            HostPlugin.self,
            from: Data(#"{"id":"dsh-mizar","capabilities":["deepseek.balance.v1","agent.skills.v1"]}"#.utf8),
        )
        #expect(supported.supportsAgentSkills)

        let old = try JSONDecoder().decode(
            HostPlugin.self,
            from: Data(#"{"id":"dsh-mizar","capabilities":["deepseek.balance.v1"]}"#.utf8),
        )
        #expect(!old.supportsAgentSkills)

        // Somebody else's plugin object is not this plugin's capability.
        let other = try JSONDecoder().decode(
            HostPlugin.self,
            from: Data(#"{"id":"other","capabilities":["agent.skills.v1"]}"#.utf8),
        )
        #expect(!other.supportsAgentSkills)
    }
}
