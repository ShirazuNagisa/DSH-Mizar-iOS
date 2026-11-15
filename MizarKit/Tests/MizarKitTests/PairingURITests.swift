//
//  PairingURITests.swift
//  MizarKitTests
//
//  The pairing URI is shared with the TypeScript side, so these tests mirror
//  `dsh/test/panel.test.ts` case for case. A disagreement between the two
//  implementations does not surface as an error — it silently dials the wrong
//  host — so both sides are pinned to the same expectations.
//

import Foundation
import Testing
@testable import MizarKit

@Suite("Pairing URI")
struct PairingURITests {
    @Test("round-trips every field")
    func roundTrip() throws {
        let uri = PairingURI.build(
            authority: "100.64.0.1:19390",
            code: "AB2C-D3EF",
            hostName: "shirazu-mac",
            protocolVersion: 1,
        )
        let text = try #require(uri)
        let target = try #require(PairingURI.parse(text))
        #expect(target.authority == "100.64.0.1:19390")
        #expect(target.code == "AB2C-D3EF")
        #expect(target.hostName == "shirazu-mac")
        #expect(target.protocolVersion == 1)
    }

    @Test("survives an IPv6 authority")
    func ipv6Authority() throws {
        let uri = PairingURI.build(
            authority: "[fd7a:115c:a1e0::1]:19390",
            code: "AB2C-D3EF",
            hostName: "mac",
            protocolVersion: 1,
        )
        let text = try #require(uri)
        let target = try #require(PairingURI.parse(text))
        #expect(target.authority == "[fd7a:115c:a1e0::1]:19390")
    }

    @Test("survives a host name needing escaping")
    func escapedHostName() throws {
        let uri = PairingURI.build(
            authority: "10.0.0.1:19390",
            code: "AB2C-D3EF",
            hostName: "Shirazu's MacBook Pro",
            protocolVersion: 1,
        )
        let text = try #require(uri)
        let target = try #require(PairingURI.parse(text))
        #expect(target.hostName == "Shirazu's MacBook Pro")
    }

    @Test("tolerates whitespace from a scanner")
    func scannerWhitespace() throws {
        let uri = PairingURI.build(
            authority: "10.0.0.1:19390",
            code: "AB2C-D3EF",
            hostName: "mac",
            protocolVersion: 1,
        )
        let text = try #require(uri)
        let target = try #require(PairingURI.parse("  \(text)\n"))
        #expect(target.authority == "10.0.0.1:19390")
    }

    @Test("rejects anything that is not a pairing URI")
    func rejectsForeignInput() {
        // A camera pointed at the wrong QR is a normal event, not an error.
        #expect(PairingURI.parse("https://example.com") == nil)
        #expect(PairingURI.parse("mizar://other?h=x&c=y") == nil)
        #expect(PairingURI.parse("") == nil)
    }

    @Test("rejects a URI missing the host or the code")
    func rejectsIncomplete() {
        #expect(PairingURI.parse("mizar://pair?c=AB2C") == nil)
        #expect(PairingURI.parse("mizar://pair?h=10.0.0.1:19390") == nil)
    }

    @Test("reports a missing or unparsable version as nil rather than a guess")
    func versionTolerance() {
        #expect(PairingURI.parse("mizar://pair?h=h&c=c")?.protocolVersion == nil)
        #expect(PairingURI.parse("mizar://pair?h=h&c=c&v=two")?.protocolVersion == nil)
    }

    @Test("builds the WebSocket URL from the authority")
    func webSocketURL() throws {
        let url = try #require(PairingURI.webSocketURL(authority: "100.64.0.1:19390"))
        #expect(url.absoluteString == "ws://100.64.0.1:19390/mizar/v1/ws")

        let secure = try #require(PairingURI.webSocketURL(authority: "100.64.0.1:19390", secure: true))
        #expect(secure.absoluteString == "wss://100.64.0.1:19390/mizar/v1/ws")
    }

