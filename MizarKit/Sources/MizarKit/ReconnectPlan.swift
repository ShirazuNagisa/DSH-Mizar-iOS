//
//  ReconnectPlan.swift
//  MizarKit
//
//  Which route a reconnect should try, and in what order.
//
//  A pairing knows up to two ways to reach the computer: the direct address
//  (the LAN, a tailnet) and the relay. The reported bug is a plan that only
//  ever named one of them: the phone was connected over the LAN, the LAN went
//  away, and every reconnect dialled the address it had just lost -- three
//  timeouts, repeat -- while the relay that would have worked sat unused in the
//  same pairing.
//
//  So the route list is a decision, not inline code:
//
//    - the route that was working stays first for an ordinary reconnect, because
//      a dropped request is usually asking to rebuild exactly that socket;
//    - the rest of the pairing follows it, so a failed route always falls
//      through to the other one inside the same reconnect;
//    - a foreground return (``routes(endpoints:active:tryingEveryRoute:)`` with
//      `tryingEveryRoute`) starts from the pairing's own order instead;
//    - and a *local* link that just died asks for the relay first, because the
//      one fact that failure carries is "this network is gone".
//
//  The attempt count lives here too: one attempt per route when there are two,
//  three when there is only one, eight for a patient reconnect. Pure, so the
//  order is tested without a socket.
//

import Foundation

/// How a reconnect orders its routes, and how many attempts it gets.
public enum ReconnectPlan {
    /// The routes to dial, in order.
    ///
    /// - Parameters:
    ///   - endpoints: every route this pairing knows, in the host's natural
    ///     order (direct first, relay second).
    ///   - active: the route the last connection used, when there was one.
    ///   - tryingEveryRoute: whether to ignore `active` and start from the
    ///     pairing's order -- what a return from the background wants, since the
    ///     network may have changed while the app slept.
    ///   - preferringRelay: whether to put relay routes in front of direct ones.
    ///     Used when a local link has just died: the relay is the route that
    ///     does not share the network that broke.
    ///   - allowingDirectPath: whether the punched route may be planned at all.
    ///     `false` — the default for a fresh install — drops `.p2p` everywhere,
    ///     including from `active`, so switching the feature off takes effect on
    ///     the next reconnect instead of only on the next pairing.
    ///   - allowingLocalNetwork: whether the direct route may be planned at all.
    ///     The same rule for 局域网优先: off drops `.direct` everywhere, including
    ///     from `active`, so a link that is up does not stay the preferred route
    ///     after the switch is turned off.
    /// - Returns: distinct routes, in the order to try them. Empty when the
    ///   pairing knows no route the switches allow.
    public static func routes(
        endpoints: [PairedHost.Endpoint],
        active: PairedHost.Endpoint?,
        tryingEveryRoute: Bool = false,
        preferringRelay: Bool = false,
        allowingLocalNetwork: Bool = true,
        allowingDirectPath: Bool = true,
    ) -> [PairedHost.Endpoint] {
        // One policy, from `RoutePolicy`, rather than two filters written here:
        // the screen that drops a live link asks the same question, and the two
        // must never answer differently.
        let policy = { (endpoint: PairedHost.Endpoint) in
            RoutePolicy.allows(
                endpoint,
                localNetworkFirst: allowingLocalNetwork,
                directConnection: allowingDirectPath,
            )
        }
        var endpoints = endpoints.filter(policy)
        // An active route that the switches no longer allow is not a route that
        // "worked last": it is a route that may not be dialled, so it stops
        // being the head of the list.
        var active = active
        if let current = active, !policy(current) { active = nil }

        var ordered: [PairedHost.Endpoint]
        if tryingEveryRoute, !endpoints.isEmpty {
            ordered = endpoints
        } else if let active {
            // Last working first, then the rest of the pairing. The rest is what
            // turns a dead LAN into a relay connection instead of a retry loop.
            ordered = [active] + endpoints.filter { $0 != active }
        } else {
            ordered = endpoints
        }

        var unique: [PairedHost.Endpoint] = []
        for endpoint in ordered where !unique.contains(endpoint) {
            unique.append(endpoint)
        }

        guard preferringRelay else { return unique }
        return unique.filter(isRelay) + unique.filter { !isRelay($0) }
    }

    /// How many attempts one reconnect call gets.
    ///
    /// A patient reconnect keeps trying while the operator watches. An ordinary
    /// one gets one attempt per route when there is more than one -- a failed
    /// route falls through instead of being retried while its alternative waits
    /// -- and three attempts when the pairing has only one way in, because then
    /// there is nothing to fall through to.
    ///
    /// - Parameters:
    ///   - routeCount: how many distinct routes the plan produced.
    ///   - patient: whether this is a reconnect a person is waiting on.
    /// - Returns: the number of attempts, at least one.
    public static func attempts(routeCount: Int, patient: Bool) -> Int {
        if patient { return 8 }
        if routeCount <= 1 { return 3 }
        return routeCount
    }

    /// Whether a route goes through the relay.
    ///
    /// - Parameter endpoint: the route.
    /// - Returns: whether it is relayed.
    public static func isRelay(_ endpoint: PairedHost.Endpoint) -> Bool {
        if case .relay = endpoint { return true }
        return false
    }

    /// Whether a route goes straight at the computer on the operator's own network.
    ///
    /// The one route that is meant to start immediately while the others wait out
    /// the head start. Written here rather than as a `case .direct` in the launch
    /// path so the rule lives beside the ordering it belongs to, and so a test can
    /// ask the same question the dial plan asks.
    ///
    /// - Parameter endpoint: the route.
    /// - Returns: whether it is a LAN (or tailnet) address.
    public static func isDirect(_ endpoint: PairedHost.Endpoint) -> Bool {
        if case .direct = endpoint { return true }
        return false
    }
}
