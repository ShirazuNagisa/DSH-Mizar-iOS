//
//  FixtureTests.swift
//  MizarKitTests
//
//  Golden frames captured from a live host.
//
//  The unit tests above check the parser against frames this repository wrote.
//  These check it against frames the *host* wrote. That is a different claim: a
//  hand-written frame and a real one agree only as long as someone remembers to
//  keep them in sync, and nothing fails when they stop.
//
//  The files live at `protocol/fixtures/` and are read from there rather than
//  copied into the test bundle, so the TypeScript suite validates the exact same
//  bytes. Refresh them with:
//
//      MIZAR_WRITE_FIXTURES=1 scripts/dev.sh smoke
//

import Foundation
import Testing
@testable import MizarKit

/// A fixture captured from a live host.
private struct Fixture {
    let name: String
    let raw: Data
}

/// Locate `protocol/fixtures/` from this file's own path.
private var fixturesDirectory: URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // MizarKitTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // MizarKit
        .deletingLastPathComponent()  // repository root
        .appendingPathComponent("protocol/fixtures")
}

/// Every captured fixture.
private func loadFixtures() throws -> [Fixture] {
    let names = try FileManager.default.contentsOfDirectory(atPath: fixturesDirectory.path)
    return try names
        .filter { $0.hasSuffix(".json") }
        .sorted()
        .map { name in
            Fixture(
                name: String(name.dropLast(".json".count)),
                raw: try Data(contentsOf: fixturesDirectory.appendingPathComponent(name)),
            )
        }
}

@Suite("Golden frames from a live host")
struct FixtureTests {
    @Test("the fixture set is present")
    func fixturesExist() throws {
        let fixtures = try loadFixtures()
        // A missing directory would make every assertion below vacuously pass.
        #expect(!fixtures.isEmpty, "no fixtures at \(fixturesDirectory.path)")
        for expected in [
            "welcome", "host-info", "session-list", "session-stats",
            "model-catalog", "permissions-catalog", "interactions-pending", "error-frame",
        ] {
            #expect(fixtures.contains { $0.name == expected }, "fixture \(expected) is missing")
        }
    }

    @Test("every fixture decodes as a server frame this build understands")
    func allFixturesDecode() throws {
        // These two are protocol tables, not API frames: one is the state
        // table, the other the state channel's byte vectors. Both are read by
        // their own suites.
        let tables: Set<String> = ["session-state", "state-frames"]
        for fixture in try loadFixtures() where !tables.contains(fixture.name) {
            let frame = try JSONDecoder().decode(ServerFrame.self, from: fixture.raw)
            if case .unknown(let type, _) = frame {
                Issue.record("fixture \(fixture.name) decoded as an unknown frame type \(type)")
            }
        }
    }

    @Test("the welcome fixture matches the model")
    func welcomeFixture() throws {
        let fixture = try #require(try loadFixtures().first { $0.name == "welcome" })
        guard case .welcome(let welcome) = try JSONDecoder().decode(ServerFrame.self, from: fixture.raw) else {
            Issue.record("expected a welcome")
            return
        }
        #expect(welcome.protocolVersion == mizarProtocolVersion)
        #expect(!welcome.hostId.isEmpty)
        #expect(!welcome.hostName.isEmpty)
    }

    @Test("the host.info fixture decodes into HostInfo")
    func hostInfoFixture() throws {
        let fixture = try #require(try loadFixtures().first { $0.name == "host-info" })
        let frame = try JSONDecoder().decode(ServerFrame.self, from: fixture.raw)
        let result = try #require(frame.resultValue)
        let info = try result.decoded(as: HostInfo.self)
        #expect(info.protocolVersion == mizarProtocolVersion)
        #expect(!info.hostName.isEmpty)
    }

    @Test("the session list decodes into rows")
    func sessionListFixture() throws {
        let fixture = try #require(try loadFixtures().first { $0.name == "session-list" })
        let frame = try JSONDecoder().decode(ServerFrame.self, from: fixture.raw)
        let result = try #require(frame.resultValue)
        let list = try result.decoded(as: SessionListResult.self)
        #expect(!list.items.isEmpty)
        for row in list.items {
            #expect(!row.sessionId.isEmpty)
            #expect(row.updatedAt > 0)
        }
    }

