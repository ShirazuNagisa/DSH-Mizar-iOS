//
//  AgentScopeTests.swift
//  MizarKitTests
//
//  One computer, three agents, and the one the phone opened.
//
//  The reported shape: a phone that had opened DSH showed DSH's five workspaces
//  and, under them, two folders that belong to Codex -- empty, because the
//  sessions in them had already been filtered out. The host merged the three
//  agent lists, and the phone kept them, so one screen was built from two
//  different answers.
//
//  These tests are the phone's own answer to the same question: which half of a
//  merged answer may this connection draw. They also pin the pairing record,
//  because a choice that is forgotten on the next launch is the same bug with a
//  longer delay.
//

import Foundation
import Testing
@testable import MizarKit

/// A workspace row, as a multi-agent host sends it.
private func workspace(
    _ engine: String,
    id: String,
    title: String = "folder",
    path: String? = nil,
) -> WorkspaceRow {
    WorkspaceRow(
        workspaceId: "\(engine):\(id)",
        path: path ?? "/Users/you/projects/\(id)",
        title: title,
        sessionIds: [],
        engine: engine,
    )
}

/// A session row with the given id.
private func session(_ id: String) -> SessionRow {
    SessionRow(
        sessionId: id,
        updatedAt: 1_700_000_000_000,
        running: false,
        blank: false,
        agentAvailable: true,
        cwd: "/Users/you/projects/one",
        parentSessionId: nil,
        origin: nil,
    )
}

@Suite("Which agent a row names")
struct WorkspaceAgentNamingTests {
    @Test("the host's own field is the answer")
    func fieldWins() {
        let row = WorkspaceRow(workspaceId: "whatever", path: "/p", title: "p", engine: "codex")
        #expect(row.namedEngine == "codex")
    }

    @Test("the id's prefix is the answer when the field is absent")
    func prefixWhenTheFieldIsAbsent() {
        // A host from before the `engine` field, but already prefixing ids: the
        // two ends of one upgrade must not disagree about whose row this is.
        let row = WorkspaceRow(workspaceId: "claude:ws-1", path: "/p", title: "p")
        #expect(row.namedEngine == "claude")
    }

    @Test("a bare id names no agent")
    func bareIds() {
        // What a single-agent host and the on-device kernel send.
        #expect(WorkspaceRow(workspaceId: "0f48bea9-cd32", path: "/p", title: "p").namedEngine == nil)
        // A colon is not an agent by itself: a directory named `build:steps`
        // would otherwise become a fourth agent and be hidden everywhere.
        #expect(WorkspaceRow(workspaceId: "build:steps", path: "/p", title: "p").namedEngine == nil)
    }

    @Test("a session id names its agent, and only when it is one")
    func sessionIds() {
        #expect(session("dsh:session-1").namedEngine == "dsh")
        #expect(session("codex:0199-abc").namedEngine == "codex")
        #expect(session("session-1").namedEngine == nil)
        #expect(session("my-project:123").namedEngine == nil)
    }

    @Test("the field decodes without a schema change, and old rows decode too")
    func decoding() throws {
        let withEngine = """
        {"workspaceId":"dsh:1","path":"/p","title":"p","engine":"dsh"}
        """
        let without = """
        {"workspaceId":"dsh:1","path":"/p","title":"p"}
        """
        let decoder = JSONDecoder()
        #expect(try decoder.decode(WorkspaceRow.self, from: Data(withEngine.utf8)).namedEngine == "dsh")
        // A stored index written by the previous build has no `engine` key; it
        // must load, and its id still says whose row it is.
        let stored = try decoder.decode(WorkspaceRow.self, from: Data(without.utf8))
        #expect(stored.engine == nil)
        #expect(stored.namedEngine == "dsh")
    }
}

@Suite("What one agent's connection may draw")
struct AgentScopeFilterTests {
    private let rows = [
        workspace("dsh", id: "ws-1", title: "DSH-Mizar"),
        workspace("claude", id: "ws-2", title: "Skylery"),
        workspace("codex", id: "ws-3", title: "Project-SN"),
    ]

    @Test("a scoped connection keeps its own agent's folders and nothing else")
    func oneAgent() {
        // The report, in one assertion: two folders that do not belong to DSH.
        let drawn = WorkspaceCatalog.scoped(rows, to: "dsh")
        #expect(drawn.map(\.title) == ["DSH-Mizar"])
    }

    @Test("all agents keeps every folder")
    func allAgents() {
        #expect(WorkspaceCatalog.scoped(rows, to: nil).count == 3)
        #expect(WorkspaceCatalog.scoped(rows, to: "").count == 3)
    }

