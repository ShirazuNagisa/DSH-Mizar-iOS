//
//  SessionPlacementPolicy.swift
//  DSH-Mizar
//
//  Pure decisions for placing a conversation at its newest message.
//

import CoreGraphics

/// Where a page's conversation is on its way to its first position.
enum InitialPlacement: Equatable {
    /// The page is up and nothing has been committed to it yet.
    case waitingForContent
    /// A conversation has been committed and the placement is running. The
    /// generation is the round, so a correction belonging to an earlier
    /// commit cannot settle a later one.
    case placing(generation: Int)
    /// The newest turn is in view; the message area is live.
    case ready
    /// Explicit turn navigation has taken ownership from initial placement.
    case navigating
    /// The session has no messages: there is no bottom to place against and
    /// nothing to gate.
    case empty
    /// The first read failed with nothing cached: the failure card is the
    /// content, and holding it back would be a spinner for ever.
    case failed
    /// Loaded content whose local placement did not converge. Offer retry.
    case positioningFailed

    /// A content commit (including refresh) may retry an unplaced page, but
    /// never takes position back from a reader or explicit turn navigation.
    @discardableResult
    mutating func beginIfNeeded(generation: Int) -> Bool {
        switch self {
        case .waitingForContent, .empty, .failed, .positioningFailed:
            self = .placing(generation: generation)
            return true
        case .placing, .ready, .navigating:
            return false
        }
    }

    /// Acceptance outlives the active scroll budget; it never issues a scroll.
    @discardableResult
    mutating func finishIfPositioned(
        _ geometry: ConversationPlacementGeometry?,
        tolerance: CGFloat,
    ) -> Bool {
        switch self {
        case .placing, .positioningFailed:
            guard geometry?.isAtBottom(tolerance: tolerance) == true else {
                return false
            }
            self = .ready
            return true
        default:
            return false
        }
    }

    /// Whether the message area may be shown and touched.
    var isRevealed: Bool {
        switch self {
        case .ready, .navigating, .empty, .failed, .positioningFailed:
            return true
        case .waitingForContent, .placing:
            return false
        }
    }
}

/// The scroll geometry used to accept an initial placement and bounded
/// corrections.
struct ConversationPlacementGeometry: Equatable {
    var contentHeight: CGFloat
    var viewportHeight: CGFloat
    var visibleMinY: CGFloat
    var visibleMaxY: CGFloat
    var topInset: CGFloat = 0
    var bottomInset: CGFloat = 0

    func isAtBottom(tolerance: CGFloat) -> Bool {
        guard contentHeight.isFinite, viewportHeight.isFinite,
              visibleMinY.isFinite, visibleMaxY.isFinite,
              topInset.isFinite, bottomInset.isFinite,
              contentHeight > 0, viewportHeight > 0, visibleMaxY > visibleMinY else {
            return false
        }
        // ScrollGeometry's raw visible rect includes content/safe-area insets.
        // Use the usable interval consistently, including for short pages;
        // containerSize and the raw visible rect are not interchangeable.
        let usableMinY = visibleMinY + topInset
        let usableMaxY = visibleMaxY - bottomInset
        let usableHeight = usableMaxY - usableMinY
        guard usableHeight.isFinite, usableHeight > 0 else { return false }
        if abs(contentHeight - usableMaxY) <= tolerance { return true }
        // A conversation shorter than the viewport has no scrollable bottom;
        // where it sits is the bottom. Accept it unless the viewport is wholly
        // past the content -- the shape that showed the blank page. The old
        // check also demanded the page be at the very top, which a short page
        // pushed down a few points by the composer reserve failed, so a
        // readable three-turn session sat behind the failure card.
        if contentHeight <= viewportHeight + tolerance {
            return visibleMinY < contentHeight - tolerance
        }
        // A short, top-aligned conversation is already entirely visible.
        // A viewport wholly below the content must not pass this branch.
        return contentHeight <= usableHeight + tolerance
            && usableMinY <= tolerance
            && usableMaxY >= contentHeight - tolerance
    }
}

/// Pure rules for initial placement and the bounded corrections around it.
enum SessionPlacementPolicy {
    /// How far from the newest message the placement accepts as "at the
    /// bottom", in points. A hair rather than zero: the composer's reserved
    /// room and rounding at non-integral display scales leave a fraction of a
    /// point between the anchor and the end of the content.
    static let tolerance: CGFloat = 4
    /// How many re-aims the placement may spend before offering a retry.
    static let placementAttempts = 32
    /// The spacing between those re-aims, in milliseconds.
    static let placementAttemptSpacingMilliseconds: Int64 = 32
    /// The bounded correction used after an explicit return to the bottom.
    static let explicitNavigationAttempts = 16
    /// The bounded correction that follows ordinary content growth.
    static let bottomCorrectionAttempts = 8
    /// The bounded correction that follows an explicit jump landing.
    static let jumpCorrectionAttempts = 6
    /// The bounded recovery attempts used when the viewport is past content.
    static let pastContentRecoveryAttempts = 3
    /// Past-content recovery waits for layout before reading geometry again.
    static let pastContentRecoverySpacingMilliseconds: Int64 = 120
    /// Past-content recovery treats this much overlap as real content.
    static let pastContentSlack: CGFloat = 2
    /// Eager layout is only a recovery for a page small enough to afford it.
    static let eagerRowLimit = 80

    /// The terminal state for a page whose read produced no content. An empty
    /// session and a failed first read are both answers with content to reveal.
    static func terminalStateWithoutContent(
        hasConversationError: Bool,
    ) -> InitialPlacement {
        hasConversationError ? .failed : .empty
    }

    /// A host answer may replace a cached first frame. Re-arm only when the
    /// operator has not taken the page and its newest message actually moved.
    static func shouldRearmAfterRefresh(
        placement: InitialPlacement,
        userHasScrolled: Bool,
        oldNewest: String?,
        newNewest: String?,
    ) -> Bool {
        !userHasScrolled && placement == .ready && oldNewest != newNewest
    }

    /// Stop an explicit seek once layout has stopped answering. Repeatedly
    /// aiming at identical geometry changes nothing and spends a layout.
    static func shouldStopWhenStill(
        previous: ConversationPlacementGeometry?,
        current: ConversationPlacementGeometry?,
        stopsWhenStill: Bool,
    ) -> Bool {
        guard stopsWhenStill else { return false }
        guard let previous, let current else { return false }
        return previous == current
    }

    /// A viewport needs recovery when it does not intersect the conversation.
    static func needsPastContentRecovery(
        _ geometry: ConversationPlacementGeometry,
    ) -> Bool {
        let top = geometry.visibleMinY + geometry.topInset
        let bottom = geometry.visibleMaxY - geometry.bottomInset
        return !(bottom > 0 && top < geometry.contentHeight - pastContentSlack)
    }

    /// `TurnIndex.visible` is a hint. Eager recovery is affordable only on a
    /// page below the row limit.
    static func shouldForceEager(rowCount: Int) -> Bool {
        rowCount <= eagerRowLimit
    }
}
