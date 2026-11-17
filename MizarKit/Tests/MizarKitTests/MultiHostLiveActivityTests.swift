import Foundation
import Testing
@testable import MizarKit

private let multiHostEpoch = Date(timeIntervalSince1970: 1_800_000_000)

@Suite("Multi-host Live Activity state")
struct MultiHostLiveActivityTests {
    @Test("legacy rows and approvals decode defaults and round-trip")
    func legacyPayloadDecodesAndNewPayloadRoundTrips() throws {
        let legacy = #"{"rows":[{"id":"s1","prompt":"run","elapsed":12,"countingSince":800000000}],"approvals":[{"requestId":"r1","sessionId":"s1","tool":"Bash","detail":"rm"}]}"#
        let state = try JSONDecoder().decode(LiveActivityState.self, from: Data(legacy.utf8))

        #expect(state.rows.first?.hostId == "")
        #expect(state.rows.first?.status == .running)
        #expect(state.approvals.first?.hostId == "")
        #expect(state.approvals.first?.requestedAt == nil)
        #expect(state.approvals.first?.requiresDetail == false)
        #expect(state.totalCount == 1)
        #expect(state.deviceCount == 1)
        #expect(state.approvalCount == 1)
        #expect(state.revision == 0)
        #expect(state.presentationRevision == 0)

        let roundTripped = try JSONDecoder().decode(LiveActivityState.self, from: JSONEncoder().encode(state))
        #expect(roundTripped == state)
    }

    @Test("same local session and request ids remain distinct across hosts")
    func compositeIdsIncludeHostWithoutChangingLegacyIds() {
        let rowA = LiveActivityRow(id: "session", prompt: "a", elapsed: 1, countingSince: multiHostEpoch, hostId: "host-a")
        let rowB = LiveActivityRow(id: "session", prompt: "b", elapsed: 1, countingSince: multiHostEpoch, hostId: "host-b")
        let approvalA = LiveActivityApproval(requestId: "request", sessionId: "session", tool: "Bash", detail: "", hostId: "host-a")
        let approvalB = LiveActivityApproval(requestId: "request", sessionId: "session", tool: "Bash", detail: "", hostId: "host-b")

        #expect(rowA.id == "session")
        #expect(rowA.compositeId != rowB.compositeId)
        #expect(approvalA.id == "request")
        #expect(approvalA.compositeId != approvalB.compositeId)
    }

    @Test("waiting rows do not take the running headline or longest clock")
    func waitingDoesNotBecomeHeadline() {
        let waiting = LiveActivityRow(
            id: "waiting", prompt: "approve", elapsed: 9_000,
            countingSince: multiHostEpoch.addingTimeInterval(-9_000), status: .waitingApproval,
        )
        let running = LiveActivityRow(
            id: "running", prompt: "work", elapsed: 80,
            countingSince: multiHostEpoch.addingTimeInterval(-80), status: .running,
        )
        let state = LiveActivityState(rows: [waiting, running])

        #expect(state.headline == 80)
        #expect(state.longestRunningSince == running.countingSince)
    }

    @Test("decision caps displayed data at four while retaining source counts")
    func decisionCapsDisplayAndKeepsActualCounts() {
        let sessions = (1...6).map { index in
            RunningSession(
                id: "session-\(index)", prompt: "work \(index)", elapsedWhenSeeded: TimeInterval(index * 100),
                seededAt: multiHostEpoch,
            )
        }
        let approvals = (1...5).map { index in
            LiveActivityApproval(
                requestId: "request-\(index)", sessionId: "session-\(index)", tool: "Bash", detail: "",
                hostId: index == 5 ? "host-b" : "host-a",
            )
        }
        let decision = LiveActivityDecision.make(
            sessions: sessions,
            approvals: approvals,
            appOpenedSinceLastFinish: false,
            now: multiHostEpoch,
            hostId: "host-a",
            hostName: "Mac A",
        )

        #expect(decision.phase.rows.count == 4)
        #expect(decision.phase.approvals.count == 4)
        #expect(decision.phase.totalCount == 6)
        #expect(decision.phase.deviceCount == 2)
        #expect(decision.phase.approvalCount == 5)
        #expect(decision.phase.longestRunningSince == multiHostEpoch.addingTimeInterval(-600))
        #expect(decision.phase.rows.allSatisfy { $0.hostId == "host-a" && $0.hostName == "Mac A" })
    }

    @Test("approval-only decisions preserve approval counts and stay active")
    func approvalOnlyStateHasZeroRows() {
        let approvals = (1...5).map { index in
            LiveActivityApproval(requestId: "r\(index)", sessionId: "s\(index)", tool: "Bash", detail: "", hostId: "host-a")
        }
        let decision = LiveActivityDecision.make(
            sessions: [], approvals: approvals, appOpenedSinceLastFinish: false, now: multiHostEpoch,
        )

        #expect(decision.phase.rows.isEmpty)
        #expect(decision.phase.approvals.count == 4)
        #expect(decision.phase.totalCount == 0)
        #expect(decision.phase.deviceCount == 1)
        #expect(decision.phase.approvalCount == 5)
        #expect(decision.phase.isFinished == false)
    }
}
