//
//  ConnectionTests.swift
//  MizarKitTests
//
//  The client's behaviour against a scripted socket.
//
//  These cover the paths that only appear when something goes wrong: a host that
//  answers with a failure, a host that stops answering, a frame from a future
//  version, and a socket that closes mid-call. Those are the paths a phone on a
//  mobile network actually spends its time in, and the ones least likely to be
//  noticed by hand.
//

import Foundation
import Testing
@testable import MizarKit

/// Build a responder that answers by frame type.
private func responder(
    onRequest: @escaping @Sendable (String) -> String? = { _ in nil },
) -> StubTransport.Responder {
    { text in
        guard let type = frameType(of: text) else { return [] }
        if type == "hello" { return [welcomeFrame()] }
        let id = correlationId(of: text) ?? ""
        if let answer = onRequest(id) { return [answer] }
        return [okFrame(id: id, result: json(["echo": .string(type)]))]
    }
}

/// Drive a responder that answers only the request types it is told about.
///
/// Anything else is left unanswered on purpose: "the host never replies" is a
/// state several tests need to reach, and a catch-all reply here would make
/// those tests pass for the wrong reason — which is exactly what happened the
/// first time this helper was written.
private func responderAnswering(_ answer: @escaping @Sendable (String) -> String?) -> StubTransport.Responder {
    { text in
        guard let type = frameType(of: text) else { return [] }
        if type == "hello" { return [welcomeFrame()] }
        guard let frame = answer(type) else { return [] }
        let id = correlationId(of: text) ?? ""
        return [frame.replacingOccurrences(of: "$ID", with: id)]
    }

}

@Suite("MizarConnection")
struct ConnectionTests {
    private func makeConnection(
        transport: StubTransport,
        timeout: Duration = .seconds(5),
    ) -> MizarConnection {
        MizarConnection(
            configuration: .init(authority: "127.0.0.1:19390", token: "mz_test", requestTimeout: timeout),
            makeTransport: { transport },
        )
    }

    @Test("completes the handshake and reports the welcome")
    func handshake() async throws {
        let transport = StubTransport(responder: responder())
        let connection = makeConnection(transport: transport)

        let welcome = try await connection.connect()
        #expect(welcome.hostId == "host-1")
        #expect(welcome.hostName == "mac")
        #expect(await connection.currentState.welcome != nil)

        let dialed = await transport.dialed
        #expect(dialed.first?.absoluteString == "ws://127.0.0.1:19390/mizar/v1/ws")
    }

    @Test("sends hello with the token before anything else")
    func sendsHelloFirst() async throws {
        let transport = StubTransport(responder: responder())
        let connection = makeConnection(transport: transport)
        _ = try await connection.connect()

        let sent = await transport.sent
        #expect(frameType(of: sent[0]) == "hello")
        let hello = try #require(try JSONDecoder().decode(JSONValue.self, from: Data(sent[0].utf8)))
        #expect(hello["token"]?.stringValue == "mz_test")
        #expect(hello["protocolVersion"]?.intValue == mizarProtocolVersion)
    }

    @Test("correlates a response to its request")
    func requestCorrelation() async throws {
        let transport = StubTransport(responder: responderAnswering { type in
            type == "host.info" ? okFrame(id: "$ID", result: json(["hostId": .string("h1")])) : nil
        })
        let connection = makeConnection(transport: transport)
        _ = try await connection.connect()

        let result = try await connection.request("host.info")
        #expect(result?["hostId"]?.stringValue == "h1")
    }

