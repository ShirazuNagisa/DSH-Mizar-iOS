//
//  SelfHostedDirectory.swift
//  MizarKit
//
//  "Which computers are online on your relay?"
//
//  A self-hosted relay has no account service, so it cannot answer the
//  question `/account/v1/desktops` answers on the official one. It keeps its
//  own directory instead: every tunnel is listed while it is up, and one
//  server PIN -- possibly none -- is what a phone presents to read the list.
//
//  The list is *discovery*, not trust: a computer in it still has to be paired
//  with the code it shows (see ``PairingURI/selfHosted(origin:room:code:name:)``).
//  That is why this client only lists, and why a wrong PIN and a missing PIN
//  are separate errors: one is a field to fix, the other is a page to open.
//

import Foundation

/// One computer that is online on a self-hosted relay.
public struct SelfHostedDesktop: Decodable, Identifiable, Equatable, Sendable {
    /// The relay room the phone dials: `<origin>/r/<room>`.
    public let room: String
    /// The computer's stable id, when it sent one. May be empty.
    public let deviceId: String
    /// The name the computer reports. The relay substitutes `Computer` when it
    /// sent none, so this is always displayable.
    public let name: String
    /// `macos`, `windows`, `linux` or `unknown`.
    public let platform: String?
    /// When the tunnel attached, in epoch milliseconds. Carried for ordering
    /// and for a future "online since" line; the list arrives newest first.
    public let onlineSince: Double?

    /// The row identity. The room is what actually addresses the computer, so
    /// it is the fallback for a computer that sent no id.
    public var id: String { deviceId.isEmpty ? room : deviceId }

    /// The platform as a sentence fragment, or `nil` when the relay does not
    /// know it.
    public var platformLabel: String? {
        switch platform?.lowercased() {
        case "macos": "macOS"
        case "windows": "Windows"
        case "linux": "Linux"
        default: nil
        }
    }
}

/// A directory list that did not come back.
public enum SelfHostedDirectoryError: Error, Equatable, Sendable {
    /// The origin is not an https origin this client may dial.
    case invalidOrigin
    /// Nothing answered: DNS, certificate, port, timeout.
    case network
    /// The relay requires a server PIN and none was sent.
    case pinRequired
    /// The relay requires a server PIN and this one is not it.
    case pinInvalid
    /// Too many wrong PINs from this address; the relay asks for a wait.
    case rateLimited
    /// Any other HTTP status, passed through so the sentence can name it.
    case http(Int)
    /// A 200 whose body is not the directory response.
    case invalidResponse
}

/// Reads the online-computer list from a self-hosted relay.
public struct SelfHostedDirectoryClient: Sendable {
    /// The header the relay reads the server PIN from.
    public static let pinHeader = "x-mizar-server-pin"

    /// The relay's origin, normalised on use.
    public let origin: String
    /// The server PIN, empty when the relay does not require one.
    public let pin: String

    /// - Parameters:
    ///   - origin: the self-hosted origin, as configured.
    ///   - pin: the server PIN, or an empty string.
    public init(origin: String, pin: String = "") {
        self.origin = origin
        self.pin = pin
    }

    /// The origin this client would dial.
    public var normalizedOrigin: String? {
        ServerSelection(mode: .selfHosted, origin: origin).normalizedOrigin
    }

    /// List the computers that are online right now.
    ///
    /// - Parameter load: how to perform a request. `nil` uses `URLSession`.
    /// - Returns: the computers, or the first thing that went wrong.
    public func list(
        load: ((URLRequest) async throws -> (Data, HTTPURLResponse))? = nil,
    ) async -> Result<[SelfHostedDesktop], SelfHostedDirectoryError> {
        guard let origin = normalizedOrigin,
              let url = URL(string: origin + "/selfhost/v1/desktops")
        else { return .failure(.invalidOrigin) }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = ServerProbe.timeout
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let pin = pin.trimmingCharacters(in: .whitespacesAndNewlines)
        if !pin.isEmpty {
            request.setValue(pin, forHTTPHeaderField: Self.pinHeader)
        }

        let data: Data
        let response: HTTPURLResponse
        do {
            if let load {
                (data, response) = try await load(request)
            } else {
                (data, response) = try await Self.defaultLoad(request)
            }
        } catch {
            return .failure(.network)
        }

        switch response.statusCode {
        case 200:
            guard let body = try? JSONDecoder().decode(ListResponse.self, from: data) else {
                return .failure(.invalidResponse)
            }
            return .success(body.desktops)
        case 401:
            return .failure(.pinRequired)
        case 403:
            return .failure(.pinInvalid)
        case 429:
            return .failure(.rateLimited)
        default:
            return .failure(.http(response.statusCode))
        }
    }

    /// The response envelope, of which only `desktops` is read.
    ///
    /// `relay` is the relay's own version block; the phone shows the configured
    /// origin instead, and the probe already read the health fields.
    private struct ListResponse: Decodable {
        let desktops: [SelfHostedDesktop]
    }

    /// The real request path, shared with ``ServerProbe``.
    ///
    /// - Parameter request: the request to send.
    /// - Returns: the body and the HTTP response.
    /// - Throws: when nothing answered or the answer was not HTTP.
    static func defaultLoad(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }
}
