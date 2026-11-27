import Foundation
import Observation
import MizarKit

/// Runs one bounded reconnect attempt loop for an AppModel.
@MainActor
@Observable
final class ReconnectCoordinator {
    struct RunIdentity: Sendable, Hashable {
        let hostId: String
        let invalidation: UInt64
    }

    struct Snapshot {
        let host: PairedHost
        let activeEndpoint: PairedHost.Endpoint?
        let localNetworkFirst: Bool
        let directConnection: Bool
    }

    @MainActor
    protocol Candidate: AnyObject {
        func connect() async throws
        func disconnect() async
    }

    typealias Validity = @MainActor () -> Bool

    struct FailureContext {
        let identity: RunIdentity
        let route: PairedHost.Endpoint
        let error: any Error
        let attempt: Int
        let attemptCount: Int
    }

    struct Operations {
        var identity: @MainActor () -> RunIdentity?
        var snapshot: @MainActor () -> Snapshot?
        var isConnected: @MainActor () -> Bool
        var prepare: @MainActor () async -> Void
        var makeCandidate: @MainActor (RunIdentity, PairedHost, PairedHost.Endpoint) -> any Candidate
        var adopt: @MainActor (
            RunIdentity,
            PairedHost,
            PairedHost.Endpoint,
            Int,
            Int,
            any Candidate,
            @escaping Validity
        ) async -> Bool
        var noteFailure: @MainActor (FailureContext) -> Void
        var noRoutes: @MainActor (RunIdentity, Snapshot) -> Void
        var routeName: @MainActor (PairedHost.Endpoint) -> String
        var log: @MainActor (String) -> Void
    }

    private var runningIdentities: Set<RunIdentity> = []
    var isRunning: Bool { !runningIdentities.isEmpty }

    private let now: @MainActor () -> ContinuousClock.Instant
    private let sleep: @MainActor (Duration) async throws -> Void
    private let waiterPoll: Duration
    private let waiterDeadline: Duration

    init(
        now: @escaping @MainActor () -> ContinuousClock.Instant = { ContinuousClock.now },
        sleep: @escaping @MainActor (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        },
        waiterPoll: Duration = .milliseconds(50),
        waiterDeadline: Duration = .seconds(20),
    ) {
        self.now = now
        self.sleep = sleep
        self.waiterPoll = waiterPoll
        self.waiterDeadline = waiterDeadline
    }

