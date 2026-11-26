import Foundation
import Testing
@testable import DSH_Mizar

@MainActor
@Suite("Link watchdog coordinator")
struct LinkWatchdogCoordinatorTests {
    @Test("the watchdog starts only while the app is active")
    func activeOnly() async {
        let harness = LinkWatchdogHarness(active: false)
        harness.coordinator.start(using: harness.operations)

        #expect(!harness.coordinator.isRunning)
        #expect(harness.sleeper.durations.isEmpty)

        harness.active = true
        harness.coordinator.start(using: harness.operations)
        #expect(harness.coordinator.isRunning)

        await harness.sleeper.started.wait()
        #expect(harness.sleeper.durations == [.seconds(5)])

        harness.coordinator.stop()
        harness.sleeper.allowOne()
        await settle()
        #expect(!harness.coordinator.isRunning)
    }

    @Test("a local link is dropped after one unanswered probe")
    func localDropsAfterOneMiss() async {
        let harness = LinkWatchdogHarness(localRoute: true, answers: [false])
        harness.coordinator.start(using: harness.operations)

        await harness.advanceSleep()
        await harness.pingStarted.wait()
        harness.allowPing()
        await harness.pingFinished.wait()
        await harness.dropCalled.wait()

        #expect(harness.pingTimeouts == [.seconds(3)])
        #expect(harness.dropped == [ObjectIdentifier(harness.connection)])
        #expect(harness.coordinator.missCount == 0)
        #expect(harness.logs == ["link watchdog: the link stopped answering; dropping the socket"])

        harness.coordinator.stop()
    }

    @Test("a relay answer resets misses and two misses drop the socket")
    func relayNeedsTwoConsecutiveMisses() async {
        let harness = LinkWatchdogHarness(
            localRoute: false,
            answers: [false, true, false, false],
        )
        harness.coordinator.start(using: harness.operations)

        await harness.runProbe()
        #expect(harness.coordinator.missCount == 1)
        #expect(harness.dropped.isEmpty)

        await harness.runProbe()
        #expect(harness.coordinator.missCount == 0)
        #expect(harness.dropped.isEmpty)

        await harness.runProbe()
        #expect(harness.coordinator.missCount == 1)
        #expect(harness.dropped.isEmpty)

        await harness.runProbe()
        await harness.dropCalled.wait()
        #expect(harness.dropped == [ObjectIdentifier(harness.connection)])
        #expect(harness.coordinator.missCount == 0)

        harness.coordinator.stop()
    }

    @Test("a late miss for a replaced connection is ignored")
    func replacementIgnoresLateMiss() async {
        let harness = LinkWatchdogHarness(localRoute: true, answers: [false])
        harness.coordinator.start(using: harness.operations)

        await harness.sleeper.started.wait()
        harness.sleeper.allowOne()
        await harness.pingStarted.wait()

        let replacement = FakeWatchdogConnection()
        harness.connection = replacement
        harness.allowPing()
        await harness.pingFinished.wait()
        await settle()

        #expect(harness.dropped.isEmpty)
        #expect(harness.connection === replacement)

        harness.coordinator.stop()
    }

    @Test("stop and restart clear the task and partial misses")
    func stopRestartAndCancel() async {
        let harness = LinkWatchdogHarness(localRoute: false, answers: [false])
        harness.coordinator.start(using: harness.operations)
        await harness.runProbe()
        #expect(harness.coordinator.missCount == 1)

        harness.coordinator.stop()
        harness.sleeper.allowOne()
        await settle()
        #expect(!harness.coordinator.isRunning)
        #expect(harness.coordinator.missCount == 0)
        #expect(harness.pingCount == 1, "a cancelled watchdog ran another probe")

        harness.coordinator.start(using: harness.operations)
        #expect(harness.coordinator.isRunning)
        #expect(harness.coordinator.missCount == 0)

        harness.coordinator.stop()
        harness.sleeper.allowOne()
        await settle()
    }

    private func settle() async {
        for _ in 0..<4 {
            await Task.yield()
        }
    }
}

@MainActor
private final class LinkWatchdogHarness {
    let coordinator: LinkWatchdogCoordinator
    let sleeper: FakeWatchdogSleeper
    let pingStarted = WatchdogEventQueue()
    let pingFinished = WatchdogEventQueue()
    let dropCalled = WatchdogEventQueue()
    let pingRelease = WatchdogEventQueue()

    var active = true
    var reconnecting = false
    var connection = FakeWatchdogConnection()
    var localRoute: Bool
    var answers: [Bool]
    var pingTimeouts: [Duration] = []
    var pingCount = 0
    var dropped: [ObjectIdentifier] = []
    var logs: [String] = []

    init(active: Bool = true, localRoute: Bool = true, answers: [Bool] = []) {
        let sleeper = FakeWatchdogSleeper()
        self.sleeper = sleeper
        self.active = active
        self.localRoute = localRoute
        self.answers = answers
        coordinator = LinkWatchdogCoordinator(sleep: { try await sleeper.sleep($0) })
    }

    var operations: LinkWatchdogCoordinator.Operations {
        LinkWatchdogCoordinator.Operations(
            isAppActive: { self.active },
            isReconnecting: { self.reconnecting },
            currentConnection: { self.connection },
            isLocalRoute: { self.localRoute },
            ping: { _, timeout in
                self.pingTimeouts.append(timeout)
                self.pingCount += 1
                self.pingStarted.send()
                await self.pingRelease.wait()
                self.pingFinished.send()
                guard !self.answers.isEmpty else { return false }
                return self.answers.removeFirst()
            },
            dropDisconnectedSocket: { connection in
                self.dropped.append(ObjectIdentifier(connection))
                self.dropCalled.send()
            },
            log: { self.logs.append($0) },
        )
    }

    /// Let the currently suspended probe answer.
    func allowPing() {
        pingRelease.send()
    }

    /// Run one five-second sleep and one probe to completion.
    func runProbe() async {
        await advanceSleep()
        await pingStarted.wait()
        pingRelease.send()
        await pingFinished.wait()
    }

    /// Release exactly the sleep the watchdog is waiting on.
    func advanceSleep() async {
        await sleeper.started.wait()
        sleeper.allowOne()
    }
}

private final class FakeWatchdogConnection: LinkWatchdogCoordinator.Connection, Equatable, @unchecked Sendable {
    static func == (lhs: FakeWatchdogConnection, rhs: FakeWatchdogConnection) -> Bool {
        lhs === rhs
    }

    func watchdogPing(within timeout: Duration) async -> Bool {
        false
    }

    func watchdogDisconnect() async {}

    func watchdogCloseReason() async -> String? {
        nil
    }
}

@MainActor
private final class FakeWatchdogSleeper {
    private(set) var durations: [Duration] = []
    let started = WatchdogEventQueue()
    private let release = WatchdogEventQueue()

    func sleep(_ duration: Duration) async throws {
        durations.append(duration)
        started.send()
        await release.wait()
        try Task.checkCancellation()
    }

    func allowOne() {
        release.send()
    }
}

@MainActor
private final class WatchdogEventQueue {
    private var events = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func send() {
        if !waiters.isEmpty {
            waiters.removeFirst().resume()
        } else {
            events += 1
        }
    }

    func wait() async {
        if events > 0 {
            events -= 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}