    @Test("a row that names no agent is never dropped")
    func unmaredRows() {
        // A single-agent host's answer is already this connection's answer;
        // dropping it would empty a list that is right.
        let mixed = rows + [WorkspaceRow(workspaceId: "0f48bea9", path: "/p", title: "default-workspace")]
        let drawn = WorkspaceCatalog.scoped(mixed, to: "dsh")
        #expect(drawn.map(\.title) == ["DSH-Mizar", "default-workspace"])
    }

    @Test("sessions follow the same rule")
    func sessions() {
        let rows = [
            session("dsh:session-1"),
            session("claude:2f6c"),
            session("codex:0199"),
            session("session-bare"),
        ]
        #expect(WorkspaceCatalog.scoped(rows, to: "dsh").map(\.sessionId) == ["dsh:session-1", "session-bare"])
        #expect(WorkspaceCatalog.scoped(rows, to: nil).count == 4)
    }
}

@Suite("Which agent a workspace heading names")
struct WorkspaceGroupAgentTests {
    @Test("the group carries the row's agent, so a merged list can be read")
    func groupCarries() {
        let rows = [
            WorkspaceRow(workspaceId: "dsh:ws-1", path: "/a", title: "Mine", sessionIds: ["dsh:s1"], engine: "dsh"),
            WorkspaceRow(workspaceId: "codex:/b", path: "/b", title: "Theirs", sessionIds: ["codex:s2"], engine: "codex"),
        ]
        let groups = WorkspaceCatalog.groups(
            sessions: [session("dsh:s1"), session("codex:s2")],
            workspaces: rows,
            selectedSessionId: nil,
        )
        #expect(groups.map(\.engine) == ["dsh", "codex"])
    }

    @Test("a fallback group built from directories names no agent")
    func fallbackIsAnonymous() {
        let groups = WorkspaceCatalog.groups(
            sessions: [session("dsh:s1")],
            workspaces: nil,
            selectedSessionId: nil,
        )
        #expect(groups.map(\.engine) == [nil])
    }

    @Test("the leftover group names no agent")
    func unclaimedIsAnonymous() {
        let rows = [WorkspaceRow(workspaceId: "dsh:ws-1", path: "/a", title: "Mine", sessionIds: [], engine: "dsh")]
        let groups = WorkspaceCatalog.groups(
            sessions: [session("dsh:s1")],
            workspaces: rows,
            selectedSessionId: nil,
        )
        #expect(groups.count == 2)
        #expect(groups.last?.isUnclaimed == true)
        #expect(groups.last?.engine == nil)
    }
}

@Suite("The agent a pairing remembers")
struct PairedHostAgentTests {
    private func pairing(engine: String? = nil, engines: [String]? = nil) -> PairedHost {
        PairedHost(
            hostId: "host-1",
            hostName: "Studio",
            authority: "10.0.0.9:19390",
            deviceId: "device-1",
            deviceToken: "token-1",
            engine: engine,
            knownEngines: engines,
        )
    }

    @Test("a record written before the choice still decodes")
    func decodesWithoutTheField() throws {
        let text = """
        {"hostId":"host-1","hostName":"Studio","deviceId":"device-1",\
        "deviceToken":"token-1","pairedAt":700000000}
        """
        let host = try JSONDecoder().decode(PairedHost.self, from: Data(text.utf8))
        #expect(host.engine == nil)
        #expect(host.knownEngines == nil)
        #expect(host.engineChoices.isEmpty)
        #expect(host.deviceToken == "token-1")
    }

    @Test("round-trips the choice")
    func roundTrips() throws {
        let host = pairing(engine: "dsh", engines: ["dsh", "claude", "codex"])
        let decoded = try JSONDecoder().decode(PairedHost.self, from: JSONEncoder().encode(host))
        #expect(decoded == host)
        #expect(decoded.engine == "dsh")
        #expect(decoded.engineChoices == ["dsh", "claude", "codex"])
    }

    @Test("every copy carries the choice with it")
    func copiesKeepTheChoice() {
        // A copy that dropped it would undo the choice on a rename, an address
        // change or a relay move -- three things that happen to a working phone
        // without anybody touching the picker.
        let host = pairing(engine: "claude", engines: ["dsh", "claude", "codex"])
        #expect(host.renamed(to: "Desk").engine == "claude")
        #expect(host.moved(to: "10.0.0.10:19390").engine == "claude")
        #expect(host.moved(toRelay: "https://relay.example.com/r/ROOM").engine == "claude")
        #expect(host.remembering(netEndpointId: "KEY").engine == "claude")
        #expect(host.remembering(desktop: HostDesktop(os: "macOS", client: "AGI Mizar")).engine == "claude")
        // And the learned list survives with it.
        #expect(host.renamed(to: "Desk").engineChoices.count == 3)
    }

