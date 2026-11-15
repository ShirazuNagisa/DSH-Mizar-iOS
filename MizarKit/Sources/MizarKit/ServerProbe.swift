//
//  ServerProbe.swift
//  MizarKit
//
//  "Is this address really a DSH relay, and does it want a PIN?"
//
//  The guide asks a person for a domain and a server PIN, and before it lets
//  them carry on it has to answer two questions that a connection attempt four
//  screens later would answer badly: whether the address is a relay at all
//  (a valid https site is not), and whether the PIN is one the relay accepts.
//
//  `/healthz` is the contract's answer to the first. It is unauthenticated and
//  carries `product` and the tunnel protocol version, which is what makes
//  "wrong host" and "too old relay" different sentences instead of one failed
//  connect. The directory endpoint is the answer to the second: a relay that
//  reports `pinRequired` has to accept the PIN on the list before the guide
//  may continue.
//
//  The loader is injectable so this runs with no network in `swift test`, and
//  so the same code path can be exercised against a stub that answers 401,
//  403 or 429.
//

import Foundation

/// What `/healthz` says about a relay.
///
/// Only the fields this client acts on. The official relay's other fields
/// (`setupPage`, `updateEnabled`, the traffic counters) belong to its setup
/// page, not to a phone deciding whether it can use the server.
public struct RelayHealth: Decodable, Equatable, Sendable {
    /// The product marker. A relay answers `dsh-mizar-relay`.
    public let product: String
    /// The relay's build version, for the log and a diagnosis.
    public let relayVersion: String?
    /// The tunnel protocol version. This is not the build version.
    public let version: Int?
    /// Whether this deployment is a self-hosted one.
    public let selfHost: Bool?
    /// Whether `/selfhost/v1/desktops` requires the server PIN.
    public let pinRequired: Bool?

    /// Whether the server requires the server PIN for its directory.
    public var requiresPin: Bool { pinRequired == true }
}

/// Why a server check did not pass.
///
/// Each case is something the operator can act on: an address to retype, a
/// PIN to find, a relay to upgrade, a wait to sit out. Collapsing them into
/// "could not connect" is what makes a setup page useless.
public enum ServerProbeError: Error, Equatable, Sendable {
    /// The address is not an https origin (or has a path, a query, a user).
    case invalidOrigin
    /// Nothing answered: DNS, certificate, port, timeout.
    case network
    /// Something answered, but it is not a DSH relay.
    case notRelay
    /// A relay, but one whose tunnel protocol is older than this client speaks.
    case protocolTooOld
    /// The relay requires a server PIN and none was entered.
    case pinRequired
    /// The relay requires a server PIN and this one is not it.
    case pinInvalid
    /// Any other HTTP status, passed through so the sentence can name it.
    case http(Int)
    /// The relay has seen too many wrong PINs from this address.
    case rateLimited
}

/// One connectivity check against a self-hosted relay.
public enum ServerProbe {
    /// The contract's timeout for both requests.
    public static let timeout: TimeInterval = 10

    /// Check an origin (and its PIN) against the relay contract.
    ///
    /// Steps, in the contract's order:
    ///
    /// 1. `GET /healthz`; it must answer 200 with the relay's product marker.
    /// 2. Its tunnel `version` must be at least 1.
    /// 3. When it reports `pinRequired`, a PIN has to be present, and the
    ///    directory endpoint has to accept it with a 200.
    ///
    /// - Parameters:
    ///   - origin: the address the operator typed.
    ///   - pin: the server PIN, empty when the relay does not require one.
    ///   - load: how to perform a request. `nil` uses `URLSession`.
    /// - Returns: the health answer, or the first thing that failed.
    public static func check(
        origin: String,
        pin: String,
        load: ((URLRequest) async throws -> (Data, HTTPURLResponse))? = nil,
    ) async -> Result<RelayHealth, ServerProbeError> {
        let selection = ServerSelection(mode: .selfHosted, origin: origin, pin: pin)
        guard let origin = selection.normalizedOrigin else { return .failure(.invalidOrigin) }
        let pin = pin.trimmingCharacters(in: .whitespacesAndNewlines)

        let healthResponse: (Data, HTTPURLResponse)
        switch await get(origin + "/healthz", pin: nil, load: load) {
        case .failure(let error): return .failure(error)
        case .success(let answer): healthResponse = answer
        }

        guard healthResponse.1.statusCode == 200 else {
            return .failure(status(healthResponse.1.statusCode))
        }
        guard let health = try? JSONDecoder().decode(RelayHealth.self, from: healthResponse.0),
              health.product == "dsh-mizar-relay"
        else {
            // A 200 from something that is not a relay is the address typo the
            // check exists for.
            return .failure(.notRelay)
        }
        guard let version = health.version, version >= 1 else {
            return .failure(.protocolTooOld)
        }

        guard health.requiresPin else { return .success(health) }

        guard !pin.isEmpty else { return .failure(.pinRequired) }
        switch await get(origin + "/selfhost/v1/desktops", pin: pin, load: load) {
        case .failure(let error):
            return .failure(error)
        case .success(let (_, response)):
            switch response.statusCode {
            case 200:
                return .success(health)
            case 401:
                // The relay says this endpoint needs a PIN and refused the
                // request: the same answer as an empty field, because the
                // remedy is the same.
                return .failure(.pinRequired)
            case 403:
                return .failure(.pinInvalid)
            case 429:
                return .failure(.rateLimited)
            default:
                return .failure(.http(response.statusCode))
            }
        }
    }

    /// The error for an HTTP status, outside the directory's own cases.
    /// - Parameter code: the status code.
    /// - Returns: the error.
    private static func status(_ code: Int) -> ServerProbeError {
        code == 429 ? .rateLimited : .http(code)
    }

    /// Perform one GET, with the probe's timeout and no caching.
    ///
    /// - Parameters:
    ///   - url: the absolute URL.
    ///   - pin: the server PIN header, or `nil` for `/healthz`.
    ///   - load: the injected loader, or `nil` for `URLSession`.
    /// - Returns: the body and the HTTP response, or ``ServerProbeError/network``.
    private static func get(
        _ url: String,
        pin: String?,
        load: ((URLRequest) async throws -> (Data, HTTPURLResponse))?,
    ) async -> Result<(Data, HTTPURLResponse), ServerProbeError> {
        guard let target = URL(string: url) else { return .failure(.invalidOrigin) }
        var request = URLRequest(url: target)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let pin, !pin.isEmpty {
            request.setValue(pin, forHTTPHeaderField: SelfHostedDirectoryClient.pinHeader)
        }
        do {
            let answer: (Data, HTTPURLResponse)
            if let load {
                answer = try await load(request)
            } else {
                answer = try await SelfHostedDirectoryClient.defaultLoad(request)
            }
            return .success(answer)
        } catch {
            return .failure(.network)
        }
    }
}
