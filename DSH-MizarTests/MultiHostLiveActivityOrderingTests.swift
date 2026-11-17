import XCTest
import MizarKit
@testable import DSH_Mizar

final class MultiHostLiveActivityOrderingTests: XCTestCase {
    @MainActor
    func testOldestWaitWinsBeforeStableCompositeId() {
        let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let olderWait = LiveActivityRow(
            id: "session-z",
            prompt: "",
            elapsed: 600,
            countingSince: startedAt.addingTimeInterval(-600),
            hostId: "host-z",
            status: .waitingApproval,
            waitingSince: startedAt.addingTimeInterval(-120),
        )
        let newerWait = LiveActivityRow(
            id: "session-a",
            prompt: "",
            elapsed: 900,
            countingSince: startedAt.addingTimeInterval(-900),
            hostId: "host-a",
            status: .waitingApproval,
            waitingSince: startedAt.addingTimeInterval(-30),
        )

        let ordered = MultiHostLiveActivityMonitor.displayOrderedRows([newerWait, olderWait])

        XCTAssertEqual(ordered.map(\.hostId), ["host-z", "host-a"])
    }
}