    @Test("only a computer with something to choose offers a choice")
    func choices() {
        #expect(pairing(engines: nil).engineChoices.isEmpty)
        #expect(pairing(engines: ["dsh"]).engineChoices.isEmpty)
        #expect(pairing(engines: ["dsh", "claude"]).engineChoices == ["dsh", "claude"])
    }

    @Test("a replacement choice is a copy, not a mutation")
    func reopened() {
        let host = pairing(engine: "dsh", engines: ["dsh", "claude", "codex"])
        let switched = host.opened(on: "codex")
        #expect(switched.engine == "codex")
        #expect(host.engine == "dsh")
        #expect(switched.deviceToken == host.deviceToken)
        // "All agents" is a choice too, and it is spelled the same way as
        // never having chosen.
        #expect(switched.opened(on: nil).engine == nil)
    }

    @Test("the learned list can be replaced without losing the choice")
    func rememberedEngines() {
        let host = pairing(engine: "dsh", engines: ["dsh"])
        let withThree = host.remembering(engines: ["dsh", "claude", "codex"])
        #expect(withThree.engine == "dsh")
        #expect(withThree.engineChoices.count == 3)
    }
}

@Suite("The scope a host answers with")
struct HostInfoScopeTests {
    @Test("a host that names its agent decodes, and one that does not is nil")
    func decodes() throws {
        let text = """
        {"hostId":"h","hostName":"Studio","home":"/Users/you","protocolVersion":1,\
        "engines":[{"id":"dsh","label":"DSH","connected":true},{"id":"codex"}],\
        "engine":"dsh"}
        """
        let info = try JSONDecoder().decode(HostInfo.self, from: Data(text.utf8))
        #expect(info.engine == "dsh")
        #expect(info.engines?.count == 2)
        #expect(info.engines?.first?.label == "DSH")
        #expect(info.engines?.last?.id == "codex")

        let older = """
        {"hostId":"h","hostName":"Studio","home":"/Users/you","protocolVersion":1}
        """
        let plain = try JSONDecoder().decode(HostInfo.self, from: Data(older.utf8))
        #expect(plain.engine == nil)
        #expect(plain.engines == nil)
    }
}

@Suite("The engine a connection asks for")
struct HelloEngineTests {
    @Test("the choice rides at the top level of hello, where the host reads it")
    func encodesAtTopLevel() throws {
        let frame = ClientFrame.hello(
            id: "h1",
            token: "mz_token",
            appVersion: "1.0",
            deviceModel: "iPhone17,1",
            engine: "dsh",
        )
        let data = try JSONEncoder().encode(frame)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["type"] as? String == "hello")
        #expect(object["engine"] as? String == "dsh")
        // Beside the token rather than inside `payload`: the host reads `hello`
        // at the top level, and a field nested here is a field it never sees.
        #expect(object["token"] as? String == "mz_token")
        #expect(object["payload"] == nil)
    }

    @Test("a phone that did not choose sends no engine at all")
    func omitsWhenAbsent() throws {
        let frame = ClientFrame.hello(id: nil, token: "mz_token", appVersion: nil, deviceModel: nil)
        let data = try JSONEncoder().encode(frame)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["engine"] == nil)
    }
}

@Suite("The account a connection belongs to")
struct HelloAccountTests {
    /// The key the computer reads with `Hello.account_id`, spelled the way it
    /// parses it: a rename on either side is a check that silently stops
    /// checking, which is worse than one that fails.
    @Test("the account rides at the top level, beside the token")
    func encodesAtTopLevel() throws {
        let frame = ClientFrame.hello(
            id: nil,
            token: "mz_token",
            appVersion: "1.0",
            deviceModel: "iPhone17,1",
            engine: "dsh",
            accountId: "8f14e45f-ceea-467a-9575-4b1d3f7c1a2b",
        )
        let data = try JSONEncoder().encode(frame)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["accountId"] as? String == "8f14e45f-ceea-467a-9575-4b1d3f7c1a2b")
        #expect(object["payload"] == nil, "the host reads hello at the top level")
    }

    @Test("a signed-out phone sends no account, and is not asked to")
    func omitsWhenSignedOut() throws {
        let frame = ClientFrame.hello(
            id: nil,
            token: "mz_token",
            appVersion: nil,
            deviceModel: nil,
            accountId: nil,
        )
        let data = try JSONEncoder().encode(frame)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["accountId"] == nil)
        // Absent, not null: an older computer reads unknown keys, and `null`
        // would be a value it has to interpret.
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("accountId"))
    }
}
