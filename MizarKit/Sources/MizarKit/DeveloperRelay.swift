//
//  DeveloperRelay.swift
//  MizarKit
//
//  The hidden switch that points the phone at the experimental relay.
//
//  There is deliberately no toggle anywhere in the UI. The switch lives in
//  `UserDefaults` under ``defaultsKey`` and can also be supplied by the
//  `MIZAR_DEV_RELAY` environment variable (simulator builds and tests, where
//  writing app defaults is awkward). An empty or unusable value means "off",
//  which is also what a deleted key means -- so switching it off restores the
//  online behaviour without a migration.
//
//  Read at dial time, never written into a pairing: the pairing's stored base
//  URL stays the real relay, and this is applied between reading that record
//  and opening the socket. Turning the switch off therefore moves the next
//  dial back to the online relay with no cleanup pass.
//

import Foundation

/// The implicit developer mode's relay override.
public enum DeveloperRelay {
    /// The `UserDefaults` key that holds the developer relay base URL.
    public static let defaultsKey = "mizar.developerRelay"

    /// The environment variable that overrides the stored value.
    ///
    /// Environment first on purpose: a test or a simulator run can point the
    /// build somewhere without touching the user's saved setting, and the
    /// override does not get baked into the app's defaults by accident.
    public static let environmentKey = "MIZAR_DEV_RELAY"

    /// The experimental relay the hidden gesture turns on.
    ///
    /// A path under the account relay's host rather than a second hostname: the
    /// lab is the same process configured with an extra route, so TLS and the
    /// account cookies are the ones the build already trusts.
    public static let defaultBaseURL = URL(string: "https://dshmizar-1.shirazu-nagisa.com/lab")!

    /// The current developer relay, or `nil` when developer mode is off.
    ///
    /// - Parameters:
    ///   - defaults: where the stored value lives.
    ///   - environment: the process environment, injected for tests.
    /// - Returns: a normalised relay base URL, or `nil`.
    public static func current(
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment,
    ) -> URL? {
        let raw = environment[environmentKey] ?? defaults.string(forKey: defaultsKey)
        return normalized(raw)
    }

    /// Whether developer mode is on.
    public static func isEnabled(
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment,
    ) -> Bool {
        current(defaults: defaults, environment: environment) != nil
    }

    /// Turn developer mode on or off, and report the state afterwards.
    ///
    /// "On" writes ``defaultBaseURL``. "Off" removes the key; an environment
    /// override still wins, which is intentional -- a test process cannot be
    /// switched off from the UI.
    ///
    /// - Returns: whether developer mode is on after the toggle.
    @discardableResult
    public static func toggle(
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment,
    ) -> Bool {
        if isEnabled(defaults: defaults, environment: environment) {
            defaults.removeObject(forKey: defaultsKey)
        } else {
            defaults.set(defaultBaseURL.absoluteString, forKey: defaultsKey)
        }
        return isEnabled(defaults: defaults, environment: environment)
    }

