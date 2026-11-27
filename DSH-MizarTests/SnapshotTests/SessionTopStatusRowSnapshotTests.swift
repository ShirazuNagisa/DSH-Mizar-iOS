//
//  SessionTopStatusRowSnapshotTests.swift
//  DSH-MizarTests
//
//  The goal and plan chips, and the two goal cards.
//
//  The running goal is deliberately absent: its capsule reads the wall clock, so
//  a reference of it would drift by a pixel every second. `SessionGoalDuration`
//  covers that arithmetic; the rest of the states are fixed stamps.
//
//  The row is rendered with `scrolls: false`: `ImageRenderer` cannot draw a
//  `ScrollView` (the reference comes out an empty rectangle), so the same
//  capsules are drawn without the UIKit container.
//

import SwiftUI
import Testing
import MizarKit
@testable import DSH_Mizar

@MainActor
struct SessionTopStatusRowSnapshotTests {
    private static let start = Date(timeIntervalSince1970: 1_700_000_000)

    private static func goal(
        phase: SessionGoalPhase,
        blockedReason: String? = nil,
    ) -> SessionGoal {
        SessionGoal(
            id: "fixture-goal",
            revision: 1,
            objective: "在 DSH-Mizar 将 Computer Use 的窗口画面、操作进度与接管绑定到宿主提供的真实 DSH 会话和轮次，生成并验证 macOS Developer ID 签名包。",
            phase: phase,
            blockedReason: blockedReason,
            createdAt: start.addingTimeInterval(-2200),
            updatedAt: start,
        )
    }

    private static let plan = SessionPlan(steps: [
        SessionPlanStep(id: 0, content: "读取会话协议", status: .completed),
        SessionPlanStep(id: 1, content: "梳理窗口事件", status: .completed),
        SessionPlanStep(id: 2, content: "设计绑定表", status: .completed),
        SessionPlanStep(id: 3, content: "实现宿主转发", status: .inProgress),
        SessionPlanStep(id: 4, content: "真机验证", status: .pending),
        SessionPlanStep(id: 5, content: "签名打包", status: .pending),
        SessionPlanStep(id: 6, content: "回归测试", status: .pending),
    ])

    private static func row(goal: SessionGoal?, plan: SessionPlan?) -> some View {
        SessionTopStatusRow(
            goal: goal,
            plan: plan,
            openCard: nil,
            scrolls: false,
            onToggle: { _ in },
        )
        .frame(width: 402, height: 50)
    }

    @Test
    func goalChipIsPaused() throws {
        let snapshot = try SnapshotHarness.assertSnapshot(
            of: Self.row(goal: Self.goal(phase: .paused), plan: nil),
            named: "SessionTopRow-goalChips-paused",
            size: CGSize(width: 402, height: 50),
        )
        #expect(snapshot.pixelWidth == 804)
        #expect(snapshot.pixelHeight == 100)
    }

    @Test
    func goalChipIsBlocked() throws {
        let snapshot = try SnapshotHarness.assertSnapshot(
            of: Self.row(goal: Self.goal(phase: .blocked), plan: nil),
            named: "SessionTopRow-goalChips-blocked",
            size: CGSize(width: 402, height: 50),
        )
        #expect(snapshot.pixelWidth == 804)
        #expect(snapshot.pixelHeight == 100)
    }

    @Test
    func goalChipIsComplete() throws {
        let snapshot = try SnapshotHarness.assertSnapshot(
            of: Self.row(goal: Self.goal(phase: .complete), plan: nil),
            named: "SessionTopRow-goalChips-complete",
            size: CGSize(width: 402, height: 50),
        )
        #expect(snapshot.pixelWidth == 804)
        #expect(snapshot.pixelHeight == 100)
    }

    @Test
    func planChipShowsThreeOfSeven() throws {
        let snapshot = try SnapshotHarness.assertSnapshot(
            of: Self.row(goal: nil, plan: Self.plan),
            named: "SessionTopRow-planChip",
            size: CGSize(width: 402, height: 50),
        )
        #expect(snapshot.pixelWidth == 804)
        #expect(snapshot.pixelHeight == 100)
    }

    @Test
    func goalCardWhileActive() throws {
        let card = SessionGoalCard(
            goal: Self.goal(phase: .active),
            now: Self.start,
            notice: nil,
            onEdit: {},
            onPause: {},
            onResume: {},
            onDelete: {},
        )

        let snapshot = try SnapshotHarness.assertSnapshot(
            of: card,
            named: "SessionGoalCard-active",
            size: CGSize(width: 370, height: 220),
        )
        #expect(snapshot.pixelWidth == 740)
        #expect(snapshot.pixelHeight == 440)
    }

    @Test
    func goalCardWhilePaused() throws {
        let card = SessionGoalCard(
            goal: Self.goal(phase: .paused),
            now: Self.start,
            notice: nil,
            onEdit: {},
            onPause: {},
            onResume: {},
            onDelete: {},
        )

        let snapshot = try SnapshotHarness.assertSnapshot(
            of: card,
            named: "SessionGoalCard-paused",
            size: CGSize(width: 370, height: 220),
        )
        #expect(snapshot.pixelWidth == 740)
        #expect(snapshot.pixelHeight == 440)
    }
}
