import Foundation

#if DEBUG
private actor LiveActivityConnectionDiagnosticLog {
    static let shared = LiveActivityConnectionDiagnosticLog()
    private var lastLogged: [String: Date] = [:]

    func write(_ message: String, key: String) {
        let now = Date()
        guard now.timeIntervalSince(lastLogged[key] ?? .distantPast) >= 10 else { return }
        lastLogged[key] = now
        print("[live-activity-connection] \(message)")
    }
}
#endif

/// Small independent connections keep activity reads away from navigation state.
public enum LiveActivityHostConnection {
    /// The route switches captured by the caller that is opening this socket.
    ///
    /// A foreground caller should pass its live settings snapshot. An App Intent
    /// has no foreground model, so the default reads the same persisted settings
    /// as the app instead of inventing a second preference or key.
    public struct RouteSettings: Sendable, Equatable {
        public let localNetworkFirst: Bool
        public let directConnection: Bool

        public init(localNetworkFirst: Bool, directConnection: Bool) {
            self.localNetworkFirst = localNetworkFirst
            self.directConnection = directConnection
        }

        public static var persisted: Self {
            let settings = MizarSettings.load(from: UserDefaultsSettingsStorage())
            return Self(
                localNetworkFirst: settings.localNetworkFirst,
                directConnection: settings.directConnection,
            )
        }
    }

    private static let directRouteHeadStart: Duration = .milliseconds(400)

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }

    static func configurations(
        host: PairedHost,
        relayHeaders: [String: String],
        accountId: String?,
        routeSettings: RouteSettings = .persisted,
    ) -> [MizarConnection.Configuration] {
        let allowedEndpoints = RoutePolicy.allowed(
            host.endpoints,
            localNetworkFirst: routeSettings.localNetworkFirst,
            directConnection: routeSettings.directConnection,
        )
        return allowedEndpoints.compactMap { endpoint -> MizarConnection.Configuration? in
            switch endpoint {
            case .direct(let authority):
                return .init(authority: authority, token: host.deviceToken, appVersion: appVersion, accountId: accountId, subscribeToStateChanges: false, requestTimeout: .seconds(5), handshakeTimeout: .seconds(4))
            case .relay(let baseURL):
                var headers = relayHeaders
                // The official account relay verifies the session during its
                // WebSocket upgrade. Other relays, arbitrary ports, and URLs
                // with userinfo/query/fragment must never receive that bearer
                // token; they only need the install/account identity.
                if !LiveActivityHostIdentity.isOfficialAccountRelay(baseURL) {
                    headers.removeValue(forKey: RelayIdentity.sessionHeader)
                }
                return .init(authority: nil, token: host.deviceToken, appVersion: appVersion, accountId: accountId, subscribeToStateChanges: false, requestTimeout: .seconds(5), baseURL: baseURL, handshakeTimeout: .seconds(5), relayHeaders: headers)
            case .p2p: return nil
            }
        }
    }

    public static func open(
        host: PairedHost,
        relayHeaders: [String: String] = [:],
        accountId: String? = nil,
        routeSettings: RouteSettings = .persisted,
        identityStore: LiveActivityHostIdentityStore = .shared,
        makeConnection: @escaping @Sendable (MizarConnection.Configuration) -> MizarConnection = { MizarConnection(configuration: $0) },
    ) async -> MizarConnection? {
        let configurations = configurations(
            host: host,
            relayHeaders: relayHeaders,
            accountId: accountId,
            routeSettings: routeSettings,
        )
        let localRouteGetsHeadStart = routeSettings.localNetworkFirst
            && configurations.contains { configuration in
                if case .direct = configuration.endpoint { return true }
                return false
            }
        return await withTaskGroup(of: MizarConnection?.self) { group in
            for configuration in configurations {
                let routeKind: String = switch configuration.endpoint {
                case .direct: "direct"
                case .relay: "relay"
                case .p2p: "p2p"
                case nil: "unknown"
                }
                group.addTask {
                    if localRouteGetsHeadStart, case .relay = configuration.endpoint {
                        do {
                            try await Task.sleep(for: directRouteHeadStart)
                        } catch {
                            return nil
                        }
                        guard !Task.isCancelled else { return nil }
                    }
                    let connection = makeConnection(configuration)
                    let deadline = Task {
                        do { try await Task.sleep(for: .seconds(6)) } catch { return }
                        await connection.disconnect()
                    }
                    defer { deadline.cancel() }
                    do {
                        let welcome = try await withTaskCancellationHandler {
                            try await connection.connect()
                        } onCancel: { Task { await connection.disconnect() } }
                        let binding = identityStore.binding(for: host)
                        let expectedHostId = LiveActivityHostIdentity.resolvedHostId(for: host, binding: binding)
                        var identityMatches = welcome.hostId == expectedHostId
                        if !identityMatches, binding == nil,
                           LiveActivityHostIdentity.canBootstrap(
                               host: host,
                               endpoint: configuration.endpoint,
                               accountId: accountId,
                               relayHeaders: configuration.relayHeaders,
                           ) {
                            identityMatches = await identityStore.bind(welcome.hostId, to: host)
                        }
                        #if DEBUG
                        await LiveActivityConnectionDiagnosticLog.shared.write(
                            "welcome route=\(routeKind) identityMatches=\(identityMatches)",
                            key: "welcome-\(routeKind)-\(identityMatches)",
                        )
                        #endif
                        guard !Task.isCancelled, identityMatches else {
                            await connection.disconnect(); return nil
                        }
                        return connection
                    } catch {
                        #if DEBUG
                        if !Task.isCancelled {
                            let error = error as NSError
                            await LiveActivityConnectionDiagnosticLog.shared.write(
                                "connect failed route=\(routeKind) domain=\(error.domain) code=\(error.code)",
                                key: "error-\(routeKind)-\(error.domain)-\(error.code)",
                            )
                        }
                        #endif
                        await connection.disconnect(); return nil
                    }
                }
            }
            while let result = await group.next() {
                if let connection = result {
                    group.cancelAll()
                    while let remaining = await group.next() {
                        if let loser = remaining { await loser.disconnect() }
                    }
                    return connection
                }
            }
            return nil
        }
    }
}