    @Test("builds the HTTP URL from the authority")
    func httpURL() throws {
        let url = try #require(PairingURI.httpURL(authority: "10.0.0.1:19390", path: "/mizar/v1/pair"))
        #expect(url.absoluteString == "http://10.0.0.1:19390/mizar/v1/pair")
    }

    @Test("refuses an authority it cannot dial")
    func refusesBadAuthority() {
        #expect(PairingURI.webSocketURL(authority: "") == nil)
        #expect(PairingURI.webSocketURL(authority: "has spaces") == nil)
    }

    // MARK: - Relay

    @Test("carries a relay base URL alongside a direct authority")
    func relayWithDirect() throws {
        let uri = PairingURI.build(
            authority: "100.64.0.1:19390",
            code: "AB2C-D3EF",
            hostName: "shirazu-mac",
            protocolVersion: 1,
            baseURL: "https://relay.example.com/r/WBKW0NZVT5QZ",
        )
        let text = try #require(uri)
        let target = try #require(PairingURI.parse(text))
        #expect(target.authority == "100.64.0.1:19390")
        #expect(target.baseURL == "https://relay.example.com/r/WBKW0NZVT5QZ")
    }

    @Test("carries a relay with no direct authority at all")
    func relayOnly() throws {
        let uri = PairingURI.build(
            authority: "",
            code: "AB2C-D3EF",
            hostName: "shirazu-mac",
            protocolVersion: 1,
            baseURL: "https://relay.example.com/r/ROOM",
        )
        let text = try #require(uri)
        let target = try #require(PairingURI.parse(text))
        #expect(target.authority == nil)
        #expect(target.baseURL == "https://relay.example.com/r/ROOM")
    }

    @Test("refuses to build a URI with no address to dial")
    func refusesEmpty() {
        // A QR that scans and then fails, with nothing useful to say about why,
        // is worse than no QR at all.
        #expect(PairingURI.build(authority: "", code: "C", hostName: "n", protocolVersion: 1) == nil)
    }

