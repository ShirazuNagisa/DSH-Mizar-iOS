import Testing
import MizarKit
@testable import DSH_Mizar

@MainActor
@Suite("A created session keeps the list it landed in")
struct CreatedSessionAdoptionTests {
    private func session(
        _ id: String,
        cwd: String,
        updatedAt: Double = 1
    ) -> SessionRow {
        SessionRow(
            sessionId: id,
            updatedAt: updatedAt,
            running: false,
            blank: false,
            agentAvailable: true,
            cwd: cwd,
        )
    }

    private func blank(_ id: String, cwd: String) -> SessionRow {
        SessionRow(
            sessionId: id,
            updatedAt: 2,
            running: false,
            blank: true,
            agentAvailable: true,
            cwd: cwd,
        )
    }

    @Test("a transient list answer cannot erase sessions that were on screen")
    func sessionsAreKept() {
        let previous = [
            session("previous", cwd: "/work/chosen", updatedAt: 3),
            session("other-a", cwd: "/work/other", updatedAt: 2),
            session("other-b", cwd: "/work/other", updatedAt: 1),
        ]
        let transient = [blank("new", cwd: "/work/chosen"), previous[0]]
        let merged = AppModel.sessionsAfterCreate(
            current: transient,
            previous: previous,
            new: blank("new", cwd: "/work/chosen"),
        )

        #expect(merged.map(\.sessionId) == ["new", "previous", "other-a", "other-b"])
    }

    @Test("a partial workspace answer keeps the other workspaces and files the new id")
    func workspacesAreKept() {
        let chosen = WorkspaceRow(
            workspaceId: "dsh:chosen",
            path: "/work/chosen",
            title: "Chosen",
            sessionIds: ["previous"],
        )
        let other = WorkspaceRow(
            workspaceId: "dsh:other",
            path: "/work/other",
            title: "Other",
            sessionIds: ["other-a", "other-b"],
        )
        let merged = AppModel.workspacesAfterCreate(
            current: [chosen],
            previous: [chosen, other],
            cwd: "/work/chosen/",
            sessionId: "new",
        )

        #expect(merged?.map(\.path) == ["/work/chosen", "/work/other"])
        #expect(merged?.first?.sessionIds == ["new", "previous"])
        #expect(merged?.last?.sessionIds == ["other-a", "other-b"])
    }

    @Test("the sidebar keeps every session under a workspace after a create")
    func sidebarGroupsAreComplete() {
        let chosen = WorkspaceRow(
            workspaceId: "dsh:chosen",
            path: "/work/chosen",
            title: "Chosen",
            sessionIds: ["previous"],
        )
        let other = WorkspaceRow(
            workspaceId: "dsh:other",
            path: "/work/other",
            title: "Other",
            sessionIds: ["other-a", "other-b"],
        )
        let previous = [
            session("previous", cwd: "/work/chosen"),
            session("other-a", cwd: "/work/other"),
            session("other-b", cwd: "/work/other"),
        ]
        let new = blank("new", cwd: "/work/chosen")
        let sessions = AppModel.sessionsAfterCreate(
            current: [new, previous[0]],
            previous: previous,
            new: new,
        )
        let workspaces = AppModel.workspacesAfterCreate(
            current: [chosen],
            previous: [chosen, other],
            cwd: "/work/chosen",
            sessionId: "new",
        ) ?? []

        let groups = WorkspaceCatalog.groups(
            sessions: sessions,
            workspaces: workspaces,
            selectedSessionId: "new",
        )
        #expect(groups.count == 2)
        #expect(groups.first?.sessions.map(\.sessionId) == ["new", "previous"])
        #expect(groups.last?.sessions.map(\.sessionId) == ["other-a", "other-b"])
        #expect(groups.allSatisfy { !$0.isUnclaimed })
    }
}
