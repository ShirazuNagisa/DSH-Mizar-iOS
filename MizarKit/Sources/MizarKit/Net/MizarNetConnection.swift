//
//  MizarNetConnection.swift
//  MizarKit
//
//  The connection state machine.
//
//  One actor per MizarNet connection. It owns the engine, the signaling
//  channel and the stream, and it is the only place in the kernel with
//  mutable state — which is what makes the kernel's behaviour describable:
//
//    idle → connecting → ready(path) ⇄ failed(...) → closed
//
//  Two deliberate refusals:
//
//  It does not choose the fallback. When a direct path degrades, the
//  connection drops the stream and says so; the app's own route policy
//  (ReconnectPlan, which already knows the relay) decides what to dial next.
//  Two components that both pick routes will eventually disagree, and the one
//  with the pairing in hand should win.
//
//  It does not retry silently. A failed punch is an event, not a loop: the
//  backoff in the policy is for a *caller* that wants to try again, and the
//  caller here is the app's reconnect, which already has its own schedule.
//

import Foundation

/// Where a connection is.
public enum MizarNetState: Sendable, Equatable {
    /// Not started.
    case idle
    /// Dialling or accepting.
    case connecting
    /// Carrying traffic, on the given path.
    case ready(path: MizarNetPathKind)
    /// The path is gone. The reason says why.
    case failed(MizarNetError)
    /// Closed on purpose.
    case closed
}

/// What happened, for whoever is listening.
public enum MizarNetEvent: Sendable, Equatable {
    /// The state changed.
    case state(MizarNetState)
    /// A signaling message arrived (or was sent and echoed by the transport).
    case signaling(MizarNetSignal)
    /// The engine reported a path it no longer trusts.
    case healthDegraded(MizarNetHealth)
    /// Something worth writing down that is not an error.
    case log(String)
}

