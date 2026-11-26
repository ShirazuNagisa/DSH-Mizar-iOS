import Foundation
import MizarKit
import Testing
@testable import DSH_Mizar

@MainActor
@Suite("Conversation sync coordinator")
struct ConversationSyncCoordinatorTests {
    @Test("a partial batch ignores duplicates and unknown ids and retries only the omission")
    func partialBatchRetriesOnlyOmissions() async throws {
        let driver = Driver(sessions: [session("a"), session("b")])
        driver.batchScript = [
            .answered(try batch([
                try item("a"),
                try item("outsider"),
                try item("a"),
            ])),
            .answered(try batch([try item("b")])),
        ]
        driver.pages = ["a": try page("a"), "b": try page("b")]

        await driver.coordinator.sync(using: driver.operations)

        #expect(driver.batchCalls.map(\.ids) == [["a", "b"], ["b"]])
        #expect(driver.fallbackCalls.isEmpty)
        #expect(driver.applied == ["a", "b"])
        #expect(driver.finished == ["host-a"])
        #expect(!driver.coordinator.isSyncing)
    }

    @Test("an unsupported batch is requested once and fallback stays within 24 session windows")
    func unsupportedBatchIsRememberedAcrossWindows() async throws {
        let rows = (0..<50).map { session("s\($0)") }
        let driver = Driver(sessions: rows)
        driver.batchScript = [.unsupported]
        driver.pages = try Dictionary(uniqueKeysWithValues: rows.map { ($0.sessionId, try page($0.sessionId)) })

        await driver.coordinator.sync(using: driver.operations)

        #expect(driver.batchCalls.count == 1)
        #expect(driver.fallbackCalls.map(\.count) == [24, 24, 2])
        #expect(driver.fallbackCalls.allSatisfy { $0.count <= 24 })
        #expect(driver.applied.count == 50)
        #expect(driver.finished == ["host-a"])
    }

    @Test("an empty answered batch falls back for that window and batching remains available")
    func emptyBatchDoesNotDisableBatching() async throws {
        let rows = (0..<25).map { session("s\($0)") }
        let driver = Driver(sessions: rows)
        driver.batchScript = [.answered(try batch([])), .answered(try batch(rows.map { try item($0.sessionId) }))]
        driver.pages = try Dictionary(uniqueKeysWithValues: rows.map { ($0.sessionId, try page($0.sessionId)) })

        await driver.coordinator.sync(using: driver.operations)

        #expect(driver.batchCalls.map { $0.ids.count } == [24, 1])
        #expect(driver.fallbackCalls.map(\.count) == [24])
        #expect(driver.applied.count == 25)
        #expect(driver.finished == ["host-a"])
    }

    @Test("a failed batch item reaches the single-session retry path")
    func failedItemUsesReconnectCapableApply() async throws {
        let driver = Driver(sessions: [session("a")])
        driver.batchScript = [.answered(try batch([try failedItem("a")]))]

        await driver.coordinator.sync(using: driver.operations)

        #expect(driver.applyAttempts == ["a"])
        #expect(driver.applied.isEmpty)
        #expect(driver.fallbackCalls.isEmpty)
        #expect(driver.finished == ["host-a"])
    }

    @Test("a late old-host answer with colliding session ids cannot apply or finish the new run")
    func oldHostReplyIsStaleAfterSwitch() async throws {
        let driver = Driver(sessions: [session("same-id")])
        let oldBatchEntered = SyncTestSignal()
        let releaseOldBatch = SyncTestSignal()
        driver.batchGateByHost["host-a"] = (oldBatchEntered, releaseOldBatch)
        driver.batchScriptByHost["host-a"] = [.answered(try batch([try item("same-id")]))]
        driver.batchScriptByHost["host-b"] = [.answered(try batch([try item("same-id")]))]
        driver.pages = ["same-id": try page("same-id")]

        let oldRun = Task { await driver.coordinator.sync(using: driver.operations) }
        await oldBatchEntered.wait()
        driver.identity = .init(hostId: "host-b", invalidation: 1)
        await releaseOldBatch.release()
        await oldRun.value

        #expect(driver.applied.isEmpty)
        #expect(driver.finished.isEmpty)
        #expect(!driver.coordinator.isSyncing)

        await driver.coordinator.sync(using: driver.operations)

        #expect(driver.batchCalls.map(\.host) == ["host-a", "host-b"])
        #expect(driver.applied == ["same-id"])
        #expect(driver.finished == ["host-b"])
    }

