//
//  CredentialStore.swift
//  MizarKit
//
//  Where the device token lives.
//
//  The token is the long-lived credential that grants remote control of an agent
//  that can execute code on the host, so it goes in the Keychain with
//  `AfterFirstUnlockThisDeviceOnly`: readable by a background reconnect after a
//  reboot, never copied to another device by a backup or iCloud sync.
//
//  The store is a protocol because the Keychain is unavailable in unit tests —
//  and, on a computer, reaching for it can prompt. Tests inject an in-memory store;
//  nothing else about the client changes.
//

import Foundation
#if canImport(Security)
import Security
#endif

/// A host this device is paired with.
public struct PairedHost: Codable, Sendable, Equatable {
    /// Stable host identity, as reported at pairing.
    public let hostId: String
    /// The host's display name, as the host reports it.
    public let hostName: String
    /// What this computer is: its OS and desktop product, when the host says.
    ///
    /// Learned from `host.info` on a live socket rather than derived from the
    /// pairing: only the plugin knows which agent it bridges, and the phone
    /// cannot tell a macOS host from a Linux one by looking at its name. Stored
    /// here so the computer list can draw it while the computer is offline.
    public let desktop: HostDesktop?
    /// What the operator called this machine on this phone.
    ///
    /// Phone-local and never sent. Someone with three computers does not want to
    /// distinguish them by `Shirazus-Mac-mini.local` and two UUIDs, and a name
    /// they typed is theirs to change without touching the host.
    public let label: String?
    /// `host:port` the device dials directly, or `nil` when it has none.
    public let authority: String?
    /// Base URL of a reverse tunnel, when the host is behind one.
    public let baseURL: String?
    /// The device id the token belongs to.
    public let deviceId: String
    /// The secret itself.
    public let deviceToken: String
    /// When pairing completed.
    public let pairedAt: Date
    /// The public half of the host's direct-path identity, when it has one.
    ///
    /// A punched connection is authenticated by a key, not by an address, so the
    /// phone has to know which key it is dialling before it dials. The host
    /// learns its half from the tunnel secret it already holds and reports it in
    /// `host.info`; this is where the phone keeps it.
    ///
    /// Optional, and absent for two different reasons that are not worth
    /// distinguishing here: a host old enough to predate the direct path, and a
    /// host new enough to have one but which has not answered since. Either way
    /// the pairing simply has no punched route, and the relay carries the
    /// session the way it always did.
    public let netEndpointId: String?

    /// Which agent on this computer the operator opened, when they chose one.
    ///
    /// A computer runs three agents and they share nothing: their sessions,
    /// their working directories and their tool surfaces are separate. The
    /// choice belongs to the pairing rather than to the connection because it
    /// has to survive a relaunch -- a phone that forgets it draws DSH's five
    /// workspaces under Codex's two, which is exactly the report this answers.
    ///
    /// Optional: a host from before the desktop learned to serve three agents
    /// has nothing to choose, and a token the relay minted already carries the
    /// choice on the computer's side (`host.info.engine` says which).
    public let engine: String?

    /// Every agent this computer said it serves, as wire names.
    ///
    /// Learned from `host.info` and stored so the picker can be drawn while the
    /// computer is offline, and so a tap on a three-agent computer can ask which
    /// one *before* opening a socket. `nil` is "the host has not said", which is
    /// also what an older host says -- the two read the same and neither is a
    /// reason to show a picker for a machine that has one agent.
    public let knownEngines: [String]?

    public init(
        hostId: String,
        hostName: String,
        authority: String?,
        deviceId: String,
        deviceToken: String,
        pairedAt: Date = Date(),
        baseURL: String? = nil,
        label: String? = nil,
        netEndpointId: String? = nil,
        desktop: HostDesktop? = nil,
        engine: String? = nil,
        knownEngines: [String]? = nil,
    ) {
        self.hostId = hostId
        self.hostName = hostName
        self.authority = authority
        self.deviceId = deviceId
        self.deviceToken = deviceToken
        self.pairedAt = pairedAt
        self.baseURL = baseURL
        self.label = label
        self.netEndpointId = netEndpointId
        self.desktop = desktop
        self.engine = engine
        self.knownEngines = knownEngines
    }

