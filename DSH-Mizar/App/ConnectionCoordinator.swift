import Foundation
import Observation
import MizarKit

/// Owns the active socket for one AppModel and identifies each adoption.
@MainActor
@Observable
final class ConnectionCoordinator {
    private(set) var activeConnection: MizarConnection?
    private(set) var generation = 0

    @discardableResult
    func install(_ connection: MizarConnection) -> Int {
        activeConnection = connection
        generation += 1
        return generation
    }

    /// Clears only the socket that is still active. Detaching never rewinds generation.
    @discardableResult
    func clear(ifMatching connection: AnyObject) -> Bool {
        guard activeConnection === connection else { return false }
        activeConnection = nil
        return true
    }

    func clear() {
        activeConnection = nil
    }

    // MARK: Launch

    /// The routes one launch races, each with the time it waits before starting.
    ///
    /// A value, not a running task: what a launch will do is decided before the
    /// first socket exists, so the schedule is testable without a network.
    struct LaunchPlan: Sendable, Equatable {
        /// One route, and how long its dial waits before the socket opens.
        struct Dial: Sendable, Equatable {
            let endpoint: PairedHost.Endpoint
            let delay: Duration
        }

        /// The dials, in the order the plan names them.
        let dials: [Dial]

        /// The routes, in plan order.
        var routes: [PairedHost.Endpoint] { dials.map(\.endpoint) }

        /// Whether the plan has nothing it may dial.
        var isEmpty: Bool { dials.isEmpty }
    }

    /// The wait between one route kind starting and the next kind starting.
    static let directHeadStart: Duration = .milliseconds(400)

    /// Which routes a launch dials, and how long each waits before it starts.
    ///
    /// The list is `ReconnectPlan.routes`': policy-filtered, preferred route in
    /// front. List order is not start order -- a preferred relay can lead the
    /// list and still start last. The wait belongs to the route's kind, and
    /// depends on which kinds this plan contains:
    ///
    /// | plan contains  | direct | p2p    | relay  |
    /// |----------------|--------|--------|--------|
    /// | direct         | 0      | —      | 400 ms |
    /// | p2p, no direct | —      | 0      | 400 ms |
    /// | direct and p2p | 0      | 400 ms | 800 ms |
    /// | neither        | —      | —      | 0      |
    ///
    /// The waits give a computer on the same network the first answer, and cost
    /// the fallback only a head start instead of the direct timeout.
    ///
    /// - Parameters:
    ///   - endpoints: every route the pairing knows, in the host's natural
    ///     order (direct first, relay second).
    ///   - active: the route that just answered, when this launch follows a
    ///     pairing or an explicit open; `nil` opens the pairing's own order.
    ///   - allowingLocalNetwork: the 局域网优先 switch. Off forbids `.direct`.
    ///   - allowingDirectPath: the 直连 switch. Off forbids `.p2p`.
    ///   - p2pOnly: whether the punched route must be the only one dialled. The
    ///     caller reads the DEBUG `-mizarP2POnly` argument and passes it, so the
    ///     plan stays testable without touching process globals.
    /// - Returns: the dials in list order, each with its kind's wait; empty when
    ///   no route the switches allow exists.
    func launchPlan(
        endpoints: [PairedHost.Endpoint],
        active: PairedHost.Endpoint?,
        allowingLocalNetwork: Bool,
        allowingDirectPath: Bool,
        p2pOnly: Bool = false,
    ) -> LaunchPlan {
        var routes = ReconnectPlan.routes(
            endpoints: endpoints,
            active: active,
            allowingLocalNetwork: allowingLocalNetwork,
            allowingDirectPath: allowingDirectPath,
        )
        // A cable-attached test can ask for the punched route alone. The launch
        // race otherwise lets the relay win whenever its handshake is a few
        // milliseconds faster, which makes "the app connected over P2P"
        // impossible to observe even when the punch landed.
        if p2pOnly { routes = routes.filter { $0.isDirectPath } }

        let hasDirect = routes.contains { endpoint in
            if case .direct = endpoint { return true }
            return false
        }
        let hasP2P = routes.contains { $0.isDirectPath }
        let directDelay: Duration = hasDirect ? Self.directHeadStart : .zero
        let p2pDelay = directDelay
        let relayDelay = directDelay + (hasP2P ? Self.directHeadStart : .zero)
        return LaunchPlan(dials: routes.map { endpoint in
            let delay: Duration
            switch endpoint {
            case .direct: delay = .zero
            case .p2p: delay = p2pDelay
            case .relay: delay = relayDelay
            }
            return LaunchPlan.Dial(endpoint: endpoint, delay: delay)
        })
    }

