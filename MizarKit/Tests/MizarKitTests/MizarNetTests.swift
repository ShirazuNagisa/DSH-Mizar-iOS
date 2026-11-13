//
//  MizarNetTests.swift
//  MizarKitTests
//
//  The kernel, without a network.
//
//  What is under test here is everything the engine is *not*: the identity
//  derivation a pairing depends on, the ticket that names a peer, the
//  priority order candidates are tried in, the budgets a punch may spend,
//  and the state machine's manners — it drops a path that stays bad, it
//  forwards a network change without inventing a reconnect, and it closes
//  cleanly enough that the peer sees a close rather than a hang.
//
//  The loopback engine (MizarNetTestSupport) supplies the connectivity, so
//  these tests run in milliseconds and fail for the kernel's reasons, not
//  the network's.
//

import Foundation
import Testing

@testable import MizarKit
import MizarNetNATLab

struct MizarNetTests {
    private let candidate = MizarNetCandidate(
        kind: .serverReflexive,
        address: "203.0.113.9",
        port: 40000,
    )

    // MARK: - Identity

    @Test("a derived identity is stable, and the purpose separates keys")
    func derivedIdentityIsStable() {
        let secret = Data(repeating: 7, count: 32)
        let first = MizarNetIdentity.derived(from: secret, purpose: .device)
        let second = MizarNetIdentity.derived(from: secret, purpose: .device)
        #expect(first == second)
        #expect(first.endpointId.count == 43)
        #expect(MizarNetCodec.base64URLDecode(first.endpointId)?.count == 32)

        // The host key and a device key share the secret but not the key:
        // one secret, two identities, which is what the pairing needs.
        let host = MizarNetIdentity.derived(from: secret, purpose: .host)
        #expect(host != first)
    }

