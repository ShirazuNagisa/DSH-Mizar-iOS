//
//  PairingClient.swift
//  MizarKit
//
//  The one unauthenticated exchange.
//
//  Pairing is the only moment the app talks to the host without a credential,
//  so it is also the only place a failure message reaches the operator before
//  they have any context. The errors below therefore carry what the code means,
//  not just the code: "the code has expired" is actionable, `410` is not.
//
//  The host answers a pairing attempt with a specific code rather than a bare
//  status — `PAIRING_CODE_INVALID`, `PAIRING_CODE_EXPIRED`, `PAIRING_CODE_UNKNOWN`,
//  `RATE_LIMITED` — and each maps to different advice, so they are preserved
//  rather than collapsed into "pairing failed".
//
//  Pairing is also the first time the app has to choose a route. A plugin 0.8.5+
//  QR carries a direct address and a relay base URL, and only one of them can
//  answer for a given phone: the direct one is the same Wi-Fi or a tailnet, and a
//  phone on cellular (or on a Wi-Fi that isolates clients, or with local-network
//  permission denied) cannot reach it while the relay works. So the routes are
//  dialled in the order ``PairingRoutes`` gives, and the rule for moving to the
//  next one is precise: only when nothing on this route answered. Once the host
//  has answered — a status, a `PAIRING_CODE_*` — the answer is the answer, and
//  asking through another door would ask the same computer the same question.
//

import Foundation

/// The HTTP surface pairing needs.
public protocol HTTPTransport: Sendable {
    /// Perform one request.
    /// - Parameter request: the request to send.
    /// - Returns: the body and the response.
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// The real transport.
public struct URLSessionHTTPTransport: HTTPTransport {
    private let session: URLSession

    public init(timeout: TimeInterval = 30) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        self.session = URLSession(configuration: configuration)
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MizarError(code: "NOT_HTTP", message: "the host did not answer over HTTP")
        }
        return (data, http)
    }
}

/// A pairing that succeeded, and the route that produced it.
public struct PairingOutcome: Sendable {
    /// The pairing, ready to store.
    public let host: PairedHost
    /// The route that answered.
    ///
    /// Returned because the first socket should be dialled over it: the route
    /// that has just answered a request is the route this phone can reach the
    /// computer on right now, and asking the other one first would spend that
    /// route's timeout before coming back. The other route stays in the pairing
    /// as the fallback every reconnect already knows how to use.
    public let route: PairingRoute
}

/// Every route a pairing tried, and why it gave up.
///
/// One error rather than only the last failure because the log is what turns
/// "pairing failed" into a diagnosis: a pairing that never left the phone and one
/// that reached the relay and was refused look identical on screen, and the list
/// of routes is the difference.
public struct PairingFailure: Error, Sendable {
    /// One route that did not pair.
    public struct Attempt: Sendable {
        /// The route that was dialled.
        public let route: PairingRoute
        /// Why it did not pair: a transport error when nothing answered, or the
        /// host's own refusal when it did.
        public let error: any Error
    }

    /// Every route tried, in order.
    public let attempts: [Attempt]
    /// The answer to act on: the host's refusal when it answered, otherwise the
    /// last route's transport error.
    public let finalError: any Error
}

/// Why one route attempt did not produce a pairing.
///
/// The two cases are the fallback rule, made explicit so it cannot be inferred
/// from error types: an error thrown before a response arrives means the route
/// was never heard from, and only that kind is worth another route.
private enum RouteAttemptFailure: Error {
    /// Nothing on this route answered: a transport failure, a timeout, or an
    /// address that could not be turned into a request. The next route is worth
    /// trying.
    case unanswered(any Error)
    /// The host answered and the answer is final. Another route would ask the
    /// same computer the same question again.
    case answered(MizarError)

    /// The failure as a caller that chose the route should see it.
    var underlyingError: any Error {
        switch self {
        case .unanswered(let error): error
        case .answered(let error): error
        }
    }
}

