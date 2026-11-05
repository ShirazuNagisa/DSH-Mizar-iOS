//
//  AgentTargetTests.swift
//  DSH-MizarTests
//
//  The phone's Agent picker has five destinations: DSH, CC GUI, CC CLI,
//  Codex GUI and Codex CLI. The host still scopes by three engines, so the
//  GUI/CLI bit is the phone's own filter over `SessionRow.source`.
//

import Foundation
import MizarKit
import Testing
@testable import DSH_Mizar

@MainActor
struct AgentTargetTests {
    @Test func thePickerHasFiveDestinationsInOrder() {
        #expect(AgentTarget.all.map(\.title) == [
            "DSH", "CC GUI", "CC CLI", "Codex GUI", "Codex CLI",
        ])
        #expect(AgentTarget.all.map(\.id) == [
            "dsh", "claude-gui", "claude-cli", "codex-gui", "codex-cli",
        ])
    }

    @Test func onlyDSHIsAnEngineWithNoSurface() {
        #expect(AgentTarget.all.filter { $0.surface == nil }.map(\.engine) == [.dsh])
    }

    @Test func fourTargetsAreMarkedExperimental() {
        #expect(AgentTarget.all.filter(\.isExperimental).count == 4)
        #expect(AgentTarget.all.first?.isExperimental == false)
        let gui = AgentTarget(engine: .claude, surface: .gui)
        #expect(gui.experimentalTitle.contains(gui.experimentalSuffix))
        #expect(gui.experimentalTitle.hasPrefix("CC GUI"))
    }

    @Test func sourceDecodesFromTheHostRow() throws {
        let json = """
        {"sessionId":"claude:s1","updatedAt":1,"running":false,"blank":false,
         "agentAvailable":true,"cwd":"/tmp","origin":null,
         "engine":"claude","source":"claude_desktop"}
        """.data(using: .utf8)!
        let row = try JSONDecoder().decode(SessionRow.self, from: json)
        #expect(row.source == "claude_desktop")
        #expect(row.namedEngine == "claude")
    }

    @Test func guiAndCLISplitOneEnginesRows() {
        let rows = [
            SessionRow(
                sessionId: "claude:gui", updatedAt: 3, running: false, blank: false,
                agentAvailable: true, cwd: "/tmp", source: "claude_desktop",
            ),
            SessionRow(
                sessionId: "claude:cli", updatedAt: 2, running: false, blank: false,
                agentAvailable: true, cwd: "/tmp", source: nil,
            ),
            SessionRow(
                sessionId: "codex:gui", updatedAt: 1, running: false, blank: false,
                agentAvailable: true, cwd: "/tmp", source: "codex_desktop",
            ),
        ]
        #expect(AppModel.surfaced(rows, to: .gui).map(\.sessionId) == [
            "claude:gui", "codex:gui",
        ])
        #expect(AppModel.surfaced(rows, to: .cli).map(\.sessionId) == ["claude:cli"])
        #expect(AppModel.surfaced(rows, to: nil).count == 3)
    }
}
