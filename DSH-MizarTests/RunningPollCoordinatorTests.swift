import Foundation
import MizarKit
import Testing
@testable import DSH_Mizar

@MainActor
@Suite("Running poll coordinator")
struct RunningPollCoordinatorTests {
    @Test("a running session starts exactly one poll")
    func startsOnce() async {
        let harness = RunningPollHarness()
        harness.observe(anySessionRunning: true)
        harness.observe(anySessionRunning: true)
        harness.observe(anySessionRunning: true)

        #expect(harness.coordinator.isActive)
        await harness.sleeper.started.wait()
        harness.observe(anySessionRunning: true)
        await settle()
        #expect(harness.sleeper.durations.count == 1)

        await harness.stop()
    }

    @Test("leaving the app stops the poll without changing its tick history")
    func backgroundStops() async {
        let harness = RunningPollHarness()
        harness.observe(anySessionRunning: true)
        await harness.runTick()
        let ticks = harness.coordinator.ticks
        let lastTick = harness.coordinator.lastTickAt

        harness.active = false
        harness.observe(anySessionRunning: true)
        #expect(!harness.coordinator.isActive)
        #expect(harness.coordinator.failures == 0)
        #expect(harness.coordinator.ticks == ticks)
        #expect(harness.coordinator.lastTickAt == lastTick)

        harness.sleeper.allowOne()
        await settle()
    }

    @Test("sleep comes first and each tick reads the current interval")
    func sleepsBeforeReadingAndUsesCurrentInterval() async {
        let harness = RunningPollHarness()
        harness.observe(anySessionRunning: true)
        #expect(harness.readCount == 0)

        await harness.sleeper.started.wait()
        #expect(harness.sleeper.durations == [.seconds(10)])
        harness.interval = .seconds(3)
        harness.sleeper.allowOne()
        await harness.readFinished.wait()
        #expect(harness.readCount == 1)

        await harness.sleeper.started.wait()
        #expect(harness.sleeper.durations == [.seconds(10), .seconds(3)])

        await harness.stop()
    }

    @Test("two failures reconnect and PollRecovery limits the next attempt")
    func reconnectRateUsesPollRecovery() async {
        let harness = RunningPollHarness()
        harness.readOutcome = .connectionFailure
        harness.reconnectResult = true
        harness.observe(anySessionRunning: true)

        await harness.runTick()
        #expect(harness.coordinator.failures == 1)
        #expect(harness.reconnectCount == 0)

        await harness.runTick()
        #expect(harness.coordinator.failures == 2)
        #expect(harness.reconnectCount == 0)

        await harness.runTick()
        #expect(harness.reconnectCount == 1)
        #expect(harness.coordinator.failures == 1)

        await harness.runTick()
        #expect(harness.reconnectCount == 1)
        #expect(harness.coordinator.failures == 2)

        await harness.runTick()
        #expect(harness.reconnectCount == 1)
        #expect(harness.coordinator.failures == 3)

        await harness.runTick()
        #expect(harness.reconnectCount == 2)
        #expect(harness.coordinator.failures == 1)

        await harness.stop()
    }

    @Test("a missing socket reconnects without counting a read failure")
    func missingSocketReconnectsImmediately() async {
        let harness = RunningPollHarness()
        harness.connectionMissing = true
        harness.readOutcome = .ignored
        harness.observe(anySessionRunning: true)

        await harness.runTick()

        #expect(harness.order == ["reconnect", "read"])
        #expect(harness.reconnectCount == 1)
        #expect(harness.coordinator.failures == 0)
        #expect(harness.coordinator.ticks == 1)

        await harness.stop()
    }

    @Test("ignored reads neither fail nor reconnect")
    func ignoredReadsAreNeutral() async {
        let harness = RunningPollHarness()
        harness.readOutcome = .ignored
        harness.observe(anySessionRunning: true)

        await harness.runTick()

        #expect(harness.readCount == 1)
        #expect(harness.reconnectCount == 0)
        #expect(harness.coordinator.failures == 0)
        #expect(harness.coordinator.ticks == 1)

        await harness.stop()
    }

    @Test("stop resets recovery while ticks survive restart")
    func cancelResetRestartPreservesTicks() async {
        let harness = RunningPollHarness()
        harness.readOutcome = .connectionFailure
        harness.observe(anySessionRunning: true)
        await harness.runTick()
        let firstTick = harness.coordinator.lastTickAt
        #expect(harness.coordinator.failures == 1)
        #expect(harness.coordinator.ticks == 1)

        harness.active = false
        harness.observe(anySessionRunning: true)
        #expect(!harness.coordinator.isActive)
        #expect(harness.coordinator.failures == 0)
        #expect(harness.coordinator.ticks == 1)
        #expect(harness.coordinator.lastTickAt == firstTick)

        harness.sleeper.allowOne()
        await settle()

        harness.active = true
        harness.readOutcome = .answered
        harness.observe(anySessionRunning: true)
        #expect(harness.coordinator.isActive)
        await harness.runTick()

        #expect(harness.coordinator.ticks == 2)
        #expect(harness.coordinator.lastTickAt != firstTick)
        #expect(harness.coordinator.failures == 0)

        await harness.stop()
    }

