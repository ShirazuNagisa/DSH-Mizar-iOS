//
//  WorkspaceGit.swift
//  MizarKit
//
//  A session's working tree, as the host counts it.
//
//  `session.workspaceGit` is the optional read behind the composer's Git
//  capsule. It answers about the directory the host's own session record
//  names, not about a path the phone chose: the phone has no way to know
//  which of a machine's worktrees a conversation belongs to, and it should
//  not have to. The host discovers the repository the way Git does, counts
//  the worktree against HEAD and answers a plain summary.
//
//  A host from before this method answers `NOT_IMPLEMENTED`. That is a
//  normal answer for an old computer, not a failure to show: the caller
//  stops asking for the rest of the connection and draws no capsule.
//

import Foundation

/// One working tree's distance from HEAD.
///
/// The three numbers are already net: a file staged and then edited again is
/// one file, and a line added and removed again is neither. Binary files
/// count as files but contribute no lines.
public struct WorkspaceGitStatus: Codable, Sendable, Equatable {
    /// How many paths differ from HEAD, including untracked files.
    public let files: Int
    /// Lines added across those paths.
    public let additions: Int
    /// Lines removed across those paths.
    public let deletions: Int

    public init(files: Int, additions: Int, deletions: Int) {
        self.files = files
        self.additions = additions
        self.deletions = deletions
    }
}

/// The host's answer to `session.workspaceGit`.
public struct SessionWorkspaceGitResult: Decodable, Sendable, Equatable {
    /// The session the answer is about, echoed back.
    public let sessionId: String
    /// The working tree's figures, or `nil` when the session's directory is
    /// not inside a repository -- which is not the same answer as a failure,
    /// and is why this field is optional rather than three zeroes.
    public let git: WorkspaceGitStatus?

    public init(sessionId: String, git: WorkspaceGitStatus?) {
        self.sessionId = sessionId
        self.git = git
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId) ?? ""
        // `null`, an absent field and an answer from a host whose repository
        // disappeared all read the same way: no worktree to report.
        git = try container.decodeIfPresent(WorkspaceGitStatus.self, forKey: .git)
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId
        case git
    }
}

// MARK: - The call

public extension MizarConnection {
    /// Read one session's working-tree figures.
    ///
    /// - Parameter sessionId: the session whose directory the host should
    ///   inspect.
    /// - Returns: the summary, or `nil` under `git` when there is no
    ///   repository.
    /// - Throws: ``MizarError`` when the host refuses. An older host answers
    ///   `NOT_IMPLEMENTED`, which callers treat as "no capsule" rather than
    ///   as an error worth showing.
    func sessionWorkspaceGit(sessionId: String) async throws -> SessionWorkspaceGitResult {
        try await call(
            "session.workspaceGit",
            payload: .object(["sessionId": .string(sessionId)]),
            as: SessionWorkspaceGitResult.self,
        )
    }
}
