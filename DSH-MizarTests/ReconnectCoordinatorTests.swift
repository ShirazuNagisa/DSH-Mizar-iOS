import Foundation
import MizarKit
import Testing
@testable import DSH_Mizar

@MainActor
@Suite("Reconnect coordinator")
struct ReconnectCoordinatorTests {
    @Test("a reconnect succeeds on the same host")
    func sameHostReconnects() async {
        let host = host("host-a")
        let harness = Harness(host: host)

        let connected = await harness.coordinator.reconnect(using: harness.operations)

        #expect(connected)
        #expect(harness.attempts == [.direct(authority: "192.168.1.10:19390")])
        #expect(harness.adopted == [.direct(authority: "192.168.1.10:19390")])
        #expect(harness.adoptedAttempt == 0)
        #expect(harness.adoptedAttemptCount == 2)
        #expect(harness.isConnected)
        #expect(!harness.coordinator.isRunning)
    }

    @Test("a concurrent exact-route request waits, then dials only that route")
    func concurrentExactRouteWaitsForSameRun() async throws {
        let host = host("host-a")
        let direct = PairedHost.Endpoint.direct(authority: "192.168.1.10:19390")
        let relay = PairedHost.Endpoint.relay(baseURL: "https://relay.example")
        let connectStarted = TestSignal()
        let releaseConnect = TestSignal()
        let waitEntered = TestSignal()
        let releaseWait = TestSignal()
        let harness = Harness(host: host)
        harness.onConnect = { route, _ in
            guard route == direct else { return }
            await connectStarted.release()
            await releaseConnect.wait()
        }
        harness.replaceSleep { duration in
            if duration == .milliseconds(50) {
                await waitEntered.release()
                await releaseWait.wait()
            }
        }

        let first = Task {
            await harness.coordinator.reconnect(using: harness.operations)
        }
        await connectStarted.wait()
        let exact = Task {
            await harness.coordinator.reconnect(
                over: relay,
                using: harness.operations,
            )
        }
        await waitEntered.wait()

        await releaseConnect.release()
        let firstResult = await first.value
        await releaseWait.release()
        let exactResult = await exact.value

        #expect(firstResult)
        #expect(exactResult)
        #expect(harness.attempts == [direct, relay])
        #expect(harness.adopted == [direct, relay])
        #expect(harness.coordinator.isRunning == false)
    }

    @Test("switching hosts after a handshake disconnects the old candidate")
    func hostSwitchDiscardsHandshake() async {
        let oldHost = host("host-a")
        let newHost = host("host-b")
        let connectStarted = TestSignal()
        let releaseConnect = TestSignal()
        let harness = Harness(host: oldHost)
        harness.onConnect = { _, _ in
            await connectStarted.release()
            await releaseConnect.wait()
        }

        let run = Task {
            await harness.coordinator.reconnect(using: harness.operations)
        }
        await connectStarted.wait()
        harness.switchHost(newHost, invalidation: 1)
        await releaseConnect.release()

        let connected = await run.value

        #expect(!connected)
        #expect(harness.adopted.isEmpty)
        #expect(harness.candidates.count == 1)
        #expect(harness.candidates[0].disconnectCount == 1)
        #expect(!harness.isConnected)
    }

    @Test("a dead LAN preferring relay orders relay first and preserves backoff")
    func relayPreferenceAndBackoff() async {
        let host = host("host-a")
        let direct = PairedHost.Endpoint.direct(authority: "192.168.1.10:19390")
        let relay = PairedHost.Endpoint.relay(baseURL: "https://relay.example")
        let harness = Harness(host: host, activeEndpoint: direct)
        harness.onConnect = { _, _ in throw TestFailure.unreachable }

        let connected = await harness.coordinator.reconnect(
            preferringRelay: true,
            using: harness.operations,
        )

        #expect(!connected)
        #expect(harness.attempts == [relay, direct])
        #expect(harness.failures == [relay, direct])
        #expect(harness.sleeps == [.milliseconds(400)])
        #expect(harness.candidates.allSatisfy { $0.disconnectCount == 1 })
    }

    @Test("no allowed route stops before creating a candidate")
    func noAllowedRouteStops() async {
        let host = PairedHost(
            hostId: "host-a",
            hostName: "A",
            authority: "192.168.1.10:19390",
            deviceId: "device-a",
            deviceToken: "token-a",
        )
        let harness = Harness(
            host: host,
            localNetworkFirst: false,
            directConnection: false,
        )

        let connected = await harness.coordinator.reconnect(using: harness.operations)

        #expect(!connected)
        #expect(harness.prepareCount == 1)
        #expect(harness.attempts.isEmpty)
        #expect(harness.noRoutesCount == 1)
        #expect(harness.candidates.isEmpty)
    }

