import Foundation
import Testing
@testable import MizarKit

@Suite("Live Activity host identity")
struct LiveActivityHostIdentityTests {
    private let unified = "https://dshmizar-1.shirazu-nagisa.com/r/room"
    private let paid8443 = "https://dshmizar-1.shirazu-nagisa.com:8443/r/room"
    private let headers = [
        RelayIdentity.clientIdHeader: "install-test",
        RelayIdentity.sessionHeader: "session-test",
    ]

    private func accountHost(
        hostId: String = "account-device",
        deviceId: String = "account-device",
        token: String = "credential-a",
        baseURL: String = "https://dshmizar-1.shirazu-nagisa.com/r/room",
    ) -> PairedHost {
        PairedHost(
            hostId: hostId,
            hostName: "Mac mini",
            authority: nil,
            deviceId: deviceId,
            deviceToken: token,
            baseURL: baseURL,
        )
    }

    @Test func bootstrapAcceptsOnlyOfficialAccountRelaysOn443Or8443() {
        for baseURL in [unified, paid8443, "https://dshmizar-1.shirazu-nagisa.com:443/r/room"] {
            let host = accountHost(baseURL: baseURL)
            #expect(
                LiveActivityHostIdentity.canBootstrap(
                    host: host,
                    endpoint: .relay(baseURL: baseURL),
                    accountId: "account-test",
                    relayHeaders: headers,
                ),
                "\(baseURL) should be the official account relay",
            )
        }

