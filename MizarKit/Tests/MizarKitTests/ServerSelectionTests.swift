//
//  ServerSelectionTests.swift
//  MizarKitTests
//
//  The address a person types and the origin the app dials.
//
//  The normaliser is load-bearing: a wrong answer here either dials a path the
//  relay does not serve, or -- worse -- falls back to an official relay for
//  somebody who asked for their own. Both are pinned below, along with the
//  three settings fields the guide and Settings write.
//

import Foundation
import Testing
@testable import MizarKit

@Suite("Server selection")
struct ServerSelectionTests {
    @Test("a fresh selection is the official server")
    func defaultsToOfficial() {
        let selection = ServerSelection()
        #expect(selection == .official)
        #expect(selection.mode == .official)
        #expect(!selection.isSelfHosted)
        #expect(selection.normalizedOrigin == nil)
    }

    @Test("normalises what an operator types into an https origin")
    func normalises() throws {
        let cases: [(String, String)] = [
            ("relay.example.com", "https://relay.example.com"),
            ("  relay.example.com  ", "https://relay.example.com"),
            ("relay.example.com/", "https://relay.example.com"),
            ("relay.example.com:8443", "https://relay.example.com:8443"),
            ("https://relay.example.com/", "https://relay.example.com"),
            ("https://Relay.Example.COM", "https://relay.example.com"),
            ("https://relay.example.com:8443/", "https://relay.example.com:8443"),
            ("HTTPS://relay.example.com", "https://relay.example.com"),
            ("https://[fd7a:115c:a1e0::1]:8443/", "https://[fd7a:115c:a1e0::1]:8443"),
        ]
        for (input, expected) in cases {
            let selection = ServerSelection(mode: .selfHosted, origin: input)
            #expect(selection.normalizedOrigin == expected, "input: \(input)")
        }
    }

    @Test("refuses anything that is not a bare https origin")
    func rejects() {
        let cases: [String] = [
            "",
            "   ",
            "http://relay.example.com",
            "ftp://relay.example.com",
            "https://",
            "https://relay.example.com/setup",
            "https://relay.example.com/healthz",
            "relay.example.com/path",
            "https://relay.example.com?pin=1",
            "https://relay.example.com#fragment",
            "https://user:pass@relay.example.com",
            "https://relay example.com",
        ]
        for input in cases {
            let selection = ServerSelection(mode: .selfHosted, origin: input)
            #expect(selection.normalizedOrigin == nil, "input: \(input)")
        }
    }

    @Test("the three settings fields round-trip as one selection")
    func settingsPersistSelection() {
        let storage = TestStorage()
        var settings = MizarSettings.load(from: storage)
        #expect(settings.serverSelection == .official)
        #expect(settings.serverMode == .official)
        #expect(settings.selfHostedOrigin.isEmpty)
        #expect(settings.selfHostedPin.isEmpty)

        settings.serverSelection = ServerSelection(
            mode: .selfHosted,
            origin: " relay.example.com ",
            pin: "K7QP-3M2X",
        )
        settings.save(to: storage)

        // The origin is trimmed on the way in, and the whole value survives a
        // second load -- the guide writes it in one process, the settings page
        // reads it in the next.
        #expect(storage.string(forKey: MizarSettings.serverModeKey) == "selfHosted")
        #expect(storage.string(forKey: MizarSettings.selfHostedOriginKey) == "relay.example.com")
        #expect(storage.string(forKey: MizarSettings.selfHostedPinKey) == "K7QP-3M2X")

        let reloaded = MizarSettings.load(from: storage)
        #expect(reloaded.serverSelection.mode == .selfHosted)
        #expect(reloaded.serverSelection.normalizedOrigin == "https://relay.example.com")
        #expect(reloaded.serverSelection.pin == "K7QP-3M2X")
        #expect(reloaded == settings)
    }

    @Test("an unknown stored mode reads as the official server")
    func unknownModeFallsBack() {
        let storage = TestStorage()
        storage.set("some-future-mode", forKey: MizarSettings.serverModeKey)
        #expect(MizarSettings.load(from: storage).serverMode == .official)
    }

    /// A store of this test's own, never `UserDefaults`.
    private final class TestStorage: SettingsStorage {
        private var values: [String: Bool] = [:]
        private var strings: [String: String] = [:]

        func bool(forKey key: String) -> Bool? { values[key] }
        func set(_ value: Bool, forKey key: String) { values[key] = value }
        func string(forKey key: String) -> String? { strings[key] }
        func set(_ value: String?, forKey key: String) { strings[key] = value }
    }
}

@Suite("Self-hosted relay tier", .serialized)
struct SelfHostedRelayTierTests {
    private let official = "https://dshmizar-1.shirazu-nagisa.com"

    @Test("a configured origin is the one the tunnel dials")
    func customOriginWins() {
        RelayTier.setCustomOrigin("https://relay.example.com")
        defer { RelayTier.setCustomOrigin(nil) }

        #expect(RelayTier.customOrigin == "https://relay.example.com")
        #expect(RelayTier.baseURL(paid: true) == "https://relay.example.com")
        #expect(RelayTier.baseURL(paid: false) == "https://relay.example.com")
        // The custom origin is not a public relay, not a paid one, and has no
        // alternate: a self-hosted room exists on exactly one server.
        #expect(RelayTier.isSelfHosted("https://relay.example.com/r/ROOM"))
        #expect(!RelayTier.isSelfHosted(official))
        #expect(!RelayTier.isPublicRelay("https://relay.example.com/r/ROOM"))
        #expect(!RelayTier.isPaidRelay("https://relay.example.com/r/ROOM"))
        #expect(RelayTier.alternate(to: "https://relay.example.com/r/ROOM") == nil)
    }

    @Test("clearing the origin restores the official relay")
    func clearingRestoresOfficial() {
        RelayTier.setCustomOrigin("https://relay.example.com")
        RelayTier.setCustomOrigin(nil)
        #expect(RelayTier.customOrigin == nil)
        #expect(RelayTier.baseURL(paid: false) == official)
        #expect(RelayTier.isPublicRelay(official))
        // An empty value is the same instruction as nil, so a settings page
        // cannot leave an unusable override behind.
        RelayTier.setCustomOrigin("   ")
        #expect(RelayTier.customOrigin == nil)
    }
}