    /// What to show for this machine: the operator's name for it, else the
    /// host's own.
    public var displayName: String {
        if let label, !label.trimmingCharacters(in: .whitespaces).isEmpty { return label }
        return hostName
    }

    /// A copy that also records the other route the QR carried.
    ///
    /// A pairing attempt dials one route, but the code may carry two: the LAN
    /// address and the relay. Storing only the route that answered leaves a
    /// phone that paired on Wi-Fi with no relay endpoint, so the same pairing
    /// cannot reconnect from cellular. The QR is the only place the second
    /// route is known; keep it while the pairing is being stored.
    public func recordingRoutes(authority: String?, baseURL: String?) -> PairedHost {
        PairedHost(
            hostId: hostId,
            hostName: hostName,
            authority: authority ?? self.authority,
            deviceId: deviceId,
            deviceToken: deviceToken,
            pairedAt: pairedAt,
            baseURL: baseURL ?? self.baseURL,
            label: label,
            netEndpointId: netEndpointId,
            desktop: desktop,
            engine: engine,
            knownEngines: knownEngines,
        )
    }

    /// A copy with a new operator-chosen name, keeping the credential.
    ///
    /// - Parameter label: the name to show, or `nil` to go back to the host's.
    /// - Returns: the updated record.
    public func renamed(to label: String?) -> PairedHost {
        PairedHost(
            hostId: hostId,
            hostName: hostName,
            authority: authority,
            deviceId: deviceId,
            deviceToken: deviceToken,
            pairedAt: pairedAt,
            baseURL: baseURL,
            label: label,
            netEndpointId: netEndpointId,
            desktop: desktop,
            engine: engine,
            knownEngines: knownEngines,
        )
    }

    /// Where this host can be reached, in the order worth trying.
    ///
    /// The direct address comes first when there is one: it is the same network
    /// or the same tailnet, so it is faster and involves nobody else. The relay
    /// is the fallback, and for a host whose network blocks inbound traffic it
    /// is the only one that works.
    ///
    /// When the stored relay is one of the two public relays, the other one is
    /// tried after it with the same room path. That is the repair for a phone
    /// that was offline while its host moved between tiers: the stored URL leads
    /// to a room nobody is in, and the alternate is where the tunnel actually
    /// is. A self-hosted relay has no alternate.
    public var endpoints: [Endpoint] {
        var out: [Endpoint] = []
        if let authority, !authority.isEmpty { out.append(.direct(authority: authority)) }
        if let baseURL, !baseURL.isEmpty, PairingURI.isUsableBaseURL(baseURL) {
            // The punched route sits between the two obvious ones: faster than
            // the relay because the bytes stop detouring, and it needs the relay
            // anyway -- the room it names is where the two sides exchange
            // addresses -- so it can only exist when a relay does.
            if let netEndpointId, !netEndpointId.isEmpty {
                out.append(.p2p(relayBaseURL: baseURL, endpointId: netEndpointId))
            }
            out.append(.relay(baseURL: baseURL))
            if let alternate = RelayTier.alternate(to: baseURL) {
                out.append(.relay(baseURL: alternate))
            }
        }
        return out
    }

    /// One way to reach a host.
    public enum Endpoint: Sendable, Equatable {
        /// Straight to `host:port`.
        case direct(authority: String)
        /// A punched connection, negotiated through the relay's room.
        ///
        /// Named by key rather than by address: the two sides meet at whatever
        /// address each NAT happens to have handed out, and both of those are
        /// discovered at dial time. `relayBaseURL` is not a fallback here, it is
        /// the side channel -- the room is where the candidates are exchanged,
        /// and without it there is nothing to punch through.
        case p2p(relayBaseURL: String, endpointId: String)
        /// Through a reverse tunnel.
        case relay(baseURL: String)

