//
//  WorkspaceGitTests.swift
//  MizarKitTests
//
//  `session.workspaceGit`: the optional summary behind the composer's Git
//  capsule.
//
//  The one distinction that matters is between "no repository" and "no answer".
//  `git: null` is a successful read that must take the capsule away; a failed
//  read or an older host must leave whatever is on screen alone. Pinning both
//  here keeps the wire shape from quietly turning `null` into three zeroes,
//  which would draw a clean repository for a directory that has none.
//

import Foundation
import Testing
@testable import MizarKit

@Suite("WorkspaceGit")
struct WorkspaceGitTests {
    private func decode(_ json: String) throws -> SessionWorkspaceGitResult {
        try JSONDecoder().decode(SessionWorkspaceGitResult.self, from: Data(json.utf8))
    }

    @Test("decodes the documented answer")
    func decodesSummary() throws {
        let result = try decode(#"""
        {"sessionId": "s-1", "git": {"files": 43, "additions": 4016, "deletions": 202}}
        """#)
        #expect(result.sessionId == "s-1")
        #expect(result.git == WorkspaceGitStatus(files: 43, additions: 4016, deletions: 202))
    }

    @Test("a clean repository keeps its three zeroes, not nil")
    func decodesCleanRepository() throws {
        let result = try decode(#"""
        {"sessionId": "s-1", "git": {"files": 0, "additions": 0, "deletions": 0}}
        """#)
        #expect(result.git == WorkspaceGitStatus(files: 0, additions: 0, deletions: 0))
    }

    @Test("null and an absent git field both mean no repository")
    func decodesNoRepository() throws {
        #expect(try decode(#"{"sessionId": "s-1", "git": null}"#).git == nil)
        #expect(try decode(#"{"sessionId": "s-1"}"#).git == nil)
    }
}
