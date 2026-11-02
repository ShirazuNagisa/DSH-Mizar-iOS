//
//  HistorySyncPolicyTests.swift
//  MizarKitTests
//
//  The history pass may skip a session only when the stored conversation was
//  synced at or after the row's last change. A cache written before this field
//  existed, or one that is behind, must still be read.
//

import Foundation
import Testing
@testable import MizarKit

@Suite("History sync policy")
struct HistorySyncPolicyTests {
    private func cached(synced: Double?) -> CachedConversation {
        CachedConversation(
            sessionId: "session",
            items: [],
            throughSeq: nil,
            syncedUpdatedAt: synced,
        )
    }

    @Test("No cache is never current")
    func noCacheIsNotCurrent() {
        #expect(!HistorySyncPolicy.isCurrent(nil, updatedAt: 10))
    }

    @Test("A cache written before the field existed is not current")
    func preUpgradeCacheIsNotCurrent() {
        #expect(!HistorySyncPolicy.isCurrent(cached(synced: nil), updatedAt: 10))
    }

    @Test("A cache behind the row is not current")
    func behindIsNotCurrent() {
        #expect(!HistorySyncPolicy.isCurrent(cached(synced: 9), updatedAt: 10))
    }

    @Test("A cache at the row's instant covers it")
    func equalCovers() {
        #expect(HistorySyncPolicy.isCurrent(cached(synced: 10), updatedAt: 10))
    }

    @Test("A cache ahead of the row covers it")
    func aheadCovers() {
        #expect(HistorySyncPolicy.isCurrent(cached(synced: 11), updatedAt: 10))
    }
}
