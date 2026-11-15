//
//  PairingURI.swift
//  MizarKit
//
//  The pairing URI the QR code carries.
//
//  Mirrors `dsh/src/protocol/pairing-uri.ts`. The two must agree byte for byte:
//  the panel renders this string and the app parses it, and any disagreement
//  silently produces a wrong host rather than an error.
//
//  `h` is an authority, not a URL — it carries no scheme, so the app decides
//  whether to speak `ws://` or `wss://`. An IPv6 literal is bracketed.
//

import Foundation

/// A decoded pairing URI.
public struct PairingTarget: Sendable, Equatable {
    /// `host:port` the app should dial directly, or `nil` when the host is only
    /// reachable through a relay.
    public let authority: String?
    /// The pairing code, in display form.
    public let code: String
    /// The host's display name, when it was included.
    public let hostName: String?
    /// The protocol version the host speaks, when it was included.
    public let protocolVersion: Int?
    /// Base URL of a reverse tunnel, when the host is behind one.
    ///
    /// A base URL rather than an authority because the room is part of the path:
    /// `https://relay.example.com/r/ABCD1234`. Both the pairing request and the
    /// WebSocket are built from it.
    public let baseURL: String?

    public init(
        authority: String?,
        code: String,
        hostName: String? = nil,
        protocolVersion: Int? = nil,
        baseURL: String? = nil,
    ) {
        self.authority = authority
        self.code = code
        self.hostName = hostName
        self.protocolVersion = protocolVersion
        self.baseURL = baseURL
    }
}

/// Parsing and building for the `mizar://` pairing URI.
public enum PairingURI {
    /// The custom scheme.
    public static let scheme = "mizar"

    /// The full prefix, scheme and host part.
    public static let prefix = "mizar://pair"

    /// Build the URI a QR code carries.
    ///
    /// - Parameters:
    ///   - authority: `host:port`, already bracketed for IPv6.
    ///   - code: the pairing code.
    ///   - hostName: the host's display name.
    ///   - protocolVersion: the protocol version the host speaks.
    /// - Returns: the URI.
    public static func build(
        authority: String,
        code: String,
        hostName: String,
        protocolVersion: Int,
        baseURL: String? = nil,
    ) -> String? {
        // A URI with no address at all would scan successfully and then fail
        // with nothing useful to say about why. Refusing to build one beats
        // rendering a code that cannot work.
        guard !authority.isEmpty || !(baseURL ?? "").isEmpty else { return nil }

        var components = URLComponents()
        var items: [URLQueryItem] = []
        if !authority.isEmpty { items.append(URLQueryItem(name: "h", value: authority)) }
        if let baseURL, !baseURL.isEmpty { items.append(URLQueryItem(name: "u", value: baseURL)) }
        items.append(URLQueryItem(name: "c", value: code))
        items.append(URLQueryItem(name: "n", value: hostName))
        items.append(URLQueryItem(name: "v", value: String(protocolVersion)))
        components.queryItems = items
        return "\(prefix)?\(components.percentEncodedQuery ?? "")"
    }

    /// Parse a pairing URI.
    ///
    /// Returns `nil` rather than throwing for anything unrecognised. A scanned
    /// code is untrusted input from a camera, and a different QR in front of the
    /// lens is a normal thing to encounter, not an error worth surfacing.
    ///
    /// - Parameter input: the scanned text.
    /// - Returns: the target, or `nil`.
    public static func parse(_ input: String) -> PairingTarget? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("\(prefix)?") else { return nil }

        let query = String(trimmed.dropFirst(prefix.count + 1))
        guard let components = URLComponents(string: "?\(query)") else { return nil }

        func value(_ name: String) -> String? {
            components.queryItems?
                .first { $0.name == name }?
                .value?
                .trimmingCharacters(in: .whitespaces)
        }

        let authority = value("h") ?? ""
        let baseURL = value("u") ?? ""
        guard let code = value("c"), !code.isEmpty else { return nil }
        // The code is the one thing that must always be present; an address may
        // arrive through either parameter, but one of them has to arrive.
        guard !authority.isEmpty || !baseURL.isEmpty else { return nil }
        if !baseURL.isEmpty, !isUsableBaseURL(baseURL) { return nil }

