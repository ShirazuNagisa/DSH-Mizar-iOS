import Foundation
import MizarKit
import Observation

/// Owns the task that follows a running turn.
///
/// The state machine decides whether one is wanted, `PollRecovery` decides when
/// a failing socket should be rebuilt, and this coordinator owns the task,
/// counters and clock used to carry those decisions out.
@MainActor
@Observable
final class RunningPollCoordinator {
    enum ReadOutcome: Sendable, Equatable {
        /// The host answered and the caller accepted the answer.
        case answered
        /// The failure is one a fresh socket could fix.
        case connectionFailure
        /// Cancellation, a missing socket, a stale host, or a host refusal.
        case ignored
    }

    struct Operations {
        var interval: @MainActor () -> Duration
        var isAppActive: @MainActor () -> Bool
        var connectionMissing: @MainActor () -> Bool
        var reconnect: @MainActor () async -> Bool
        var readSessionList: @MainActor () async -> ReadOutcome
        var log: @MainActor (String) -> Void
    }

    private let sleep: @MainActor (Duration) async throws -> Void
    private let now: @MainActor () -> ContinuousClock.Instant
    private let date: @MainActor () -> Date

    private var poll: Task<Void, Never>?
    /// Invalidates ticks left suspended in a previous poll after stop/restart.
    private var pollGeneration: UInt64 = 0
    private var state = RunningPoll()
    private var recovery = PollRecovery()

    private(set) var ticks = 0
    private(set) var lastTickAt: Date?

    var isActive: Bool { poll != nil }
    var failures: Int { recovery.failures }

    init(
        sleep: @escaping @MainActor (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        },
        now: @escaping @MainActor () -> ContinuousClock.Instant = { ContinuousClock.now },
        date: @escaping @MainActor () -> Date = { Date() },
    ) {
        self.sleep = sleep
        self.now = now
        self.date = date
    }

    /// Apply one observation from the session list, page or app lifecycle.
    func observe(
        anySessionRunning: Bool,
        conversationTurnIsRunning: Bool,
        appIsActive: Bool,
        using operations: Operations,
    ) {
        switch state.observe(
            anySessionRunning: anySessionRunning,
            conversationTurnIsRunning: conversationTurnIsRunning,
            appIsActive: appIsActive,
        ) {
        case .start:
            start(using: operations)
        case .stop:
            stop(using: operations)
        case .none:
            break
        }
    }

    private func start(using operations: Operations) {
        guard poll == nil else { return }
        pollGeneration &+= 1
        let generation = pollGeneration
        operations.log("running poll: started, a session is running")
        poll = Task { [weak self, sleep] in
            while !Task.isCancelled {
                do {
                    try await sleep(operations.interval())
                } catch {
                    return
                }
                guard !Task.isCancelled, let self else { return }
                await tick(generation: generation, using: operations)
            }
        }
    }

    private func stop(using operations: Operations) {
        pollGeneration &+= 1
        guard let poll else { return }
        poll.cancel()
        self.poll = nil
        recovery.reset()
        operations.log(
            operations.isAppActive()
                ? "running poll: stopped, nothing is running"
                : "running poll: stopped, the app is not on screen",
        )
    }

    private func tick(generation: UInt64, using operations: Operations) async {
        guard isCurrentPoll(generation), operations.isAppActive() else { return }

        if recovery.reconnectIsDue(
            connectionMissing: operations.connectionMissing(),
            now: now(),
        ) {
            recovery.noteAttempt(at: now())
            let reconnected = await operations.reconnect()
            guard isCurrentPoll(generation) else { return }
            if reconnected {
                recovery.recordSuccess()
            }
        }

        let outcome = await operations.readSessionList()
        guard isCurrentPoll(generation) else { return }
        switch outcome {
        case .answered:
            recovery.recordSuccess()
        case .connectionFailure:
            recovery.recordFailure()
        case .ignored:
            break
        }

        lastTickAt = date()
        ticks &+= 1
    }

    private func isCurrentPoll(_ generation: UInt64) -> Bool {
        !Task.isCancelled
            && generation == pollGeneration
            && poll != nil
            && state.isPolling
    }
}
