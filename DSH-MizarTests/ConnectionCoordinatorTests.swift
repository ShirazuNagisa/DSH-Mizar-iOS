import Foundation
import MizarKit
import Testing
@testable import DSH_Mizar

@MainActor
@Suite("Connection coordinator")
struct ConnectionCoordinatorTests {
    @Test("each coordinator owns its connection and replacements advance the generation")
    func ownershipAndGenerationArePerInstance() async {
        let firstOwner = ConnectionCoordinator()
        let secondOwner = ConnectionCoordinator()
        let first = connection()
        let replacement = connection()
        let otherOwnerConnection = connection()

        #expect(firstOwner.install(first) == 1)
        #expect(firstOwner.activeConnection === first)
        #expect(firstOwner.install(replacement) == 2)
        #expect(firstOwner.activeConnection === replacement)

        #expect(secondOwner.install(otherOwnerConnection) == 1)
        #expect(secondOwner.activeConnection === otherOwnerConnection)
        #expect(firstOwner.activeConnection !== secondOwner.activeConnection)

        await first.disconnect()
        await replacement.disconnect()
        await otherOwnerConnection.disconnect()
    }

    @Test("a stale close cannot clear a replacement, and reopening starts a newer generation")
    func staleCloseCannotClearReplacement() async {
        let coordinator = ConnectionCoordinator()
        let old = connection()
        let current = connection()
        let reopened = connection()
        let currentIdentity: AnyObject = current
        let unrelatedIdentity: AnyObject = NSObject()

        let oldGeneration = coordinator.install(old)
        let currentGeneration = coordinator.install(current)
        #expect(currentGeneration > oldGeneration)
        #expect(!coordinator.clear(ifMatching: old))
        #expect(!coordinator.clear(ifMatching: unrelatedIdentity))
        #expect(coordinator.activeConnection === current)

        #expect(coordinator.clear(ifMatching: currentIdentity))
        #expect(coordinator.activeConnection == nil)
        let reopenedGeneration = coordinator.install(reopened)
        #expect(reopenedGeneration > currentGeneration)
        #expect(coordinator.activeConnection === reopened)

        coordinator.clear()
        #expect(coordinator.activeConnection == nil)
        #expect(coordinator.generation == reopenedGeneration)

        await old.disconnect()
        await current.disconnect()
        await reopened.disconnect()
    }

    @Test("the first handshake wins and cancellation closes the losing route")
    func firstAnswerCancelsAndClosesLoser() async throws {
        let coordinator = ConnectionCoordinator()
        let winnerSocket = GatedConnectionTransport()
        let loserSocket = GatedConnectionTransport(blockSendUntilCancelled: true)
        let winner = connection(transport: winnerSocket)
        let loser = connection(transport: loserSocket)
        let winnerRoute = PairedHost.Endpoint.direct(authority: "winner:1")
        let loserRoute = PairedHost.Endpoint.relay(baseURL: "https://loser.example")

        let race = Task {
            try await coordinator.firstAnswer(in: [
                (endpoint: winnerRoute, connection: winner, delay: .zero),
                (endpoint: loserRoute, connection: loser, delay: .zero),
            ])
        }

        await winnerSocket.waitUntilReceiving()
        await loserSocket.waitUntilSending()
        await winnerSocket.answerHandshake()
        let answer = try await race.value

        #expect(answer.endpoint == winnerRoute)
        #expect(answer.connection === winner)
        #expect(await loserSocket.didClose)

        await winner.disconnect()
    }

    @Test("parent cancellation during a suspended handshake closes the route")
    func parentCancellationClosesSuspendedHandshake() async {
        let coordinator = ConnectionCoordinator()
        let socket = GatedConnectionTransport()
        let routeConnection = connection(transport: socket)
        let route = PairedHost.Endpoint.direct(authority: "suspended:1")

        let race = Task {
            try await coordinator.firstAnswer(in: [
                (endpoint: route, connection: routeConnection, delay: .zero),
            ])
        }

        await socket.waitUntilReceiving()
        race.cancel()

        do {
            _ = try await race.value
            #expect(Bool(false), "cancelled route race unexpectedly returned an answer")
        } catch is CancellationError {
            #expect(await socket.didClose)
        } catch {
            #expect(Bool(false), "expected CancellationError, got \(error)")
        }
    }

