import Foundation

public extension LiveActivityState {
    /// Keeps an approval's session visible within a bounded row budget, then
    /// fills remaining slots by approval, answer, running and offline priority.
    /// Older known waits and longer-running sessions rank first. The returned
    /// rows retain their original relative order for consistent presentation.
    func approvalSurfaceRows(capacity: Int, selectedApproval: LiveActivityApproval?) -> [LiveActivityRow] {
        let limit = max(0, capacity)
        guard limit > 0 else { return [] }

        var retainedIDs = Set<String>()
        if let approval = selectedApproval,
           !approval.hostId.isEmpty,
           !approval.sessionId.isEmpty,
           let selected = rows.first(where: { $0.hostId == approval.hostId && $0.id == approval.sessionId }) {
            retainedIDs.insert(selected.compositeId)
        }

        let allApprovals = approvals + (selectedApproval.map { [$0] } ?? [])
        func priority(of status: LiveActivitySessionStatus) -> Int {
            switch status {
            case .waitingApproval: 0
            case .waitingAnswer: 1
            case .running: 2
            case .offline: 3
            }
        }
        func waitingApprovalTime(for row: LiveActivityRow) -> Date? {
            let requestTime = allApprovals
                .filter { $0.hostId == row.hostId && $0.sessionId == row.id }
                .compactMap(\.requestedAt)
                .min()
            return requestTime ?? row.waitingSince
        }
        func priorityTime(for row: LiveActivityRow) -> Date? {
            switch row.status {
            case .waitingApproval: waitingApprovalTime(for: row)
            case .waitingAnswer: row.waitingSince
            case .running: row.countingSince
            case .offline: nil
            }
        }

        let candidates = rows.enumerated()
            .filter { !retainedIDs.contains($0.element.compositeId) }
            .sorted { left, right in
                let leftPriority = priority(of: left.element.status)
                let rightPriority = priority(of: right.element.status)
                guard leftPriority == rightPriority else { return leftPriority < rightPriority }

                let leftTime = priorityTime(for: left.element)
                let rightTime = priorityTime(for: right.element)
                switch (leftTime, rightTime) {
                case let (left?, right?) where left != right:
                    return left < right
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                default:
                    return left.offset < right.offset
                }
            }
        for candidate in candidates where retainedIDs.count < limit {
            retainedIDs.insert(candidate.element.compositeId)
        }

        return rows.filter { retainedIDs.contains($0.compositeId) }
    }

    /// ActivityKit's state budget is shared by every desktop. Only presentation
    /// strings are shortened; routing identities always remain exact.
    func boundedForActivity() -> LiveActivityState {
        func clipped(_ value: String, bytes: Int) -> String {
            guard value.utf8.count > bytes else { return value }
            var result = ""
            for character in value {
                let next = result + String(character)
                if next.utf8.count + 3 > bytes { break }
                result = next
            }
            return result + "…"
        }
        var state = self
        state.rows = Array(rows.prefix(4)).map { row in
            .init(id: row.id, prompt: "", title: clipped(row.displayTitle, bytes: 160), elapsed: row.elapsed,
                  countingSince: row.countingSince, hostId: row.hostId, hostName: clipped(row.hostName, bytes: 48),
                  status: row.status, waitingSince: row.waitingSince)
        }
        state.approvals = Array(approvals.prefix(4)).map { approval in
            let detail = clipped(approval.detail, bytes: 240)
            let tool = clipped(approval.tool, bytes: 64)
            return .init(requestId: approval.requestId, sessionId: approval.sessionId, tool: tool, detail: detail,
                         hostId: approval.hostId, hostName: clipped(approval.hostName, bytes: 48), requestedAt: approval.requestedAt,
                         requiresDetail: approval.requiresDetail || detail != approval.detail || tool != approval.tool || detail.isEmpty)
        }
        let encoder = JSONEncoder()
        while (try? encoder.encode(state).count) ?? Int.max > 3_500 {
            if state.approvals.count > 1 { state.approvals.removeLast() }
            else if state.rows.count > 1 { state.rows.removeLast() }
            else if !state.approvals.isEmpty { state.approvals.removeLast() }
            else if !state.rows.isEmpty { state.rows.removeLast() }
            else { break }
        }
        return state
    }
}

public extension LiveActivityState {
    /// Time ticks locally; metadata, waiting states and approvals do not. This
    /// comparison must not suppress a pending approval on an unchanged session.
    func hasSamePresentation(as other: LiveActivityState) -> Bool {
        guard rows.count == other.rows.count, approvals == other.approvals,
              totalCount == other.totalCount, deviceCount == other.deviceCount,
              approvalCount == other.approvalCount, longestRunningSince == other.longestRunningSince else { return false }
        return zip(rows, other.rows).allSatisfy { left, right in
            left.compositeId == right.compositeId && left.hostName == right.hostName
                && left.status == right.status && left.prompt == right.prompt && left.title == right.title
                && left.waitingSince == right.waitingSince
                && abs(left.countingSince.timeIntervalSince(right.countingSince)) < 1
        }
    }
}
