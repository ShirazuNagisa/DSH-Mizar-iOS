import Foundation
import Testing
@testable import MizarKit

@Suite("Approval surface row selection")
struct LiveActivityProjectionSelectionTests {
    private let instant = Date(timeIntervalSince1970: 1_800_000_000)

    private func at(_ seconds: TimeInterval) -> Date {
        instant.addingTimeInterval(seconds)
    }

    private func row(
        _ id: String,
        host: String = "host",
        status: LiveActivitySessionStatus = .running,
        waitingSince: Date? = nil,
        countingSince: Date? = nil,
    ) -> LiveActivityRow {
        LiveActivityRow(id: id, prompt: "prompt", elapsed: 30, countingSince: countingSince ?? instant,
                        hostId: host, hostName: host, status: status, waitingSince: waitingSince)
    }

    private func approval(
        _ request: String,
        session: String,
        host: String = "host",
        requestedAt: Date? = nil,
    ) -> LiveActivityApproval {
        LiveActivityApproval(requestId: request, sessionId: session, tool: "Bash", detail: "Approve?",
                             hostId: host, requestedAt: requestedAt)
    }

    @Test("retains selected session and next priority row in source order")
    func selectedRowAfterCapacityKeepsRelativeOrder() {
        let state = LiveActivityState(rows: [row("oldest"), row("next"), row("selected"), row("later")])

        let visible = state.approvalSurfaceRows(capacity: 2, selectedApproval: approval("request", session: "selected"))

        #expect(visible.map(\.id) == ["oldest", "selected"])
    }

    @Test("fills after a selected first row from the priority order")
    func selectedFirstKeepsNextPriorityRow() {
        let state = LiveActivityState(rows: [row("selected"), row("next"), row("later")])

        let visible = state.approvalSurfaceRows(capacity: 2, selectedApproval: approval("request", session: "selected"))

        #expect(visible.map(\.id) == ["selected", "next"])
    }

    @Test("multiple requests for one session retain its single matching row")
    func multipleApprovalsForSameSession() {
        let requests = [approval("request-1", session: "target"), approval("request-2", session: "target")]
        let state = LiveActivityState(rows: [row("first"), row("target"), row("last")], approvals: requests)
        let selectedRequest = requests[1]

        let visible = state.approvalSurfaceRows(capacity: 2, selectedApproval: selectedRequest)

        #expect(visible.map(\.id) == ["first", "target"])
    }

    @Test("does not guess a selected row when legacy identity is incomplete")
    func incompleteApprovalIdentityUsesPriorityOrder() {
        let state = LiveActivityState(rows: [row("first"), row("second"), row("target")])

        let visible = state.approvalSurfaceRows(capacity: 2, selectedApproval: approval("request", session: "target", host: ""))

        #expect(visible.map(\.id) == ["first", "second"])
    }

    @Test("prioritizes approval, answer, and longest run, then restores source order")
    func statusAndAgePriorityWithStablePresentation() {
        let rows = [
            row("running-short", status: .running, countingSince: at(-10)),
            row("running-long", status: .running, countingSince: at(-100)),
            row("answer", status: .waitingAnswer, waitingSince: at(-200)),
            row("approval", status: .waitingApproval, waitingSince: at(-300)),
            row("selected", status: .offline),
        ]
        let approvals = [approval("pending", session: "approval", requestedAt: at(-400))]
        let state = LiveActivityState(rows: rows, approvals: approvals)

        let visible = state.approvalSurfaceRows(capacity: 4, selectedApproval: approval("selected", session: "selected"))

        #expect(visible.map(\.id) == ["running-long", "answer", "approval", "selected"])
    }

    @Test("chooses the oldest same-status wait even when it appears later in input")
    func sameStatusWaitAgeBeatsInputOrder() {
        let rows = [
            row("newer", status: .waitingApproval, waitingSince: at(-1_000)),
            row("older", status: .waitingApproval, waitingSince: at(-10)),
            row("selected", status: .offline),
        ]
        let approvals = [
            approval("newer-request", session: "newer", requestedAt: at(-5)),
            approval("older-request", session: "older", requestedAt: at(-100)),
            approval("oldest-older-request", session: "older", requestedAt: at(-200)),
        ]
        let state = LiveActivityState(rows: rows, approvals: approvals)

        let visible = state.approvalSurfaceRows(capacity: 2, selectedApproval: approval("selected", session: "selected"))

        #expect(visible.map(\.id) == ["older", "selected"])
    }

    @Test("chooses the oldest answer wait before a running session")
    func answerAgeBeatsRunningPriority() {
        let rows = [
            row("running", status: .running, countingSince: at(-1_000)),
            row("answer-new", status: .waitingAnswer, waitingSince: at(-20)),
            row("answer-old", status: .waitingAnswer, waitingSince: at(-200)),
            row("selected", status: .offline),
        ]
        let state = LiveActivityState(rows: rows)

        let visible = state.approvalSurfaceRows(capacity: 2, selectedApproval: approval("selected", session: "selected"))

        #expect(visible.map(\.id) == ["answer-old", "selected"])
    }

    @Test("keeps missing wait times in stable input order without inventing dates")
    func missingWaitTimesFallBackStably() {
        let rows = [
            row("missing-b", status: .waitingAnswer),
            row("known", status: .waitingAnswer, waitingSince: at(-10)),
            row("missing-a", status: .waitingAnswer),
            row("selected", status: .offline),
        ]
        let state = LiveActivityState(rows: rows)

        let visible = state.approvalSurfaceRows(capacity: 3, selectedApproval: approval("selected", session: "selected"))

        #expect(visible.map(\.id) == ["missing-b", "known", "selected"])
    }

    @Test("decodes old rows without a waiting timestamp")
    func legacyRowWithoutWaitingSinceDecodes() throws {
        let data = Data(#"{"id":"legacy","prompt":"prompt","elapsed":30,"countingSince":1800000000,"hostId":"host","hostName":"Mac","status":"waitingAnswer"}"#.utf8)

        let decoded = try JSONDecoder().decode(LiveActivityRow.self, from: data)

        #expect(decoded.status == .waitingAnswer)
        #expect(decoded.waitingSince == nil)
    }

    @Test("copies waiting timestamp into bounded state and treats its change as presentation")
    func waitingSinceSurvivesProjectionAndComparison() {
        let waiting = row("waiting", status: .waitingAnswer, waitingSince: at(-60))
        let original = LiveActivityState(rows: [waiting])
        let bounded = original.boundedForActivity()
        let later = LiveActivityState(rows: [row("waiting", status: .waitingAnswer, waitingSince: at(-30))])

        #expect(bounded.rows.first?.waitingSince == waiting.waitingSince)
        #expect(!original.hasSamePresentation(as: later))
    }
}
