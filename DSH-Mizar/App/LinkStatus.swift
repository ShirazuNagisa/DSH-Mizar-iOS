//
//  LinkStatus.swift
//  DSH-Mizar
//
//  What the sidebar's link bar draws.
//
//  The bar answers one question at a glance -- which half of the trip is down --
//  and it answers it with a picture rather than a sentence. The sentence was the
//  old `problem` row: accurate, and in the way of everything the sidebar is for.
//
//  This type is the drawing's whole input: how many devices to draw, whether the
//  link is alive, which segment carries the cross, and what VoiceOver should
//  say. It is derived here rather than in the view so the cross and the label
//  come from the same classification the log's sentence comes from, and so the
//  mapping can be tested without a screen.
//

import Foundation
import MizarKit

/// The sidebar's link bar, as a value.
struct LinkStatus: Equatable {
    /// How many devices the picture has.
    enum Topology: Equatable {
        /// Phone, computer.
        case direct
        /// Phone, relay server, computer.
        case relay
    }

    /// A stretch of line the bar can draw.
    enum Segment: Equatable {
        case phoneToRelay
        case relayToComputer
        case phoneToComputer
    }

    /// What the bar is, in the short sentence VoiceOver reads.
    ///
    /// Short on purpose: the bar is a status, not an explanation. The long
    /// sentence stays in the log and on the failure screen.
    enum Label: Equatable {
        case connectedDirect
        case connectedRelay
        case connecting
        case relayUnreachable
        case offline
        case computerAbsent
        case computerUnreachable
        case refused
    }

    let topology: Topology
    /// Whether the link is up right now. Only a connected link breathes.
    let connected: Bool
    /// The segment carrying the cross, or `nil` for no cross.
    let broken: Segment?
    let label: Label
}

extension LinkStatus {
    /// The status for a dial that failed, from the route it failed on.
    ///
    /// `isRelay` is the fact that decides which half a failure belongs to, and
    /// it comes from the route, not from the error: the same timeout means "the
    /// phone cannot reach the server" over a relay and "the phone cannot reach
    /// the computer" directly.
    ///
    /// - Parameters:
    ///   - error: what the dial threw.
    ///   - authority: the address it was dialling.
    ///   - isRelay: whether a relay sat in between.
    /// - Returns: the bar's status for that failure.
    static func failure(
        _ error: any Error,
        authority: String,
        isRelay: Bool,
    ) -> LinkStatus {
        let topology: Topology = isRelay ? .relay : .direct
        let diagnosis = ConnectionDiagnosis.of(
            error,
            authority: authority,
            over: isRelay ? .server : .direct,
        )

        // The computer's own answer. Its words are more specific than anything
        // the hop can add, so the cross goes on the line immediately to its
        // left -- the only segment in a direct picture, the second in a relayed
        // one.
        if let mizar = error as? MizarError {
            // A handshake that never completed is the one host-shaped failure
            // that is really about the computer being absent, and the diagnosis
            // is what names it (over a relay, that is the deferred upgrade the
            // server never completed). Asking the diagnosis rather than the
            // code keeps one rule for both.
            let silentHandshake = ConnectionDiagnosis.of(mizar, authority: authority, over: .server)
                == .serverReachedComputerAbsent
            if silentHandshake {
                return LinkStatus(
                    topology: topology,
                    connected: false,
                    broken: isRelay ? .relayToComputer : .phoneToComputer,
                    label: isRelay ? .computerAbsent : .computerUnreachable,
                )
            }
            // A code this build knows is the computer answering and saying no.
            // The dial-level ones (`CONNECTION_CLOSED`, `REQUEST_TIMEOUT`) are
            // this side describing a socket that never got that far, so they
            // are a failure to reach the computer -- not a refusal, and not a
            // broken relay: the socket existed, so the server was reached.
            let refused = mizar.known != nil
            return LinkStatus(
                topology: topology,
                connected: false,
                broken: isRelay ? .relayToComputer : .phoneToComputer,
                label: refused ? .refused : .computerUnreachable,
            )
        }

        if isRelay {
            switch diagnosis {
            case .offline:
                return LinkStatus(topology: .relay, connected: false, broken: .phoneToRelay, label: .offline)
            case .serverReachedComputerAbsent:
                return LinkStatus(topology: .relay, connected: false, broken: .relayToComputer, label: .computerAbsent)
            default:
                // Everything else the relay itself did or did not do: no answer,
                // a 402/5xx refusal, a name that did not resolve.
                return LinkStatus(topology: .relay, connected: false, broken: .phoneToRelay, label: .relayUnreachable)
            }
        }

        switch diagnosis {
        case .offline:
            return LinkStatus(topology: .direct, connected: false, broken: .phoneToComputer, label: .offline)
        default:
            return LinkStatus(topology: .direct, connected: false, broken: .phoneToComputer, label: .computerUnreachable)
        }
    }

    /// The picture a pairing would draw before anything has answered.
    ///
    /// A route that is not a relay -- a LAN address, a tailnet one, a punched
    /// path -- is what the pairing reaches for first, so a picture that shows
    /// the computer directly is the shape a success is most likely to have. A
    /// pairing with only relay addresses has nothing else to try, and says so
    /// from the start.
    ///
    /// - Parameter host: the pairing being dialled.
    /// - Returns: the topology to draw while connecting.
    static func plannedTopology(for host: PairedHost?) -> Topology {
        guard let host else { return .direct }
        let hasDirect = host.endpoints.contains { endpoint in
            if case .relay = endpoint { return false }
            return true
        }
        return hasDirect ? .direct : .relay
    }
}