/// The pairing conversation.
public struct PairingClient: Sendable {
    /// How to dial one route.
    ///
    /// A factory rather than one transport because the route carries its own
    /// timeout, and the transport is where a timeout lives.
    private let makeTransport: @Sendable (PairingRoute) -> any HTTPTransport
    /// Identity headers for a relayed attempt.
    ///
    /// Pairing through a relay is the first request a fresh install makes and the
    /// one that creates the device's traffic identity; sending the headers here
    /// keeps a guest's pairing traffic attributed to the install rather than to
    /// an anonymous hash of the room and user agent. They are attached to relay
    /// attempts only: a direct pairing goes to the operator's own computer, which
    /// meters nothing and has no use for an account hash.
    private let headers: [String: String]

    /// A client that sends every attempt over one injected transport.
    ///
    /// Kept for the tests that pin a single exchange, and for the single-route
    /// entry point. It is not what the app uses for a scanned QR: one transport
    /// means one timeout, and the whole point of the plan is that the direct
    /// attempt may not spend the relay's.
    ///
    /// - Parameters:
    ///   - transport: how to reach the host; injectable for tests.
    ///   - headers: relay identity headers, attached to relay attempts.
    public init(
        transport: any HTTPTransport = URLSessionHTTPTransport(),
        headers: [String: String] = [:],
    ) {
        self.makeTransport = { _ in transport }
        self.headers = headers
    }

    /// A client that dials the real network, one transport per route.
    ///
    /// - Parameters:
    ///   - makeTransport: how to dial one route; the app builds a
    ///     ``URLSessionHTTPTransport`` with `route.timeout`, so a dead direct
    ///     address costs its six seconds and no more.
    ///   - headers: relay identity headers, attached to relay attempts.
    public init(
        makeTransport: @escaping @Sendable (PairingRoute) -> any HTTPTransport,
        headers: [String: String] = [:],
    ) {
        self.makeTransport = makeTransport
        self.headers = headers
    }

    /// Ask an unauthenticated host who it is.
    ///
    /// Used before pairing to confirm something is listening and to check
    /// whether a code is outstanding, so a wrong address fails with "nothing is
    /// listening there" rather than a confusing pairing error.
    ///
    /// - Parameter authority: `host:port`.
    /// - Returns: the host's identity.
    public func hello(authority: String) async throws -> HelloResponse {
        let url = try requireURL(authority: authority, baseURL: nil, path: "\(mizarHTTPPrefix)/hello")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "accept")
        // No identity headers: a hello is always a direct probe -- it only takes
        // an authority -- and those headers are relay bookkeeping the computer
        // has no use for. There is no relay in front of this request to read them.