    @Test("a rejection before the welcome keeps its code")
    func handshakeFailureKeepsItsCode() async throws {
        // `DEVICE_REVOKED`, a cross-account hello and a blocked device are all
        // sent as an error frame with no id, before the welcome. Without a
        // pending call to attach it to, the code used to be dropped and every
        // one of those cases surfaced as "the host closed the connection" --
        // which tells the operator nothing and hides the one screen that says
        // to pair again.
        let transport = StubTransport(responder: { text in
            guard let type = frameType(of: text) else { return [] }
            if type == "hello" {
                return [errorFrame(code: "DEVICE_REVOKED", message: "this phone was removed", id: nil)]
            }
            return []
        })
        let connection = makeConnection(transport: transport)
        do {
            _ = try await connection.connect()
            Issue.record("connect() should have thrown the host's refusal")
        } catch let error as MizarError {
            #expect(error.code == "DEVICE_REVOKED")
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    @Test("fans out calls, correlating every answer and keeping one failure from discarding the rest")
    func requestAllCorrelatesEachAnswer() async throws {
        // The socket was always multiplexed; the caller was not. `requestAll` is
        // what lets a 342-session sync issue its pages at once, so what has to
        // hold is that each answer lands on its own id -- and that one session
        // refusing does not throw away the pages that did arrive.
        let transport = StubTransport(responder: { text in
            guard let type = frameType(of: text) else { return [] }
            if type == "hello" { return [welcomeFrame()] }
            let id = correlationId(of: text) ?? ""
            let frame = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
            let session = frame?["payload"]?["sessionId"]?.stringValue ?? ""
            if session == "session-2" {
                return [errorFrame(code: "SESSION_GONE", message: "no such session", id: id)]
            }
            return [okFrame(id: id, result: json(["sessionId": .string(session)]))]
        })
        let connection = makeConnection(transport: transport)
        _ = try await connection.connect()

        let requests = (0..<8).map { index in
            (
                id: "r\(index)",
                method: "session.messages",
                payload: JSONValue.object(["sessionId": .string("session-\(index)")]),
            )
        }
        let outcomes = await connection.requestAll(requests, concurrency: 3)
        #expect(outcomes.count == 8)
        for index in 0..<8 where index != 2 {
            #expect(outcomes["r\(index)"]?.value?["sessionId"]?.stringValue == "session-\(index)")
        }
        #expect(outcomes["r2"]?.error?.code == "SESSION_GONE")
        // A missing id is absent, not a made-up success: the caller decides
        // what an unanswered page means.
        #expect(outcomes["r99"] == nil)
    }

    @Test("decodes a typed result")
    func typedCall() async throws {
        let transport = StubTransport(responder: responderAnswering { type in
            type == "host.info"
                ? okFrame(id: "$ID", result: json([
                    "hostId": .string("h1"),
                    "hostName": .string("studio"),
                    "home": .string("/home/dsh"),
                    "protocolVersion": .number(1),
                    "desktop": .object([
                        "os": .string("macOS"),
                        "client": .string("DSH"),
                    ]),
                ]))
                : nil
        })
        let connection = makeConnection(transport: transport)
        _ = try await connection.connect()

        let info = try await connection.call("host.info", as: HostInfo.self)
        #expect(info.hostId == "h1")
        #expect(info.hostName == "studio")
        #expect(info.desktop == HostDesktop(os: "macOS", client: "DSH"))
        #expect(info.desktop?.labels == ["macOS", "DSH"])
    }

    @Test("surfaces a host failure as a coded error")
    func hostFailure() async throws {
        let transport = StubTransport(responder: responderAnswering { type in
            type == "session.create" ? errorFrame(code: "WRITER_HELD", message: "busy", id: "$ID") : nil
        })
        let connection = makeConnection(transport: transport)
        _ = try await connection.connect()

        await #expect(throws: MizarError.self) {
            _ = try await connection.request("session.create")
        }
        do {
            _ = try await connection.request("session.create")
            Issue.record("expected a failure")
        } catch let error as MizarError {
            #expect(error.known == .writerHeld)
            #expect(!error.requiresRepairing)
        }
    }

    @Test("delivers unsolicited events to subscribers")
    func events() async throws {
        let transport = StubTransport(responder: responder())
        let connection = makeConnection(transport: transport)
        _ = try await connection.connect()

        let stream = await connection.events()
        await transport.push(eventFrame(name: "approval.request", data: json(["requestId": .string("ap-1")])))

        var iterator = stream.makeAsyncIterator()
        let frame = try #require(await iterator.next())
        guard case .event(let name, let data) = frame else {
            Issue.record("expected an event")
            return
        }
        #expect(name == "approval.request")
        #expect(data["requestId"]?.stringValue == "ap-1")
    }

    @Test("keeps the connection alive across a frame type it does not know")
    func unknownFramesAreNotFatal() async throws {
        let transport = StubTransport(responder: responderAnswering { type in
            type == "host.info" ? okFrame(id: "$ID", result: json(["hostId": .string("h1")])) : nil
        })
        let connection = makeConnection(transport: transport)
        _ = try await connection.connect()

        // A frame from a newer host, then a normal call.
        await transport.push(serverFrame([
            "v": .number(Double(mizarProtocolVersion)),
            "type": .string("brand.new.frame"),
            "anything": .string("preserved"),
        ]))

        let result = try await connection.request("host.info")
        #expect(result?["hostId"]?.stringValue == "h1")
    }

    @Test("ignores a frame that will not decode instead of dropping the socket")
    func undecodableFramesAreNotFatal() async throws {
        let transport = StubTransport(responder: responderAnswering { type in
            type == "host.info" ? okFrame(id: "$ID", result: json(["hostId": .string("h1")])) : nil
        })
        let connection = makeConnection(transport: transport)
        _ = try await connection.connect()

        await transport.push("{ not json at all")
        let result = try await connection.request("host.info")
        #expect(result?["hostId"]?.stringValue == "h1")
    }

    @Test("fails in-flight calls when the socket closes")
    func closeFailsInFlight() async throws {
        let transport = StubTransport(responder: responderAnswering { _ in nil })
        let connection = makeConnection(transport: transport)
        _ = try await connection.connect()

        let call = Task { try await connection.request("never.answers") }
        // Let the call reach its suspension point before closing.
        _ = await eventually { await transport.sent.count >= 2 }
        await transport.pushClose()

        do {
            _ = try await call.value
            Issue.record("expected the call to fail")
        } catch let error as MizarError {
            #expect(error.retryable)
        } catch {
            Issue.record("expected a MizarError, got \(error)")
        }
    }

    @Test("a request made after the socket closed is retryable, so the caller reconnects")
    func requestAfterCloseIsRetryable() async throws {
        let transport = StubTransport(responder: responder())
        let connection = makeConnection(transport: transport)
        _ = try await connection.connect()
        await transport.pushClose()
        // The read loop tears the transport down; a request arriving after that
        // used to throw a plain SOCKET_CLOSED, which the app classifies as "not
        // about the connection" and therefore never reconnects for -- the screen
        // then said "the socket is not open" on every refresh.
        _ = await eventually { await connection.currentState.welcome == nil }

        do {
            _ = try await connection.request("host.info")
            Issue.record("expected the request to fail")
        } catch let error as MizarError {
            #expect(error.code == "SOCKET_CLOSED")
            #expect(error.retryable, "the app only reconnects for errors it can retry")
        }
    }

    @Test("finishes event streams when the socket closes")
    func closeFinishesStreams() async throws {
        let transport = StubTransport(responder: responder())
        let connection = makeConnection(transport: transport)
        _ = try await connection.connect()

        let stream = await connection.events()
        await transport.pushClose()

        var iterator = stream.makeAsyncIterator()
        // The stream ends rather than waiting forever on a socket that is gone.
        let value = await iterator.next()
        #expect(value == nil)
    }

    @Test("times a request out rather than waiting forever")
    func requestTimeout() async throws {
        let transport = StubTransport(responder: responderAnswering { _ in nil })
        let connection = makeConnection(transport: transport, timeout: .milliseconds(120))
        _ = try await connection.connect()

        do {
            _ = try await connection.request("never.answers")
            Issue.record("expected a timeout")
        } catch let error as MizarError {
            #expect(error.code == "REQUEST_TIMEOUT")
            #expect(error.retryable)
        }
    }

    @Test("fails a connect whose socket closes before the welcome")
    func closeBeforeWelcome() async throws {
        // The race this guards: the read loop starts before `hello` is sent, so
        // the socket can close before `connect()` reaches its suspension point.
        // Handling only the post-suspension case would leave the caller waiting
        // on a connection that is already gone.
        let transport = StubTransport(responder: { _ in [] })
        let connection = makeConnection(transport: transport, timeout: .milliseconds(200))

        let task = Task { try await connection.connect() }
        _ = await eventually { await transport.sent.count >= 1 }
        await transport.pushClose()

        do {
            _ = try await task.value
            Issue.record("expected the handshake to fail")
        } catch let error as MizarError {
            #expect(error.code == "CONNECTION_CLOSED" || error.code == "REQUEST_TIMEOUT")
            #expect(error.retryable)
        }
    }

    @Test("propagates a dial failure")
    func dialFailure() async throws {
        let transport = StubTransport(responder: responder())
        await transport.failConnect(with: MizarError(code: "SOCKET_CLOSED", message: "refused"))
        let connection = makeConnection(transport: transport)

        await #expect(throws: MizarError.self) {
            _ = try await connection.connect()
        }
    }