    @Test("switching away and back to the same host id invalidates the old reply")
    func switchingAwayAndBackInvalidatesSuspendedReply() async throws {
        let driver = Driver(sessions: [session("same-id")])
        let entered = SyncTestSignal()
        let release = SyncTestSignal()
        driver.batchGateByHost["host-a"] = (entered, release)
        driver.batchScriptByHost["host-a"] = [
            .answered(try batch([try item("same-id")])),
            .answered(try batch([try item("same-id")])),
        ]
        driver.pages = ["same-id": try page("same-id")]

        let run = Task { await driver.coordinator.sync(using: driver.operations) }
        await entered.wait()
        driver.identity = .init(hostId: "host-b", invalidation: 1)
        driver.identity = .init(hostId: "host-a", invalidation: 2)
        await release.release()
        await run.value

        #expect(driver.applied.isEmpty)
        #expect(driver.finished.isEmpty)
        #expect(driver.coordinator.progress == nil)

        await driver.coordinator.sync(using: driver.operations)

        #expect(driver.batchCalls.map(\.identity) == [
            .init(hostId: "host-a", invalidation: 0),
            .init(hostId: "host-a", invalidation: 2),
        ])
        #expect(driver.applied == ["same-id"])
        #expect(driver.finished == ["host-a"])
    }

    @Test("a second sync request cannot start while the first pass is suspended")
    func onlyOnePassCanRunAtOnce() async throws {
        let driver = Driver(sessions: [session("same-id")])
        let entered = SyncTestSignal()
        let release = SyncTestSignal()
        driver.batchGateByHost["host-a"] = (entered, release)
        driver.batchScript = [.answered(try batch([try item("same-id")]))]
        driver.pages = ["same-id": try page("same-id")]

        let firstRun = Task { await driver.coordinator.sync(using: driver.operations) }
        await entered.wait()
        await driver.coordinator.sync(using: driver.operations)

        #expect(driver.batchCalls.count == 1)
        #expect(driver.finished.isEmpty)
        #expect(driver.coordinator.isSyncing)

        await release.release()
        await firstRun.value

        #expect(driver.batchCalls.count == 1)
        #expect(driver.finished == ["host-a"])
        #expect(!driver.coordinator.isSyncing)
    }

    @Test("a disconnected host stops the pass before requesting the next window")
    func disconnectStopsBeforeNextWindow() async throws {
        let rows = (0..<25).map { session("s\($0)") }
        let driver = Driver(sessions: rows)
        driver.batchHandler = { _, entries in
            driver.isConnected = false
            return .answered(try batch(entries.map { try item($0.session.sessionId) }))
        }

        await driver.coordinator.sync(using: driver.operations)

        #expect(driver.batchCalls.map { $0.ids.count } == [24])
        #expect(driver.applied.count == 24)
        #expect(driver.fallbackCalls.isEmpty)
        #expect(driver.coordinator.progress == nil)
    }

    @Test("cancellation after a committed window leaves only unfinished sessions for retry")
    func cancellationKeepsCommittedWindowAndRetriesRemainder() async throws {
        let rows = (0..<25).map { session("s\($0)") }
        let driver = Driver(sessions: rows)
        let secondBatchEntered = SyncTestSignal()
        let releaseSecondBatch = SyncTestSignal()
        driver.pages = try Dictionary(uniqueKeysWithValues: rows.map { ($0.sessionId, try page($0.sessionId)) })
        driver.batchHandler = { call, _ in
            if call == 1 {
                return .answered(try batch(rows.prefix(24).map { try item($0.sessionId) }))
            }
            await secondBatchEntered.release()
            await releaseSecondBatch.wait()
            return .answered(try batch([try item("s24")]))
        }

        let run = Task { await driver.coordinator.sync(using: driver.operations) }
        await secondBatchEntered.wait()
        run.cancel()
        await releaseSecondBatch.release()
        await run.value

        #expect(driver.applied.count == 24)
        #expect(driver.applied.allSatisfy { $0 != "s24" })
        #expect(driver.finished.isEmpty)
        #expect(driver.coordinator.progress == nil)
        #expect(!driver.coordinator.isSyncing)

        driver.batchHandler = nil
        driver.batchScript = [.answered(try batch([try item("s24")]))]
        await driver.coordinator.sync(using: driver.operations)

        #expect(driver.batchCalls.last?.ids == ["s24"])
        #expect(driver.applied.count == 25)
        #expect(driver.finished == ["host-a"])
        #expect(driver.coordinator.progress == nil)
    }

    private func session(_ id: String, updatedAt: Double = 1) -> SessionRow {
        SessionRow(
            sessionId: id,
            updatedAt: updatedAt,
            running: false,
            blank: false,
            agentAvailable: true,
            cwd: "/work",
        )
    }

    private func page(_ id: String) throws -> SessionMessagesResult {
        let source = #"{"sessionId":"\#(id)","asOfSeq":1,"records":[],"hasMore":false}"#
        return try JSONDecoder().decode(SessionMessagesResult.self, from: Data(source.utf8))
    }

    private func batch(_ items: [String]) throws -> SessionSyncResult {
        let source = #"{"items":[\#(items.joined(separator: ","))]}"#
        return try JSONDecoder().decode(SessionSyncResult.self, from: Data(source.utf8))
    }

    private func item(_ id: String) throws -> String {
        let object: [String: Any] = [
            "sessionId": id,
            "messages": ["sessionId": id, "asOfSeq": 1, "records": [], "hasMore": false],
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func failedItem(_ id: String) throws -> String {
        let object: [String: Any] = [
            "sessionId": id,
            "error": ["code": "REMOTE_ERROR", "message": "scripted failure"],
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}

@MainActor
private final class Driver {
    struct BatchCall {
        let host: String
        let identity: ConversationSyncCoordinator.RunIdentity
        let ids: [String]
    }

    var isConnected = true
    var identity = ConversationSyncCoordinator.RunIdentity(hostId: "host-a", invalidation: 0)
    let sessions: [SessionRow]
    var batchCalls: [BatchCall] = []
    var fallbackCalls: [[String]] = []
    var applyAttempts: [String] = []
    var applied: [String] = []
    var finished: [String] = []
    var fallbackHosts: [String] = []
    var pages: [String: SessionMessagesResult] = [:]
    var committed = Set<String>()
    var batchScript: [ConversationSyncCoordinator.Batch] = []
    var batchScriptByHost: [String: [ConversationSyncCoordinator.Batch]] = [:]
    var batchGateByHost: [String: (SyncTestSignal, SyncTestSignal)] = [:]
    var batchHandler: (@MainActor (Int, [ConversationSyncCoordinator.Entry]) async throws -> ConversationSyncCoordinator.Batch)?
    let coordinator = ConversationSyncCoordinator()

    init(sessions: [SessionRow]) {
        self.sessions = sessions
    }

    var operations: ConversationSyncCoordinator.Operations {
        ConversationSyncCoordinator.Operations(
            identity: { self.identity },
            initialTotal: { self.sessions.count },
            isConnected: { self.isConnected },
            preflight: { _ in .ready(self.sessions) },
            load: { id in
                guard self.committed.contains(id), let row = self.sessions.first(where: { $0.sessionId == id }) else { return nil }
                return CachedConversation(
                    sessionId: id,
                    items: [],
                    throughSeq: 1,
                    syncedUpdatedAt: row.updatedAt,
                )
            },
            nextCursor: { cached in
                if let delivered = cached?.deliveredSeq { return .after(delivered) }
                if cached == nil { return .empty }
                return .unstated
            },
            batch: { identity, entries in
                let host = identity.hostId
                self.batchCalls.append(BatchCall(host: host, identity: identity, ids: entries.map { $0.session.sessionId }))
                if let (entered, release) = self.batchGateByHost[host] {
                    await entered.release()
                    await release.wait()
                }
                if let handler = self.batchHandler {
                    return (try? await handler(self.batchCalls.count, entries)) ?? .failed("scripted batch failed")
                }
                if var script = self.batchScriptByHost[host], !script.isEmpty {
                    let next = script.removeFirst()
                    self.batchScriptByHost[host] = script
                    return next
                }
                if !self.batchScript.isEmpty { return self.batchScript.removeFirst() }
                return .failed("no scripted batch response")
            },
            fallback: { identity, entries in
                let ids = entries.map { $0.session.sessionId }
                self.fallbackHosts.append(identity.hostId)
                self.fallbackCalls.append(ids)
                return self.pages.filter { ids.contains($0.key) }
            },
            applyPage: { entry, page, isCurrent in
                let id = entry.session.sessionId
                self.applyAttempts.append(id)
                guard isCurrent(), page != nil else { return }
                self.applied.append(id)
                self.committed.insert(id)
            },
            markUnchanged: { entry, isCurrent in
                guard isCurrent() else { return }
                self.committed.insert(entry.session.sessionId)
            },
            finish: { identity, isCurrent in
                guard isCurrent() else { return nil }
                self.finished.append(identity.hostId)
                return nil
            },
            log: { _ in },
        )
    }
}

private actor SyncTestSignal {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation in
            if released { continuation.resume() }
            else { waiters.append(continuation) }
        }
    }

    func release() {
        guard !released else { return }
        released = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}
