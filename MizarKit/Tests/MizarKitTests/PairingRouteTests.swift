//
//  PairingRouteTests.swift
//  MizarKitTests
//
//  Pairing against a QR that carries two routes.
//
//  Plugin 0.8.5 on puts both the LAN address (`h`) and the relay (`u`) in one
//  code, and iOS 0.9.3 dialled only the first of them whenever it was present.
//  A phone that could not reach that address -- cellular, a client-isolated
//  Wi-Fi, local-network permission denied -- therefore never paired, although
//  the relay in the same code answered. These tests pin the two halves of the
//  fix: the plan that orders the routes, and the rule that decides when a failed
//  route is worth falling through and when the host has already answered.
//

import Foundation
import Testing
@testable import MizarKit

@Suite("Pairing route plan")
struct PairingRoutePlanTests {
    private static let direct = "10.0.0.5:19390"
    private static let relay = "https://relay.example.com/r/ABCD"

    @Test("tries the direct address first and the relay behind it")
    func bothRoutes() {
        let target = PairingTarget(
            authority: Self.direct,
            code: "AB2C-D3EF",
            baseURL: Self.relay,
        )
        #expect(
            PairingRoutes.plan(for: target) == [
                .direct(authority: Self.direct),
                .relay(baseURL: Self.relay),
            ],
        )
    }

    @Test("a LAN-only code has one route")
    func directOnly() {
        let target = PairingTarget(authority: Self.direct, code: "AB2C-D3EF")
        #expect(PairingRoutes.plan(for: target) == [.direct(authority: Self.direct)])
    }

    @Test("a relay-only code has one route, and it is the relay")
    func relayOnly() {
        let target = PairingTarget(authority: nil, code: "AB2C-D3EF", baseURL: Self.relay)
        #expect(PairingRoutes.plan(for: target) == [.relay(baseURL: Self.relay)])
    }

    @Test("a target with no address has no plan")
    func noAddress() {
        // The parser refuses such a URI, so this only protects against a target
        // built by hand (the manual-entry screen builds one from typed fields).
        let target = PairingTarget(authority: nil, code: "AB2C-D3EF")
        #expect(PairingRoutes.plan(for: target).isEmpty)
    }

    @Test("a relay URL this client cannot dial is not a route")
    func unusableRelayIsDropped() {
        let target = PairingTarget(
            authority: Self.direct,
            code: "AB2C-D3EF",
            baseURL: "ftp://relay.example.com/r/ABCD",
        )
        #expect(PairingRoutes.plan(for: target) == [.direct(authority: Self.direct)])
    }

    @Test("each route carries the timeout the connection gives it")
    func routeTimeouts() {
        // Six seconds for direct, twenty for relay: the same leashes
        // `AppModel.makeConnection` uses. The direct number is what keeps a dead
        // LAN address from delaying the relay by the thirty-second default.
        #expect(PairingRoute.direct(authority: Self.direct).timeout == 6)
        #expect(PairingRoute.relay(baseURL: Self.relay).timeout == 20)
    }

    @Test("a route converts to the endpoint a pairing records")
    func routeEndpoints() {
        #expect(PairingRoute.direct(authority: Self.direct).endpoint == .direct(authority: Self.direct))
        #expect(PairingRoute.relay(baseURL: Self.relay).endpoint == .relay(baseURL: Self.relay))
    }
}

@Suite("Pairing fallback")
struct PairingFallbackTests {
    private static let direct = "10.0.0.5:19390"
    private static let relay = "https://relay.example.com/r/ABCD"
    private static let directURL = "http://10.0.0.5:19390/mizar/v1/pair"
    private static let relayURL = "https://relay.example.com/r/ABCD/mizar/v1/pair"
    private static let pairing = RelayIdentity(clientId: "install-1234", accountToken: "mza_abc")