        /// Whether this route reaches the computer on the operator's own
        /// network rather than through the relay.
        ///
        /// One rule, in ``LocalNetwork``, because the answer decides what the
        /// screen may call the link *and* what the account is allowed to use:
        /// a LAN link is not metered by the relay, so the features the relay's
        /// bandwidth pays for are free on it. Loopback is the simulator talking
        /// to the Mac itself and is deliberately not local.
        public var isLocalNetwork: Bool {
            switch self {
            case .direct(let authority): LocalNetwork.isLocal(authority: authority)
            // A punched connection is direct data over the open internet: the
            // phone and the computer may be in different cities. It is not
            // metered by the relay, but it is not the operator's own network
            // either, so the features that ask "are we on the same LAN" keep
            // their answer.
            case .p2p: false
            case .relay: false
            }
        }

        /// Whether this route is the punched one.
        ///
        /// Named because two call sites ask a related question of it and would
        /// otherwise write `case .p2p` twice: the toggle that turns the direct
        /// path on filters these out, and the log line names them differently
        /// from a relay.
        public var isDirectPath: Bool {
            if case .p2p = self { return true }
            return false
        }
    }

    /// A copy pointing at a different authority, keeping the credential.
    ///
    /// Used when the host's address changes — a tailnet address is stable but a
    /// LAN address is not — so a moved host is a reconnect rather than a
    /// re-pair.
    ///
    /// - Parameter authority: the new `host:port`.
    /// - Returns: the updated record.
    public func moved(to authority: String) -> PairedHost {
        PairedHost(
            hostId: hostId,
            hostName: hostName,
            authority: authority,
            deviceId: deviceId,
            deviceToken: deviceToken,
            pairedAt: pairedAt,
            baseURL: baseURL,
            // The operator's own name for this machine travels with it. Dropping
            // it here renamed the machine back to the host's own name the moment
            // its address changed, which is the one thing the label exists to
            // avoid -- `Shirazus-Mac-mini.local` is exactly what somebody with
            // two computers cannot tell apart.
            label: label,
            netEndpointId: netEndpointId,
            desktop: desktop,
            engine: engine,
            knownEngines: knownEngines,
        )
    }

    /// A copy remembering where this host can be punched, keeping everything
    /// else.
    ///
    /// Its own copy rather than a mutation because `PairedHost` is a value the
    /// credential store compares and persists; the same reason `moved(to:)` and
    /// `moved(toRelay:)` exist.
    ///
    /// - Parameter endpointId: the host's direct-path identity.
    /// - Returns: the updated record.
    public func remembering(netEndpointId endpointId: String) -> PairedHost {
        PairedHost(
            hostId: hostId,
            hostName: hostName,
            authority: authority,
            deviceId: deviceId,
            deviceToken: deviceToken,
            pairedAt: pairedAt,
            baseURL: baseURL,
            label: label,
            netEndpointId: endpointId,
            desktop: desktop,
            engine: engine,
            knownEngines: knownEngines,
        )
    }

    /// A copy remembering what this computer is, keeping everything else.
    ///
    /// Learned from `host.info` on every ready socket; written through to the
    /// pairing so the computer list can show the OS and desktop product while
    /// the machine is offline.
    ///
    /// - Parameter desktop: the host's answer.
    /// - Returns: the updated record.
    public func remembering(desktop: HostDesktop) -> PairedHost {
        PairedHost(
            hostId: hostId,
            hostName: hostName,
            authority: authority,
            deviceId: deviceId,
            deviceToken: deviceToken,
            pairedAt: pairedAt,
            baseURL: baseURL,
            label: label,
            netEndpointId: netEndpointId,
            desktop: desktop,
            engine: engine,
            knownEngines: knownEngines,
        )
    }

