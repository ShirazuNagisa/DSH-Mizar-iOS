//
//  MizarNetCandidate.swift
//  MizarKit
//
//  An address a peer might be reachable at.
//
//  Three kinds, in the order ICE would try them: a host address (a local
//  interface — the LAN case the app already handles by probing), a
//  server-reflexive address (what a STUN server saw — the public side of the
//  phone's or the computer's NAT), and a relayed address (an allocation on a
//  relay — the last resort). The priority formula is ICE's, compressed: type
//  preference in the top bits, a local preference to break ties inside a
//  kind, and a constant component id at the bottom.
//
//  The priority is computed once at construction rather than on every
//  comparison, because the order candidates are tried in is the one decision
//  the punch engine gets to make cheaply and visibly.
//

import Foundation

/// One address a peer may answer on.
public struct MizarNetCandidate: Sendable, Equatable, Codable {
    /// What kind of address this is.
    public enum Kind: String, Sendable, Codable, CaseIterable {
        /// An address on a local interface — the LAN.
        case host = "host"
        /// The public side of a NAT, as observed by a STUN server.
        ///
        /// The raw value is the *wire* name (`srflx`), not the case name:
        /// `Codable` synthesis encodes a `String` enum by its raw value, and
        /// the desktop sends ICE's spelling. With the case name as the raw
        /// value the desktop's answer failed to decode as a whole -- one
        /// `srflx` entry poisoned the hello, the candidate list stayed empty,
        /// and every punch ended in "no candidate addresses to dial".
        case serverReflexive = "srflx"
        /// An allocation on a relay.
        case relay = "relay"

        /// The wire name, matching ICE's vocabulary.
        public var wireName: String { rawValue }

        /// ICE's type preference: host beats server-reflexive beats relay.
        public var typePreference: Int {
            switch self {
            case .host: return 126
            case .serverReflexive: return 100
            case .relay: return 0
            }
        }
    }

    /// The kind of address.
    public let kind: Kind
    /// The address: an IPv4/IPv6 literal or a host name.
    public let address: String
    /// The port.
    public let port: UInt16
    /// ICE-style priority. Higher is tried first.
    public let priority: Int

    /// A candidate.
    ///
    /// - Parameters:
    ///   - kind: host, server-reflexive or relayed.
    ///   - address: where to send.
    ///   - port: the port.
    ///   - localPreference: 0–65535, breaks ties inside a kind. ICE lets an
    ///     operator prefer one interface over another with this; the kernel
    ///     leaves the choice to whoever gathered the candidates.
    public init(kind: Kind, address: String, port: UInt16, localPreference: Int = 0) {
        self.kind = kind
        self.address = address
        self.port = port
        self.priority = (kind.typePreference << 24)
            | ((localPreference & 0xFFFF) << 8)
            | 1
    }

    /// Candidates in the order they should be tried.
    ///
    /// - Parameter candidates: the gathered candidates, in any order.
    /// - Returns: the same candidates, best first.
    public static func sortedByPriority(_ candidates: [MizarNetCandidate]) -> [MizarNetCandidate] {
        candidates.sorted { $0.priority > $1.priority }
    }
}

extension MizarNetCandidate.Kind: CustomStringConvertible {
    public var description: String { wireName }
}
