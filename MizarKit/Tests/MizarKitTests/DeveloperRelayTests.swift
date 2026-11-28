//
//  DeveloperRelayTests.swift
//  MizarKitTests
//
//  The hidden developer relay: where its value comes from, how it is cleaned,
//  and how a pairing is moved onto it without the move reaching the Keychain.
//
//  The value is untrusted input from defaults or the environment and it decides
//  where the device token and account session are sent. The rewrite tests hold
//  the promise that the stored pairing keeps pointing at the online relay: the
//  functions are pure, so "what gets dialled" and "what gets saved" can be
//  compared without a socket.
//

import Foundation
import Testing
@testable import MizarKit

@Suite("DeveloperRelay")
struct DeveloperRelayTests {
    /// A defaults domain of its own per test, so a developer's real defaults
    /// (or a parallel append) cannot make a test pass or fail.
    private func makeDefaults() -> UserDefaults {
        let name = "DeveloperRelayTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private let environmentKey = DeveloperRelay.environmentKey
    private let defaultsKey = DeveloperRelay.defaultsKey
    private let lab = "https://dshmizar-1.shirazu-nagisa.com/lab"

    // MARK: - current

    @Test("no stored value and no environment override means off")
    func absentIsOff() {
        let defaults = makeDefaults()
        #expect(DeveloperRelay.current(defaults: defaults, environment: [:]) == nil)
        #expect(!DeveloperRelay.isEnabled(defaults: defaults, environment: [:]))
    }

    @Test("an unusable value means off")
    func unusableIsOff() {
        let defaults = makeDefaults()
        for value in ["", "   ", "ftp://relay.example.com/lab", "relay.example.com/lab", "https://"] {
            defaults.set(value, forKey: defaultsKey)
            #expect(DeveloperRelay.current(defaults: defaults, environment: [:]) == nil, "\(value)")
        }
    }

    @Test("the environment variable wins over the stored value")
    func environmentWins() {
        let defaults = makeDefaults()
        defaults.set("https://stored.example.com/lab", forKey: defaultsKey)
        let current = DeveloperRelay.current(
            defaults: defaults,
            environment: [environmentKey: "https://env.example.com/experiment"],
        )
        #expect(current?.absoluteString == "https://env.example.com/experiment")
    }

    @Test("trailing slashes are cleaned")
    func trailingSlashCleaned() {
        let defaults = makeDefaults()
        defaults.set("\(lab)///", forKey: defaultsKey)
        #expect(DeveloperRelay.current(defaults: defaults, environment: [:])?.absoluteString == lab)
    }

    @Test("the gesture writes the default and removes the key again")
    func toggleWritesAndClears() {
        let defaults = makeDefaults()
        #expect(DeveloperRelay.toggle(defaults: defaults, environment: [:]))
        #expect(defaults.string(forKey: defaultsKey) == lab)
        #expect(!DeveloperRelay.toggle(defaults: defaults, environment: [:]))
        #expect(defaults.string(forKey: defaultsKey) == nil)
        #expect(!DeveloperRelay.isEnabled(defaults: defaults, environment: [:]))
    }

    // MARK: - isDeveloperRelay

    @Test("a pairing recorded through the developer relay belongs to it")
    func pairingOnDeveloperRelay() {
        let defaults = makeDefaults()
        defaults.set("http://127.0.0.1:8791", forKey: defaultsKey)
        // Compared by origin: the room and any prefix are path.
        #expect(
            DeveloperRelay.isDeveloperRelay(
                "http://127.0.0.1:8791/r/ROOM",
                defaults: defaults,
                environment: [:],
            )
        )
        #expect(
            !DeveloperRelay.isDeveloperRelay(
                "https://dshmizar-1.shirazu-nagisa.com/r/ROOM",
                defaults: defaults,
                environment: [:],
            )
        )
        // With developer mode off, nothing belongs to a developer relay.
        #expect(
            !DeveloperRelay.isDeveloperRelay(
                "http://127.0.0.1:8791/r/ROOM",
                defaults: makeDefaults(),
                environment: [:],
            )
        )
    }

    // MARK: - Rewriting

    @Test("a pairing moves to the lab relay and keeps its room")
    func hostRewriteKeepsRoom() {
        let defaults = makeDefaults()
        let host = PairedHost(
            hostId: "h1",
            hostName: "mac",
            authority: "10.0.0.5:19390",
            deviceId: "d1",
            deviceToken: "mz_token",
            baseURL: "https://prod.example.com/r/ABC",
        )

        let moved = DeveloperRelay.rewriting(host, defaults: defaults, environment: [environmentKey: lab])

        #expect(moved.baseURL == "\(lab)/r/ABC")
        #expect(moved.deviceToken == host.deviceToken)
        #expect(moved.authority == host.authority)
        // Every relay route is derived from the base, so all of them moved --
        // including the punched route, whose signaling channel rides the same
        // room.
        let relays = moved.endpoints.compactMap { endpoint -> String? in
            switch endpoint {
            case .direct: return nil
            case .relay(let baseURL): return baseURL
            case .p2p(let baseURL, _): return baseURL
            }
        }
        #expect(!relays.isEmpty)
        #expect(relays.allSatisfy { $0.hasPrefix("\(lab)/r/ABC") })
        // Off by default: the same pairing is returned untouched.
        #expect(DeveloperRelay.rewriting(host, defaults: makeDefaults(), environment: [:]) == host)
    }

    @Test("a base with no room uses the room the caller knows")
    func rewriteFallsBackToRoom() {
        let rewritten = DeveloperRelay.rewriting(
            baseURL: "https://prod.example.com",
            to: URL(string: lab)!,
            room: "ABC",
        )
        #expect(rewritten == "\(lab)/r/ABC")
    }

    @Test("a relay route is rewritten and a direct route is not")
    func endpointRewrite() {
        let environment = [environmentKey: lab]
        let defaults = makeDefaults()
        #expect(
            DeveloperRelay.rewriting(.relay(baseURL: "https://prod.example.com/r/ABC"), defaults: defaults, environment: environment)
                == .relay(baseURL: "\(lab)/r/ABC"),
        )
        #expect(
            DeveloperRelay.rewriting(.p2p(relayBaseURL: "https://prod.example.com/r/ABC", endpointId: "key"), defaults: defaults, environment: environment)
                == .p2p(relayBaseURL: "\(lab)/r/ABC", endpointId: "key"),
        )
        #expect(
            DeveloperRelay.rewriting(.direct(authority: "10.0.0.5:19390"), defaults: defaults, environment: environment)
                == .direct(authority: "10.0.0.5:19390"),
        )
    }

    @Test("a pairing target is rewritten for the handshake only")
    func targetRewrite() {
        let target = PairingTarget(
            authority: "10.0.0.5:19390",
            code: "AB2C-D3EF",
            baseURL: "https://prod.example.com/r/ABC",
        )
        let dial = DeveloperRelay.rewriting(
            target,
            defaults: makeDefaults(),
            environment: [environmentKey: lab],
        )
        #expect(dial.baseURL == "\(lab)/r/ABC")
        #expect(dial.authority == target.authority)
        #expect(dial.code == target.code)
        #expect(target.baseURL == "https://prod.example.com/r/ABC")
    }

    // MARK: - Session header destination

    @Test("the developer origin may receive the session header")
    func developerOriginIsAccountHost() {
        let developerRelay = URL(string: "https://lab.example.com/lab")!
        #expect(AccountClient.isAccountHost("https://lab.example.com/lab/r/ABC", developerRelay: developerRelay))
        // Another origin is still refused, and an official origin still counts.
        #expect(!AccountClient.isAccountHost("https://other.example.com/r/ABC", developerRelay: developerRelay))
        #expect(AccountClient.isAccountHost("https://dshmizar-1.shirazu-nagisa.com", developerRelay: developerRelay))
        #expect(AccountClient.isAccountHost("https://dshmizar-1.shirazu-nagisa.com/r/ABCD", developerRelay: nil))
        // Developer mode off: the developer origin is not special.
        #expect(!AccountClient.isAccountHost("https://lab.example.com/lab/r/ABC", developerRelay: nil))
        #expect(!AccountClient.isAccountHost("https://dshmizar-0.example.com", developerRelay: developerRelay))
    }
}