    /// A copy opened for one agent, keeping everything else.
    ///
    /// `nil` is a real choice -- "all agents", which is what a phone that has
    /// not chosen gets and what an older host can only answer -- rather than an
    /// omission, so the parameter takes the optional and the caller says which.
    ///
    /// - Parameter engine: the wire name of the agent, or `nil` for all of them.
    /// - Returns: the updated record.
    public func opened(on engine: String?) -> PairedHost {
        PairedHost(
            hostId: hostId,
            hostName: hostName,
            authority: authority,
            deviceId: deviceId,
            deviceToken: deviceToken,
            pairedAt: pairedAt,
            baseURL: baseURL,
            label: label,
            netEndpointId: netEndpointId,
            desktop: desktop,
            engine: engine,
            knownEngines: knownEngines,
        )
    }

    /// A copy remembering which agents this computer serves.
    ///
    /// - Parameter engines: the wire names, in the host's order.
    /// - Returns: the updated record.
    public func remembering(engines: [String]?) -> PairedHost {
        PairedHost(
            hostId: hostId,
            hostName: hostName,
            authority: authority,
            deviceId: deviceId,
            deviceToken: deviceToken,
            pairedAt: pairedAt,
            baseURL: baseURL,
            label: label,
            netEndpointId: netEndpointId,
            desktop: desktop,
            engine: engine,
            knownEngines: engines,
        )
    }

    /// The agents this pairing offers a choice of, in the host's order.
    ///
    /// Empty when there is nothing to choose -- an older host, or a computer
    /// with one agent running -- and the callers all read it as "do not ask".
    public var engineChoices: [String] {
        guard let knownEngines, knownEngines.count > 1 else { return [] }
        return knownEngines
    }

    /// A copy pointing at a different relay, keeping the credential.
    ///
    /// - Parameter baseURL: the new relay base URL.
    /// - Returns: the updated record.
    public func moved(toRelay baseURL: String?) -> PairedHost {
        PairedHost(
            hostId: hostId,
            hostName: hostName,
            authority: authority,
            deviceId: deviceId,
            deviceToken: deviceToken,
            pairedAt: pairedAt,
            baseURL: baseURL,
            label: label,
            netEndpointId: netEndpointId,
            desktop: desktop,
            engine: engine,
            knownEngines: knownEngines,
        )
    }
}

/// Storage for the paired-host credentials.
///
/// A list, not a single pairing. One phone managing one computer was the first
/// version's assumption and it is the wrong one for the product: somebody with a
/// laptop and a desktop should not have to unpair one to reach the other.
public protocol CredentialStore: Sendable {
    /// Every machine this phone is paired with, oldest pairing first.
    /// - Returns: the pairings; empty when this device is not paired at all.
    func loadAll() async throws -> [PairedHost]

    /// Insert or replace one pairing, matched by host id.
    /// - Parameter host: the pairing to store.
    func save(_ host: PairedHost) async throws

    /// Forget one pairing.
    /// - Parameter hostId: the machine to forget.
    func remove(hostId: String) async throws

    /// Forget every pairing.
    func clear() async throws
}

extension CredentialStore {
    /// The most recently paired machine, which is the one to open on launch.
    /// - Returns: the pairing, or `nil` when there is none.
    public func load() async throws -> PairedHost? {
        try await loadAll().max { $0.pairedAt < $1.pairedAt }
    }
}

/// A store that keeps the pairings in memory only.
///
/// For tests, and for previews. Explicitly not a fallback for a failed Keychain
/// write: silently degrading to memory would mean a pairing that appears to work
/// and vanishes on the next launch.
public actor InMemoryCredentialStore: CredentialStore {
    private var hosts: [PairedHost]

    public init(host: PairedHost? = nil) {
        self.hosts = host.map { [$0] } ?? []
    }

    public init(hosts: [PairedHost]) {
        self.hosts = hosts
    }

    public func loadAll() async throws -> [PairedHost] { hosts }

    public func save(_ host: PairedHost) async throws {
        if let index = hosts.firstIndex(where: { $0.hostId == host.hostId }) {
            hosts[index] = host
        } else {
            hosts.append(host)
        }
    }

    public func remove(hostId: String) async throws {
        hosts.removeAll { $0.hostId == hostId }
    }

    public func clear() async throws { hosts = [] }
}

