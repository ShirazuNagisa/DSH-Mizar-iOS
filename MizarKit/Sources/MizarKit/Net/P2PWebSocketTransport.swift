//
//  P2PWebSocketTransport.swift
//  MizarKit
//
//  A MizarNet connection as a `WebSocketTransport`.
//
//  This is the seam the whole kernel was shaped around. `MizarConnection`
//  needs four methods — connect, send, receive, close — and a socket that
//  behaves like the wire; the app's route policy, handshake, correlation and
//  event routing are all written against that protocol already. So a direct
//  connection is not a new connection layer: it is a new transport, chosen
//  the same way the local kernel is chosen, and the Mizar frames travel over
//  it unchanged.
//
//  The URL is `mizar-net://dial?t=<ticket>`. The scheme is deliberately not
//  `ws`/`wss`: nothing here speaks WebSocket, and a URL that looked like one
//  would invite a caller to dial it with the wrong transport. The headers
//  are accepted and ignored, exactly as ``LocalKernelTransport`` ignores
//  them — the relay's identity headers belong to the relay's transport, and
//  the direct path authenticates inside the protocol, with the device token
//  in the `hello` frame.
//

import Foundation

/// The `mizar-net://` URL forms.
public enum MizarNetDialURL {
    /// The scheme.
    public static let scheme = "mizar-net"
    /// The dial host.
    public static let host = "dial"

    /// Build the URL a ``P2PWebSocketTransport`` dials.
    ///
    /// - Parameter ticket: what to reach.
    /// - Returns: `mizar-net://dial?t=<base64url ticket>`.
    public static func make(ticket: MizarNetTicket) throws -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.queryItems = [URLQueryItem(name: "t", value: try ticket.encode())]
        guard let url = components.url else {
            throw MizarNetError.ticketInvalid(reason: "the ticket does not form a URL")
        }
        return url
    }

    /// Read the ticket back out of a URL.
    ///
    /// - Parameter url: what ``P2PWebSocketTransport`` was asked to dial.
    /// - Returns: the ticket.
    /// - Throws: ``MizarNetError/ticketInvalid(reason:)`` for anything that is
    ///   not a dial URL with a `t` parameter.
    public static func ticket(from url: URL) throws -> MizarNetTicket {
        guard url.scheme == scheme else {
            throw MizarNetError.ticketInvalid(reason: "scheme is not \(scheme)")
        }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let path = url.path
        let isDial = components?.host == host || path == "/\(host)" || path == host
        guard isDial else {
            throw MizarNetError.ticketInvalid(reason: "host is not \(host)")
        }
        guard let encoded = components?.queryItems?.first(where: { $0.name == "t" })?.value else {
            throw MizarNetError.ticketInvalid(reason: "no t parameter")
        }
        return try MizarNetTicket.decode(encoded)
    }
}