    // MARK: Launch plan

    @Test("the plan is the allowed routes, with the preferred one in front")
    func planFollowsRoutePolicyAndPreference() {
        let coordinator = ConnectionCoordinator()

        #expect(plan(coordinator).routes == [direct, p2p, relay])
        // The route that just answered leads the rest of the pairing.
        #expect(plan(coordinator, active: relay).routes == [relay, direct, p2p])
        #expect(plan(coordinator, active: p2p).routes == [p2p, direct, relay])
        // 局域网优先 off forbids the direct address entirely.
        #expect(plan(coordinator, allowingLocalNetwork: false).routes == [p2p, relay])
        // 直连 off forbids the punched route.
        #expect(plan(coordinator, allowingDirectPath: false).routes == [direct, relay])
        #expect(plan(coordinator, allowingLocalNetwork: false, allowingDirectPath: false).routes == [relay])
        // An active route the switches no longer allow stops leading: the
        // punched route is dropped, so the direct address leads again.
        #expect(plan(coordinator, active: p2p, allowingDirectPath: false).routes == [direct, relay])
        // A still-allowed active relay does keep leading, even with the punched
        // route switched off.
        #expect(plan(coordinator, active: relay, allowingDirectPath: false).routes == [relay, direct])
    }

    @Test("start delays are a property of the route kind, not of list order")
    func planStaggersByRouteKind() {
        let coordinator = ConnectionCoordinator()

        // Direct alone: no one to wait for.
        #expect(delay(of: direct, in: plan(coordinator, endpoints: [direct])) == Duration.zero)

        // Direct plus relay: the relay waits one head start.
        let directRelay = plan(coordinator, endpoints: [direct, relay])
        #expect(delay(of: direct, in: directRelay) == Duration.zero)
        #expect(delay(of: relay, in: directRelay) == Duration.milliseconds(400))

        // Direct, punched route and relay: 0 / 400 / 800 ms.
        let full = plan(coordinator, endpoints: [direct, p2p, relay])
        #expect(delay(of: direct, in: full) == Duration.zero)
        #expect(delay(of: p2p, in: full) == Duration.milliseconds(400))
        #expect(delay(of: relay, in: full) == Duration.milliseconds(800))

        // No direct address: the punched route starts at once, the relay one
        // head start behind it.
        let punch = plan(coordinator, endpoints: [p2p, relay])
        #expect(delay(of: p2p, in: punch) == Duration.zero)
        #expect(delay(of: relay, in: punch) == Duration.milliseconds(400))

        // A lone punched route, and a relay with nothing to wait behind.
        #expect(delay(of: p2p, in: plan(coordinator, endpoints: [p2p])) == Duration.zero)
        #expect(delay(of: relay, in: plan(coordinator, endpoints: [relay])) == Duration.zero)
        // An alternate relay is not another kind: neither waits.
        let twoRelays = plan(coordinator, endpoints: [relay, relayOther])
        #expect(twoRelays.dials.map(\.delay) == [Duration.zero, Duration.zero])
    }

    @Test("a preferred route leads the list but keeps its own kind's delay")
    func planSeparatesListOrderFromStartDelay() {
        let coordinator = ConnectionCoordinator()

        // Preferred relay: first in the list, still waiting behind the direct
        // address, which is second in the list and starts at once.
        let relayFirst = plan(coordinator, endpoints: [direct, relay], active: relay)
        #expect(relayFirst.routes == [relay, direct])
        #expect(delay(of: relay, in: relayFirst) == Duration.milliseconds(400))
        #expect(delay(of: direct, in: relayFirst) == Duration.zero)

        // Preferred punched route with no direct address: leads and starts at
        // once; the relay keeps its one-head-start wait.
        let punchFirst = plan(coordinator, endpoints: [p2p, relay], active: p2p)
        #expect(punchFirst.routes == [p2p, relay])
        #expect(delay(of: p2p, in: punchFirst) == Duration.zero)
        #expect(delay(of: relay, in: punchFirst) == Duration.milliseconds(400))
    }