    @Test("keeps the status of a refused upgrade instead of describing it")
    func refusedUpgrade() async throws {
        // The reported bug: a relay answering 404 for a room with no computer
        // attached reached the screen as "there was a bad response from the
        // server", which is also what a server that cannot be reached says. The
        // status is the only thing that tells the two apart, so it has to survive
        // the read loop -- which used to flatten every failure to a string.
        let transport = StubTransport(responder: { _ in [] })
        await transport.failReceive(with: WebSocketUpgradeRefused(status: 404))
        let connection = makeConnection(transport: transport, timeout: .milliseconds(500))

        do {
            _ = try await connection.connect()
            Issue.record("expected the handshake to fail")
        } catch let refusal as WebSocketUpgradeRefused {
            #expect(refusal.status == 404)
            #expect(refusal.meansComputerAbsent)
        }
    }

    @Test("refuses to dial an authority it cannot parse")
    func badAuthority() async throws {
        let transport = StubTransport(responder: responder())
        let connection = MizarConnection(
            configuration: .init(authority: "not a host", token: "mz_test"),
            makeTransport: { transport },
        )
        do {
            _ = try await connection.connect()
            Issue.record("expected a failure")
        } catch let error as MizarError {
            #expect(error.code == "BAD_AUTHORITY")
        }
        #expect(await transport.dialed.isEmpty)
    }