    /// Parse and clean a relay base URL.
    ///
    /// The value is untrusted input from two places (defaults and the
    /// environment), and it decides where the device token and account session
    /// go, so the same shape rules as a scanned pairing URL apply: `http(s)`
    /// with a non-empty host. Query and fragment are dropped, and trailing
    /// slashes are removed so `https://host/lab/` and `https://host/lab` compare
    /// and concatenate the same way.
    ///
    /// - Parameter raw: the candidate text.
    /// - Returns: the cleaned URL, or `nil` when it is empty or unusable.
    public static func normalized(_ raw: String?) -> URL? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, PairingURI.isUsableBaseURL(trimmed),
              var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              // Credentials in the URL would be forwarded to whoever the relay
              // is, and a base URL has no use for them.
              components.user == nil, components.password == nil
        else { return nil }
        components.scheme = scheme
        components.query = nil
        components.fragment = nil
        while components.path.count > 1, components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        if components.path == "/" { components.path = "" }
        return components.url
    }

    /// Whether a relay URL belongs to the configured developer relay.
    ///
    /// Compared by origin (scheme, host and port), not by full path: the room
    /// and the `/lab` prefix are path, and a URL built from an old room is still
    /// the same relay.
    ///
    /// - Parameter baseURL: a relay origin or a room URL.
    /// - Returns: whether this is the developer relay.
    public static func isDeveloperRelay(
        _ baseURL: String,
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment,
    ) -> Bool {
        guard let relay = current(defaults: defaults, environment: environment),
              let relayOrigin = RelayTier.canonicalOrigin(relay.absoluteString),
              let origin = RelayTier.canonicalOrigin(baseURL)
        else { return false }
        return origin == relayOrigin
    }

    // MARK: - Rewriting, in memory only

    /// Move a relay base URL's origin to `relay`, keeping its room.
    ///
    /// The room is the path after `/r/`; everything before it is the relay's
    /// prefix, which belongs to the old relay and is replaced. When the stored
    /// value has no room path, `room` is used to build one -- the account
    /// connect path knows the room even when a caller only kept an origin.
    ///
    /// - Parameters:
    ///   - baseURL: the stored relay base URL.
    ///   - relay: the developer relay to move to.
    ///   - room: the room to use when `baseURL` carries no `/r/` path.
    /// - Returns: the rewritten URL string, or `nil` when the input is unusable.
    public static func rewriting(
        baseURL: String,
        to relay: URL,
        room: String? = nil,
    ) -> String? {
        guard PairingURI.isUsableBaseURL(baseURL) else { return nil }
        var base = relay.absoluteString
        while base.count > 1, base.hasSuffix("/") { base.removeLast() }
        let path = URLComponents(string: baseURL)?.path ?? ""
        if let range = path.range(of: "/r/"), !range.isEmpty {
            return base + path[range.lowerBound...]
        }
        if let room, !room.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let cleaned = room.trimmingCharacters(in: .whitespacesAndNewlines)
            return base + "/r/" + cleaned
        }
        return base
    }

    /// A pairing whose relay address is the developer relay, in memory.
    ///
    /// The direct route is untouched: it is the operator's own network and has
    /// nothing to do with which relay the phone would fall back to. All relay
    /// endpoints are derived from `baseURL`, so rewriting the record moves the
    /// relay and the punched route together.
    ///
    /// - Parameters:
    ///   - host: the pairing as read from the credential store.
    ///   - defaults: settings source.
    ///   - environment: environment override.
    /// - Returns: the dial-time pairing; the input when developer mode is off.
    public static func rewriting(
        _ host: PairedHost,
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment,
    ) -> PairedHost {
        guard let relay = current(defaults: defaults, environment: environment),
              let baseURL = host.baseURL,
              let rewritten = rewriting(baseURL: baseURL, to: relay)
        else { return host }
        return host.moved(toRelay: rewritten)
    }

    /// A route whose relay address is the developer relay, in memory.
    ///
    /// - Parameters:
    ///   - endpoint: the route about to be dialled.
    ///   - defaults: settings source.
    ///   - environment: environment override.
    /// - Returns: the dial-time route; the input when developer mode is off.
    public static func rewriting(
        _ endpoint: PairedHost.Endpoint,
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment,
    ) -> PairedHost.Endpoint {
        guard let relay = current(defaults: defaults, environment: environment) else { return endpoint }
        switch endpoint {
        case .direct:
            return endpoint
        case .relay(let baseURL):
            guard let rewritten = rewriting(baseURL: baseURL, to: relay) else { return endpoint }
            return .relay(baseURL: rewritten)
        case .p2p(let baseURL, let endpointId):
            guard let rewritten = rewriting(baseURL: baseURL, to: relay) else { return endpoint }
            return .p2p(relayBaseURL: rewritten, endpointId: endpointId)
        }
    }

    /// A pairing target whose relay address is the developer relay, in memory.
    ///
    /// Used for the pairing handshake, not for what gets stored: the caller
    /// keeps the original target and records that on the host, so a pairing made
    /// while the switch is on still returns to the online relay when it is off.
    ///
    /// - Parameters:
    ///   - target: the decoded QR or typed code.
    ///   - defaults: settings source.
    ///   - environment: environment override.
    /// - Returns: the dial-time target; the input when developer mode is off.
    public static func rewriting(
        _ target: PairingTarget,
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment,
    ) -> PairingTarget {
        guard let relay = current(defaults: defaults, environment: environment),
              let baseURL = target.baseURL,
              let rewritten = rewriting(baseURL: baseURL, to: relay)
        else { return target }
        return PairingTarget(
            authority: target.authority,
            code: target.code,
            hostName: target.hostName,
            protocolVersion: target.protocolVersion,
            baseURL: rewritten,
        )
    }
}
