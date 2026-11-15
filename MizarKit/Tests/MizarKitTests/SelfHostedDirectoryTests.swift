//
//  SelfHostedDirectoryTests.swift
//  MizarKitTests
//
//  The online-computer list of a self-hosted relay.
//
//  The response shape is the relay's (see `dsh-relay/src/selfhost.ts`), and the
//  status codes are its refusals. Both are pinned with an injected loader, so
//  the mapping between "what the relay said" and "what the guide shows" cannot
//  drift without a failure here.
//

import Foundation
import Testing
@testable import MizarKit

@Suite("Self-hosted directory")
struct SelfHostedDirectoryTests {
    private let origin = "relay.example.com"
    private let pin = "K7QP-3M2X"

    @Test("decodes the relay's list, including a computer with no id")
    func decodesList() async throws {
        let recorder = Recorder()
        let result = await SelfHostedDirectoryClient(origin: origin, pin: pin).list(
            load: recorder.answer(200, #"""
            {
              "relay": {"version": "0.5.0", "protocol": 1, "publicURL": "https://relay.example.com"},
              "desktops": [
                {"room": "ROOM1", "deviceId": "device-1", "name": "Office Mac", "platform": "macos", "onlineSince": 1763200000000},
                {"room": "ROOM2", "deviceId": "", "name": "Computer", "platform": "unknown", "onlineSince": 1763200001000}
              ]
            }
            """#),
        )
        guard case .success(let desktops) = result else {
            Issue.record("expected a list, got \(result)")
            return
        }
        #expect(desktops.count == 2)
        #expect(desktops[0].room == "ROOM1")
        #expect(desktops[0].deviceId == "device-1")
        #expect(desktops[0].name == "Office Mac")
        #expect(desktops[0].platform == "macos")
        #expect(desktops[0].platformLabel == "macOS")
        #expect(desktops[0].onlineSince == 1_763_200_000_000)
        // A computer that sent no id is still identifiable: the room addresses
        // it, and that is what the phone pairs with.
        #expect(desktops[1].id == "ROOM2")
        #expect(desktops[1].platformLabel == nil)

        #expect(recorder.paths == ["/selfhost/v1/desktops"])
        #expect(recorder.urls.first?.absoluteString == "https://relay.example.com/selfhost/v1/desktops")
        #expect(recorder.requests.first?.value(forHTTPHeaderField: "x-mizar-server-pin") == pin)
    }

    @Test("a relay with no PIN needs no header")
    func noPinNoHeader() async {
        let recorder = Recorder()
        _ = await SelfHostedDirectoryClient(origin: origin, pin: "").list(
            load: recorder.answer(200, #"{"relay":{"version":"0.5.0","protocol":1},"desktops":[]}"#),
        )
        #expect(recorder.requests.first?.value(forHTTPHeaderField: "x-mizar-server-pin") == nil)
    }

    @Test("every refusal keeps its own case")
    func refusals() async {
        let cases: [(Int, SelfHostedDirectoryError)] = [
            (401, .pinRequired),
            (403, .pinInvalid),
            (429, .rateLimited),
            (500, .http(500)),
        ]
        for (status, expected) in cases {
            let result = await SelfHostedDirectoryClient(origin: origin, pin: pin).list(
                load: Recorder().answer(status, "{}"),
            )
            #expect(result == .failure(expected), "status \(status)")
        }
    }

    @Test("a 200 that is not the directory response is not an empty list")
    func invalidBody() async {
        let result = await SelfHostedDirectoryClient(origin: origin, pin: pin).list(
            load: Recorder().answer(200, "<html>hello</html>"),
        )
        #expect(result == .failure(.invalidResponse))
    }

    @Test("a dead host and a bad origin are distinguishable")
    func transportAndOrigin() async {
        let offline = await SelfHostedDirectoryClient(origin: origin, pin: pin).list(
            load: { _ in throw URLError(.cannotConnectToHost) },
        )
        #expect(offline == .failure(.network))

        let recorder = Recorder()
        let invalid = await SelfHostedDirectoryClient(origin: "http://relay.example.com", pin: pin).list(
            load: recorder.answer(200, #"{"desktops":[]}"#),
        )
        #expect(invalid == .failure(.invalidOrigin))
        #expect(recorder.requests.isEmpty)
    }

    // MARK: - The stub

    private final class Recorder {
        private(set) var requests: [URLRequest] = []
        var urls: [URL] { requests.compactMap(\.url) }
        var paths: [String] { urls.map(\.path) }

        func answer(_ status: Int, _ body: String) -> (URLRequest) async throws -> (Data, HTTPURLResponse) {
            { [self] request in
                requests.append(request)
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
}