    @Test("a stopped poll's late read cannot overwrite the restarted poll")
    func staleReadCannotOverwriteRestartedPoll() async {
        let harness = RunningPollHarness()
        harness.firstReadWaits = true
        harness.firstReadOutcome = .answered
        harness.readOutcome = .connectionFailure
        harness.observe(anySessionRunning: true)

        await harness.sleeper.started.wait()
        harness.sleeper.allowOne()
        await harness.readFinished.wait()
        #expect(harness.readCount == 1)

        harness.active = false
        harness.observe(anySessionRunning: true)
        #expect(!harness.coordinator.isActive)
        #expect(harness.coordinator.failures == 0)
        #expect(harness.coordinator.ticks == 0)
        #expect(harness.coordinator.lastTickAt == nil)

        harness.active = true
        harness.observe(anySessionRunning: true)
        await harness.runTick()
        #expect(harness.readCount == 2)
        #expect(harness.coordinator.failures == 1)
        #expect(harness.coordinator.ticks == 1)
        let ticksAfterRestart = harness.coordinator.ticks
        let lastTickAfterRestart = harness.coordinator.lastTickAt

        harness.sleeper.advanceDate(by: 60)
        harness.releaseFirstRead()
        await harness.firstReadReturned.wait()
        await settle()

        #expect(harness.coordinator.failures == 1)
        #expect(harness.coordinator.ticks == ticksAfterRestart)
        #expect(harness.coordinator.lastTickAt == lastTickAfterRestart)

        await harness.stop()
    }

    private func settle() async {
        for _ in 0..<4 {
            await Task.yield()
        }
    }
}

@MainActor
private final class RunningPollHarness {
    let coordinator: RunningPollCoordinator
    let sleeper: FakeRunningPollSleeper
    let readFinished = RunningPollEventQueue()
    let firstReadReturned = RunningPollEventQueue()

    var active = true
    var anySessionRunning = false
    var conversationTurnIsRunning = false
    var interval: Duration = .seconds(10)
    var connectionMissing = false
    var reconnectResult = false
    var readOutcome: RunningPollCoordinator.ReadOutcome = .answered
    var firstReadWaits = false
    var firstReadOutcome: RunningPollCoordinator.ReadOutcome = .answered

    var reconnectCount = 0
    var readCount = 0
    var order: [String] = []
    private let firstReadRelease = RunningPollEventQueue()

    init() {
        let sleeper = FakeRunningPollSleeper()
        self.sleeper = sleeper
        coordinator = RunningPollCoordinator(
            sleep: { try await sleeper.sleep($0) },
            now: { sleeper.now },
            date: { sleeper.date },
        )
    }

    var operations: RunningPollCoordinator.Operations {
        RunningPollCoordinator.Operations(
            interval: { self.interval },
            isAppActive: { self.active },
            connectionMissing: { self.connectionMissing },
            reconnect: {
                self.order.append("reconnect")
                self.reconnectCount += 1
                return self.reconnectResult
            },
            readSessionList: {
                self.order.append("read")
                self.readCount += 1
                let readNumber = self.readCount
                self.readFinished.send()
                if readNumber == 1, self.firstReadWaits {
                    await self.firstReadRelease.wait()
                    defer { self.firstReadReturned.send() }
                    return self.firstReadOutcome
                }
                return self.readOutcome
            },
            log: { _ in },
        )
    }

    func observe(anySessionRunning: Bool) {
        self.anySessionRunning = anySessionRunning
        coordinator.observe(
            anySessionRunning: anySessionRunning,
            conversationTurnIsRunning: conversationTurnIsRunning,
            appIsActive: active,
            using: operations,
        )
    }

    func runTick() async {
        await sleeper.started.wait()
        sleeper.allowOne()
        await readFinished.wait()
        for _ in 0..<3 {
            await Task.yield()
        }
    }

    func releaseFirstRead() {
        firstReadRelease.send()
    }

    func stop() async {
        active = false
        observe(anySessionRunning: anySessionRunning)
        sleeper.allowOne()
        for _ in 0..<4 {
            await Task.yield()
        }
    }
}

@MainActor
private final class FakeRunningPollSleeper {
    private(set) var durations: [Duration] = []
    private(set) var now = ContinuousClock.now
    private(set) var date = Date(timeIntervalSince1970: 1_800_000_000)

    let started = RunningPollEventQueue()
    private let release = RunningPollEventQueue()

    func sleep(_ duration: Duration) async throws {
        durations.append(duration)
        started.send()
        await release.wait()
        try Task.checkCancellation()
        now = now.advanced(by: duration)
        date = date.addingTimeInterval(seconds(duration))
    }

    func allowOne() {
        release.send()
    }

    func advanceDate(by seconds: TimeInterval) {
        date = date.addingTimeInterval(seconds)
    }

    private func seconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }
}

@MainActor
private final class RunningPollEventQueue {
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
