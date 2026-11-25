import MizarKit

/// Pure list reconciliation for the transient host indexes returned after a
/// session is created. The caller owns row creation and app state mutation.
enum CreatedSessionAdoption {
    /// The session list after a create, minus a transient list answer.
    static func sessionsAfterCreate(
        current: [SessionRow],
        previous: [SessionRow],
        new: SessionRow,
    ) -> [SessionRow] {
        var merged = current
        if !merged.contains(where: { $0.sessionId == new.sessionId }) {
            merged.insert(new, at: 0)
        }
        let ids = Set(merged.map(\.sessionId))
        merged.append(contentsOf: previous.filter { !ids.contains($0.sessionId) })
        return merged
    }

    /// The workspace list after a create, with the new session filed under the
    /// directory the operator chose.
    static func workspacesAfterCreate(
        current: [WorkspaceRow]?,
        previous: [WorkspaceRow]?,
        cwd: String,
        sessionId: String,
    ) -> [WorkspaceRow]? {
        guard var next = current ?? previous else { return nil }
        if let previous {
            let paths = Set(next.map(\.path))
            for old in previous where !paths.contains(old.path) {
                next.append(old)
            }
        }
        let normalized = normalizedPath(cwd)
        return next.map { workspace in
            guard normalizedPath(workspace.path) == normalized else { return workspace }
            var ids = workspace.sessionIds ?? []
            if !ids.contains(sessionId) { ids.insert(sessionId, at: 0) }
            return WorkspaceRow(
                workspaceId: workspace.workspaceId,
                path: workspace.path,
                title: workspace.title,
                sessionIds: ids,
                engine: workspace.engine,
            )
        }
    }

    private static func normalizedPath(_ path: String) -> String {
        var value = path
        while value.count > 1, value.hasSuffix("/") { value.removeLast() }
        return value
    }
}