    @Test("retry reconnects until the host answers")
    func retrySucceeds() async throws {
        // Fail the first dial, then let the second succeed.
        let flaky = FlakyTransport(failuresBeforeSuccess: 1)
        let connection = MizarConnection(
            configuration: .init(authority: "127.0.0.1:19390", token: "mz_test"),
            makeTransport: { flaky },
        )
        try await connection.connectWithRetry(backoff: Backoff(steps: [0.01], jitter: 0))
        #expect(await connection.currentState.welcome != nil)
        #expect(await flaky.attempts == 2)
    }
    @Test("fails a handshake the host never finishes")
    func handshakeDeadline() async throws {
        // A host that completes the upgrade, accepts `hello`, and then says
        // nothing at all. There is no read to time out -- `receive()` is simply
        // never answered -- so without a deadline of its own `connect()` waits
        // for the life of the process and the screen behind it reads
        // "Connecting…" with nothing that can ever change it.
        let transport = StubTransport(responder: { _ in [] })
        let connection = MizarConnection(
            configuration: .init(
                authority: "127.0.0.1:19390",
                token: "mz_test",
                requestTimeout: .seconds(5),
                handshakeTimeout: .milliseconds(150),
            ),
            makeTransport: { transport },
        )

        let outcome = ConnectOutcome()
        let attempt = Task {
            do {
                let welcome = try await connection.connect()
                await outcome.settled(.success(welcome))
            } catch {
                await outcome.settled(.failure(error))
            }
        }
        // Polled rather than awaited, because the failure this test exists for is
        // `connect()` never returning: awaiting it directly would hang the suite
        // instead of reporting it.
        let didSettle = await eventually(timeout: 3) { await outcome.isSettled }
        attempt.cancel()
        #expect(didSettle, "connect() never settled: a host that never says hello hangs the app")

        guard case .failure(let error) = await outcome.result else {
            Issue.record("expected the handshake to fail")
            return
        }
        #expect((error as? MizarError)?.code == "REQUEST_TIMEOUT")
        // And the socket is closed rather than left half-open behind a screen
        // that has already moved on to the next route.
        #expect(await transport.didClose, "the socket was left open after the handshake gave up")
    }

