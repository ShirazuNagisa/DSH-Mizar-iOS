import Foundation

public struct LiveActivityApprovalFeedback: Codable, Sendable, Equatable {
    public enum Phase: String, Codable, Sendable { case sending, accepted, rejected, failed, unknown }
    public var phase: Phase
    public var message: String
    public var updatedAt: Date
    public init(phase: Phase, message: String, updatedAt: Date = Date()) {
        self.phase = phase; self.message = message; self.updatedAt = updatedAt
    }

    public static func answerResult(
        _ result: LiveActivityAnswers.Result,
        outcome: ApprovalOutcome,
    ) -> Self {
        switch result {
        case .accepted:
            return .init(
                phase: outcome == .allowedOnce ? .accepted : .rejected,
                message: outcome == .allowedOnce ? String(localized: "Allowed once") : String(localized: "Rejected"),
            )
        case .unavailable:
            return .init(phase: .failed, message: String(localized: "Could not connect. Try again."))
        case .rejected:
            return .init(phase: .failed, message: String(localized: "Request changed. Open details."))
        case .unknown:
            return .init(phase: .unknown, message: String(localized: "Result unknown. Open details to check."))
        }
    }
}
public struct LiveActivityPresentation: Codable, Sendable, Equatable {
    public var selectedApprovalId: String?
    public var feedback: [String: LiveActivityApprovalFeedback] = [:]
    public init(selectedApprovalId: String? = nil, feedback: [String: LiveActivityApprovalFeedback] = [:]) {
        self.selectedApprovalId = selectedApprovalId; self.feedback = feedback
    }
}

/// Keeps the operator's current approval in focus as the host queue changes.
public enum LiveActivityApprovalSelection {
    /// Preserve a still-pending selection; when it disappears, advance through
    /// the previous stable queue before falling back to the new queue's first item.
    public static func reconciledId(
        currentId: String?,
        previous: [LiveActivityApproval],
        incoming: [LiveActivityApproval],
    ) -> String? {
        let next = ordered(incoming)
        guard !next.isEmpty else { return currentId }
        let incomingIds = Set(next.map(\.compositeId))
        if let currentId, incomingIds.contains(currentId) { return currentId }
        guard let currentId else { return next.first?.compositeId }

        let old = ordered(previous)
        if let index = old.firstIndex(where: { $0.compositeId == currentId }), !old.isEmpty {
            let following = Array(old.dropFirst(index + 1)) + Array(old.prefix(index + 1))
            if let successor = following.first(where: { incomingIds.contains($0.compositeId) }) {
                return successor.compositeId
            }
        }
        return next.first?.compositeId
    }

    private static func ordered(_ approvals: [LiveActivityApproval]) -> [LiveActivityApproval] {
        approvals.sorted {
            let left = $0.requestedAt ?? .distantPast
            let right = $1.requestedAt ?? .distantPast
            if left != right { return left < right }
            return $0.compositeId < $1.compositeId
        }
    }
}

/// Presentation only: no credentials or command details cross into the widget.
public enum LiveActivityPresentationStore {
    public static let group = "group.me.shirazu.dshmizar.liveactivity"
    private static let key = "activity.presentation.v2"
    public static func read() -> LiveActivityPresentation {
        guard let data = UserDefaults(suiteName: group)?.data(forKey: key),
              let result = try? JSONDecoder().decode(LiveActivityPresentation.self, from: data) else { return .init() }
        return result
    }
    public static func write(_ value: LiveActivityPresentation) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults(suiteName: group)?.set(data, forKey: key)
    }
}
