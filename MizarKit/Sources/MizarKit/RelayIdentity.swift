//
//  RelayIdentity.swift
//  MizarKit
//
//  Who a relayed request is from.
//
//  The relay meters traffic per identity — the account behind a session, or the
//  install when there is no account — and it reads that identity from two headers
//  on the request before the request is forwarded:
//
//    x-mizar-client-id   an install id, `[A-Za-z0-9._-]{8,64}`
//    x-mizar-account     SHA-256 of the account bearer token, 64 lowercase hex
//
//  Deliberately *not* the token itself. The relay needs a stable label for a
//  bucket in its traffic table, not a credential it could replay: a hash gives it
//  the label and gives a leaked relay log nothing it can authenticate with. The
//  client id is not a secret either, for the same reason — it names an install,
//  and the relay never treats it as proof of anything.
//
//  The paid relay is the exception, and it is a narrow one: it has to know
//  whether the account is paying, and only the token can answer that. So a third
//  header — `x-mizar-session`, built by ``sessionHeaders`` — goes to that host
//  and no other. It is stripped by the relay before replay, exactly like the
//  other two, so the computer still never sees any of them.
//
//  All three are stripped from the request before it is replayed upstream and
//  from the WebSocket upgrade headers, so a host never sees them. This type only
//  produces them; where they are attached is the connection's business.
//

import CryptoKit
import Foundation

/// The identity headers a relayed request carries.
public struct RelayIdentity: Sendable, Equatable {
    /// The header naming an install.
    public static let clientIdHeader = "x-mizar-client-id"
    /// The header naming the account, as a token hash.
    public static let accountHeader = "x-mizar-account"
    /// The header carrying the session token itself, for the paid relay's gate.
    public static let sessionHeader = "x-mizar-session"

    /// Shortest client id the relay accepts.
    public static let minimumClientIdLength = 8
    /// Longest client id the relay accepts.
    public static let maximumClientIdLength = 64

    /// The install id, sent with every request.
    ///
    /// Empty means "send nothing": a pairing that happens before the account
    /// store exists has no client id, and an invalid header is worse than an
    /// absent one — the relay answers 400 for a malformed one.
    public let clientId: String

    /// The account bearer token, or `nil` when signed out.
    ///
    /// Kept as the token rather than as the hash so there is exactly one place
    /// the hash is computed: if the two ever disagreed, the relay's traffic table
    /// would bucket a session under an identity the account API does not know.
    public let accountToken: String?

    /// - Parameters:
    ///   - clientId: the install id.
    ///   - accountToken: the signed-in token, when there is one.
    public init(clientId: String, accountToken: String? = nil) {
        self.clientId = clientId
        // An empty token is no token. `Authorization: Bearer ` is a 401, and an
        // all-zero hash would bucket every signed-out request under one account.
        if let accountToken, !accountToken.isEmpty {
            self.accountToken = accountToken
        } else {
            self.accountToken = nil
        }
    }

    /// The identity used when the account store has not been consulted yet.
    ///
    /// Only the install id: a request with no account header is metered as a
    /// guest installation, which is the correct answer for a phone that has not
    /// signed in.
    public static func guest(clientId: String) -> RelayIdentity {
        RelayIdentity(clientId: clientId)
    }

    /// The SHA-256 of the account token, lowercase hex, or `nil` when signed out.
    public var accountHash: String? {
        accountToken.map(Self.hash(of:))
    }

    /// The headers to attach, ready to merge into a request or an upgrade.
    ///
    /// Only headers that have a value are included. A client id that the relay
    /// would reject is dropped rather than sent: one malformed header can refuse
    /// a whole request that would otherwise have been served as anonymous.
    public var headers: [String: String] {
        var out: [String: String] = [:]
        if Self.isValidClientId(clientId) {
            out[Self.clientIdHeader] = clientId
        }
        if let accountHash {
            out[Self.accountHeader] = accountHash
        }
        return out
    }

    /// Whether a string is a client id the relay accepts.
    ///
    /// - Parameter clientId: the candidate.
    /// - Returns: whether it is 8–64 characters of `[A-Za-z0-9._-]`.
    public static func isValidClientId(_ clientId: String) -> Bool {
        guard (minimumClientIdLength...maximumClientIdLength).contains(clientId.count) else {
            return false
        }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        return clientId.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && allowed.contains(scalar)
        }
    }

    /// The header that proves this phone may use the paid relay.
    ///
    /// Separate from ``headers`` on purpose. A hash is enough to bucket traffic,
    /// but it cannot prove anything: only the token itself can be resolved
    /// against the account store, and the paid relay refuses to carry a session
    /// without it. Because it *is* a credential, it is attached only to the
    /// official account origin, or to the configured developer relay when that
    /// hidden mode is on — see `AccountClient.isAccountHost`. Sending it to a
    /// free relay would hand a token to a host with nothing to verify it.
    ///
    /// Empty when signed out, which the paid relay reads as "no account" and
    /// refuses (or allows, if it was configured to allow unaccounted phones).
    public var sessionHeaders: [String: String] {
        guard let accountToken, !accountToken.isEmpty else { return [:] }
        return [Self.sessionHeader: accountToken]
    }

    /// SHA-256 of a token, as the relay computes it.
    ///
    /// `CryptoKit`'s hex is lowercase, which is what the relay compares against;
    /// the protocol says lowercase and this is the one place it is produced.
    ///
    /// - Parameter token: the bearer token.
    /// - Returns: 64 lowercase hex characters.
    public static func hash(of token: String) -> String {
        SHA256.hash(data: Data(token.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