/// A direct MizarNet connection, wearing the transport protocol.
public actor P2PWebSocketTransport: WebSocketTransport {
    private let makeEngine: @Sendable () -> any MizarNetEngine
    private let signaling: (any MizarNetSignalingTransport)?
    private let makeSignaling: (@Sendable () async throws -> any MizarNetSignalingTransport)?
    /// The device token the connection presents on the signal channel.
    private let deviceToken: String?
    /// The channel this transport opened, if it opened one, so `close()` can
    /// shut it. A channel handed in by the caller is the caller's to close.
    private var openedSignaling: (any MizarNetSignalingTransport)?
    private var connection: MizarNetConnection?
    private var stream: (any MizarNetStream)?
    private var closed = false

    /// A transport.
    ///
    /// - Parameters:
    ///   - makeEngine: builds a fresh engine per `connect()`. A closure, not
    ///     an engine, for the same reason ``MizarConnection`` takes a
    ///     transport factory: a second dial must not inherit the first
    ///     attempt's sockets.
    ///   - signaling: the side channel, already open.
    ///   - makeSignaling: called during `connect` to open the side channel, for
    ///     a caller that would rather the transport owned its lifetime.
    ///   - deviceToken: what the phone presents to the desktop's signal
    ///     endpoint. The desktop passes nothing: it is the side being asked.
    ///
    /// `signaling` is for a test that hands in a loopback pair; `makeSignaling`
    /// is for a caller whose channel needs an async open and whose lifetime is
    /// the attempt's. The difference matters on the losing side of a route race:
    /// a channel opened before the race and never used has nobody to close it,
    /// while one opened here is closed by `close()` whether or not the dial
    /// ever got as far as a stream.
    public init(
        makeEngine: @escaping @Sendable () -> any MizarNetEngine,
        signaling: (any MizarNetSignalingTransport)? = nil,
        makeSignaling: (@Sendable () async throws -> any MizarNetSignalingTransport)? = nil,
        deviceToken: String? = nil,
    ) {
        self.makeEngine = makeEngine
        self.signaling = signaling
        self.makeSignaling = makeSignaling
        self.deviceToken = deviceToken
    }

    public func connect(url: URL, headers: [String: String]) async throws {
        guard !closed, stream == nil else {
            throw MizarError(code: "SOCKET_CLOSED", message: "the transport is already connected", retryable: true)
        }
        do {
            let ticket = try MizarNetDialURL.ticket(from: url)
            // Opened here rather than by the caller: this is the moment the
            // attempt becomes real, and a channel that fails to open is an
            // attempt that fails -- which the route above handles by falling
            // through to the relay, not by surfacing an error to the operator.
            if openedSignaling == nil, let makeSignaling, signaling == nil {
                do {
                    let channel = try await makeSignaling()
                    // `close()` can land while the channel is opening — the losing
                    // side of a route race is cancelled exactly then — and a channel
                    // assigned after that would never be closed by anybody.
                    if closed {
                        await channel.close()
                        throw MizarNetError.cancelled
                    }
                    openedSignaling = channel
                } catch {
                    // A signal channel that did not open is the one failure the
                    // user cannot tell from "the punch did not land". Keep the
                    // error instead of turning it into a silent nil: the route
                    // falls back to the relay either way, but the diagnosis log
                    // now says which half failed.
                    #if DEBUG
                    print("p2p: the signal channel did not open — \(error)")
                    #endif
                    throw error
                }
            }
            let connection = MizarNetConnection(
                engine: makeEngine(),
                ticket: ticket,
                signaling: signaling ?? openedSignaling,
                deviceToken: deviceToken,
            )
            self.connection = connection
            let stream = try await connection.connect()
            self.stream = stream
            #if DEBUG
            print("p2p: punched to \(ticket.endpointId.prefix(8))…")
            #endif
        } catch let error as MizarNetError {
            #if DEBUG
            print("p2p: the punch failed — \(error)")
            #endif
            // Everything the kernel can throw crosses this boundary as a
            // Mizar error: the diagnosis layer above only speaks that
            // vocabulary, and a raw kernel error would surface to the user
            // as a type name.
            await connection?.close()
            self.connection = nil
            throw error.mizarError
        }
    }

    public func send(text: String) async throws {
        guard !closed, let stream else {
            throw MizarError(code: "SOCKET_CLOSED", message: "the socket is not open", retryable: true)
        }
        do {
            try await stream.send(Data(text.utf8))
        } catch let error as MizarNetError {
            throw error.mizarError
        }
    }

    public func receive() async throws -> WebSocketFrame? {
        guard !closed, let stream else { return nil }
        do {
            guard let data = try await stream.receive() else { return nil }
            // The session carries both kinds. A UTF-8 body that starts with `{`
            // is a JSON API frame; anything else is a binary channel frame. The
            // first byte is the discriminator the state channel itself uses.
            if let text = String(data: data, encoding: .utf8),
               text.first(where: { !$0.isWhitespace }) == "{"
            {
                return .text(text)
            }
            return .binary(data)
        } catch let error as MizarNetError {
            throw error.mizarError
        }
    }

    public func close() async {
        guard !closed else { return }
        closed = true
        if let stream {
            await stream.close()
            self.stream = nil
        }
        await connection?.close()
        connection = nil
        // Only what this transport opened: a channel the caller passed in may
        // outlive the attempt, and closing somebody else's socket is the kind
        // of courtesy that shows up later as a mystery disconnect.
        await openedSignaling?.close()
        openedSignaling = nil
    }
}