/// One MizarNet connection: dialer or acceptor.
public actor MizarNetConnection {
    /// The connection's event stream. Finished when the connection closes.
    public let events: AsyncStream<MizarNetEvent>
    private let eventContinuation: AsyncStream<MizarNetEvent>.Continuation

    private let engine: any MizarNetEngine
    private let ticket: MizarNetTicket
    private let signaling: (any MizarNetSignalingTransport)?
    /// The pairing token this connection presents on the signal channel.
    ///
    /// Nil for the desktop, which is the side being asked. The phone sends it
    /// in its first frame: without it the desktop has no way to tell a phone
    /// on the same network from anyone else who can route to that port.
    private let deviceToken: String?
    private let policy: MizarNetPathPolicy

    private var currentState: MizarNetState = .idle
    private var engineIdentity: MizarNetIdentity?
    private var stream: (any MizarNetStream)?
    private var healthTask: Task<Void, Never>?
    private var candidateTask: Task<Void, Never>?
    private var finished = false

    /// A connection.
    ///
    /// - Parameters:
    ///   - engine: the connectivity engine. Fresh per connection: an engine
    ///     holds sockets, and a reused one carries the previous attempt's
    ///     state into the next.
    ///   - ticket: what to dial, or — for the acceptor — what the dialer will
    ///     present. The acceptor uses it only to know which room to listen
    ///     in, so any ticket naming the local endpoint works.
    ///   - signaling: the side channel, already open. Optional: a punch can
    ///     still be attempted from the ticket's direct hints alone.
    ///   - deviceToken: what to present to the far end's signal endpoint, if it
    ///     checks. The phone has one; the desktop does not send one.
    ///   - policy: the numbers.
    public init(
        engine: any MizarNetEngine,
        ticket: MizarNetTicket,
        signaling: (any MizarNetSignalingTransport)? = nil,
        deviceToken: String? = nil,
        policy: MizarNetPathPolicy = .standard,
    ) {
        self.engine = engine
        self.ticket = ticket
        self.signaling = signaling
        self.deviceToken = deviceToken
        self.policy = policy
        let made = AsyncStream<MizarNetEvent>.makeStream(of: MizarNetEvent.self, bufferingPolicy: .unbounded)
        self.events = made.stream
        self.eventContinuation = made.continuation
    }

    /// The current state.
    public var state: MizarNetState { currentState }

    /// The local endpoint's identity, once the engine has started.
    public var identity: MizarNetIdentity? { engineIdentity }

    // MARK: - Dialling

    /// Dial the ticket.
    ///
    /// - Returns: the connected stream. The caller owns it; ``close()``
    ///   releases everything the connection built around it.
    /// - Throws: ``MizarNetError`` — `dialTimeout` when the punch budget ran
    ///   out, `punchFailed` when the engine gave up, `alreadyReady` when the
    ///   connection is already up.
    public func connect() async throws -> any MizarNetStream {
        try assertNotBusy()
        await engine.noteIntent(.dial)
        currentState = .connecting
        emit(.state(.connecting))
        do {
            try await engine.start()
            engineIdentity = await engine.identity
            await startCandidateConsumer()
            await sendHello()
            let stream = try await dialWithBudget(policy.punchBudget)
            await adopt(stream)
            return stream
        } catch {
            await fail(error)
            throw error
        }
    }

    /// Accept the peer's dial.
    ///
    /// The acceptor sends its own hello first — the dialer is waiting for
    /// exactly that — and then waits.
    ///
    /// - Returns: the stream the peer dialled in on.
    /// - Throws: ``MizarNetError``.
    public func accept() async throws -> any MizarNetStream {
        try assertNotBusy()
        await engine.noteIntent(.accept)
        currentState = .connecting
        emit(.state(.connecting))
        do {
            try await engine.start()
            engineIdentity = await engine.identity
            await startCandidateConsumer()
            await sendHello()
            for await stream in await engine.incomingStreams() {
                await adopt(stream)
                return stream
            }
            // The incoming stream finished without a connection: the engine
            // shut down under us.
            throw MizarNetError.streamClosed
        } catch {
            await fail(error)
            throw error
        }
    }

    // MARK: - Lifecycle

    /// The network changed.
    ///
    /// Forwarded to the engine and nothing else. A multipath engine migrates
    /// the live stream; a single-path engine re-gathers candidates so the
    /// next dial is fresh. Closing the stream here would be the connection
    /// second-guessing the engine, and would turn a Wi-Fi-to-cellular switch
    /// into a reconnect the app did not ask for.
    public func networkChanged() async {
        await engine.networkChanged()
        emit(.log("network changed"))
    }

    /// Close everything.
    public func close() async {
        cancelTasks()
        if let stream {
            await stream.close()
            self.stream = nil
        }
        await signaling?.close()
        await engine.shutdown()
        currentState = .closed
        emit(.state(.closed))
        finished = true
        eventContinuation.finish()
    }

    // MARK: - Internals

    private func cancelTasks() {
        healthTask?.cancel()
        healthTask = nil
        candidateTask?.cancel()
        candidateTask = nil
    }

    /// A failed dial lands here: state becomes `failed`, the engine is shut
    /// down, and the error is rethrown by the caller.
    ///
    /// Shutting the engine down matters: a punch that failed halfway has
    /// usually opened a socket, and the transport's contract is a fresh
    /// engine per dial anyway.
    private func fail(_ error: any Error) async {
        cancelTasks()
        let netError = (error as? MizarNetError) ?? .punchFailed(reason: "\(error)")
        currentState = .failed(netError)
        emit(.state(currentState))
        await engine.shutdown()
    }

    private func assertNotBusy() throws {
        switch currentState {
        case .ready:
            throw MizarNetError.alreadyReady
        case .connecting:
            throw MizarNetError.alreadyReady
        case .closed:
            throw MizarNetError.cancelled
        case .idle, .failed:
            return
        }
    }

    /// The dial, bounded by the punch budget.
    ///
    /// A task group rather than a naked `Task.sleep` race, because the losing
    /// task has to be cancelled: a dial that lands one second after its
    /// budget expired has opened a socket nobody is holding, and the engine
    /// would keep it until its own timeout.
    private func dialWithBudget(_ budget: Duration) async throws -> any MizarNetStream {
        let engine = self.engine
        let ticket = self.ticket
        return try await withThrowingTaskGroup(of: (any MizarNetStream)?.self) { group in
            group.addTask {
                try await engine.dial(ticket: ticket, timeout: budget)
            }
            group.addTask {
                try? await Task.sleep(for: budget)
                return nil
            }
            while let result = try await group.next() {
                if let stream = result {
                    group.cancelAll()
                    return stream
                }
                throw MizarNetError.dialTimeout(path: .p2p)
            }
            throw MizarNetError.dialTimeout(path: .p2p)
        }
    }

    /// Announce ourselves on the signaling channel, before anything dials.
    ///
    /// The hello carries the candidates the engine can see right now — the
    /// LAN addresses, and whatever a STUN answer has already produced — so
    /// the peer's punch starts from the best list available instead of
    /// waiting for a second message. It is sent by both sides: a dial that
    /// only heard from the far end would have nothing to punch towards.
    ///
    /// The phone's hello also carries the device token: the desktop's signal
    /// endpoint answers nothing until it can tell whose channel this is, and
    /// the candidates in this frame are what its punch is aimed with. The
    /// desktop's hello has no token, and an old desktop ignores the key.
    ///
    /// A failure here is not fatal. Signaling is an accelerator, not a
    /// requirement: the ticket's direct hints are enough to attempt a punch,
    /// and the relay path needs no signaling at all.
    private func sendHello() async {
        guard let signaling, let identity = engineIdentity else { return }
        let candidates = await engine.localCandidates()
        do {
            try await signaling.send(
                .hello(MizarNetHello(endpointId: identity.endpointId, candidates: candidates, token: deviceToken))
            )
        } catch {
            emit(.log("signaling hello failed: \(error)"))
        }
    }

    /// Drain the signaling channel into the engine, for the connection's life.
    ///
    /// Detached, so a slow or silent peer never blocks the connection actor:
    /// the punch runs on the candidates gathered so far and improves when
    /// more arrive.
    private func startCandidateConsumer() async {
        guard let signaling else { return }
        // `signals()` is nonisolated by contract: it hands out a constant.
        let signals = signaling.signals()
        let engine = self.engine
        candidateTask = Task.detached {
            for await signal in signals {
                switch signal {
                case .hello(let hello):
                    #if DEBUG
                    print("p2p: signal hello \(hello.candidates.count) candidate(s)")
                    #endif
                    await engine.offerCandidates(hello.candidates)
                case .candidates(let candidates):
                    #if DEBUG
                    print("p2p: signal \(candidates.count) more candidate(s)")
                    #endif
                    await engine.offerCandidates(candidates)
                case .bye:
                    break
                }
                await self.emit(.signaling(signal))
            }
        }
    }

    private func adopt(_ stream: any MizarNetStream) async {
        self.stream = stream
        let path = await stream.pathKind
        currentState = .ready(path: path)
        emit(.state(currentState))
        startHealthMonitor()
    }

    /// Poll the engine's opinion of the path.
    ///
    /// `unknown` never counts against a path — see ``MizarNetHealth``. When
    /// the streak runs out, the stream is dropped and the state says so: the
    /// app's reconnect sees a closed socket and applies its own route policy,
    /// which is the only place that knows about the relay.
    private func startHealthMonitor() {
        healthTask?.cancel()
        let engine = self.engine
        let policy = self.policy
        healthTask = Task.detached {
            var streak = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: policy.healthInterval)
                if Task.isCancelled { break }
                let health = await engine.health()
                if health.isHealthy {
                    streak = 0
                    continue
                }
                if case .unknown = health { continue }
                streak += 1
                if streak >= policy.downgradeAfter {
                    await self.handleDegraded(health)
                    break
                }
            }
        }
    }

    private func handleDegraded(_ health: MizarNetHealth) async {
        emit(.healthDegraded(health))
        if let stream {
            await stream.close()
            self.stream = nil
        }
        currentState = .failed(.streamClosed)
        emit(.state(currentState))
    }

    private func emit(_ event: MizarNetEvent) {
        guard !finished else { return }
        eventContinuation.yield(event)
    }
}