        return PairingTarget(
            authority: authority.isEmpty ? nil : authority,
            code: code,
            hostName: value("n"),
            protocolVersion: value("v").flatMap(Int.init),
            baseURL: baseURL.isEmpty ? nil : baseURL,
        )
    }

    /// Build the pairing URI for a computer found on a self-hosted relay.
    ///
    /// The directory gives a room, the computer shows a code, and the phone
    /// turns the two into the same `mizar://pair?u=...` payload a QR code would
    /// carry -- then hands it to ``parse`` so both paths produce one kind of
    /// target. That is the point: a discovered computer and a scanned one must
    /// not be able to disagree about what a pairing is.
    ///
    /// - Parameters:
    ///   - origin: the relay's origin, as configured. Normalised here, so a
    ///     trailing slash or a missing scheme is not the caller's problem.
    ///   - room: the relay room the computer listed.
    ///   - code: the code the computer is showing.
    ///   - name: the computer's display name, when it has one.
    /// - Returns: the parsed target, or `nil` when an input is unusable.
    public static func selfHosted(
        origin: String,
        room: String,
        code: String,
        name: String?,
    ) -> PairingTarget? {
        guard let origin = ServerSelection(mode: .selfHosted, origin: origin).normalizedOrigin else {
            return nil
        }
        let room = room.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        // A room is a path segment, not a path: a slash here would move the
        // relay's room somewhere else, and a query would become part of the
        // base URL that the WebSocket path is appended to.
        let roomCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._~-")
        guard !room.isEmpty,
              room.unicodeScalars.allSatisfy(roomCharacters.contains),
              !code.isEmpty
        else { return nil }

        var components = URLComponents()
        var items = [
            URLQueryItem(name: "u", value: "\(origin)/r/\(room)"),
            URLQueryItem(name: "c", value: code),
        ]
        if let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            items.append(URLQueryItem(name: "n", value: name))
        }
        items.append(URLQueryItem(name: "v", value: "1"))
        components.queryItems = items
        return parse("\(prefix)?\(components.percentEncodedQuery ?? "")")
    }

    /// Whether a base URL is one this client can dial.
    ///
    /// A scanned code is untrusted input from a camera, and this URL decides
    /// where a device token gets sent. Restricting the scheme to what the
    /// protocol actually speaks keeps a crafted QR from pointing the app
    /// somewhere it would never otherwise go.
    ///
    /// - Parameter value: the candidate.
    /// - Returns: whether it is usable.
    public static func isUsableBaseURL(_ value: String) -> Bool {
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host(), !host.isEmpty
        else { return false }
        return true
    }

    /// The WebSocket URL for a relay base URL.
    ///
    /// - Parameter baseURL: the relay base, e.g. `https://relay.example.com/r/ROOM`.
    /// - Returns: the URL, or `nil` when it is unusable.
    public static func relayWebSocketURL(baseURL: String) -> URL? {
        relayWebSocketURL(baseURL: baseURL, path: mizarWebSocketPath)
    }

    /// The WebSocket URL that carries direct-path signaling for a relay base URL.
    ///
    /// Same host and same room as ``relayWebSocketURL(baseURL:)``, different
    /// path: the tunnel carries Mizar frames and this carries candidates, and
    /// they are separate sockets because they have separate lifetimes — a punch
    /// ends once the two sides are talking directly, while the tunnel is the
    /// thing it was trying to replace.
    ///
    /// - Parameter baseURL: the relay base, e.g. `https://relay.example.com/r/ROOM`.
    /// - Returns: the URL, or `nil` when it is unusable.
    public static func relaySignalWebSocketURL(baseURL: String) -> URL? {
        relayWebSocketURL(baseURL: baseURL, path: mizarNetSignalPath)
    }

    /// The WebSocket URL for a relay base URL and a path inside its room.
    ///
    /// - Parameters:
    ///   - baseURL: the relay base, room path included.
    ///   - path: the path to append, beginning with a slash.
    /// - Returns: the URL, or `nil` when the base is unusable.
    public static func relayWebSocketURL(baseURL: String, path: String) -> URL? {
        guard var components = URLComponents(string: baseURL) else { return nil }
        switch components.scheme?.lowercased() {
        case "https": components.scheme = "wss"
        case "http": components.scheme = "ws"
        default: return nil
        }
        components.path = components.path.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
            + path
        components.query = nil
        components.fragment = nil
        return components.url
    }

    /// The pairing HTTP URL for a relay base URL.
    ///
    /// - Parameters:
    ///   - baseURL: the relay base.
    ///   - path: the path to append, beginning with a slash.
    /// - Returns: the URL, or `nil`.
    public static func relayHTTPURL(baseURL: String, path: String) -> URL? {
        guard let url = URL(string: baseURL + path), let host = url.host(), !host.isEmpty else {
            return nil
        }
        return url
    }

    /// Build a URL for one authority.
    ///
    /// `URL(string:)` accepts far more than it should here: `ws:///path` is a
    /// perfectly valid URL with an *empty* host, so a blank or malformed
    /// authority would produce something that looks dialable and fails later
    /// with a confusing transport error. The host is checked explicitly.
    ///
    /// - Parameters:
    ///   - authority: `host:port`.
    ///   - path: the path to append.
    ///   - scheme: the scheme to use.
    /// - Returns: the URL, or `nil` when the authority is unusable.
    public static func url(authority: String, path: String, scheme: String) -> URL? {
        let trimmed = authority.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let url = URL(string: "\(scheme)://\(trimmed)\(path)"),
              let host = url.host(), !host.isEmpty
        else { return nil }
        return url
    }

    /// Build the WebSocket URL for a target.
    ///
    /// - Parameters:
    ///   - authority: `host:port`.
    ///   - secure: whether to use `wss`.
    /// - Returns: the URL, or `nil` when the authority is unusable.
    public static func webSocketURL(authority: String, secure: Bool = false) -> URL? {
        url(authority: authority, path: mizarWebSocketPath, scheme: secure ? "wss" : "ws")
    }

    /// Build the HTTP URL for a target.
    ///
    /// - Parameters:
    ///   - authority: `host:port`.
    ///   - path: the path to append.
    ///   - secure: whether to use `https`.
    /// - Returns: the URL, or `nil` when the authority is unusable.
    public static func httpURL(authority: String, path: String, secure: Bool = false) -> URL? {
        url(authority: authority, path: path, scheme: secure ? "https" : "http")
    }
}
