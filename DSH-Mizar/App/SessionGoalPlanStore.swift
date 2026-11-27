//
//  SessionGoalPlanStore.swift
//  DSH-Mizar
//
//  Where a session's goal and plan live until the desktop can send them.
//
//  The store is a cache with one door: `apply(_:)` is the only writer, so a
//  backend, a fixture and a test all change the same state the same way. The
//  actions are a seam for the same reason -- the cards can be built and felt
//  before the RPCs that back them exist, and the unwired default says so
//  instead of pretending.
//

import Foundation
import Observation
import MizarKit

enum GoalPlanActionError: Error { case notWired }

@MainActor
protocol SessionGoalActions {
    func pause(sessionId: String, goalId: String) async throws
    func resume(sessionId: String, goalId: String) async throws
    func delete(sessionId: String, goalId: String) async throws
}

@MainActor
struct UnwiredGoalActions: SessionGoalActions {
    func pause(sessionId: String, goalId: String) async throws {
        throw GoalPlanActionError.notWired
    }

    func resume(sessionId: String, goalId: String) async throws {
        throw GoalPlanActionError.notWired
    }

    func delete(sessionId: String, goalId: String) async throws {
        throw GoalPlanActionError.notWired
    }
}

@MainActor @Observable
final class SessionGoalPlanStore {
    private(set) var goals: [String: SessionGoal] = [:]
    private(set) var plans: [String: SessionPlan] = [:]
    var actions: any SessionGoalActions = UnwiredGoalActions()

    func goal(for sessionId: String) -> SessionGoal? {
        goals[sessionId]
    }

    func plan(for sessionId: String) -> SessionPlan? {
        plans[sessionId]
    }

    /// The one writer. The backend (item 9) calls this; the fixture calls it in DEBUG.
    func apply(sessionId: String, goal: SessionGoal?, plan: SessionPlan?) {
        goals[sessionId] = goal
        // A plan with no steps is not a plan: `plan` is nil when there is
        // nothing to draw, and an empty list would otherwise draw an empty card.
        plans[sessionId] = plan?.steps.isEmpty == true ? nil : plan
    }

    #if DEBUG
    /// `-mizarGoalFixture` on the launch arguments puts a demo goal and plan on every
    /// desktop DSH session, and swaps `actions` for ones that edit this store.
    func installFixtureIfRequested(sessionId: String) {
        guard ProcessInfo.processInfo.arguments.contains("-mizarGoalFixture") else { return }
        actions = FixtureGoalActions(store: self)

        let now = Date()
        let goal = SessionGoal(
            id: "fixture-goal",
            revision: 1,
            objective: "在 DSH-Mizar 将 Computer Use 的窗口画面、操作进度与接管绑定到宿主提供的真实 DSH 会话和轮次，生成并验证 macOS Developer ID 签名包。",
            phase: .active,
            createdAt: now.addingTimeInterval(-2200),
            updatedAt: now,
        )
        let contents = ["读取会话协议", "梳理窗口事件", "设计绑定表", "实现宿主转发", "真机验证", "签名打包", "回归测试"]
        let steps = contents.enumerated().map { index, content in
            SessionPlanStep(
                id: index,
                content: content,
                status: index < 3 ? .completed : (index == 3 ? .inProgress : .pending),
            )
        }
        apply(sessionId: sessionId, goal: goal, plan: SessionPlan(steps: steps))
    }
    #endif
}

#if DEBUG
/// The fixture's buttons, so the demo goal can be paused, resumed and deleted
/// before the RPCs exist. Every change goes through the store's one writer.
@MainActor
private struct FixtureGoalActions: SessionGoalActions {
    unowned let store: SessionGoalPlanStore

    func pause(sessionId: String, goalId: String) async throws {
        guard let goal = store.goal(for: sessionId), goal.id == goalId else { return }
        store.apply(sessionId: sessionId, goal: goal.with(phase: .paused), plan: store.plan(for: sessionId))
    }

    func resume(sessionId: String, goalId: String) async throws {
        guard let goal = store.goal(for: sessionId), goal.id == goalId else { return }
        store.apply(sessionId: sessionId, goal: goal.with(phase: .active), plan: store.plan(for: sessionId))
    }

    func delete(sessionId: String, goalId: String) async throws {
        guard let goal = store.goal(for: sessionId), goal.id == goalId else { return }
        store.apply(sessionId: sessionId, goal: nil, plan: store.plan(for: sessionId))
    }
}

private extension SessionGoal {
    /// The same goal at a new phase, keeping its revision and stamps.
    func with(phase: SessionGoalPhase) -> SessionGoal {
        SessionGoal(
            id: id,
            revision: revision,
            objective: objective,
            phase: phase,
            blockedReason: blockedReason,
            createdAt: createdAt,
            updatedAt: updatedAt,
        )
    }
}
#endif

/// Whether a session should show the goal and plan row.
enum SessionGoalPlanAvailability {
    /// Whether this session is a DSH session served by the desktop app.
    static func isDesktopDSH(
        sessionId: String,
        isLocalAgent: Bool,
        hasDesktop: Bool,
        engineScope: AgentEngine?,
    ) -> Bool {
        guard !isLocalAgent, hasDesktop else { return false }
        if let colon = sessionId.firstIndex(of: ":"),
           let engine = AgentEngine(rawValue: String(sessionId[..<colon])) {
            return engine == .dsh
        }
        return (engineScope ?? .dsh) == .dsh
    }
}
