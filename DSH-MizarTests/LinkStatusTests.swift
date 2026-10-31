//
//  LinkStatusTests.swift
//  DSH-MizarTests
//
//  The bar's one job is to put the cross on the hop that failed, and the hop is
//  decided by the route, not by the error: the same timeout is the server over a
//  relay and the computer directly. These pin that mapping without a screen.
//

import Foundation
import Testing
import MizarKit
@testable import DSH_Mizar

@Suite("Link status")
struct LinkStatusTests {
    private func status(_ error: any Error, relay: Bool) -> LinkStatus {
        LinkStatus.failure(error, authority: "example.test:19390", isRelay: relay)
    }

    @Test("a relay 404 marks the hop behind the server")
    func computerAbsent() {
        let bar = status(WebSocketUpgradeRefused(status: 404), relay: true)
        #expect(bar.topology == .relay)
        #expect(bar.broken == .relayToComputer)
        #expect(bar.label == .computerAbsent)
        #expect(!bar.connected)
    }

    @Test("a server that cannot be reached marks the phone's own hop")
    func relayUnreachable() {
        let errors: [any Error] = [
            URLError(.timedOut),
            URLError(.cannotFindHost),
            WebSocketUpgradeRefused(status: 503),
        ]
        for error in errors {
            let bar = status(error, relay: true)
            #expect(bar.topology == .relay)
            #expect(bar.broken == .phoneToRelay)
            #expect(bar.label == .relayUnreachable)
        }
    }

    @Test("a direct failure marks the only segment")
    func directFailure() {
        let bar = status(URLError(.timedOut), relay: false)
        #expect(bar.topology == .direct)
        #expect(bar.broken == .phoneToComputer)
        #expect(bar.label == .computerUnreachable)
    }

    @Test("no network says so, whichever hop was being dialled")
    func offline() {
        #expect(status(URLError(.notConnectedToInternet), relay: true).label == .offline)
        #expect(status(URLError(.notConnectedToInternet), relay: false).label == .offline)
    }

    @Test("the computer's own refusal is a refusal, not a missing computer")
    func refused() {
        let error = MizarError(code: "UNAUTHENTICATED", message: "this device is not paired")
        let relayed = status(error, relay: true)
        #expect(relayed.broken == .relayToComputer)
        #expect(relayed.label == .refused)
        let direct = status(error, relay: false)
        #expect(direct.broken == .phoneToComputer)
        #expect(direct.label == .refused)
    }

    @Test("a dial-level code is a failure to reach, not a refusal")
    func dialLevel() {
        let error = MizarError(code: "CONNECTION_CLOSED", message: "the host closed the connection")
        #expect(status(error, relay: false).label == .computerUnreachable)
        // The socket existed, so the server was reached: the cross stays on the
        // hop behind it even though nothing was said.
        #expect(status(error, relay: true).label == .computerUnreachable)
        #expect(status(error, relay: true).broken == .relayToComputer)
    }

    @Test("a silent relay handshake is the computer, not the server")
    func silentHandshake() {
        let error = MizarError(code: "REQUEST_TIMEOUT", message: "the host did not say hello in time")
        let bar = status(error, relay: true)
        #expect(bar.broken == .relayToComputer)
        #expect(bar.label == .computerAbsent)
    }

    @Test("a pairing with a direct route is drawn as two devices while connecting")
    func plannedTopology() {
        #expect(LinkStatus.plannedTopology(for: nil) == .direct)
        #expect(LinkStatus.plannedTopology(for: host(authority: "10.0.0.2:19390")) == .direct)
        #expect(LinkStatus.plannedTopology(for: host(baseURL: "https://relay.example")) == .relay)
        // Both routes: the direct one is what the pairing reaches for first, so
        // the picture that a success is most likely to have is the two-device one.
        #expect(
            LinkStatus.plannedTopology(
                for: host(authority: "10.0.0.2:19390", baseURL: "https://relay.example"),
            ) == .direct,
        )
    }

    /// A pairing with just enough in it to answer the topology question.
    private func host(authority: String? = nil, baseURL: String? = nil) -> PairedHost {
        PairedHost(
            hostId: "host",
            hostName: "Computer",
            authority: authority,
            deviceId: "device",
            deviceToken: "token",
            baseURL: baseURL,
        )
    }
}
