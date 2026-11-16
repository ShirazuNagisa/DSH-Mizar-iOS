import CryptoKit
import Foundation

/// A host identity alias pinned to one pairing credential generation.
public struct LiveActivityHostIdentityBinding: Sendable, Equatable {
    public let pairedHostId: String
    public let deviceId: String
    public let credentialDigest: String
    public let canonicalHostId: String

    public func matches(_ host: PairedHost) -> Bool {
        pairedHostId == host.hostId
            && deviceId == host.deviceId
            && credentialDigest == Self.credentialDigest(for: host.deviceToken)
    }

    static func credentialDigest(for token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func storageKey(for host: PairedHost) -> String {
        let digest = credentialDigest(for: host.deviceToken)
        let scope = "\(host.hostId.utf8.count):\(host.hostId)\(host.deviceId.utf8.count):\(host.deviceId)\(digest)"
        let keyDigest = SHA256.hash(data: Data(scope.utf8)).map { String(format: "%02x", $0) }.joined()
        return "live.activity.host.identity.v1.\(keyDigest)"
    }
}

/// Resolves account-directory aliases without weakening QR or custom-relay identity checks.
public enum LiveActivityHostIdentity {
    public static func canBootstrap(
        host: PairedHost,
        endpoint: PairedHost.Endpoint?,
        accountId: String?,
        relayHeaders: [String: String],
    ) -> Bool {
        guard host.hostId == host.deviceId,
              let accountId, !accountId.isEmpty,
              let session = relayHeaders[RelayIdentity.sessionHeader], !session.isEmpty,
              case .relay(let baseURL) = endpoint,
              isOfficialAccountRelay(baseURL)
        else { return false }
        return true
    }

    /// Whether a URL names the official account relay on its HTTPS port.
    ///
    /// Account pairings may store the unified origin (`https://host`, port 443)
    /// or the legacy paid origin (`https://host:8443`). Only those origins are
    /// trusted with a session header or a first binding: an arbitrary port, a
    /// self-hosted relay, or userinfo/query/fragment in the URL is never the
    /// account relay.
    static func isOfficialAccountRelay(_ baseURL: String) -> Bool {
        guard let components = URLComponents(string: baseURL),
              components.scheme?.lowercased() == "https",
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil
        else { return false }

        let port = components.port ?? 443
        guard port == 443 || port == 8443 else { return false }

        var normalized = components
        if port == 443 { normalized.port = nil }
        guard let normalizedURL = normalized.url?.absoluteString else { return false }
        return RelayTier.isPaidRelay(normalizedURL) && !RelayTier.isSelfHosted(normalizedURL)
    }

    /// Resolves an activity target only through an existing, authorized pairing.
    ///
    /// A live card may carry the pairing alias (legacy) or the canonical host
    /// ID learned from `welcome` (current). An exact `PairedHost.hostId` match
    /// is the strongest identity: it is the QR/legacy record for that physical
    /// host, so it wins over an account alias that maps to the same canonical
    /// ID. Without an exact match, only one canonical alias may resolve; two
    /// aliases are ambiguous and resolve to nothing rather than picking a
    /// computer.
    public static func resolvePairedHost(
        hostId: String,
        hosts: [PairedHost],
        canonicalHostIds: [String: String],
    ) -> PairedHost? {
        if hostId.isEmpty { return hosts.count == 1 ? hosts.first : nil }

        let exact = hosts.filter { $0.hostId == hostId }
        if !exact.isEmpty { return exact.count == 1 ? exact.first : nil }

        let aliases = hosts.filter { canonicalHostIds[$0.hostId] == hostId }
        return aliases.count == 1 ? aliases.first : nil
    }

    public static func resolvedHostId(
        for host: PairedHost,
        binding: LiveActivityHostIdentityBinding?,
    ) -> String {
        guard let binding, binding.matches(host) else { return host.hostId }
        return binding.canonicalHostId
    }
}

/// Non-secret App Group metadata. It never creates or restores a pairing credential.
public actor LiveActivityHostIdentityStore {
    public static let shared = LiveActivityHostIdentityStore()

    private let suiteName: String

    public init(suiteName: String = LiveActivityPresentationStore.group) {
        self.suiteName = suiteName
    }

    /// Reads the pin for the current credential generation.
    ///
    /// Nonisolated because the read is immutable metadata and callers such as
    /// deep-link routing need it synchronously; the actor still serializes the
    /// one-time write.
    public nonisolated func binding(for host: PairedHost) -> LiveActivityHostIdentityBinding? {
        guard let canonicalHostId = UserDefaults(suiteName: suiteName)?.string(
            forKey: LiveActivityHostIdentityBinding.storageKey(for: host),
        ), !canonicalHostId.isEmpty else { return nil }
        return LiveActivityHostIdentityBinding(
            pairedHostId: host.hostId,
            deviceId: host.deviceId,
            credentialDigest: LiveActivityHostIdentityBinding.credentialDigest(for: host.deviceToken),
            canonicalHostId: canonicalHostId,
        )
    }

    /// The canonical IDs currently pinned to these pairings.
    ///
    /// The dictionary is keyed by pairing alias so callers can keep the
    /// alias as their internal snapshot cache key while matching public URLs.
    public nonisolated func canonicalHostIds(for hosts: [PairedHost]) -> [String: String] {
        var result: [String: String] = [:]
        for host in hosts {
            guard let binding = binding(for: host), binding.matches(host) else { continue }
            result[host.hostId] = binding.canonicalHostId
        }
        return result
    }

    /// Pins once for this credential generation; a later canonical ID cannot replace it.
    @discardableResult
    public func bind(_ canonicalHostId: String, to host: PairedHost) -> Bool {
        guard !canonicalHostId.isEmpty,
              let defaults = UserDefaults(suiteName: suiteName) else { return false }
        let key = LiveActivityHostIdentityBinding.storageKey(for: host)
        if let existing = defaults.string(forKey: key) { return existing == canonicalHostId }
        defaults.set(canonicalHostId, forKey: key)
        return true
    }
}