        let (data, response) = try await makeTransport(.direct(authority: authority)).data(for: request)
        guard response.statusCode == 200 else {
            throw MizarError(
                code: "HELLO_FAILED",
                message: describeStatus(response.statusCode),
                retryable: response.statusCode >= 500,
            )
        }
        return try decode(data, as: HelloResponse.self)
    }

    /// Redeem a pairing code over the first route that answers.
    ///
    /// Every route the QR carries is tried in order, direct first. Only a
    /// transport-level failure falls through to the next route; a refusal from
    /// the host stops the attempt, because the same code sent through the relay
    /// would be refused for the same reason.
    ///
    /// - Parameters:
    ///   - target: the decoded QR.
    ///   - deviceName: what to call this device in the host's roster.
    ///   - deviceModel: the hardware model.
    /// - Returns: the pairing and the route that produced it.
    /// - Throws: ``PairingFailure`` when no route paired. Its `finalError` is
    ///   the answer to act on, and its `attempts` are what the log records.
    public func pair(
        target: PairingTarget,
        deviceName: String,
        deviceModel: String,
    ) async throws -> PairingOutcome {
        let routes = PairingRoutes.plan(for: target)
        guard !routes.isEmpty else {
            throw MizarError(
                code: "BAD_AUTHORITY",
                message: "the scan carries no address this app can dial",
            )
        }

        var attempts: [PairingFailure.Attempt] = []
        for route in routes {
            do {
                // The relay's identity headers ride on a relay attempt only.
                // They are relay bookkeeping -- the computer strips them on the
                // far side and never sees them -- so a direct attempt has
                // nothing to carry.
                let host = try await pair(
                    over: route,
                    headers: route.isRelay ? headers : [:],
                    code: target.code,
                    deviceName: deviceName,
                    deviceModel: deviceModel,
                )
                // The answered route is the first one to dial, not the only one
                // the pairing may know: a QR that also carried the relay must
                // keep it, or a phone paired on Wi-Fi can never return from
                // cellular.
                let stored = host.recordingRoutes(
                    authority: target.authority,
                    baseURL: target.baseURL,
                )
                return PairingOutcome(host: stored, route: route)
            } catch let failure as RouteAttemptFailure {
                switch failure {
                case .unanswered(let error):
                    // Nothing on this route answered. This is the case the
                    // fallback exists for: the phone is off the LAN the direct
                    // route names, and the relay in the same QR may still work.
                    attempts.append(PairingFailure.Attempt(route: route, error: error))
                case .answered(let error):
                    // The host answered, and its answer is the pairing's answer.
                    // An expired code is not a network problem; retrying it
                    // through the other route would only ask twice.
                    attempts.append(PairingFailure.Attempt(route: route, error: error))
                    throw PairingFailure(attempts: attempts, finalError: error)
                }
            }
        }

        // No route got through. The last error is the one to show: with direct
        // then relay, it is the relay's, which is the route that was supposed to
        // be the fallback and is therefore the failure worth diagnosing.
        throw PairingFailure(
            attempts: attempts,
            finalError: attempts.last?.error
                ?? MizarError(code: "UNREACHABLE", message: "no route reached the host"),
        )
    }

    /// Redeem a pairing code over the one route named.
    ///
    /// The single-route entry point from before route planning; kept because the
    /// exchange is tested through it, and because a caller that already knows
    /// which route it wants should not have to build a plan. It does not fall
    /// back: use ``pair(target:deviceName:deviceModel:)`` for a scanned QR.
    ///
    /// - Parameters:
    ///   - authority: `host:port`.
    ///   - code: the code from the QR or typed by hand.
    ///   - deviceName: what to call this device in the host's roster.
    ///   - deviceModel: the hardware model.
    ///   - baseURL: the relay base URL, when going through one.
    /// - Returns: the pairing, ready to store.
    public func pair(
        authority: String?,
        code: String,
        deviceName: String,
        deviceModel: String,
        baseURL: String? = nil,
    ) async throws -> PairedHost {
        let route: PairingRoute
        if let authority, !authority.isEmpty {
            route = .direct(authority: authority)
        } else if let baseURL, !baseURL.isEmpty {
            route = .relay(baseURL: baseURL)
        } else {
            throw MizarError(
                code: "BAD_AUTHORITY",
                message: "\"\(authority ?? baseURL ?? "")\" is not an address this app can dial",
            )
        }

        do {
            return try await pair(
                over: route,
                headers: route.isRelay ? headers : [:],
                code: code,
                deviceName: deviceName,
                deviceModel: deviceModel,
            )
        } catch let failure as RouteAttemptFailure {
            // The single-route form has no plan to report: the caller chose the
            // route, so the underlying error is the whole story.
            throw failure.underlyingError
        }
    }

    // MARK: - Internals

    /// Redeem the code over one route.
    ///
    /// Throws ``RouteAttemptFailure`` rather than the underlying error so the
    /// plan can tell "nothing answered" from "the host refused": only the first
    /// is worth another route.
    ///
    /// - Parameters:
    ///   - route: the way to reach the host.
    ///   - headers: identity headers to attach to this attempt; empty for a
    ///     direct route.
    ///   - code: the code from the QR or typed by hand.
    ///   - deviceName: what to call this device in the host's roster.
    ///   - deviceModel: the hardware model.
    /// - Returns: the pairing, ready to store.
    private func pair(
        over route: PairingRoute,
        headers: [String: String],
        code: String,
        deviceName: String,
        deviceModel: String,
    ) async throws -> PairedHost {
        var request: URLRequest
        do {
            request = URLRequest(url: try route.url(path: "\(mizarHTTPPrefix)/pair"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.setValue("application/json", forHTTPHeaderField: "accept")
            request.httpBody = try JSONEncoder().encode(
                PairRequest(
                    code: code,
                    deviceName: deviceName,
                    deviceModel: deviceModel,
                    appVersion: Self.appVersion,
                ),
            )
        } catch {
            // The route could not even be turned into a request -- an address
            // the QR carries but this client cannot dial. Nothing was sent, so
            // this is not the host refusing anything: the next route is worth
            // trying.
            throw RouteAttemptFailure.unanswered(error)
        }
        applyHeaders(headers, to: &request)

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await makeTransport(route).data(for: request)
        } catch {
            throw RouteAttemptFailure.unanswered(error)
        }

        guard response.statusCode == 200 else {
            throw RouteAttemptFailure.answered(pairFailure(status: response.statusCode, body: data))
        }

        do {
            let body = try decode(data, as: PairResponse.self)
            return PairedHost(
                hostId: body.hostId,
                hostName: body.hostName,
                authority: route.authority,
                deviceId: body.deviceId,
                deviceToken: body.deviceToken,
                // Recorded so later reconnects can use the same route the
                // pairing went through, rather than rediscovering it every time.
                baseURL: route.baseURL,
            )
        } catch let error as MizarError {
            // A 200 this app cannot read is still the host answering; the next
            // route would hand back the same body.
            throw RouteAttemptFailure.answered(error)
        }
    }

    /// Attach headers to a request.
    ///
    /// - Parameters:
    ///   - headers: the headers to set.
    ///   - request: the request to modify.
    private func applyHeaders(_ headers: [String: String], to request: inout URLRequest) {
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
    }

    /// The app's marketing version, sent for the host's roster.
    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }

    /// Build the URL for one step of pairing, over whichever route is named.
    ///
    /// - Parameters:
    ///   - authority: `host:port`, or `nil` to go through the relay.
    ///   - baseURL: the relay base URL, when going through one.
    ///   - path: the path to append.
    /// - Returns: the URL.
    /// - Throws: when neither route produces something dialable.
    private func requireURL(authority: String?, baseURL: String?, path: String) throws -> URL {
        if let authority, !authority.isEmpty,
           let url = PairingURI.httpURL(authority: authority, path: path) {
            return url
        }
        if let baseURL, !baseURL.isEmpty, let url = PairingURI.relayHTTPURL(baseURL: baseURL, path: path) {
            return url
        }
        throw MizarError(
            code: "BAD_AUTHORITY",
            message: "\"\(authority ?? baseURL ?? "")\" is not an address this app can dial",
        )
    }

    private func decode<T: Decodable>(_ data: Data, as type: T.Type) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw MizarError(
                code: "MALFORMED_RESPONSE",
                message: "the host answered something this app could not read",
            )
        }
    }

    /// Turn a refused pairing into an error the operator can act on.
    ///
    /// The host reports a specific code per reason, and each implies different
    /// advice — a wrong code means retype it, an expired or already-used one
    /// means ask the host for a fresh one, and being rate limited means wait.
    private func pairFailure(status: Int, body: Data) -> MizarError {
        let reported = (try? JSONDecoder().decode([String: String].self, from: body))?["error"]
        let code = reported ?? "PAIRING_FAILED"

        let message: String
        switch code {
        case "PAIRING_CODE_INVALID":
            message = "That pairing code is not right. Check the code shown on the host."
        case "PAIRING_CODE_EXPIRED":
            message = "That pairing code has expired. Generate a new one on the host."
        case "PAIRING_CODE_UNKNOWN":
            // The host also answers this for a code that was already used —
            // deliberately, so the endpoint is not an oracle — which is why the
            // wording covers both.
            message = "That pairing code is no longer valid. Generate a new one on the host."
        case "RATE_LIMITED":
            message = "Too many attempts. Wait a moment and try again."
        case "MALFORMED_FRAME":
            message = "The host could not read the request. Check that the app is up to date."
        default:
            message = describeStatus(status)
        }

        return MizarError(
            code: code,
            message: message,
            // A rate limit is worth retrying; a wrong code is not.
            retryable: code == "RATE_LIMITED" || status >= 500,
        )
    }

    private func describeStatus(_ status: Int) -> String {
        switch status {
        case 401: "The host refused the request."
        case 403: "The host refused the request because it did not come from a trusted address."
        case 404: "Nothing is listening at that address."
        case 405: "The host does not accept that request."
        case 410: "That pairing code is no longer valid. Generate a new one on the host."
        case 413: "The request was too large."
        case 429: "Too many attempts. Wait a moment and try again."
        default: "The host answered with status \(status)."
        }
    }
}