    /// Race a plan's dials and return the first route that answered.
    ///
    /// The winner is decided by arrival. The plan only decides each dial's
    /// wait. Losing routes are cancelled the moment the winner is known, and
    /// each closes its own socket on the way out, so the group drains at the
    /// speed of a cancellation rather than at the speed of a timeout. A calling
    /// task that is cancelled closes the winner it had already accepted.
    ///
    /// The caller keeps the transport policy: this only opens one socket per
    /// planned route, at the wait the plan named, and hands the winner back.
    ///
    /// - Parameters:
    ///   - plan: the routes to dial, and when.
    ///   - makeConnection: builds the socket for one route.
    ///   - onFailure: called once per route that failed while no winner was
    ///     known, so the caller can log it in its own words.
    /// - Returns: the first route to complete its handshake, with its socket.
    /// - Throws: ``Failure`` carrying one reason per route when none answered,
    ///   or `CancellationError`.
    func launch(
        _ plan: LaunchPlan,
        makeConnection: (PairedHost.Endpoint) -> MizarConnection,
        onFailure: ((PairedHost.Endpoint, any Error) -> Void)? = nil,
    ) async throws -> Answered {
        try await firstAnswer(
            in: plan.dials.map { dial in
                (
                    endpoint: dial.endpoint,
                    connection: makeConnection(dial.endpoint),
                    delay: dial.delay,
                )
            },
            onFailure: onFailure,
        )
    }

    struct Answered: Sendable {
        let endpoint: PairedHost.Endpoint
        let connection: MizarConnection
        let welcome: WelcomeFrame
    }

    struct Failure: Error, Sendable {
        let attempts: [(route: PairedHost.Endpoint, error: any Error)]
    }

    private enum DialResult: Sendable {
        case answered(Answered)
        case failed(route: PairedHost.Endpoint, error: any Error)
        case skipped
    }

    /// Runs the launch race; a cancelled handoff closes a winner that raced with cancellation.
    func firstAnswer(
        in dials: [(endpoint: PairedHost.Endpoint, connection: MizarConnection, delay: Duration)],
        onFailure: ((PairedHost.Endpoint, any Error) -> Void)? = nil,
    ) async throws -> Answered {
        var failures: [(route: PairedHost.Endpoint, error: any Error)] = []
        var winner: Answered?

        await withTaskGroup(of: DialResult.self) { group in
            for dial in dials {
                group.addTask {
                    if dial.delay > .zero {
                        do { try await Task.sleep(for: dial.delay) }
                        catch { return .skipped }
                    }
                    if Task.isCancelled { return .skipped }
                    do {
                        let welcome = try await dial.connection.connect()
                        return .answered(Answered(endpoint: dial.endpoint, connection: dial.connection, welcome: welcome))
                    } catch {
                        await dial.connection.disconnect()
                        return Task.isCancelled ? .skipped : .failed(route: dial.endpoint, error: error)
                    }
                }
            }
            for await result in group {
                switch result {
                case .answered(let answer):
                    guard winner == nil else {
                        await answer.connection.disconnect()
                        continue
                    }
                    winner = answer
                    group.cancelAll()
                case .failed(let route, let error):
                    guard winner == nil else { continue }
                    failures.append((route, error))
                    onFailure?(route, error)
                case .skipped:
                    break
                }
            }
        }

        if Task.isCancelled {
            if let winner { await winner.connection.disconnect() }
            throw CancellationError()
        }
        guard let winner else { throw Failure(attempts: failures) }
        return winner
    }
}