    @Test("the short id is eight Crockford characters")
    func shortIdIsCrockford() {
        let identity = MizarNetIdentity.generate()
        #expect(identity.shortId.count == 8)
        let alphabet = Set("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        #expect(Set(identity.shortId).isSubset(of: alphabet))
    }

    @Test("a signature verifies for the right message and key only")
    func signatureRoundTrip() throws {
        let identity = MizarNetIdentity.generate()
        let message = Data("mizar-net".utf8)
        let signature = try identity.sign(message)
        #expect(MizarNetIdentity.verify(signature: signature, message: message, endpointId: identity.endpointId))
        #expect(!MizarNetIdentity.verify(signature: signature, message: Data("mizar-net!".utf8), endpointId: identity.endpointId))

        let other = MizarNetIdentity.generate()
        #expect(!MizarNetIdentity.verify(signature: signature, message: message, endpointId: other.endpointId))
    }

    // MARK: - Ticket

    @Test("a ticket survives the wire form")
    func ticketRoundTrip() throws {
        let identity = MizarNetIdentity.generate()
        let ticket = MizarNetTicket(
            endpointId: identity.endpointId,
            relays: ["https://relay.example.com"],
            direct: ["10.0.0.2:19390"],
        )
        #expect(try MizarNetTicket.decode(try ticket.encode()) == ticket)
    }

    @Test("a broken ticket is rejected, not guessed at")
    func brokenTicketsAreRejected() {
        #expect(throws: (any Error).self) {
            try MizarNetTicket.decode("!!!!")
        }
        let junk = MizarNetCodec.base64URLEncode(Data("not json".utf8))
        #expect(throws: (any Error).self) {
            try MizarNetTicket.decode(junk)
        }
        // A ticket naming something that is not a 32-byte key.
        let shortKey = MizarNetTicket(endpointId: "abc")
        #expect(throws: (any Error).self) {
            try MizarNetTicket.decode(try shortKey.encode())
        }
        // A version this build does not speak.
        let future = #"{"direct":[],"endpointId":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","relays":[],"v":2}"#
        #expect(throws: (any Error).self) {
            try MizarNetTicket.decode(MizarNetCodec.base64URLEncode(Data(future.utf8)))
        }
    }

    @Test("the dial URL carries the ticket, and rejects foreign URLs")
    func dialURL() throws {
        let identity = MizarNetIdentity.generate()
        let ticket = MizarNetTicket(endpointId: identity.endpointId, direct: ["10.0.0.2:19390"])
        let url = try MizarNetDialURL.make(ticket: ticket)
        #expect(url.scheme == "mizar-net")
        #expect(try MizarNetDialURL.ticket(from: url) == ticket)

        // A relay URL is a relay URL: dialling it here would be a caller
        // bug, and saying so beats a mystery timeout.
        #expect(throws: (any Error).self) {
            try MizarNetDialURL.ticket(from: URL(string: "https://relay.example.com/r/ROOM/mizar/v1/ws")!)
        }
    }

    // MARK: - Candidates

    @Test("candidates are ordered host, server-reflexive, relay")
    func candidateOrder() {
        let host = MizarNetCandidate(kind: .host, address: "10.0.0.2", port: 19390, localPreference: 100)
        let reflexive = MizarNetCandidate(kind: .serverReflexive, address: "203.0.113.9", port: 40000, localPreference: 100)
        let relay = MizarNetCandidate(kind: .relay, address: "relay.example.com", port: 443, localPreference: 100)
        #expect(MizarNetCandidate.sortedByPriority([relay, reflexive, host]) == [host, reflexive, relay])

        // Local preference breaks ties inside a kind.
        let preferred = MizarNetCandidate(kind: .host, address: "10.0.0.3", port: 19390, localPreference: 200)
        #expect(MizarNetCandidate.sortedByPriority([host, preferred]).first == preferred)
    }

    @Test("a candidate speaks the wire's spelling, not the Swift case name")
    func candidateWireSpelling() throws {
        // The desktop's signaling answer is a hello whose candidate kinds are
        // ICE's: `host` and `srflx`. `Codable` synthesis encodes a String enum
        // by its raw value, so the case name must *be* the wire name. When it
        // was not, one `srflx` entry failed the whole hello and the dialler
        // reported "no candidate addresses to dial" while the desktop had
        // answered.
        let json = #"{"address":"203.0.113.9","kind":"srflx","port":40000,"priority":1694498817}"#
        let decoded = try JSONDecoder().decode(MizarNetCandidate.self, from: Data(json.utf8))
        #expect(decoded.kind == .serverReflexive)
        let encoded = try JSONEncoder().encode(decoded)
        let text = String(decoding: encoded, as: UTF8.self)
        #expect(text.contains("\"srflx\""))
        #expect(!text.contains("serverReflexive"))

        let hello = #"{"candidates":[{"address":"10.0.0.2","kind":"host","port":19390,"priority":1},{"address":"203.0.113.9","kind":"srflx","port":40000,"priority":2}],"endpointId":"x","type":"hello","v":1}"#
        let signal = try MizarNetSignalingJSON.decode(hello)
        guard case .hello(let decodedHello) = signal else {
            Issue.record("the desktop's hello did not decode")
            return
        }
        #expect(decodedHello.candidates.count == 2)
        #expect(decodedHello.candidates.map(\.kind) == [.host, .serverReflexive])
    }

    // MARK: - Signaling

    @Test("a signal survives the JSON form")
    func signalRoundTrip() throws {
        let identity = MizarNetIdentity.generate()
        let hello = MizarNetSignal.hello(MizarNetHello(endpointId: identity.endpointId, candidates: [candidate]))
        #expect(try MizarNetSignalingJSON.decode(MizarNetSignalingJSON.encode(hello)) == hello)

        // The phone's hello carries its pairing token; the desktop's does not.
        // One decoder has to read both, because an old desktop ignores the key
        // and an old app sends nothing under it.
        let authenticated = MizarNetSignal.hello(
            MizarNetHello(endpointId: identity.endpointId, candidates: [candidate], token: "device-token"),
        )
        let encoded = try MizarNetSignalingJSON.encode(authenticated)
        #expect(encoded.contains("\"token\":\"device-token\""))
        #expect(try MizarNetSignalingJSON.decode(encoded) == authenticated)

        let unauthenticated = MizarNetSignal.hello(
            MizarNetHello(endpointId: identity.endpointId, candidates: [candidate]),
        )
        let plain = try MizarNetSignalingJSON.encode(unauthenticated)
        #expect(!plain.contains("\"token\""))
        // A token-less hello on the wire is the desktop's, and decodes to nil
        // rather than failing.
        #expect(
            try MizarNetSignalingJSON.decode(#"{"candidates":[],"endpointId":"x","type":"hello","v":1}"#)
                == .hello(MizarNetHello(endpointId: "x", candidates: [])),
        )

        let bye = MizarNetSignal.bye(reason: "gone")
        #expect(try MizarNetSignalingJSON.decode(MizarNetSignalingJSON.encode(bye)) == bye)

        // Unknown versions and types are refused, the same tolerance the
        // Mizar protocol has for unknown frames.
        #expect(throws: (any Error).self) {
            try MizarNetSignalingJSON.decode(#"{"reason":"x","type":"bye","v":2}"#)
        }
        #expect(throws: (any Error).self) {
            try MizarNetSignalingJSON.decode(#"{"type":"nope","v":1}"#)
        }
    }

    @Test("signaling rides any WebSocket transport")
    func signalingOverWebSocket() async throws {
        let stub = StubTransport()
        let signaling = WebSocketSignalingTransport(socket: stub)
        try await signaling.open(url: URL(string: "wss://relay.example.com/r/ROOM/signal")!)

        let identity = MizarNetIdentity.generate()
        let hello = MizarNetSignal.hello(MizarNetHello(endpointId: identity.endpointId, candidates: [candidate]))
        try await signaling.send(hello)

        #expect(await stub.sent.count == 1)
        #expect(await stub.sent[0].contains("\"type\":\"hello\""))

        // An incoming frame becomes a signal on the stream.
        await stub.push(try MizarNetSignalingJSON.encode(.bye(reason: "later")))
        var iterator = signaling.signals().makeAsyncIterator()
        #expect(await iterator.next() == .bye(reason: "later"))

        await signaling.close()
        #expect(await stub.didClose)
    }

    @Test("the loopback signaling pair moves signals both ways")
    func loopbackSignaling() async throws {
        let (a, b) = await LabSignalingTransport.pair()
        try await a.send(.bye(reason: "done"))
        var bIterator = b.signals().makeAsyncIterator()
        #expect(await bIterator.next() == .bye(reason: "done"))

        try await b.send(.candidates([candidate]))
        var aIterator = a.signals().makeAsyncIterator()
        #expect(await aIterator.next() == .candidates([candidate]))
    }

    // MARK: - Policy

    @Test("the policy's numbers are the ones the plan measured")
    func policyNumbers() {
        let policy = MizarNetPathPolicy.standard
        #expect(policy.punchBudget == .seconds(3))
        #expect(policy.keepaliveInterval == .seconds(22))
        #expect(policy.downgradeAfter == 3)

        #expect(policy.punchDelay(afterFailures: 0) == .zero)
        #expect(policy.punchDelay(afterFailures: 1) == .seconds(1))
        #expect(policy.punchDelay(afterFailures: 2) == .seconds(2))
        #expect(policy.punchDelay(afterFailures: 9) == .seconds(8))

        #expect(policy.allowsAnotherRound(completedRounds: 2))
        #expect(!policy.allowsAnotherRound(completedRounds: 3))
    }

    @Test("kernel errors cross the transport boundary as Mizar errors")
    func errorMapping() {
        #expect(MizarNetError.dialTimeout(path: .p2p).mizarError.code == "P2P_TIMEOUT")
        #expect(MizarNetError.dialTimeout(path: .p2p).mizarError.retryable)
        #expect(MizarNetError.streamClosed.mizarError.code == "SOCKET_CLOSED")
        #expect(!MizarNetError.ticketInvalid(reason: "x").mizarError.retryable)
    }

    // MARK: - Connection state machine

    @Test("a dial connects, carries bytes both ways, and closes")
    func loopbackRoundTrip() async throws {
        let pair = try await connectedPair()

        #expect(await pair.dialer.state == .ready(path: .p2p))
        #expect(await pair.acceptor.state == .ready(path: .p2p))

        // Dialer to acceptor.
        try await pair.dialerStream.send(Data("hello".utf8))
        #expect(try await pair.acceptorStream.receive() == Data("hello".utf8))

        // Acceptor to dialer.
        try await pair.acceptorStream.send(Data("welcome".utf8))
        #expect(try await pair.dialerStream.receive() == Data("welcome".utf8))

        await pair.dialer.close()
        #expect(await pair.dialer.state == .closed)
        // The peer sees a close, not a hang.
        #expect(try await pair.acceptorStream.receive() == nil)
    }

    @Test("events report the path that came up")
    func eventsReportThePath() async throws {
        let pair = try await connectedPair()
        let events = await pair.dialer.events
        var iterator = events.makeAsyncIterator()
        var states: [MizarNetState] = []
        for _ in 0..<2 {
            if let event = await iterator.next(), case .state(let state) = event {
                states.append(state)
            }
        }
        #expect(states == [.connecting, .ready(path: .p2p)])
    }

    @Test("a dial that never lands times out at the budget")
    func dialRespectsTheBudget() async throws {
        let desktop = MizarNetLoopbackEngine(identity: MizarNetIdentity.generate())
        let phone = MizarNetLoopbackEngine(identity: MizarNetIdentity.generate())
        await phone.scriptHang()

        let policy = MizarNetPathPolicy(
            punchBudget: .milliseconds(250),
            healthInterval: .seconds(10),
            keepaliveInterval: .seconds(22),
            downgradeAfter: 3,
            punchBackoff: [.seconds(1)],
            maxPunchRounds: 1,
        )
        let dialer = MizarNetConnection(
            engine: phone,
            ticket: MizarNetTicket(endpointId: desktop.identity.endpointId),
            policy: policy,
        )

        do {
            _ = try await dialer.connect()
            Issue.record("a hanging dial must not connect")
        } catch let error as MizarNetError {
            #expect(error == .dialTimeout(path: .p2p))
        }
        // The failure is reported, and the engine was shut down rather than
        // left holding a socket from the attempt.
        #expect(await dialer.state == .failed(.dialTimeout(path: .p2p)))
        #expect(await phone.shutdownCount() == 1)
    }

    @Test("a path that stays bad is dropped, and the peer sees it")
    func healthDegradationDropsThePath() async throws {
        let pair = try await connectedPair(
            policy: MizarNetPathPolicy(
                punchBudget: .seconds(3),
                healthInterval: .milliseconds(30),
                keepaliveInterval: .seconds(22),
                downgradeAfter: 2,
                punchBackoff: [.seconds(1)],
                maxPunchRounds: 1,
            ),
        )

        await pair.phone.setHealth(.degraded(rttMilliseconds: 800, lossPercent: 20))

        let dropped = await eventually(timeout: 2) {
            await pair.dialer.state == .failed(.streamClosed)
        }
        #expect(dropped)
        // Dropping the stream is how the kernel asks the app's route policy
        // for the relay: the peer's read ends rather than hanging.
        #expect(try await pair.acceptorStream.receive() == nil)
    }

    @Test("a network change reaches the engine and nothing else happens")
    func networkChangeIsForwarded() async throws {
        let pair = try await connectedPair()
        await pair.dialer.networkChanged()
        #expect(await pair.phone.networkChangeCount() == 1)
        // The connection stays up: whether the stream survives is the
        // engine's call, not the connection's.
        #expect(await pair.dialer.state == .ready(path: .p2p))
        try await pair.dialerStream.send(Data("still here".utf8))
    }

    @Test("signaling does not get in the way of a dial")
    func dialWithSignaling() async throws {
        let desktop = MizarNetLoopbackEngine(identity: MizarNetIdentity.generate())
        let phone = MizarNetLoopbackEngine(identity: MizarNetIdentity.generate())
        try await desktop.start()
        let desktopId = desktop.identity.endpointId

        let (phoneSide, desktopSide) = await LabSignalingTransport.pair()
        let acceptor = MizarNetConnection(
            engine: desktop,
            ticket: MizarNetTicket(endpointId: desktopId),
            signaling: desktopSide,
        )
        let dialer = MizarNetConnection(
            engine: phone,
            ticket: MizarNetTicket(endpointId: desktopId),
            signaling: phoneSide,
            deviceToken: "device-token",
        )
        let acceptTask = Task { try await acceptor.accept() }

        let stream = try await dialer.connect()
        #expect(await dialer.state == .ready(path: .p2p))

        // The acceptor saw the dialer's hello, and the engine saw its
        // candidates — the exchange the punch would be built on.
        let hellos = await desktopSide.received.filter {
            if case .hello = $0 { return true }
            return false
        }
        #expect(hellos.count == 1)

        // The phone says who it is in that first frame; the desktop's own
        // hello answers without one, because it is the side being asked.
        var presented: String? = "no hello seen"
        for signal in await desktopSide.received {
            if case .hello(let hello) = signal { presented = hello.token }
        }
        #expect(presented == "device-token")

        var answered: String? = "no hello seen"
        for signal in await phoneSide.received {
            if case .hello(let hello) = signal { answered = hello.token }
        }
        #expect(answered == nil)
        // The candidates land in the engine through a detached consumer, so
        // the observation is a wait rather than a read.
        let offeredHello = await eventually(timeout: 2) {
            !(await desktop.offeredCandidates()).isEmpty
        }
        #expect(offeredHello)

        _ = try await acceptTask.value
        try await stream.send(Data("frame".utf8))
    }

    // MARK: - The transport seam

    @Test("the transport carries Mizar frames over a direct stream")
    func transportCarriesFrames() async throws {
        let desktop = MizarNetLoopbackEngine(identity: MizarNetIdentity.generate())
        let phoneEngine = MizarNetLoopbackEngine(identity: MizarNetIdentity.generate())
        try await desktop.start()
        let desktopId = desktop.identity.endpointId

        let acceptor = MizarNetConnection(
            engine: desktop,
            ticket: MizarNetTicket(endpointId: desktopId),
        )
        let acceptTask = Task { try await acceptor.accept() }

        let transport = P2PWebSocketTransport(makeEngine: { phoneEngine })
        try await transport.connect(
            url: try MizarNetDialURL.make(ticket: MizarNetTicket(endpointId: desktopId)),
            headers: ["x-mizar-client-id": "install-1"],
        )

        try await transport.send(text: "{\"v\":1,\"type\":\"ping\"}")
        let accepted = try await acceptTask.value
        #expect(try await accepted.receive() == Data("{\"v\":1,\"type\":\"ping\"}".utf8))

        try await accepted.send(Data("{\"v\":1,\"type\":\"pong\"}".utf8))
        #expect(try await transport.receive() == .text("{\"v\":1,\"type\":\"pong\"}"))

        await transport.close()
        #expect(try await accepted.receive() == nil)
    }

    @Test("a bad dial URL is a malformed ticket, not a network error")
    func transportRejectsForeignURL() async throws {
        let transport = P2PWebSocketTransport(
            makeEngine: { MizarNetLoopbackEngine(identity: MizarNetIdentity.generate()) },
        )
        do {
            try await transport.connect(url: URL(string: "https://relay.example.com")!, headers: [:])
            Issue.record("a relay URL must not dial as a direct connection")
        } catch let error as MizarError {
            #expect(error.code == "P2P_TICKET_INVALID")
            #expect(!error.retryable)
        }
    }

    // MARK: - Helpers

    /// A connected pair, both sides' engines included so a test can script
    /// the engine's behaviour and observe what reached it.
    private struct Pair {
        let dialer: MizarNetConnection
        let acceptor: MizarNetConnection
        let dialerStream: any MizarNetStream
        let acceptorStream: any MizarNetStream
        let phone: MizarNetLoopbackEngine
        let desktop: MizarNetLoopbackEngine
    }

    private func connectedPair(
        policy: MizarNetPathPolicy = .standard,
    ) async throws -> Pair {
        let desktop = MizarNetLoopbackEngine(identity: MizarNetIdentity.generate())
        let phone = MizarNetLoopbackEngine(identity: MizarNetIdentity.generate())
        try await desktop.start()
        let desktopId = desktop.identity.endpointId

        let acceptor = MizarNetConnection(
            engine: desktop,
            ticket: MizarNetTicket(endpointId: desktopId),
            policy: policy,
        )
        let dialer = MizarNetConnection(
            engine: phone,
            ticket: MizarNetTicket(endpointId: desktopId),
            policy: policy,
        )
        let acceptTask = Task { try await acceptor.accept() }
        let dialerStream = try await dialer.connect()
        let acceptorStream = try await acceptTask.value
        return Pair(
            dialer: dialer,
            acceptor: acceptor,
            dialerStream: dialerStream,
            acceptorStream: acceptorStream,
            phone: phone,
            desktop: desktop,
        )
    }
}
