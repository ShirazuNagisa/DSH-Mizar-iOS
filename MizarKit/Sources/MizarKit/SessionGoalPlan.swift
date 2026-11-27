//
//  SessionGoalPlan.swift
//  MizarKit
//
//  The session's goal and its plan, as values. The fields follow the desktop's
//  `GoalSnapshot` / `TodoItem`; the wire format is decided by the batch that
//  reads them, so these types stay plain.
//

import Foundation

public enum SessionGoalPhase: String, Sendable, Equatable, CaseIterable {
    case active, paused, blocked, complete
}

public struct SessionGoal: Sendable, Equatable, Identifiable {
    public let id: String
    public let revision: Int
    public let objective: String
    public let phase: SessionGoalPhase
    public let blockedReason: String?
    public let createdAt: Date
    public let updatedAt: Date
    public init(id: String, revision: Int, objective: String, phase: SessionGoalPhase,
                blockedReason: String? = nil, createdAt: Date, updatedAt: Date) {
        self.id = id
        self.revision = revision
        self.objective = objective
        self.phase = phase
        self.blockedReason = blockedReason
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum SessionPlanStepStatus: String, Sendable, Equatable {
    case pending
    case inProgress = "in_progress"
    case completed
}

public struct SessionPlanStep: Sendable, Equatable, Identifiable {
    public let id: Int          // index in the list
    public let content: String
    public let status: SessionPlanStepStatus
    public init(id: Int, content: String, status: SessionPlanStepStatus) {
        self.id = id
        self.content = content
        self.status = status
    }
}

public struct SessionPlan: Sendable, Equatable {
    public let steps: [SessionPlanStep]
    public init(steps: [SessionPlanStep]) {
        self.steps = steps
    }
    public var completedCount: Int { steps.count(where: { $0.status == .completed }) }
    public var hasStepInProgress: Bool { steps.contains { $0.status == .inProgress } }
}