    @Test("p2p-only filtering is a flag, not a process global")
    func planKeepsOnlyThePunchedRouteWhenAsked() {
        let coordinator = ConnectionCoordinator()

        #expect(plan(coordinator, p2pOnly: true).routes == [p2p])
        #expect(delay(of: p2p, in: plan(coordinator, p2pOnly: true)) == Duration.zero)
        // Filtering happens before the delays are computed, so the punched
        // route no longer waits for a direct address that is gone.
        #expect(delay(of: p2p, in: plan(coordinator, endpoints: [direct, p2p], p2pOnly: true)) == Duration.zero)
        // A pairing with no punched route has nothing left to dial.
        #expect(plan(coordinator, endpoints: [direct, relay], p2pOnly: true).isEmpty)
        #expect(plan(coordinator, endpoints: [direct, relay], p2pOnly: false).isEmpty == false)
    }

    @Test("a plan with no allowed route is empty, not a one-route guess")
    func planIsEmptyWhenEveryRouteIsForbidden() {
        let coordinator = ConnectionCoordinator()

        let empty = plan(
            coordinator,
            endpoints: [direct, p2p],
            allowingLocalNetwork: false,
            allowingDirectPath: false,
        )
        #expect(empty.isEmpty)
        #expect(empty.routes.isEmpty)
        #expect(empty.dials.isEmpty)
        // The same pairing with nothing in it at all.
        #expect(plan(coordinator, endpoints: []).isEmpty)
    }

    @Test("a launch opens one socket per planned route through the caller's factory")
    func launchDialsEveryPlannedRouteThroughFactory() async throws {
        let coordinator = ConnectionCoordinator()
        let firstSocket = GatedConnectionTransport()
        let secondSocket = GatedConnectionTransport()
        let first = connection(transport: firstSocket)
        let second = connection(transport: secondSocket)
        let recorder = EndpointRecorder()
        // Two relays: distinct routes, and neither kind waits behind the other,
        // so both dials start without a sleep.
        let firstRoute = relay
        let secondRoute = relayOther
        let launch = plan(coordinator, endpoints: [firstRoute, secondRoute])

        let race = Task {
            try await coordinator.launch(
                launch,
                makeConnection: { endpoint in
                    recorder.note(endpoint)
                    return endpoint == firstRoute ? first : second
                },
            )
        }

        await firstSocket.waitUntilReceiving()
        await secondSocket.waitUntilReceiving()
        await secondSocket.answerHandshake()
        let answer = try await race.value

        // The factory was asked for both planned routes, in plan order, before
        // the race had a winner; the loser was closed on the way out.
        #expect(recorder.endpoints == [firstRoute, secondRoute])
        #expect(answer.endpoint == secondRoute)
        #expect(answer.connection === second)
        #expect(await firstSocket.didClose)

        await second.disconnect()
    }

    // MARK: Launch-plan fixtures

    private var direct: PairedHost.Endpoint { .direct(authority: "10.0.0.2:19395") }
    private var p2p: PairedHost.Endpoint { .p2p(relayBaseURL: "https://relay.example", endpointId: "endpoint-1") }
    private var relay: PairedHost.Endpoint { .relay(baseURL: "https://relay.example") }
    private var relayOther: PairedHost.Endpoint { .relay(baseURL: "https://relay-2.example") }

