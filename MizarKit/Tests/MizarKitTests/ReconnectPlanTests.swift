//
//  ReconnectPlanTests.swift
//  MizarKitTests
//
//  The route order a reconnect uses.
//
//  The reported bug: connected over the LAN, the LAN died, and the phone kept
//  dialling the dead local address -- three attempts, then again from the next
//  read -- while the relay in the same pairing was never tried. These tests pin
//  the order that makes the fall-through happen, and the attempt count that
//  stops a two-route pairing from spending all its attempts on one of them.
//

import Foundation
import Testing

@testable import MizarKit

struct ReconnectPlanTests {
    private let direct = PairedHost.Endpoint.direct(authority: "192.168.1.42:19390")
    private let relay = PairedHost.Endpoint.relay(baseURL: "https://relay.example.com/r/ROOM")

    @Test("only the local route counts as direct, so only it starts at once")
    func onlyTheLocalRouteIsDirect() {
        // The launch plan gives the local route a head start and delays
        // everything else. P2P is an alternative to a lost LAN, not a second
        // local network: delaying it behind the relay would hand the slower route
        // every race.
        #expect(ReconnectPlan.isDirect(direct))
        #expect(!ReconnectPlan.isDirect(relay))
        #expect(
            !ReconnectPlan.isDirect(
                .p2p(relayBaseURL: "https://relay.example.com/r/ROOM", endpointId: "key"),
            ),
        )
    }

    @Test("the route that was working is tried first, then the other one")
    func lastWorkingFirst() {
        // The relay is the fallback that turns a dead LAN into a working link
        // inside the same reconnect; leaving it out is the bug.
        #expect(
            ReconnectPlan.routes(endpoints: [direct, relay], active: direct)
                == [direct, relay],
        )
        #expect(
            ReconnectPlan.routes(endpoints: [direct, relay], active: relay)
                == [relay, direct],
        )
    }

    @Test("a local link that died tries the relay first")
    func relayFirstAfterLocalFailure() {
        // The one fact a dead local socket carries is "this network is gone".
        #expect(
            ReconnectPlan.routes(
                endpoints: [direct, relay],
                active: direct,
                preferringRelay: true,
            ) == [relay, direct],
        )
        // Already relayed: preferring the relay changes nothing.
        #expect(
            ReconnectPlan.routes(
                endpoints: [direct, relay],
                active: relay,
                preferringRelay: true,
            ) == [relay, direct],
        )
    }

    @Test("a foreground return starts from the pairing's own order")
    func everyRouteStartsFromTheHostOrder() {
        #expect(
            ReconnectPlan.routes(
                endpoints: [direct, relay],
                active: relay,
                tryingEveryRoute: true,
            ) == [direct, relay],
        )
    }

    @Test("a moved address is still a route, in front of the stored ones")
    func activeRouteNotInThePairing() {
        // A LAN scan may have moved the host to an address the stored pairing
        // does not list; that route is still the one that was working.
        let moved = PairedHost.Endpoint.direct(authority: "192.168.1.99:19390")
        #expect(
            ReconnectPlan.routes(endpoints: [direct, relay], active: moved)
                == [moved, direct, relay],
        )
    }

    @Test("a route in the pairing is not repeated because it is active too")
    func noDuplicates() {
        #expect(
            ReconnectPlan.routes(endpoints: [direct, relay], active: direct)
                == [direct, relay],
        )
        #expect(
            ReconnectPlan.routes(endpoints: [], active: nullEndpoint)
                == [nullEndpoint],
        )
    }

    @Test("no active route uses the pairing's order, and no pairing is empty")
    func fallbacks() {
        #expect(ReconnectPlan.routes(endpoints: [direct, relay], active: nil) == [direct, relay])
        #expect(ReconnectPlan.routes(endpoints: [relay], active: nil) == [relay])
        #expect(ReconnectPlan.routes(endpoints: [], active: nil).isEmpty)
    }

    @Test("one route gets three attempts; two routes get one each")
    func attemptCounts() {
        #expect(ReconnectPlan.attempts(routeCount: 1, patient: false) == 3)
        #expect(ReconnectPlan.attempts(routeCount: 2, patient: false) == 2)
        #expect(ReconnectPlan.attempts(routeCount: 0, patient: false) >= 1)
        #expect(ReconnectPlan.attempts(routeCount: 2, patient: true) == 8)
    }

    @Test("relay routes are recognisable for the ordering")
    func relayDetection() {
        #expect(ReconnectPlan.isRelay(relay))
        #expect(!ReconnectPlan.isRelay(direct))
    }

    /// A second direct endpoint, for the "not in the pairing" case.
    private var nullEndpoint: PairedHost.Endpoint {
        .direct(authority: "10.0.0.9:19390")
    }
}
