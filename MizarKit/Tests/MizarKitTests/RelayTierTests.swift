//
//  RelayTierTests.swift
//  MizarKitTests
//
//  The two public relays and the movement between them.
//
//  The room lives in the path, so a phone that missed a tier change can repair
//  its stored URL by trying the other relay with the same room. These cases pin
//  that mapping and the boundary that keeps a self-hosted relay unaddressable
//  by the tier machinery.
//

import Foundation
import Testing
@testable import MizarKit

@Suite("Relay tiers")
struct RelayTierTests {
    private let free = "https://dshmizar.shirazu-nagisa.com"
    // The account-gated relay on its own port, kept for 0.9.8 and older builds.
    private let paid = "https://dshmizar-1.shirazu-nagisa.com:8443"
    // What 0.9.9 uses for every plan: the account relay on 443.
    private let unified = "https://dshmizar-1.shirazu-nagisa.com"

    @Test("every plan is on the account relay from 0.9.9")
    func baseURLByPlan() {
        #expect(RelayTier.baseURL(paid: true) == unified)
        #expect(RelayTier.baseURL(paid: false) == unified)
        #expect(RelayTier.unifiedBaseURL == unified)
    }

    @Test("recognises the public relays through a room path")
    func recognisesRelays() {
        #expect(RelayTier.isPublicRelay(free))
        #expect(RelayTier.isPublicRelay("\(free)/r/ROOM"))
        #expect(RelayTier.isPublicRelay(paid))
        #expect(RelayTier.isPublicRelay(unified))
        #expect(RelayTier.isPaidRelay("\(paid)/r/ROOM"))
        #expect(RelayTier.isPaidRelay("\(unified)/r/ROOM"))
        #expect(!RelayTier.isPaidRelay(free))
        #expect(!RelayTier.isPublicRelay("https://relay.example.com/r/ROOM"))
        #expect(!RelayTier.isPublicRelay("ftp://dshmizar.shirazu-nagisa.com"))
    }

    @Test("the alternate relay keeps the room path")
    func alternateKeepsRoom() {
        #expect(RelayTier.alternate(to: "\(free)/r/ROOM1") == "\(paid)/r/ROOM1")
        #expect(RelayTier.alternate(to: "\(paid)/r/ROOM1") == "\(free)/r/ROOM1")
        // An origin without a room still maps, to an origin without a room.
        #expect(RelayTier.alternate(to: free) == paid)
        // A self-hosted relay is the only place that host can be.
        #expect(RelayTier.alternate(to: "https://relay.example.com/r/ROOM1") == nil)
    }

    @Test("rebases a room URL onto another origin")
    func rebased() {
        #expect(
            RelayTier.rebased("\(free)/r/ROOM1", onto: paid) == "\(paid)/r/ROOM1",
        )
        #expect(RelayTier.rebased("\(free)/r/ROOM1", onto: "\(paid)/") == "\(paid)/r/ROOM1")
    }

    @Test("a pairing on a public relay has an alternate route, a self-hosted one does not")
    func pairingEndpoints() {
        let publicPairing = PairedHost(
            hostId: "h1",
            hostName: "mac",
            authority: nil,
            deviceId: "d1",
            deviceToken: "token",
            baseURL: "\(free)/r/ROOM1",
        )
        #expect(publicPairing.endpoints == [
            .relay(baseURL: "\(free)/r/ROOM1"),
            .relay(baseURL: "\(paid)/r/ROOM1"),
        ])

        // The alternate is a fallback, not a second stored pairing: moving to
        // it rewrites the stored URL and leaves one relay route plus its
        // alternate again.
        let moved = publicPairing.moved(toRelay: "\(paid)/r/ROOM1")
        #expect(moved.baseURL == "\(paid)/r/ROOM1")
        #expect(moved.endpoints == [
            .relay(baseURL: "\(paid)/r/ROOM1"),
            .relay(baseURL: "\(free)/r/ROOM1"),
        ])

        let selfHosted = PairedHost(
            hostId: "h2",
            hostName: "mac",
            authority: nil,
            deviceId: "d2",
            deviceToken: "token",
            baseURL: "https://relay.example.com/r/ROOM1",
        )
        #expect(selfHosted.endpoints == [
            .relay(baseURL: "https://relay.example.com/r/ROOM1"),
        ])
    }

    @Test("decodes host.info's relay facts and a relay.set answer")
    func decodesRelayFrames() throws {
        let info = try JSONDecoder().decode(
            HostInfo.self,
            from: Data(#"{"hostId":"h1","hostName":"mac","home":"/home","protocolVersion":1,"relay":{"url":"\#(paid)","room":"ROOM1","baseURL":"\#(paid)/r/ROOM1"}}"#.utf8),
        )
        #expect(info.relay == HostRelay(url: paid, room: "ROOM1", baseURL: "\(paid)/r/ROOM1"))

        let result = try JSONDecoder().decode(
            RelaySetResult.self,
            from: Data(#"{"url":"\#(free)","room":"ROOM1","baseURL":null}"#.utf8),
        )
        #expect(result.url == free)
        #expect(result.room == "ROOM1")
        #expect(result.baseURL == nil)
    }

    @Test("an older host's host.info carries no relay")
    func absentRelay() throws {
        let info = try JSONDecoder().decode(
            HostInfo.self,
            from: Data(#"{"hostId":"h1","hostName":"mac","home":"/home","protocolVersion":1}"#.utf8),
        )
        #expect(info.relay == nil)
    }
}