    @Test("cancelling a suspended handshake disconnects its candidate")
    func cancellationCleansCandidate() async {
        let host = host("host-a")
        let harness = Harness(host: host)
        harness.onConnect = { _, _ in
            try await Task.sleep(for: .seconds(60))
        }

        let run = Task {
            await harness.coordinator.reconnect(using: harness.operations)
        }
        await harness.awaitAttempt()
        run.cancel()

        let connected = await run.value

        #expect(!connected)
        #expect(harness.candidates.count == 1)
        #expect(harness.candidates[0].disconnectCount == 1)
        #expect(!harness.coordinator.isRunning)
    }

    @Test("history invalidation after a handshake disconnects the candidate")
    func historyInvalidationCleansCandidate() async {
        let host = host("host-a")
        let harness = Harness(host: host)
        harness.onConnect = { _, _ in
            harness.historyValid = false
        }

        let connected = await harness.coordinator.reconnect(
            historyValidity: { harness.historyValid },
            using: harness.operations,
        )

        #expect(!connected)
        #expect(harness.adopted.isEmpty)
        #expect(harness.candidates.count == 1)
        #expect(harness.candidates[0].disconnectCount == 1)
    }

    @Test("a different host identity does not wait behind the old run")
    func differentHostStartsImmediately() async {
        let oldHost = host("host-a")
        let newHost = host("host-b")
        let oldConnectStarted = TestSignal()
        let releaseOldConnect = TestSignal()
        let harness = Harness(host: oldHost)
        harness.onConnect = { _, attempt in
            guard attempt == 0 else { return }
            await oldConnectStarted.release()
            await releaseOldConnect.wait()
        }

        let oldRun = Task {
            await harness.coordinator.reconnect(using: harness.operations)
        }
        await oldConnectStarted.wait()
        harness.switchHost(newHost, invalidation: 1)
        let newResult = await harness.coordinator.reconnect(using: harness.operations)

        #expect(newResult)
        #expect(harness.adopted == [.direct(authority: "192.168.1.10:19390")])
        #expect(harness.isConnected)
        #expect(harness.candidates.count == 2)
        #expect(harness.candidates[1].disconnectCount == 0)

        await releaseOldConnect.release()
        let oldResult = await oldRun.value

        #expect(!oldResult)
        #expect(harness.candidates[0].disconnectCount == 1)
        #expect(harness.adopted == [.direct(authority: "192.168.1.10:19390")])
        #expect(!harness.coordinator.isRunning)
    }

    @Test("a host switch inside adopt rejects the candidate")
    func hostSwitchDuringAdoptRejectsCandidate() async {
        let oldHost = host("host-a")
        let newHost = host("host-b")
        let adoptStarted = TestSignal()
        let releaseAdopt = TestSignal()
        let harness = Harness(host: oldHost)
        harness.onAdopt = { _, isCurrent in
            await adoptStarted.release()
            await releaseAdopt.wait()
            return isCurrent()
        }

        let run = Task {
            await harness.coordinator.reconnect(using: harness.operations)
        }
        await adoptStarted.wait()
        harness.switchHost(newHost, invalidation: 1)
        await releaseAdopt.release()

        let connected = await run.value

        #expect(!connected)
        #expect(harness.adopted.isEmpty)
        #expect(harness.candidates.count == 1)
        #expect(harness.candidates[0].disconnectCount == 1)
        #expect(!harness.isConnected)
    }

    @Test("cancellation after adoption does not discard the valid socket")
    func cancellationAfterAdoptKeepsSocket() async {
        let host = host("host-a")
        let adoptStarted = TestSignal()
        let releaseAdopt = TestSignal()
        let harness = Harness(host: host)
        harness.onAdopt = { _, isCurrent in
            await adoptStarted.release()
            await releaseAdopt.wait()
            return isCurrent()
        }

        let run = Task {
            await harness.coordinator.reconnect(using: harness.operations)
        }
        await adoptStarted.wait()
        run.cancel()
        await releaseAdopt.release()

        let connected = await run.value

        #expect(connected)
        #expect(harness.adopted.count == 1)
        #expect(harness.candidates.count == 1)
        #expect(harness.candidates[0].disconnectCount == 0)
        #expect(harness.isConnected)
        #expect(!harness.coordinator.isRunning)
    }

    @Test("a patient reconnect keeps eight attempts and caps its backoff")
    func patientAttemptCountAndBackoff() async {
        let host = host("host-a")
        let direct = PairedHost.Endpoint.direct(authority: "192.168.1.10:19390")
        let relay = PairedHost.Endpoint.relay(baseURL: "https://relay.example")
        let harness = Harness(host: host)
        harness.onConnect = { _, _ in throw TestFailure.unreachable }

        let connected = await harness.coordinator.reconnect(
            patient: true,
            using: harness.operations,
        )

        #expect(!connected)
        #expect(harness.attempts == [
            direct, relay, direct, relay, direct, relay, direct, relay,
        ])
        #expect(harness.sleeps == [
            .milliseconds(800),
            .milliseconds(1_600),
            .milliseconds(3_200),
            .milliseconds(4_000),
            .milliseconds(4_000),
            .milliseconds(4_000),
            .milliseconds(4_000),
        ])
    }

    private func host(_ id: String) -> PairedHost {
        PairedHost(
            hostId: id,
            hostName: id,
            authority: "192.168.1.10:19390",
            deviceId: "device-\(id)",
            deviceToken: "token-\(id)",
            baseURL: "https://relay.example",
        )
    }
}

