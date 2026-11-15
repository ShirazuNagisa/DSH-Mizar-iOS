//
//  ServerProbeTests.swift
//  MizarKitTests
//
//  The guide's "verify connection" button, without a network.
//
//  Every refusal the relay contract defines is pinned here: not a relay, a
//  protocol too old, a PIN that is missing or wrong, too many attempts. The
//  injected loader is the point -- a test that needed a real server could not
//  produce a 403 on demand.
//

import Foundation
import Testing
@testable import MizarKit

@Suite("Server probe")
struct ServerProbeTests {
    private let origin = "relay.example.com"

    @Test("a healthy relay with no PIN passes with one request")
    func healthyNoPin() async throws {
        let recorder = Recorder()
        let result = await ServerProbe.check(
            origin: origin,
            pin: "",
            load: recorder.answer(200, #"""
            {"product":"dsh-mizar-relay","relayVersion":"0.5.0","version":1,"selfHost":true,"pinRequired":false}
            """#),
        )
        guard case .success(let health) = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(health.product == "dsh-mizar-relay")
        #expect(health.relayVersion == "0.5.0")
        #expect(health.version == 1)
        #expect(health.selfHost == true)
        #expect(!health.requiresPin)
        #expect(recorder.paths == ["/healthz"])
        // The origin was normalised, scheme included.
        #expect(recorder.urls.first?.absoluteString == "https://relay.example.com/healthz")
    }

    @Test("a relay that needs a PIN refuses an empty field without a second request")
    func pinRequired() async {
        let recorder = Recorder()
        let result = await ServerProbe.check(
            origin: origin,
            pin: "   ",
            load: recorder.answer(200, #"""
            {"product":"dsh-mizar-relay","relayVersion":"0.5.0","version":1,"selfHost":true,"pinRequired":true}
            """#),
        )
        #expect(result == .failure(.pinRequired))
        #expect(recorder.paths == ["/healthz"])
    }

    @Test("a PIN the relay accepts passes and is sent as the documented header")
    func pinAccepted() async throws {
        let recorder = Recorder()
        let result = await ServerProbe.check(
            origin: origin,
            pin: "K7QP-3M2X",
            load: recorder.answer(
                paths: [
                    "/healthz": (200, #"""
                    {"product":"dsh-mizar-relay","relayVersion":"0.5.0","version":1,"selfHost":true,"pinRequired":true}
                    """#),
                    "/selfhost/v1/desktops": (200, #"{"relay":{"version":"0.5.0","protocol":1},"desktops":[]}"#),
                ],
            ),
        )
        guard case .success = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(recorder.paths == ["/healthz", "/selfhost/v1/desktops"])
        #expect(recorder.requests.last?.value(forHTTPHeaderField: "x-mizar-server-pin") == "K7QP-3M2X")
        // No PIN header on the unauthenticated health check.
        #expect(recorder.requests.first?.value(forHTTPHeaderField: "x-mizar-server-pin") == nil)
    }

    @Test("a PIN the relay refuses is its own answer")
    func pinInvalid() async {
        let recorder = Recorder()
        let result = await ServerProbe.check(
            origin: origin,
            pin: "WRONG",
            load: recorder.answer(
                paths: [
                    "/healthz": (200, #"""
                    {"product":"dsh-mizar-relay","relayVersion":"0.5.0","version":1,"selfHost":true,"pinRequired":true}
                    """#),
                    "/selfhost/v1/desktops": (403, #"{"error":"SECRET_INVALID"}"#),
                ],
            ),
        )
        #expect(result == .failure(.pinInvalid))
    }

    @Test("a 401 on the directory is read as 'a PIN is required'")
    func directoryUnauthorized() async {
        let recorder = Recorder()
        let result = await ServerProbe.check(
            origin: origin,
            pin: "K7QP-3M2X",
            load: recorder.answer(
                paths: [
                    "/healthz": (200, #"""
                    {"product":"dsh-mizar-relay","relayVersion":"0.5.0","version":1,"selfHost":true,"pinRequired":true}
                    """#),
                    "/selfhost/v1/desktops": (401, #"{"error":"PIN_REQUIRED"}"#),
                ],
            ),
        )
        #expect(result == .failure(.pinRequired))
    }

    @Test("too many wrong PINs is not the same as a wrong PIN")
    func rateLimited() async {
        let recorder = Recorder()
        let result = await ServerProbe.check(
            origin: origin,
            pin: "K7QP-3M2X",
            load: recorder.answer(
                paths: [
                    "/healthz": (200, #"""
                    {"product":"dsh-mizar-relay","relayVersion":"0.5.0","version":1,"selfHost":true,"pinRequired":true}
                    """#),
                    "/selfhost/v1/desktops": (429, #"{"error":"TOO_MANY_ATTEMPTS"}"#),
                ],
            ),
        )
        #expect(result == .failure(.rateLimited))
    }

    @Test("a valid https site that is not a relay is refused")
    func notARelay() async {
        let recorder = Recorder()
        let result = await ServerProbe.check(
            origin: origin,
            pin: "",
            load: recorder.answer(200, "<html>hello</html>"),
        )
        #expect(result == .failure(.notRelay))

        let wrongProduct = await ServerProbe.check(
            origin: origin,
            pin: "",
            load: Recorder().answer(200, #"{"product":"something-else","version":1}"#),
        )
        #expect(wrongProduct == .failure(.notRelay))
    }

    @Test("a relay on an older tunnel protocol is refused")
    func protocolTooOld() async {
        let zero = await ServerProbe.check(
            origin: origin,
            pin: "",
            load: Recorder().answer(200, #"""
            {"product":"dsh-mizar-relay","relayVersion":"0.1.0","version":0}
            """#),
        )
        #expect(zero == .failure(.protocolTooOld))

        // A health answer with no protocol at all cannot be trusted to speak
        // this client's tunnel; the sentence is about the protocol, not the
        // address.
        let missing = await ServerProbe.check(
            origin: origin,
            pin: "",
            load: Recorder().answer(200, #"{"product":"dsh-mizar-relay","relayVersion":"0.1.0"}"#),
        )
        #expect(missing == .failure(.protocolTooOld))
    }

    @Test("an unreachable host and a bad status keep their own sentences")
    func transportAndStatus() async {
        let offline = await ServerProbe.check(
            origin: origin,
            pin: "",
            load: { _ in throw URLError(.cannotFindHost) },
        )
        #expect(offline == .failure(.network))

        let broken = await ServerProbe.check(
            origin: origin,
            pin: "",
            load: Recorder().answer(500, "{}"),
        )
        #expect(broken == .failure(.http(500)))

        let limited = await ServerProbe.check(
            origin: origin,
            pin: "",
            load: Recorder().answer(429, "{}"),
        )
        #expect(limited == .failure(.rateLimited))
    }

    @Test("an address that is not an https origin never leaves the phone")
    func invalidOrigin() async {
        let recorder = Recorder()
        let result = await ServerProbe.check(
            origin: "http://relay.example.com",
            pin: "",
            load: recorder.answer(200, #"{"product":"dsh-mizar-relay","version":1}"#),
        )
        #expect(result == .failure(.invalidOrigin))
        #expect(recorder.requests.isEmpty)
    }

    // MARK: - The stub

    /// Records what the probe asked for and answers from a table.
    private final class Recorder {
        private(set) var requests: [URLRequest] = []

        var urls: [URL] { requests.compactMap(\.url) }
        var paths: [String] { urls.map(\.path) }

        /// One answer for every request.
        func answer(_ status: Int, _ body: String) -> (URLRequest) async throws -> (Data, HTTPURLResponse) {
            { [self] request in
                record(request)
                return response(to: request, status: status, body: body)
            }
        }

        /// One answer per path, keyed by `URL.path`.
        func answer(
            paths: [String: (Int, String)],
        ) -> (URLRequest) async throws -> (Data, HTTPURLResponse) {
            { [self] request in
                record(request)
                let answer = paths[request.url?.path ?? ""] ?? (404, "{}")
                return response(to: request, status: answer.0, body: answer.1)
            }
        }

        private func record(_ request: URLRequest) {
            requests.append(request)
        }

        private func response(to request: URLRequest, status: Int, body: String) -> (Data, HTTPURLResponse) {
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://relay.example.com")!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"],
            )!
            return (Data(body.utf8), response)
        }
    }
}