    @Test("builds the old shape when there is no relay")
    func backwardCompatible() throws {
        let uri = try #require(
            PairingURI.build(authority: "10.0.0.1:1", code: "C", hostName: "n", protocolVersion: 1),
        )
        #expect(!uri.contains("u="))
        #expect(PairingURI.parse(uri)?.baseURL == nil)
    }

    @Test("parses a URI written before the relay existed")
    func parsesOld() {
        let target = PairingURI.parse("mizar://pair?h=10.0.0.1:19390&c=AB2C-D3EF&n=mac&v=1")
        #expect(target?.authority == "10.0.0.1:19390")
        #expect(target?.baseURL == nil)
    }

    @Test("refuses a relay scheme the client cannot dial")
    func refusesBadScheme() {
        // A scanned code is untrusted input from a camera, and this URL decides
        // where a device token gets sent.
        #expect(PairingURI.parse("mizar://pair?u=file:///etc/passwd&c=C&v=1") == nil)
        #expect(PairingURI.parse("mizar://pair?u=javascript:alert(1)&c=C&v=1") == nil)
        #expect(PairingURI.parse("mizar://pair?u=rdp://host/x&c=C&v=1") == nil)
    }

    @Test("refuses a URI with a code but no address")
    func refusesNoAddress() {
        #expect(PairingURI.parse("mizar://pair?c=AB2C-D3EF&n=mac&v=1") == nil)
    }

    @Test("accepts a plain http relay for a LAN or a test")
    func acceptsPlainHTTP() {
        #expect(PairingURI.parse("mizar://pair?u=http://127.0.0.1:8787/r/R&c=C&v=1")?.baseURL
            == "http://127.0.0.1:8787/r/R")
    }

    @Test("turns a relay base URL into its WebSocket URL")
    func relayWebSocket() {
        #expect(
            PairingURI.relayWebSocketURL(baseURL: "https://relay.example.com/r/ROOM")?.absoluteString
                == "wss://relay.example.com/r/ROOM/mizar/v1/ws",
        )
    }

    @Test("keeps the room in the relay WebSocket path")
    func relayWebSocketKeepsRoom() {
        // The room is what routes the request to the right computer; losing it would
        // produce a URL that connects to the relay and reaches nobody.
        let url = PairingURI.relayWebSocketURL(baseURL: "https://relay.example.com/r/WBKW0NZVT5QZ")
        #expect(url?.path.contains("/r/WBKW0NZVT5QZ/") == true)
    }

    @Test("builds the relay HTTP URL for pairing")
    func relayHTTP() {
        #expect(
            PairingURI.relayHTTPURL(baseURL: "https://relay.example.com/r/ROOM", path: "/mizar/v1/pair")?
                .absoluteString == "https://relay.example.com/r/ROOM/mizar/v1/pair",
        )
    }

    @Test("a relay-only target has no direct authority but does have a base URL")
    func relayOnlyTargetIsUsable() throws {
        // The gap this pins: the parser can understand `u` perfectly while the
        // pairing call never passes it on, which shows up only when something
        // tries to dial the relay. A simulator run against a relay-only QR is
        // what found it.
        let target = try #require(
            PairingURI.parse("mizar://pair?u=https://relay.example.com/r/ROOM&c=AB2C-D3EF&v=1"),
        )
        #expect(target.authority == nil)
        #expect(target.baseURL == "https://relay.example.com/r/ROOM")
        // Both legs must be constructible from the base URL alone, since that is
        // all a relay-only scan provides.
        #expect(PairingURI.relayHTTPURL(baseURL: try #require(target.baseURL), path: "/mizar/v1/pair") != nil)
        #expect(PairingURI.relayWebSocketURL(baseURL: try #require(target.baseURL)) != nil)
    }

    @Test("a discovered self-hosted computer builds the same URI a QR would carry")
    func selfHostedRoundTrip() throws {
        let target = try #require(PairingURI.selfHosted(
            origin: " https://relay.example.com/ ",
            room: "ROOM1",
            code: " K7QP-3M2X ",
            name: "Office Mac",
        ))
        #expect(target.baseURL == "https://relay.example.com/r/ROOM1")
        #expect(target.authority == nil)
        #expect(target.code == "K7QP-3M2X")
        #expect(target.hostName == "Office Mac")
        #expect(target.protocolVersion == 1)
        // The payload is what a QR carries, so the scanned path and the
        // discovered path cannot produce two different kinds of target.
        let rebuilt = try #require(PairingURI.build(
            authority: "",
            code: target.code,
            hostName: target.hostName ?? "",
            protocolVersion: 1,
            baseURL: target.baseURL,
        ))
        #expect(PairingURI.parse(rebuilt)?.baseURL == target.baseURL)
        #expect(PairingURI.parse(rebuilt)?.code == target.code)
    }

    @Test("a self-hosted URI without a name still parses")
    func selfHostedWithoutName() throws {
        let target = try #require(PairingURI.selfHosted(
            origin: "relay.example.com",
            room: "ROOM1",
            code: "123456",
            name: nil,
        ))
        #expect(target.hostName == nil)
        #expect(target.baseURL == "https://relay.example.com/r/ROOM1")
    }

    @Test("a room that is not one path segment, and an empty code, are refused")
    func selfHostedRejects() {
        #expect(PairingURI.selfHosted(origin: "relay.example.com", room: "", code: "123456", name: nil) == nil)
        #expect(PairingURI.selfHosted(origin: "relay.example.com", room: "ROOM/OTHER", code: "123456", name: nil) == nil)
        #expect(PairingURI.selfHosted(origin: "relay.example.com", room: "ROOM?x=1", code: "123456", name: nil) == nil)
        #expect(PairingURI.selfHosted(origin: "relay.example.com", room: "ROOM1", code: "  ", name: nil) == nil)
        #expect(PairingURI.selfHosted(origin: "http://relay.example.com", room: "ROOM1", code: "123456", name: nil) == nil)
    }
}