@MainActor
private final class Harness {
    let coordinator: ReconnectCoordinator
    private let sleeper: SleepRecorder
    var identity: ReconnectCoordinator.RunIdentity
    var snapshot: ReconnectCoordinator.Snapshot
    var isConnected = false
    var historyValid = true
    var prepareCount = 0
    var attempts: [PairedHost.Endpoint] = []
    var adopted: [PairedHost.Endpoint] = []
    var adoptedAttempt: Int?
    var adoptedAttemptCount: Int?
    var failures: [PairedHost.Endpoint] = []
    var noRoutesCount = 0
    var sleeps: [Duration] { sleeper.durations }
    var candidates: [FakeCandidate] = []
    var attemptWaiter: TestSignal?
    var onConnect: @MainActor (PairedHost.Endpoint, Int) async throws -> Void = { _, _ in }
    var onAdopt: @MainActor (PairedHost.Endpoint, ReconnectCoordinator.Validity) async -> Bool = {
        _, isCurrent in isCurrent()
    }

    init(
        host: PairedHost,
        activeEndpoint: PairedHost.Endpoint? = nil,
        localNetworkFirst: Bool = true,
        directConnection: Bool = true,
    ) {
        identity = ReconnectCoordinator.RunIdentity(hostId: host.hostId, invalidation: 0)
        snapshot = ReconnectCoordinator.Snapshot(
            host: host,
            activeEndpoint: activeEndpoint,
            localNetworkFirst: localNetworkFirst,
            directConnection: directConnection,
        )
        let sleeper = SleepRecorder()
        self.sleeper = sleeper
        coordinator = ReconnectCoordinator(
            now: { sleeper.now },
            sleep: { try await sleeper.sleep($0) },
        )
    }

    var operations: ReconnectCoordinator.Operations {
        ReconnectCoordinator.Operations(
            identity: { self.identity },
            snapshot: { self.snapshot },
            isConnected: { self.isConnected },
            prepare: {
                self.prepareCount += 1
                self.isConnected = false
            },
            makeCandidate: { _, _, route in
                let attempt = self.attempts.count
                self.attempts.append(route)
                if let waiter = self.attemptWaiter {
                    Task { await waiter.release() }
                }
                let candidate = FakeCandidate(
                    onConnect: {
                        try await self.onConnect(route, attempt)
                    },
                )
                self.candidates.append(candidate)
                return candidate
            },
            adopt: { _, _, route, attempt, attemptCount, _, isCurrent in
                guard await self.onAdopt(route, isCurrent) else { return false }
                self.adopted.append(route)
                self.adoptedAttempt = attempt
                self.adoptedAttemptCount = attemptCount
                self.isConnected = true
                return isCurrent()
            },
            noteFailure: { context in
                self.failures.append(context.route)
            },
            noRoutes: { _, _ in
                self.noRoutesCount += 1
            },
            routeName: { String(describing: $0) },
            log: { _ in },
        )
    }

    func replaceSleep(_ sleep: @escaping @MainActor (Duration) async throws -> Void) {
        sleeper.replacement = sleep
    }

    func switchHost(_ host: PairedHost, invalidation: UInt64) {
        identity = ReconnectCoordinator.RunIdentity(
            hostId: host.hostId,
            invalidation: invalidation,
        )
        snapshot = ReconnectCoordinator.Snapshot(
            host: host,
            activeEndpoint: nil,
            localNetworkFirst: true,
            directConnection: true,
        )
    }

    func awaitAttempt() async {
        let waiter = TestSignal()
        attemptWaiter = waiter
        if !attempts.isEmpty { await waiter.release() }
        await waiter.wait()
        attemptWaiter = nil
    }
}

@MainActor
private final class FakeCandidate: ReconnectCoordinator.Candidate {
    let onConnect: @MainActor () async throws -> Void
    private(set) var disconnectCount = 0

    init(onConnect: @escaping @MainActor () async throws -> Void) {
        self.onConnect = onConnect
    }

    func connect() async throws {
        try await onConnect()
    }

    func disconnect() async {
        disconnectCount += 1
    }
}

@MainActor
private final class SleepRecorder {
    private(set) var now = ContinuousClock.now
    private(set) var durations: [Duration] = []
    var replacement: (@MainActor (Duration) async throws -> Void)?

    func sleep(_ duration: Duration) async throws {
        now = now.advanced(by: duration)
        durations.append(duration)
        if let replacement {
            try await replacement(duration)
        }
    }
}

private enum TestFailure: Error {
    case unreachable
}

private actor TestSignal {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation in
            if released {
                continuation.resume()
            } else {
                waiters.append(continuation)
            }
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
