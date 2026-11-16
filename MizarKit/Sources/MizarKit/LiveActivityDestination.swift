import Foundation

/// A destination always keeps the desktop identity alongside its session.
public enum LiveActivityDestination: Hashable, Sendable, Identifiable {
    case overview
    case session(hostId: String, sessionId: String)
    case approval(hostId: String, sessionId: String, requestId: String)

    public var id: String { url.absoluteString }
    public var url: URL {
        var components = URLComponents()
        components.scheme = "dshmizar"
        components.host = "activity"
        switch self {
        case .overview: components.path = "/overview"
        case let .session(host, session):
            components.path = "/session"
            components.queryItems = [.init(name: "host", value: host), .init(name: "session", value: session)]
        case let .approval(host, session, request):
            components.path = "/approval"
            components.queryItems = [.init(name: "host", value: host), .init(name: "session", value: session), .init(name: "request", value: request)]
        }
        return components.url!
    }
    public init?(url: URL) {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "dshmizar", parts.host == "activity" else { return nil }
        func field(_ name: String) -> String? {
            let matches = (parts.queryItems ?? []).filter { $0.name == name }
            guard matches.count == 1, let value = matches[0].value, !value.isEmpty else { return nil }
            return value
        }
        switch parts.path {
        case "/overview": self = .overview
        case "/session":
            guard let host = field("host"), let session = field("session") else { return nil }
            self = .session(hostId: host, sessionId: session)
        case "/approval":
            guard let host = field("host"), let session = field("session"), let request = field("request") else { return nil }
            self = .approval(hostId: host, sessionId: session, requestId: request)
        default: return nil
        }
    }
}