    private func plan(
        _ coordinator: ConnectionCoordinator,
        endpoints: [PairedHost.Endpoint]? = nil,
        active: PairedHost.Endpoint? = nil,
        allowingLocalNetwork: Bool = true,
        allowingDirectPath: Bool = true,
        p2pOnly: Bool = false,
    ) -> ConnectionCoordinator.LaunchPlan {
        coordinator.launchPlan(
            endpoints: endpoints ?? [direct, p2p, relay],
            active: active,
            allowingLocalNetwork: allowingLocalNetwork,
            allowingDirectPath: allowingDirectPath,
            p2pOnly: p2pOnly,
        )
    }

    private func delay(
        of endpoint: PairedHost.Endpoint,
        in plan: ConnectionCoordinator.LaunchPlan,
    ) -> Duration? {
        plan.dials.first { $0.endpoint == endpoint }?.delay
    }

    private func connection(transport: GatedConnectionTransport = GatedConnectionTransport()) -> MizarConnection {
        MizarConnection(
            configuration: .init(
                authority: "test:1",
                token: "test-token",
                subscribeToStateChanges: false,
                handshakeTimeout: .seconds(5),
            ),
            makeTransport: { transport },
        )
    }
}

/// Collects the endpoints a launch's connection factory is asked for.
///
/// Main-actor isolated because construction, factory writes and assertions all
/// stay on the suite's actor.
@MainActor
private final class EndpointRecorder {
    private(set) var endpoints: [PairedHost.Endpoint] = []

    func note(_ endpoint: PairedHost.Endpoint) {
        endpoints.append(endpoint)
    }
}

/// A socket that lets a test release the welcome on demand. Cancelling a
/// blocked receive resumes it with `CancellationError`, so structured dial
/// races finish deterministically and their socket cleanup remains observable.
private actor GatedConnectionTransport: WebSocketTransport {
    private let blockSendUntilCancelled: Bool
    private var queued: [WebSocketFrame?] = []
    private var waiter: CheckedContinuation<WebSocketFrame?, any Error>?
    private var receiveStarted = false
    private var receiveStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var sendStarted = false
    private var sendStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var sendWaiter: CheckedContinuation<Void, any Error>?
    private var closed = false

    init(blockSendUntilCancelled: Bool = false) {
        self.blockSendUntilCancelled = blockSendUntilCancelled
    }

    var didClose: Bool { closed }

    func connect(url: URL, headers: [String: String]) async throws {}

    func send(text: String) async throws {
        sendStarted = true
        let startWaiters = sendStartWaiters
        sendStartWaiters.removeAll()
        startWaiters.forEach { $0.resume() }
        guard blockSendUntilCancelled else { return }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                sendWaiter = continuation
            }
        } onCancel: {
            Task { await self.cancelSend() }
        }
    }

    func receive() async throws -> WebSocketFrame? {
        receiveStarted = true
        let startWaiters = receiveStartWaiters
        receiveStartWaiters.removeAll()
        startWaiters.forEach { $0.resume() }

        if !queued.isEmpty { return queued.removeFirst() }
        if closed { return nil }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if closed {
                    continuation.resume(returning: nil)
                } else {
                    waiter = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelReceive() }
        }
    }

    func close() async {
        closed = true
        waiter?.resume(returning: nil)
        waiter = nil
    }

    func waitUntilReceiving() async {
        if receiveStarted { return }
        await withCheckedContinuation { continuation in
            receiveStartWaiters.append(continuation)
        }
    }

    func waitUntilSending() async {
        if sendStarted { return }
        await withCheckedContinuation { continuation in
            sendStartWaiters.append(continuation)
        }
    }

    func answerHandshake() {
        let frame = WebSocketFrame.text(
            #"{"v":1,"type":"welcome","hostId":"host-winner","hostName":"Fixture","protocolVersion":1,"home":"/tmp","deviceId":"device-test"}"#,
        )
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: frame)
        } else {
            queued.append(frame)
        }
    }

    private func cancelReceive() {
        guard let waiter else { return }
        self.waiter = nil
        waiter.resume(throwing: CancellationError())
    }

    private func cancelSend() {
        guard let sendWaiter else { return }
        self.sendWaiter = nil
        sendWaiter.resume(throwing: CancellationError())
    }
}
