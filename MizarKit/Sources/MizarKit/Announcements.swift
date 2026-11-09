//
//  Announcements.swift
//  MizarKit
//
//  The banners the account relay pushes to phones, and the socket they arrive
//  on.
//
//  An announcement is a title, a sentence and optionally one button. The
//  button may name a settings page to open; the phone validates the name
//  against ``AnnouncementTarget`` and hides the button when it does not
//  recognise it, which is what the server promised ("hide it when the server
//  did not ask for one, show it when it did").
//
//  The socket is on the *relay* origin rather than the account API's, because
//  a WebSocket upgrade cannot be proxied by the account relay's HTTP
//  forwarder. The endpoint is `/app/v1/announcements`, authenticated with the
//  same session token the data plane uses. The polling twin,
//  `/account/v1/announcements`, is the fallback for a phone that cannot hold a
//  socket.
//

import Foundation

/// One settings page a banner may open.
///
/// The raw values are the server's `buttonTarget` vocabulary, which is the
/// settings directory's own shelf names. A target this build does not know is
/// not a reason to drop the banner: the text is still useful, so the button is
/// simply not drawn.
public enum AnnouncementTarget: String, Sendable, CaseIterable {
    case account
    case notifications
    case sending
    case transfer
    case localAgent
    case files
    case community
    case logs
    case about

    /// What the server may send, for a test to pin against the relay.
    public static var allRawValues: [String] { allCases.map(\.rawValue) }
}

/// The optional call to action.
public struct AnnouncementButton: Codable, Sendable, Equatable {
    public let label: String
    public let target: String

    public init(label: String, target: String) {
        self.label = label
        self.target = target
    }

    /// The shelf this button opens, when this build knows it.
    public var destination: AnnouncementTarget? { AnnouncementTarget(rawValue: target) }
}

/// One banner.
public struct Announcement: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let title: String
    public let body: String
    /// An SF Symbol the server chose; `nil` and an unknown name both fall back.
    public let symbol: String?
    /// `info` (the app's accent) or `notice` (its waiting colour).
    public let tone: String?
    public let button: AnnouncementButton?
    public let createdAt: Date?
    public let expiresAt: Date?
    /// Whether the server says it is still live.
    public let active: Bool?

    /// Build one by hand: previews and the mock host need a banner that did not
    /// come off a socket.
    public init(
        id: String = UUID().uuidString,
        title: String,
        body: String,
        symbol: String? = nil,
        tone: String? = nil,
        button: AnnouncementButton? = nil,
        createdAt: Date? = nil,
        expiresAt: Date? = nil,
        active: Bool? = true,
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.symbol = symbol
        self.tone = tone
        self.button = button
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.active = active
    }

    /// A preview banner.
    public static func preview(
        title: String,
        body: String,
        button: AnnouncementButton? = nil,
    ) -> Announcement {
        Announcement(title: title, body: body, symbol: "megaphone", tone: "info", button: button)
    }

    /// The symbol to draw, with the app's own default.
    public var resolvedSymbol: String {
        guard let symbol, !symbol.isEmpty else { return "megaphone" }
        return symbol
    }

    /// Whether this banner should still be shown.
    public var isLive: Bool {
        guard active != false else { return false }
        guard let expiresAt else { return true }
        return expiresAt > Date()
    }

    /// The button, when this build can act on it.
    public var actionableButton: AnnouncementButton? {
        guard let button, button.destination != nil, !button.label.isEmpty else { return nil }
        return button
    }
}

/// What one socket connection yields.
public enum AnnouncementEvent: Sendable, Equatable {
    /// Everything live when the socket opened.
    case snapshot([Announcement])
    /// One banner, as it was created.
    case announcement(Announcement)
}

/// A long-lived announcement socket.
///
/// One connection per account session, reconnected with a capped backoff while
/// the caller keeps the stream. The stream finishes when the consuming task is
/// cancelled, which is how the app stops it: the center cancels its consuming
/// task when the account signs out or the app goes to the background.
public actor AnnouncementStream {
    /// The relay origin that answers the socket. The account API's origin is a
    /// different port and cannot upgrade.
    public static let productionURL = URL(string: "wss://dshmizar-1.shirazu-nagisa.com")!

    private let baseURL: URL
    private let session: URLSession
    private var loop: Task<Void, Never>?

    /// - Parameters:
    ///   - baseURL: the relay origin, `wss://…` or `https://…`.
    ///   - session: the URL session; injectable for tests.
    public init(baseURL: URL = AnnouncementStream.productionURL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    /// Open the socket and yield events until the caller stops consuming.
    ///
    /// - Parameter token: the account session token.
    /// - Returns: a stream that reconnects on its own.
    public func events(token: String) -> AsyncStream<AnnouncementEvent> {
        AsyncStream { continuation in
            let task = Task { [baseURL, session] in
                var delay: UInt64 = 2_000_000_000
                while !Task.isCancelled {
                    await Self.runOnce(baseURL: baseURL, session: session, token: token) { event in
                        continuation.yield(event)
                    }
                    if Task.isCancelled { break }
                    try? await Task.sleep(nanoseconds: delay)
                    delay = min(delay * 2, 30_000_000_000)
                }
                continuation.finish()
            }
            loop = task
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// Stop the socket.
    public func stop() {
        loop?.cancel()
        loop = nil
    }

    /// Connect once and forward frames until the socket closes.
    private static func runOnce(
        baseURL: URL,
        session: URLSession,
        token: String,
        yield: @Sendable (AnnouncementEvent) -> Void,
    ) async {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return }
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.path = "/app/v1/announcements"
        guard let url = components.url else { return }
        var request = URLRequest(url: url)
        request.setValue(token, forHTTPHeaderField: "x-mizar-session")
        request.timeoutInterval = 30
        let socket = session.webSocketTask(with: request)
        socket.resume()
        defer { socket.cancel(with: .goingAway, reason: nil) }
        while !Task.isCancelled {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await socket.receive()
            } catch {
                return
            }
            guard let data = Self.payload(of: message) else { continue }
            for event in Self.decode(data) {
                yield(event)
            }
        }
    }

    /// The bytes of one frame, whichever kind it is.
    private static func payload(of message: URLSessionWebSocketTask.Message) -> Data? {
        switch message {
        case .data(let data): data
        case .string(let text): text.data(using: .utf8)
        @unknown default: nil
        }
    }

    /// Decode one server frame.
    ///
    /// Exposed rather than private so the wire shape is testable without a
    /// socket: the two frames the relay sends are the whole protocol.
    ///
    /// - Parameter data: one JSON frame.
    /// - Returns: the events it carries, possibly empty.
    public static func decode(_ data: Data) -> [AnnouncementEvent] {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = object["type"] as? String
        else { return [] }
        switch type {
        case "snapshot":
            guard let raw = object["announcements"] as? [Any] else { return [] }
            let announcements = raw.compactMap { element -> Announcement? in
                guard let payload = try? JSONSerialization.data(withJSONObject: element) else { return nil }
                return try? AccountCoding.decoder().decode(Announcement.self, from: payload)
            }
            return [.snapshot(announcements)]
        case "announcement":
            guard let element = object["announcement"],
                  let payload = try? JSONSerialization.data(withJSONObject: element),
                  let announcement = try? AccountCoding.decoder().decode(Announcement.self, from: payload)
            else { return [] }
            return [.announcement(announcement)]
        default:
            return []
        }
    }
}