    /// Reconnect once, or wait for the reconnect already in flight.
    @discardableResult
    func reconnect(
        patient: Bool = false,
        tryingEveryRoute: Bool = false,
        preferringRelay: Bool = false,
        over exactRoute: PairedHost.Endpoint? = nil,
        historyValidity: Validity? = nil,
        using operations: Operations,
    ) async -> Bool {
        guard historyValidity?() ?? true else { return false }
        guard let waitingIdentity = operations.identity() else {
            return operations.isConnected()
        }

        if runningIdentities.contains(waitingIdentity) {
            return await waitForRun(
                waitingIdentity,
                patient: patient,
                tryingEveryRoute: tryingEveryRoute,
                preferringRelay: preferringRelay,
                exactRoute: exactRoute,
                historyValidity: historyValidity,
                operations: operations,
            )
        }

        runningIdentities.insert(waitingIdentity)
        defer { runningIdentities.remove(waitingIdentity) }

        operations.log(
            "reconnecting\(patient ? " (patient)" : "")"
                + "\(tryingEveryRoute ? " (every route)" : "")",
        )
        await operations.prepare()
        guard valid(
            waitingIdentity,
            historyValidity: historyValidity,
            operations: operations,
        ) else {
            return false
        }

        guard let snapshot = operations.snapshot(),
              snapshot.host.hostId == waitingIdentity.hostId else {
            return false
        }
        let routes = routes(
            from: snapshot,
            tryingEveryRoute: tryingEveryRoute,
            preferringRelay: preferringRelay,
            exactRoute: exactRoute,
        )
        guard !routes.isEmpty else {
            operations.noRoutes(waitingIdentity, snapshot)
            return false
        }

        let attemptCount = ReconnectPlan.attempts(routeCount: routes.count, patient: patient)
        operations.log(
            "routes: " + routes.map(operations.routeName).joined(separator: " -> "),
        )

        for attempt in 0..<attemptCount {
            guard valid(
                waitingIdentity,
                historyValidity: historyValidity,
                operations: operations,
            ) else {
                return false
            }
            if attempt > 0 {
                let pause = patient
                    ? min(4_000, 400 << attempt)
                    : 400 * attempt
                try? await sleep(.milliseconds(pause))
            }
            guard valid(
                waitingIdentity,
                historyValidity: historyValidity,
                operations: operations,
            ) else {
                return false
            }

            let route = routes[attempt % routes.count]
            let candidate = operations.makeCandidate(waitingIdentity, snapshot.host, route)
            do {
                try await candidate.connect()
                guard valid(
                    waitingIdentity,
                    historyValidity: historyValidity,
                    operations: operations,
                ) else {
                    await candidate.disconnect()
                    return false
                }

                let adopted = await operations.adopt(
                    waitingIdentity,
                    snapshot.host,
                    route,
                    attempt,
                    attemptCount,
                    candidate,
                    {
                        self.matchesIdentityAndHistory(
                            waitingIdentity,
                            historyValidity: historyValidity,
                            operations: operations,
                        )
                    },
                )
                guard adopted else {
                    await candidate.disconnect()
                    return false
                }
                guard matchesIdentityAndHistory(
                    waitingIdentity,
                    historyValidity: historyValidity,
                    operations: operations,
                ) else {
                    await candidate.disconnect()
                    return false
                }
                return true
            } catch {
                await candidate.disconnect()
                guard valid(
                    waitingIdentity,
                    historyValidity: historyValidity,
                    operations: operations,
                ) else {
                    return false
                }
                operations.noteFailure(
                    FailureContext(
                        identity: waitingIdentity,
                        route: route,
                        error: error,
                        attempt: attempt,
                        attemptCount: attemptCount,
                    ),
                )
            }
        }

        operations.log("reconnect gave up after \(attemptCount) attempts")
        return false
    }

    private func waitForRun(
        _ waitingIdentity: RunIdentity,
        patient: Bool,
        tryingEveryRoute: Bool,
        preferringRelay: Bool,
        exactRoute: PairedHost.Endpoint?,
        historyValidity: Validity?,
        operations: Operations,
    ) async -> Bool {
        let deadline = now().advanced(by: waiterDeadline)
        while runningIdentities.contains(waitingIdentity), now() < deadline {
            do {
                try await sleep(waiterPoll)
            } catch {
                break
            }
        }

        guard historyValidity?() ?? true,
              !Task.isCancelled,
              operations.identity() == waitingIdentity else {
            return false
        }
        if let exactRoute, !runningIdentities.contains(waitingIdentity) {
            return await reconnect(
                patient: patient,
                tryingEveryRoute: tryingEveryRoute,
                preferringRelay: preferringRelay,
                over: exactRoute,
                historyValidity: historyValidity,
                using: operations,
            )
        }
        return operations.isConnected()
    }

    private func routes(
        from snapshot: Snapshot,
        tryingEveryRoute: Bool,
        preferringRelay: Bool,
        exactRoute: PairedHost.Endpoint?,
    ) -> [PairedHost.Endpoint] {
        if let exactRoute,
           RoutePolicy.allows(
               exactRoute,
               localNetworkFirst: snapshot.localNetworkFirst,
               directConnection: snapshot.directConnection,
           ) {
            return [exactRoute]
        }
        return ReconnectPlan.routes(
            endpoints: snapshot.host.endpoints,
            active: snapshot.activeEndpoint,
            tryingEveryRoute: tryingEveryRoute,
            preferringRelay: preferringRelay,
            allowingLocalNetwork: snapshot.localNetworkFirst,
            allowingDirectPath: snapshot.directConnection,
        )
    }

    private func valid(
        _ identity: RunIdentity,
        historyValidity: Validity?,
        operations: Operations,
    ) -> Bool {
        !Task.isCancelled
            && matchesIdentityAndHistory(
                identity,
                historyValidity: historyValidity,
                operations: operations,
            )
    }

    private func matchesIdentityAndHistory(
        _ identity: RunIdentity,
        historyValidity: Validity?,
        operations: Operations,
    ) -> Bool {
        (historyValidity?() ?? true) && operations.identity() == identity
    }
}