    private static let pairedBody = #"""
    {"deviceToken":"mz_abc","deviceId":"d1","hostId":"h1","hostName":"mac","protocolVersion":1}
    """#

    /// The code a plugin 0.8.5+ shows: both routes, direct first.
    private static var bothRoutes: PairingTarget {
        PairingTarget(authority: direct, code: "AB2C-D3EF", baseURL: relay)
    }

    @Test("falls through a dead direct route to the relay, over the relay's dial and headers")
    func fallsThroughToRelay() async throws {
        let transport = ScriptedHTTPTransport()
        await transport.on("pair", failure: URLError(.cannotConnectToHost))
        await transport.on("pair", body: Self.pairedBody)
        let client = PairingClient(transport: transport, headers: Self.pairing.headers)

        let outcome = try await client.pair(
            target: Self.bothRoutes,
            deviceName: "iPhone",
            deviceModel: "iPhone18,1",
        )

        #expect(outcome.route == .relay(baseURL: Self.relay))
        // The pairing was made over the relay, but the QR's direct address is
        // kept as the faster fallback when the phone is back on the LAN.
        #expect(outcome.host.authority == Self.direct)
        #expect(outcome.host.baseURL == Self.relay)
        #expect(outcome.host.endpoints == [
            .direct(authority: Self.direct),
            .relay(baseURL: Self.relay),
        ])
        #expect(outcome.host.deviceToken == "mz_abc")

        let requests = await transport.recorded()
        #expect(requests.count == 2)
        // The direct attempt went to the address the code carried, and carried
        // no identity headers: those are relay bookkeeping.
        #expect(requests[0].url?.absoluteString == Self.directURL)
        #expect(requests[0].value(forHTTPHeaderField: RelayIdentity.clientIdHeader) == nil)
        #expect(requests[0].value(forHTTPHeaderField: RelayIdentity.accountHeader) == nil)
        // The relay attempt is the one that must carry them, and it went to the
        // relay's pair URL -- not to the direct address again.
        #expect(requests[1].url?.absoluteString == Self.relayURL)
        #expect(requests[1].value(forHTTPHeaderField: RelayIdentity.clientIdHeader) == "install-1234")
        #expect(requests[1].value(forHTTPHeaderField: RelayIdentity.accountHeader) == RelayIdentity.hash(of: "mza_abc"))
    }

    @Test("falls through a direct address that cannot even be dialled")
    func undialableDirectFallsThrough() async throws {
        // The parser accepts any non-empty `h`, and a scanned code is untrusted
        // input. Nothing is sent to a route whose URL cannot be built, so this is
        // a route that never reached the host -- the relay is worth trying, and
        // no request with the code in it ever leaves for the direct address.
        let transport = ScriptedHTTPTransport()
        await transport.on("pair", body: Self.pairedBody)
        let client = PairingClient(transport: transport, headers: Self.pairing.headers)

        let outcome = try await client.pair(
            target: PairingTarget(authority: "not a host", code: "AB2C-D3EF", baseURL: Self.relay),
            deviceName: "iPhone",
            deviceModel: "iPhone18,1",
        )

        #expect(outcome.route == .relay(baseURL: Self.relay))
        let requests = await transport.recorded()
        #expect(requests.count == 1)
        #expect(requests[0].url?.absoluteString == Self.relayURL)
    }

    @Test("does not fall through a host refusal: the host answered, and that is the answer")
    func hostRefusalStops() async throws {
        let transport = ScriptedHTTPTransport()
        await transport.on("pair", status: 401, body: #"{"error":"PAIRING_CODE_INVALID"}"#)
        // Scripted, but it must never be asked for: a wrong code through the
        // relay would be the same wrong code.
        await transport.on("pair", body: Self.pairedBody)
        let client = PairingClient(transport: transport, headers: Self.pairing.headers)

        let failure = try #require(
            await capturedFailure {
                _ = try await client.pair(
                    target: Self.bothRoutes,
                    deviceName: "iPhone",
                    deviceModel: "iPhone18,1",
                )
            },
        )

        #expect(failure.attempts.count == 1)
        #expect(failure.attempts.first?.route == .direct(authority: Self.direct))
        #expect((failure.finalError as? MizarError)?.code == "PAIRING_CODE_INVALID")
        let requests = await transport.recorded()
        #expect(requests.count == 1)
        #expect(requests[0].url?.absoluteString == Self.directURL)
    }

    @Test("surface the last attempt when no route answers")
    func bothRoutesFail() async throws {
        let transport = ScriptedHTTPTransport()
        await transport.on("pair", failure: URLError(.cannotConnectToHost))
        await transport.on("pair", failure: URLError(.timedOut))
        let client = PairingClient(transport: transport, headers: Self.pairing.headers)

        let failure = try #require(
            await capturedFailure {
                _ = try await client.pair(
                    target: Self.bothRoutes,
                    deviceName: "iPhone",
                    deviceModel: "iPhone18,1",
                )
            },
        )

        #expect(failure.attempts.count == 2)
        #expect(failure.attempts.map(\.route) == [
            .direct(authority: Self.direct),
            .relay(baseURL: Self.relay),
        ])
        // The relay is the last route tried and the one that was supposed to
        // work, so its error is the one to show.
        #expect((failure.finalError as? URLError)?.code == .timedOut)
    }

    @Test("reports a relay refusal with the attempts that led to it")
    func relayRefusalIsLast() async throws {
        let transport = ScriptedHTTPTransport()
        await transport.on("pair", failure: URLError(.cannotConnectToHost))
        await transport.on("pair", status: 410, body: #"{"error":"PAIRING_CODE_EXPIRED"}"#)
        let client = PairingClient(transport: transport, headers: Self.pairing.headers)

        let failure = try #require(
            await capturedFailure {
                _ = try await client.pair(
                    target: Self.bothRoutes,
                    deviceName: "iPhone",
                    deviceModel: "iPhone18,1",
                )
            },
        )

        #expect(failure.attempts.count == 2)
        #expect((failure.finalError as? MizarError)?.code == "PAIRING_CODE_EXPIRED")
    }

    @Test("a direct success is reported, and the relay is not dialled")
    func directSuccess() async throws {
        let transport = ScriptedHTTPTransport()
        await transport.on("pair", body: Self.pairedBody)
        // Never reached: a direct route that answers is the pairing's route, and
        // spending the relay's timeout after it would be a second wait for a
        // question already answered.
        await transport.on("pair", failure: URLError(.timedOut))
        let client = PairingClient(transport: transport, headers: Self.pairing.headers)

        let outcome = try await client.pair(
            target: Self.bothRoutes,
            deviceName: "iPhone",
            deviceModel: "iPhone18,1",
        )

        #expect(outcome.route == .direct(authority: Self.direct))
        #expect(outcome.host.authority == Self.direct)
        // The relay from the same QR survives the LAN pairing. Without it the
        // phone has no route at all once it leaves Wi-Fi.
        #expect(outcome.host.baseURL == Self.relay)
        #expect(outcome.host.endpoints == [
            .direct(authority: Self.direct),
            .relay(baseURL: Self.relay),
        ])
        let requests = await transport.recorded()
        #expect(requests.count == 1)
    }

    @Test("asks for one transport per route, so each attempt keeps its own timeout")
    func perRouteTransport() async throws {
        // The app builds a URLSessionHTTPTransport with `route.timeout`; the
        // factory is the seam that makes a dead direct address cost six seconds
        // rather than the relay attempt's twenty.
        let direct = ScriptedHTTPTransport()
        await direct.on("pair", failure: URLError(.cannotConnectToHost))
        let relay = ScriptedHTTPTransport()
        await relay.on("pair", body: Self.pairedBody)
        let client = PairingClient(
            makeTransport: { route in
                switch route {
                case .direct: return direct
                case .relay: return relay
                }
            },
            headers: Self.pairing.headers,
        )

        let outcome = try await client.pair(
            target: Self.bothRoutes,
            deviceName: "iPhone",
            deviceModel: "iPhone18,1",
        )

        #expect(outcome.route == .relay(baseURL: Self.relay))
        #expect(await direct.recorded().count == 1)
        #expect(await relay.recorded().count == 1)
    }

    @Test("a relay-only scan pairs over the relay without a direct attempt")
    func relayOnlyScan() async throws {
        let transport = ScriptedHTTPTransport()
        await transport.on("pair", body: Self.pairedBody)
        let client = PairingClient(transport: transport, headers: Self.pairing.headers)

        let outcome = try await client.pair(
            target: PairingTarget(authority: nil, code: "AB2C-D3EF", baseURL: Self.relay),
            deviceName: "iPhone",
            deviceModel: "iPhone18,1",
        )

        #expect(outcome.route == .relay(baseURL: Self.relay))
        let requests = await transport.recorded()
        #expect(requests.count == 1)
        #expect(requests[0].url?.absoluteString == Self.relayURL)
    }

    @Test("a scan with no dialable address fails before making a request")
    func noDialableAddress() async throws {
        let transport = ScriptedHTTPTransport()
        let client = PairingClient(transport: transport, headers: Self.pairing.headers)

        do {
            _ = try await client.pair(
                target: PairingTarget(authority: nil, code: "AB2C-D3EF"),
                deviceName: "iPhone",
                deviceModel: "iPhone18,1",
            )
            Issue.record("expected a failure")
        } catch let error as MizarError {
            #expect(error.code == "BAD_AUTHORITY")
        }
        #expect(await transport.recorded().isEmpty)
    }
}

/// Run one pairing attempt and return its failure, or `nil` when it succeeded.
///
/// Swift Testing's `#expect(throws:)` proves the type but does not hand back the
/// value, and these tests are about what the error (and its attempts) carry.
///
/// - Parameter operation: the pairing call to run.
/// - Returns: the failure, or `nil` when the call succeeded.
private func capturedFailure(
    _ operation: () async throws -> Void,
) async -> PairingFailure? {
    do {
        try await operation()
        Issue.record("expected a pairing failure")
        return nil
    } catch let failure as PairingFailure {
        return failure
    } catch {
        Issue.record("expected PairingFailure, got \(error)")
        return nil
    }
}