/// The Keychain-backed store.
///
/// One item holds the whole list. That keeps the migration from the single-host
/// shape to a single decode, and an atomic write, at the cost of rewriting every
/// pairing when one changes -- which happens when somebody pairs a machine or
/// renames one, and never otherwise.
public struct KeychainCredentialStore: CredentialStore {
    /// The Keychain account name.
    private let account: String
    /// The Keychain service name.
    private let service: String

    public init(service: String = "dsh-mizar", account: String = "paired-host") {
        self.service = service
        self.account = account
    }

    #if canImport(Security)
    /// The base query identifying this item.
    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
    #endif

    public func loadAll() async throws -> [PairedHost] {
        #if canImport(Security)
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let data = item as? Data else {
            throw MizarError(
                code: "KEYCHAIN_READ_FAILED",
                message: "could not read the pairing from the keychain (status \(status))",
            )
        }
        return Self.decode(data)
        #else
        return []
        #endif
    }

    /// Decode the stored blob, accepting the single-pairing shape it used to be.
    ///
    /// The first version stored one `PairedHost` object. Anyone upgrading has one
    /// of those, and refusing to read it would silently unpair them and make them
    /// scan again -- so the old shape is read as a list of one, and rewritten in
    /// the new shape the next time anything is saved.
    ///
    /// - Parameter data: the stored bytes.
    /// - Returns: the pairings.
    private static func decode(_ data: Data) -> [PairedHost] {
        let decoder = JSONDecoder()
        if let list = try? decoder.decode([PairedHost].self, from: data) { return list }
        if let one = try? decoder.decode(PairedHost.self, from: data) { return [one] }
        return []
    }

    public func save(_ host: PairedHost) async throws {
        var hosts = try await loadAll()
        if let index = hosts.firstIndex(where: { $0.hostId == host.hostId }) {
            hosts[index] = host
        } else {
            hosts.append(host)
        }
        try await write(hosts)
    }

    public func remove(hostId: String) async throws {
        let remaining = try await loadAll().filter { $0.hostId != hostId }
        if remaining.isEmpty {
            try await clear()
            return
        }
        try await write(remaining)
    }

    public func clear() async throws {
        #if canImport(Security)
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw MizarError(
                code: "KEYCHAIN_DELETE_FAILED",
                message: "could not remove the pairing from the keychain (status \(status))",
            )
        }
        #endif
    }

    /// Store the whole list, replacing whatever was there.
    ///
    /// Update first, then add: `SecItemAdd` fails with `errSecDuplicateItem` when
    /// an item already exists, and deleting-then-adding would open a window where
    /// the credential does not exist -- which on a phone that reconnects in the
    /// background is a window something will fall through.
    ///
    /// - Parameter hosts: the pairings to store.
    private func write(_ hosts: [PairedHost]) async throws {
        #if canImport(Security)
        let data = try JSONEncoder().encode(hosts)

        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary,
        )
        if updateStatus == errSecSuccess { return }

        var query = baseQuery
        query[kSecValueData as String] = data
        // Readable after the first unlock so a reconnect can happen in the
        // background, but never migrated to another device.
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw MizarError(
                code: "KEYCHAIN_WRITE_FAILED",
                message: "could not store the pairing in the keychain (status \(addStatus))",
            )
        }
        #else
        _ = hosts
        throw MizarError(
            code: "KEYCHAIN_UNAVAILABLE",
            message: "no keychain on this platform",
        )
        #endif
    }
}
