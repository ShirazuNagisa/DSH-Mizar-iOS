import Testing
@testable import DSH_Mizar

struct SessionPlacementPolicyTests {
    @Test
    func pastContentRecoveryRequiresNonIntersectingGeometry() {
        let atBottom = ConversationPlacementGeometry(
            contentHeight: 6_134,
            viewportHeight: 652,
            visibleMinY: 5_366,
            visibleMaxY: 6_210,
            topInset: 116,
            bottomInset: 76,
        )
        let belowContent = ConversationPlacementGeometry(
            contentHeight: 6_134,
            viewportHeight: 652,
            visibleMinY: 6_260,
            visibleMaxY: 7_104,
            topInset: 116,
            bottomInset: 76,
        )
        let aboveContent = ConversationPlacementGeometry(
            contentHeight: 6_134,
            viewportHeight: 652,
            visibleMinY: -1_200,
            visibleMaxY: -548,
            topInset: 116,
            bottomInset: 76,
        )

        #expect(!SessionPlacementPolicy.needsPastContentRecovery(atBottom))
        #expect(SessionPlacementPolicy.needsPastContentRecovery(belowContent))
        #expect(SessionPlacementPolicy.needsPastContentRecovery(aboveContent))
    }

    @Test
    func refreshRearmsOnlyAnUnclaimedPageWhoseNewestMoved() {
        #expect(SessionPlacementPolicy.shouldRearmAfterRefresh(
            placement: .ready,
            userHasScrolled: false,
            oldNewest: "cached",
            newNewest: "host",
        ))
        #expect(!SessionPlacementPolicy.shouldRearmAfterRefresh(
            placement: .ready,
            userHasScrolled: true,
            oldNewest: "cached",
            newNewest: "host",
        ))
        #expect(!SessionPlacementPolicy.shouldRearmAfterRefresh(
            placement: .ready,
            userHasScrolled: false,
            oldNewest: "same",
            newNewest: "same",
        ))
        #expect(!SessionPlacementPolicy.shouldRearmAfterRefresh(
            placement: .navigating,
            userHasScrolled: false,
            oldNewest: "cached",
            newNewest: "host",
        ))
    }

    @Test
    func seekStillnessAndEagerRecoveryBoundaries() {
        let first = ConversationPlacementGeometry(
            contentHeight: 1_000,
            viewportHeight: 400,
            visibleMinY: 600,
            visibleMaxY: 1_000,
        )
        let changed = ConversationPlacementGeometry(
            contentHeight: 1_000,
            viewportHeight: 400,
            visibleMinY: 620,
            visibleMaxY: 1_020,
        )
        #expect(SessionPlacementPolicy.shouldStopWhenStill(
            previous: first,
            current: first,
            stopsWhenStill: true,
        ))
        #expect(!SessionPlacementPolicy.shouldStopWhenStill(
            previous: first,
            current: first,
            stopsWhenStill: false,
        ))
        #expect(!SessionPlacementPolicy.shouldStopWhenStill(
            previous: nil,
            current: first,
            stopsWhenStill: true,
        ))
        #expect(!SessionPlacementPolicy.shouldStopWhenStill(
            previous: first,
            current: nil,
            stopsWhenStill: true,
        ))
        #expect(!SessionPlacementPolicy.shouldStopWhenStill(
            previous: first,
            current: changed,
            stopsWhenStill: true,
        ))
        #expect(SessionPlacementPolicy.shouldForceEager(rowCount: 80))
        #expect(!SessionPlacementPolicy.shouldForceEager(rowCount: 81))
    }
}