    @Test("a session row carries the additive title, model and context")
    func sessionRowAdditiveFields() throws {
        // The three fields that let a history sync name its rows without one
        // `session.stats` request each. `pressureTokens` is the spelling the
        // host puts on the wire (`session.messages` and `session.stats` use it
        // too) -- the desktop's own domain struct calls the same number `used`,
        // and decoding that spelling here would leave the ring without a count.
        let modern = """
        {"sessionId":"dsh:s","updatedAt":1,"running":false,"blank":false,"agentAvailable":true,
         "cwd":null,"parentSessionId":null,"origin":null,"source":null,
         "title":"会话","model":"deepseek-chat",
         "context":{"window":128000,"pressureTokens":32000,"percent":25}}
        """
        let row = try JSONDecoder().decode(SessionRow.self, from: Data(modern.utf8))
        #expect(row.title == "会话")
        #expect(row.model == "deepseek-chat")
        #expect(row.context?.window == 128_000)
        #expect(row.context?.pressureTokens == 32_000)
        #expect(row.context?.percent == 25)

        // An older host sends none of the three. The row still decodes, and the
        // fields read as "not said" rather than as a zero nobody claimed.
        let older = """
        {"sessionId":"dsh:o","updatedAt":1,"running":false,"blank":true,"agentAvailable":true,"cwd":null}
        """
        let legacy = try JSONDecoder().decode(SessionRow.self, from: Data(older.utf8))
        #expect(legacy.title == nil)
        #expect(legacy.model == nil)
        #expect(legacy.context == nil)
    }

    @Test("the usage fixture decodes into a stats frame")
    func sessionStatsFixture() throws {
        let fixture = try #require(try loadFixtures().first { $0.name == "session-stats" })
        let frame = try JSONDecoder().decode(ServerFrame.self, from: fixture.raw)
        let result = try #require(frame.resultValue)
        let stats = try result.decoded(as: SessionStatsResult.self)
        // The four counters the cache-hit formula needs must survive decoding.
        let usage = try #require(stats.stats?.tokenUsage)
        #expect(usage.billedInputTokens == usage.uncachedInputTokens + usage.cacheReadTokens + usage.cacheWriteTokens)
    }

    @Test("the model catalog decodes, including reasoning efforts")
    func modelCatalogFixture() throws {
        let fixture = try #require(try loadFixtures().first { $0.name == "model-catalog" })
        let frame = try JSONDecoder().decode(ServerFrame.self, from: fixture.raw)
        let result = try #require(frame.resultValue)
        let catalog = try result.decoded(as: ModelCatalog.self)
        #expect(!catalog.providers.isEmpty)
        for provider in catalog.providers {
            for model in provider.models {
                #expect(!model.id.isEmpty)
                // A model with no efforts must decode as an empty list, never as
                // nil, because the picker branches on emptiness.
                for effort in model.efforts {
                    #expect(!effort.id.isEmpty)
                }
            }
        }
    }

    @Test("the permission catalog decodes and never offers `custom` as a target")
    func permissionCatalogFixture() throws {
        let fixture = try #require(try loadFixtures().first { $0.name == "permissions-catalog" })
        let frame = try JSONDecoder().decode(ServerFrame.self, from: fixture.raw)
        let result = try #require(frame.resultValue)
        let catalog = try result.decoded(as: PermissionCatalog.self)
        #expect(!catalog.options.isEmpty)
        // `custom` is derived-only: it can be the current value but must never be
        // a selectable row.
        #expect(!catalog.options.contains { $0.value == "custom" })
        for option in catalog.options {
            #expect(!option.name.isEmpty)
        }
    }

    @Test("the pending interactions fixture decodes")
    func interactionsFixture() throws {
        let fixture = try #require(try loadFixtures().first { $0.name == "interactions-pending" })
        let frame = try JSONDecoder().decode(ServerFrame.self, from: fixture.raw)
        let result = try #require(frame.resultValue)
        _ = try result.decoded(as: PendingInteractions.self)
    }

    @Test("the error fixture carries a code this build classifies")
    func errorFixture() throws {
        let fixture = try #require(try loadFixtures().first { $0.name == "error-frame" })
        guard case .failure(let error, _) = try JSONDecoder().decode(ServerFrame.self, from: fixture.raw) else {
            Issue.record("expected a failure")
            return
        }
        #expect(!error.code.isEmpty)
        #expect(!error.message.isEmpty)
    }

    @Test("no fixture leaks a credential")
    func fixturesCarryNoSecrets() throws {
        // These files are committed. A device token or a token hash reaching one
        // would be a credential in version control.
        for fixture in try loadFixtures() {
            let text = String(decoding: fixture.raw, as: UTF8.self)
            #expect(!text.contains("deviceToken"), "\(fixture.name) contains a device token")
            #expect(!text.contains("tokenHash"), "\(fixture.name) contains a token hash")
            #expect(!text.contains("mz_"), "\(fixture.name) contains a token")
        }
    }
}

private extension ServerFrame {
    /// The `result` of an `ok` frame, for the fixtures that are all `ok`.
    var resultValue: JSONValue? {
        if case .ok(_, let result) = self { return result }
        return nil
    }
}