        let rejected = [
            "https://dshmizar-1.shirazu-nagisa.com:444/r/room",
            "http://dshmizar-1.shirazu-nagisa.com/r/room",
            "https://dshmizar.shirazu-nagisa.com/r/room",
            "https://relay.example.invalid/r/room",
            "https://user@dshmizar-1.shirazu-nagisa.com/r/room",
            "https://user:pass@dshmizar-1.shirazu-nagisa.com/r/room",
            "https://dshmizar-1.shirazu-nagisa.com/r/room?token=leak",
            "https://dshmizar-1.shirazu-nagisa.com/r/room#fragment",
        ]
        for baseURL in rejected {
            let host = accountHost(baseURL: baseURL)
            #expect(
                !LiveActivityHostIdentity.canBootstrap(
                    host: host,
                    endpoint: .relay(baseURL: baseURL),
                    accountId: "account-test",
                    relayHeaders: headers,
                ),
                "\(baseURL) must not be trusted for a first binding",
            )
        }
    }

    @Test func bootstrapRequiresAccountSessionAndMatchingPairingShape() {
        let host = accountHost()
        #expect(!LiveActivityHostIdentity.canBootstrap(
            host: host, endpoint: .relay(baseURL: unified), accountId: nil, relayHeaders: headers,
        ))
        #expect(!LiveActivityHostIdentity.canBootstrap(
            host: host, endpoint: .relay(baseURL: unified), accountId: "", relayHeaders: headers,
        ))
        #expect(!LiveActivityHostIdentity.canBootstrap(
            host: host, endpoint: .relay(baseURL: unified), accountId: "account-test", relayHeaders: [:],
        ))
        #expect(!LiveActivityHostIdentity.canBootstrap(
            host: host,
            endpoint: .relay(baseURL: unified),
            accountId: "account-test",
            relayHeaders: [RelayIdentity.sessionHeader: ""],
        ))

        let aliasPairing = accountHost(hostId: "pairing-alias", deviceId: "credential-device")
        #expect(!LiveActivityHostIdentity.canBootstrap(
            host: aliasPairing,
            endpoint: .relay(baseURL: unified),
            accountId: "account-test",
            relayHeaders: headers,
        ))

        #expect(!LiveActivityHostIdentity.canBootstrap(
            host: host,
            endpoint: .direct(authority: "10.0.0.1:19390"),
            accountId: "account-test",
            relayHeaders: headers,
        ))
        #expect(!LiveActivityHostIdentity.canBootstrap(
            host: host, endpoint: nil, accountId: "account-test", relayHeaders: headers,
        ))
    }

    @Test func pinIsFixedPerCredentialGenerationAndNotInheritedAfterRotation() async {
        let suite = "LiveActivityHostIdentityTests.\(UUID().uuidString)"
        let store = LiveActivityHostIdentityStore(suiteName: suite)
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }

        let host = accountHost()
        #expect(store.binding(for: host) == nil)
        #expect(await store.bind("canonical-a", to: host))
        #expect(store.binding(for: host)?.canonicalHostId == "canonical-a")
        #expect(!(await store.bind("canonical-b", to: host)))
        #expect(store.binding(for: host)?.canonicalHostId == "canonical-a")
        #expect(LiveActivityHostIdentity.resolvedHostId(
            for: host, binding: store.binding(for: host),
        ) == "canonical-a")

        let rotated = accountHost(token: "credential-b")
        #expect(store.binding(for: rotated) == nil)
        #expect(LiveActivityHostIdentity.resolvedHostId(
            for: rotated, binding: store.binding(for: rotated),
        ) == rotated.hostId)
        #expect(await store.bind("canonical-b", to: rotated))
        #expect(store.binding(for: rotated)?.canonicalHostId == "canonical-b")
        #expect(store.canonicalHostIds(for: [host]) == [host.hostId: "canonical-a"])
        #expect(store.canonicalHostIds(for: [rotated]) == [rotated.hostId: "canonical-b"])
    }

    @Test func metadataContainsOnlyPublicCanonicalIdAndOneWayKey() async {
        let suite = "LiveActivityHostIdentityTests.\(UUID().uuidString)"
        let token = "credential-must-never-appear-in-metadata"
        let store = LiveActivityHostIdentityStore(suiteName: suite)
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }

        let host = accountHost(token: token)
        #expect(await store.bind("canonical-a", to: host))
        let defaults = try! #require(UserDefaults(suiteName: suite))
        let entries = defaults.dictionaryRepresentation().filter {
            $0.key.hasPrefix("live.activity.host.identity.v1.")
        }
        #expect(entries.count == 1)
        #expect(entries.values.allSatisfy { ($0 as? String) == "canonical-a" })
        #expect(!entries.keys.contains { $0.contains(token) })
        #expect(!entries.values.contains { ($0 as? String)?.contains(token) == true })
        #expect(entries.keys.allSatisfy { $0.count == "live.activity.host.identity.v1.".count + 64 })
    }

    @Test func targetResolvesCanonicalOnlyThroughExactlyOneAuthorizedPairing() {
        let a = PairedHost(hostId: "alias-a", hostName: "Mac A", authority: nil, deviceId: "d-a", deviceToken: "t-a")
        let b = PairedHost(hostId: "alias-b", hostName: "Mac B", authority: nil, deviceId: "d-b", deviceToken: "t-b")
        let canonical = ["alias-a": "canonical-a"]

        #expect(LiveActivityAnswers.target(hostId: "alias-a", hosts: [a, b], canonicalHostIds: canonical) == a)
        #expect(LiveActivityAnswers.target(hostId: "canonical-a", hosts: [a, b], canonicalHostIds: canonical) == a)
        #expect(LiveActivityAnswers.target(hostId: "missing", hosts: [a, b], canonicalHostIds: canonical) == nil)
        #expect(LiveActivityAnswers.target(hostId: "", hosts: [a, b], canonicalHostIds: canonical) == nil)
        #expect(LiveActivityAnswers.target(hostId: "", hosts: [a], canonicalHostIds: canonical) == a)

        let shared = ["alias-a": "shared", "alias-b": "shared"]
        #expect(LiveActivityAnswers.target(hostId: "shared", hosts: [a, b], canonicalHostIds: shared) == nil)

        let collision = PairedHost(
            hostId: "canonical-a", hostName: "Collision", authority: nil, deviceId: "d-c", deviceToken: "t-c",
        )
        #expect(LiveActivityAnswers.target(
            hostId: "canonical-a", hosts: [a, collision], canonicalHostIds: canonical,
        ) == collision)

        let destination = LiveActivityDestination(url: URL(
            string: "dshmizar://activity/approval?host=canonical-a&session=s&request=r",
        )!)
        guard case let .approval(hostId, _, _) = destination else {
            Issue.record("approval destination did not round-trip")
            return
        }
        #expect(LiveActivityHostIdentity.resolvePairedHost(
            hostId: hostId, hosts: [a, b], canonicalHostIds: canonical,
        ) == a)
    }

    @Test func accountAndQRRecordsForSameMachinePreferExactHostId() {
        let qr = PairedHost(
            hostId: "physical-host",
            hostName: "Mac mini",
            authority: "10.0.0.1:19390",
            deviceId: "qr-device",
            deviceToken: "qr-token",
        )
        let account = PairedHost(
            hostId: "account-device-alias",
            hostName: "Mac mini",
            authority: nil,
            deviceId: "account-device",
            deviceToken: "account-token",
            baseURL: "https://dshmizar-1.shirazu-nagisa.com/r/room",
        )
        let bindings = ["account-device-alias": "physical-host"]

        // The account alias and the QR record are the same physical machine.
        // A canonical target must select the exact QR record, not become
        // ambiguous between two records for one computer.
        #expect(LiveActivityHostIdentity.resolvePairedHost(
            hostId: "physical-host", hosts: [account, qr], canonicalHostIds: bindings,
        ) == qr)
        #expect(LiveActivityAnswers.target(
            hostId: "physical-host", hosts: [account, qr], canonicalHostIds: bindings,
        ) == qr)

        // A legacy alias still resolves to its own exact pairing.
        #expect(LiveActivityHostIdentity.resolvePairedHost(
            hostId: "account-device-alias", hosts: [account, qr], canonicalHostIds: bindings,
        ) == account)

        // Two aliases and no exact record are still ambiguous.
        let secondAccount = PairedHost(
            hostId: "account-two",
            hostName: "Mac mini",
            authority: nil,
            deviceId: "account-two-device",
            deviceToken: "account-two-token",
            baseURL: "https://dshmizar-1.shirazu-nagisa.com/r/room",
        )
        #expect(LiveActivityHostIdentity.resolvePairedHost(
            hostId: "physical-host",
            hosts: [account, secondAccount],
            canonicalHostIds: [
                "account-device-alias": "physical-host",
                "account-two": "physical-host",
            ],
        ) == nil)
    }

    @Test func sessionCredentialOnlyGoesToOfficialAccountRelay() {
        let credentialHeaders = [
            RelayIdentity.clientIdHeader: "install-test",
            RelayIdentity.accountHeader: "account-hash-test",
            RelayIdentity.sessionHeader: "session-only",
        ]
        let settings = LiveActivityHostConnection.RouteSettings(localNetworkFirst: false, directConnection: false)

        func sessionHeader(at baseURL: String) -> String? {
            let host = accountHost(baseURL: baseURL)
            return LiveActivityHostConnection.configurations(
                host: host,
                relayHeaders: credentialHeaders,
                accountId: "account-test",
                routeSettings: settings,
            ).first?.relayHeaders[RelayIdentity.sessionHeader]
        }

        #expect(sessionHeader(at: unified) == "session-only")
        #expect(sessionHeader(at: paid8443) == "session-only")
        #expect(sessionHeader(at: "https://dshmizar-1.shirazu-nagisa.com:444/r/room") == nil)
        #expect(sessionHeader(at: "https://relay.example.invalid/r/room") == nil)
        #expect(sessionHeader(at: "http://dshmizar-1.shirazu-nagisa.com/r/room") == nil)
    }

    @Test func accountRelayPinsOnceAndRejectsChangedCanonical() async {
        let suite = "LiveActivityHostIdentityTests.\(UUID().uuidString)"
        let store = LiveActivityHostIdentityStore(suiteName: suite)
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }

        let host = accountHost(baseURL: unified)
        let settings = LiveActivityHostConnection.RouteSettings(localNetworkFirst: false, directConnection: false)

        func open(
            welcomeHostId: String,
            host: PairedHost,
            headers: [String: String],
        ) async -> MizarConnection? {
            await LiveActivityHostConnection.open(
                host: host,
                relayHeaders: headers,
                accountId: "account-test",
                routeSettings: settings,
                identityStore: store,
            ) { configuration in
                MizarConnection(configuration: configuration, makeTransport: {
                    StubTransport { text in
                        frameType(of: text) == "hello" ? [welcomeFrame(hostId: welcomeHostId)] : []
                    }
                })
            }
        }

        let first = await open(welcomeHostId: "canonical-a", host: host, headers: headers)
        #expect(first != nil)
        await first?.disconnect()
        #expect(store.binding(for: host)?.canonicalHostId == "canonical-a")

        let changed = await open(welcomeHostId: "canonical-b", host: host, headers: headers)
        #expect(changed == nil)
        #expect(store.binding(for: host)?.canonicalHostId == "canonical-a")

        let rotated = accountHost(token: "credential-b", baseURL: unified)
        let rebound = await open(welcomeHostId: "canonical-b", host: rotated, headers: headers)
        #expect(rebound != nil)
        await rebound?.disconnect()
        #expect(store.binding(for: rotated)?.canonicalHostId == "canonical-b")
    }

    @Test func directAndSelfHostedRoutesNeverBindACanonicalAlias() async {
        let suite = "LiveActivityHostIdentityTests.\(UUID().uuidString)"
        let store = LiveActivityHostIdentityStore(suiteName: suite)
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let relaySettings = LiveActivityHostConnection.RouteSettings(localNetworkFirst: false, directConnection: false)
        let directSettings = LiveActivityHostConnection.RouteSettings(localNetworkFirst: true, directConnection: true)

        func open(
            host: PairedHost,
            welcomeHostId: String,
            settings: LiveActivityHostConnection.RouteSettings,
        ) async -> MizarConnection? {
            await LiveActivityHostConnection.open(
                host: host,
                relayHeaders: headers,
                accountId: "account-test",
                routeSettings: settings,
                identityStore: store,
            ) { configuration in
                MizarConnection(configuration: configuration, makeTransport: {
                    StubTransport { text in
                        frameType(of: text) == "hello" ? [welcomeFrame(hostId: welcomeHostId)] : []
                    }
                })
            }
        }

        let direct = PairedHost(
            hostId: "direct-alias", hostName: "Mac direct", authority: "10.0.0.1:19390",
            deviceId: "direct-alias", deviceToken: "credential-a",
        )
        #expect(await open(host: direct, welcomeHostId: "canonical-direct", settings: directSettings) == nil)
        #expect(store.binding(for: direct) == nil)

        let selfHosted = accountHost(baseURL: "https://relay.example.invalid/r/room")
        #expect(await open(host: selfHosted, welcomeHostId: "canonical-self-hosted", settings: relaySettings) == nil)
        #expect(store.binding(for: selfHosted) == nil)
    }
}
