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

        let oldGeneration = coordinator.install(old)
        let currentGeneration = coordinator.install(current)
        #expect(currentGeneration > oldGeneration)
        #expect(!coordinator.clear(ifMatching: old))
        #expect(coordinator.activeConnection === current)

        #expect(coordinator.clear(ifMatching: current))
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