    @Test("ends an event stream asked for after the socket closed")
    func eventsAfterCloseFinish() async throws {
        let transport = StubTransport(responder: responder())
        let connection = makeConnection(transport: transport)
        _ = try await connection.connect()
        await transport.pushClose()
        // Let the read loop notice before subscribing, which is the race the
        // listener in the app actually runs: `startInteractionPoll` subscribes
        // from a `Task` started after `connect()` returns.
        _ = await eventually { await connection.currentState.welcome == nil }

        // A stream registered after the close had nothing left to finish it, so
        // its consumer waited for the life of the process.
        let stream = await connection.events()
        let ended = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                return await iterator.next() == nil
            }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(400))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        #expect(ended, "an event stream registered after the close never finished")
    }

    @Test("binary state frames drive the session state")
    func stateChannel() async throws {
        let transport = StubTransport(responder: responder())
        let connection = makeConnection(transport: transport)
        _ = try await connection.connect()

        let sent = await transport.sent
        #expect(sent.contains { $0.contains("state.subscribe") })

        func envelope(_ frame: StateFrame, session: String = "s-1") -> WebSocketFrame {
            var out = Data([UInt8(session.utf8.count)])
            out.append(contentsOf: session.utf8)
            out.append(frame.encoded())
            return .binary(out)
        }

        await transport.push(frame: envelope(StateFrame(state: .thinking, interval: 1, flags: [])))
        #expect(await stateSettles { await connection.sessionState("s-1") == .thinking })

        await transport.push(frame: envelope(
            StateFrame(state: .streamFinal, interval: 2, flags: [.snapshot, .append], text: "先说")
        ))
        #expect(await stateSettles { await connection.streamedText("s-1") == "先说" })

        await transport.push(frame: envelope(
            StateFrame(state: .streamFinal, interval: 2, textSeq: 6, flags: [.append], text: "结论")
        ))
        #expect(await stateSettles { await connection.streamedText("s-1") == "先说结论" })

        // An append that skips bytes means a frame was lost; splicing it would
        // draw a sentence that was never said, so the channel waits for the
        // next snapshot instead.
        await transport.push(frame: envelope(
            StateFrame(state: .streamFinal, interval: 2, textSeq: 20, flags: [.append], text: "跳")
        ))
        try await Task.sleep(for: .milliseconds(80))
        #expect(await connection.streamedText("s-1") == "先说结论")

        await transport.push(frame: envelope(StateFrame(state: .completed, interval: 3, flags: [])))
        #expect(await stateSettles { await connection.sessionState("s-1") == .completed })
    }

    @Test("a reconnect starts a new state-channel epoch")
    func reconnectResetsStateInterval() async throws {
        let first = StubTransport(responder: responder())
        let second = StubTransport(responder: responder())
        let queue = TransportQueue([first, second])
        let connection = MizarConnection(
            configuration: .init(
                authority: "127.0.0.1:19390",
                token: "mz_test",
                requestTimeout: .seconds(5),
            ),
            makeTransport: { queue.next() },
        )
        _ = try await connection.connect()

        func envelope(_ frame: StateFrame) -> WebSocketFrame {
            var out = Data([UInt8("s-1".utf8.count)])
            out.append(contentsOf: "s-1".utf8)
            out.append(frame.encoded())
            return .binary(out)
        }

        await first.push(frame: envelope(StateFrame(state: .tool, interval: 9, flags: [])))
        #expect(await stateSettles { await connection.sessionState("s-1") == .tool })

        await connection.disconnect()
        _ = try await connection.connect()
        // A rebuilt desktop app can restart intervals at 1. The old 9 must not
        // make the fresh interval look stale.
        await second.push(frame: envelope(StateFrame(state: .completed, interval: 1, flags: [])))
        #expect(await stateSettles { await connection.sessionState("s-1") == .completed })
    }

    /// Poll until the read loop has caught up: "pushed" is not "applied".
    private func stateSettles(
        _ condition: @Sendable () async -> Bool,
    ) async -> Bool {
        for _ in 0..<100 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }
}

/// A thread-safe sequence of stub sockets for one reconnect test.
final class TransportQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var transports: [StubTransport]

    init(_ transports: [StubTransport]) { self.transports = transports }

    func next() -> StubTransport {
        lock.lock()
        defer { lock.unlock() }
        return transports.isEmpty ? StubTransport() : transports.removeFirst()
    }
}

// MARK: - Test doubles

/// Where a connect attempt's outcome lands, for a test that must not await it.
actor ConnectOutcome {
    private(set) var isSettled = false
    private(set) var result: Result<WelcomeFrame, any Error>?

    func settled(_ outcome: Result<WelcomeFrame, any Error>) {
        isSettled = true
        result = outcome
    }
}

/// A transport that refuses its first dials, for the retry test.
actor FlakyTransport: WebSocketTransport {
    private let failuresBeforeSuccess: Int
    private(set) var attempts = 0
    private var queue: [String?] = []
    private var waiting: [CheckedContinuation<WebSocketFrame?, any Error>] = []

    init(failuresBeforeSuccess: Int) {
        self.failuresBeforeSuccess = failuresBeforeSuccess
    }

    func connect(url: URL, headers: [String: String]) async throws {
        attempts += 1
        if attempts <= failuresBeforeSuccess {
            throw MizarError(code: "SOCKET_CLOSED", message: "refused", retryable: true)
        }
    }

    func send(text: String) async throws {
        guard frameType(of: text) == "hello" else { return }
        queue.append(welcomeFrame())
        while let waiter = waiting.first, let next = queue.first {
            waiting.removeFirst()
            queue.removeFirst()
            waiter.resume(returning: next.map { WebSocketFrame.text($0) })
        }
    }

    func receive() async throws -> WebSocketFrame? {
        if let next = queue.first {
            queue.removeFirst()
            return next.map { WebSocketFrame.text($0) }
        }
        return try await withCheckedThrowingContinuation { continuation in
            waiting.append(continuation)
        }
    }

    func close() async {
        for waiter in waiting { waiter.resume(returning: nil) }
        waiting.removeAll()
    }
}
