//
//  ServerSelection.swift
//  MizarKit
//
//  Which relay this phone talks to.
//
//  Two products in one app. The official relay carries accounts, plans and
//  announcements; a self-hosted relay is somebody's own server, has no accounts
//  at all, and is addressed by the origin they typed in. Everything downstream
//  asks this value which of the two it is, so the two modes cannot drift apart
//  in one screen and stay together in another.
//
//  The origin is normalised here rather than at every call site: a person types
//  `relay.example.com`, pastes it with a trailing slash, or brings the scheme
//  from the setup page. One function answers "what is the origin this app will
//  dial", and `nil` is an answer -- an address that is not an https origin must
//  never silently become the official relay.
//

import Foundation

/// Which kind of relay this phone is configured for.
public enum ServerMode: String, Codable, Sendable, CaseIterable {
    /// The official relay: accounts, plans and push.
    case official
    /// A relay the operator runs, addressed by ``ServerSelection/origin``.
    case selfHosted
}

/// The operator's server choice: a mode, a self-hosted origin and its PIN.
///
/// A value, like ``MizarSettings``: it is read by the model, written by the
/// guide and the settings page, and compared to decide whether a switch changed
/// anything. `origin` keeps exactly what was typed (defaults and prefills rely
/// on that); ``normalizedOrigin`` is the only form that should be dialled.
public struct ServerSelection: Equatable, Sendable {
    /// Whether this phone uses the official relay or a self-hosted one.
    public var mode: ServerMode
    /// The self-hosted origin, as the operator entered it.
    public var origin: String
    /// The server PIN, empty when the relay does not require one.
    ///
    /// Sent only to the relay's `/selfhost/v1/*` listing endpoint. It is not an
    /// account credential and is not attached to anything else.
    public var pin: String

    /// The official server, with no address and no PIN.
    public static let official = ServerSelection()

    /// - Parameters:
    ///   - mode: the server kind. Official by default.
    ///   - origin: the self-hosted origin, as typed.
    ///   - pin: the self-hosted server PIN, empty when there is none.
    public init(mode: ServerMode = .official, origin: String = "", pin: String = "") {
        self.mode = mode
        self.origin = origin
        self.pin = pin
    }

    /// Whether this selection is for a self-hosted relay.
    public var isSelfHosted: Bool { mode == .selfHosted }

    /// The origin to dial, or `nil` when there is no usable self-hosted origin.
    ///
    /// Rules, in order:
    ///
    /// - surrounding whitespace is trimmed;
    /// - a missing scheme becomes `https://` (a person types a domain);
    /// - only `https` is accepted, because a pairing code and a PIN travel over
    ///   this origin;
    /// - `host:port` is allowed;
    /// - a path, a query, a fragment and credentials are refused -- a path
    ///   would put the relay's `/healthz` somewhere it does not live;
    /// - a trailing slash is dropped, so two spellings of one origin compare
    ///   equal.
    ///
    /// - Returns: the normalised origin, or `nil` when it is not one.
    public var normalizedOrigin: String? {
        var trimmed = origin.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // A space inside an authority is a paste accident, and URLComponents
        // would percent-encode it into a hostname that cannot resolve.
        guard !trimmed.contains(where: \.isWhitespace) else { return nil }

        // A scheme, when present, has to be the one this app speaks. Testing
        // for the separator rather than for `URLComponents.scheme` is
        // deliberate: `relay.example.com:8443` parses with `scheme` equal to
        // the hostname and `path` equal to the port.
        if !trimmed.contains("://") {
            trimmed = "https://" + trimmed
        }
        guard let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "https",
              let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.percentEncodedPath.isEmpty || components.percentEncodedPath == "/"
        else { return nil }

        // IPv6 literals are bracketed in an origin. Foundation has returned
        // them both with and without the brackets across OS versions, so the
        // form is decided here rather than trusted from the parse.
        let lowered = host.lowercased()
        let authority: String
        if lowered.hasPrefix("[") && lowered.hasSuffix("]") {
            authority = lowered
        } else if lowered.contains(":") {
            authority = "[\(lowered)]"
        } else {
            authority = lowered
        }
        if let port = components.port {
            return "https://\(authority):\(port)"
        }
        return "https://\(authority)"
    }
}
