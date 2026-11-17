import Foundation
import Testing
@testable import MizarKit

@Suite("Activity routing and acknowledgements")
struct LiveActivityRoutingTests {
    @Test func destinationsKeepExactIdentity() throws {
        for target in [LiveActivityDestination.overview, .session(hostId: "a&b", sessionId: "same/会话"), .approval(hostId: "a", sessionId: "s", requestId: "x?y")] {
            #expect(LiveActivityDestination(url: target.url) == target)
        }
        #expect(LiveActivityDestination(url: URL(string: "dshmizar://activity/approval?host=a&session=s&request=x&request=y")!) == nil)
    }
    @Test func routingNeverProbesAnotherComputer() {
        let a = PairedHost(hostId: "a", hostName: "a", authority: nil, deviceId: "d", deviceToken: "test")
        let b = PairedHost(hostId: "b", hostName: "b", authority: nil, deviceId: "d", deviceToken: "test")
        #expect(LiveActivityAnswers.target(hostId: "a", hosts: [b, a]) == a)
        #expect(LiveActivityAnswers.target(hostId: "missing", hosts: [a, b]) == nil)
        #expect(LiveActivityAnswers.target(hostId: "", hosts: [a, b]) == nil)
        #expect(LiveActivityAnswers.target(hostId: "", hosts: [a]) == a)
    }
    @Test func aMissingAcknowledgementIsNotSuccess() throws {
        let missing = try JSONDecoder().decode(LiveActivityAnswers.Acceptance.self, from: Data("{}".utf8))
        #expect(missing.accepted != true)
    }

    @Test func selfHostedAnswerUsesGuestIdentityDespiteCachedOfficialAccount() {
        let identity = LiveActivityAnswers.ConnectionIdentity.resolve(
            clientId: "install-test",
            accountToken: "cached-official-token",
            accountId: "cached-official-account",
            serverSelection: ServerSelection(mode: .selfHosted, origin: "relay.example.invalid"),
        )

        #expect(identity.accountId == nil)
        #expect(identity.relayHeaders == [RelayIdentity.clientIdHeader: "install-test"])
    }

    @Test func officialAnswerKeepsAccountIdentity() {
        let identity = LiveActivityAnswers.ConnectionIdentity.resolve(
            clientId: "install-test",
            accountToken: "official-session-test",
            accountId: "official-account-test",
            serverSelection: .official,
        )

        #expect(identity.accountId == "official-account-test")
        #expect(identity.relayHeaders[RelayIdentity.clientIdHeader] == "install-test")
        #expect(identity.relayHeaders[RelayIdentity.accountHeader] != nil)
        #expect(identity.relayHeaders[RelayIdentity.sessionHeader] == "official-session-test")
    }

    @Test func answerFeedbackSeparatesAcceptedRejectionFromRefusedDecision() {
        let acceptedReject = LiveActivityApprovalFeedback.answerResult(.accepted, outcome: .rejected)
        let refused = LiveActivityApprovalFeedback.answerResult(.rejected, outcome: .rejected)
        let unknown = LiveActivityApprovalFeedback.answerResult(.unknown, outcome: .allowedOnce)

        #expect(acceptedReject.phase == .rejected)
        #expect(acceptedReject.message == String(localized: "Rejected"))
        #expect(refused.phase == .failed)
        #expect(refused.message == String(localized: "Request changed. Open details."))
        #expect(unknown.phase == .unknown)
    }

    @Test func genericActivityTitleDoesNotFallBackToApprovalText() {
        let row = LiveActivityRow(
            id: "session",
            prompt: "private command and path",
            title: "Waiting for approval",
            elapsed: 1,
            countingSince: Date(),
            status: .waitingApproval,
        )
        #expect(row.displayTitle == "Waiting for approval")
        #expect(!row.displayTitle.contains("private command"))
    }

    @Test func relaySessionCredentialIsScopedToOfficialAccountHost() {
        let headers = [
            RelayIdentity.clientIdHeader: "install-test",
            RelayIdentity.accountHeader: "account-hash-test",
            RelayIdentity.sessionHeader: "unit-session-only",
        ]
        let official = PairedHost(
            hostId: "host-1", hostName: "mac", authority: nil, deviceId: "d", deviceToken: "test",
            baseURL: "https://dshmizar-1.shirazu-nagisa.com:8443/tunnel/room",
        )
        let custom = PairedHost(
            hostId: "host-1", hostName: "mac", authority: nil, deviceId: "d", deviceToken: "test",
            baseURL: "https://relay.example.invalid/tunnel/room",
        )

        let officialHeaders = LiveActivityHostConnection.configurations(
            host: official, relayHeaders: headers, accountId: "account-id",
            routeSettings: .init(localNetworkFirst: true, directConnection: false),
        ).first?.relayHeaders
        let customHeaders = LiveActivityHostConnection.configurations(
            host: custom, relayHeaders: headers, accountId: "account-id",
            routeSettings: .init(localNetworkFirst: true, directConnection: false),
        ).first?.relayHeaders

        #expect(officialHeaders?[RelayIdentity.sessionHeader] == "unit-session-only")
        #expect(customHeaders?[RelayIdentity.sessionHeader] == nil)
        #expect(customHeaders?[RelayIdentity.accountHeader] == "account-hash-test")
    }

    @Test func directLiveActivityConnectionNeverCarriesRelayHeaders() {
        let host = PairedHost(
            hostId: "host-1", hostName: "mac", authority: "192.0.2.1:19390", deviceId: "d", deviceToken: "test",
        )
        let configuration = LiveActivityHostConnection.configurations(
            host: host,
            relayHeaders: [RelayIdentity.sessionHeader: "unit-session-only"],
            accountId: "account-id",
            routeSettings: .init(localNetworkFirst: true, directConnection: false),
        ).first

        #expect(configuration?.relayHeaders[RelayIdentity.sessionHeader] == nil)
        #expect(configuration?.subscribeToStateChanges == false)
    }

    @Test func localNetworkOffFiltersDirectRoutesButKeepsRelay() {
        let host = PairedHost(
            hostId: "host-1", hostName: "mac", authority: "10.0.0.1:19390", deviceId: "d", deviceToken: "test",
            baseURL: "https://relay.invalid/tunnel/a",
        )

        let configurations = LiveActivityHostConnection.configurations(
            host: host,
            relayHeaders: [:],
            accountId: nil,
            routeSettings: .init(localNetworkFirst: false, directConnection: false),
        )

        #expect(configurations.count == 1)
        #expect(configurations.first?.authority == nil)
        #expect(configurations.first?.baseURL == "https://relay.invalid/tunnel/a")
        #expect(configurations.first?.subscribeToStateChanges == false)
    }

    @Test func reachableLocalRouteGetsAHeadStartOverRelay() async throws {
        let direct = StubTransport { text in frameType(of: text) == "hello" ? [welcomeFrame()] : [] }
        let relay = StubTransport { text in frameType(of: text) == "hello" ? [welcomeFrame()] : [] }
        let host = PairedHost(
            hostId: "host-1", hostName: "mac", authority: "10.0.0.1:19390", deviceId: "d", deviceToken: "test",
            baseURL: "https://relay.invalid/tunnel/a",
        )

        let connection = await LiveActivityHostConnection.open(
            host: host,
            routeSettings: .init(localNetworkFirst: true, directConnection: false),
        ) { configuration in
            MizarConnection(configuration: configuration, makeTransport: {
                configuration.baseURL == nil ? direct : relay
            })
        }

        #expect(connection != nil)
        #expect(await direct.dialed.count == 1)
        #expect(await relay.dialed.isEmpty)
        #expect(!(await direct.sent).contains { $0.contains("state.subscribe") })
        await connection?.disconnect()
    }

    @Test func approvalSelectionSurvivesAnOlderRequestArrivingLater() {
        let selected = approval("selected", at: 20)
        let newlyArrivedOlder = approval("older", at: 10)

        #expect(LiveActivityApprovalSelection.reconciledId(
            currentId: selected.compositeId,
            previous: [selected],
            incoming: [newlyArrivedOlder, selected],
        ) == selected.compositeId)
    }

    @Test func approvalSelectionAdvancesThroughPreviousQueueWhenRemoved() {
        let first = approval("first", at: 10)
        let selected = approval("selected", at: 20)
        let next = approval("next", at: 30)
        let newlyArrivedOlder = approval("newer-arrival", at: 5)

        #expect(LiveActivityApprovalSelection.reconciledId(
            currentId: selected.compositeId,
            previous: [first, selected, next],
            incoming: [newlyArrivedOlder, next, first],
        ) == next.compositeId)
    }

    @Test func approvalSelectionStartsAtFirstObservedRequest() {
        let later = approval("later", at: 20)
        let first = approval("first", at: 10)

        #expect(LiveActivityApprovalSelection.reconciledId(
            currentId: nil,
            previous: [],
            incoming: [later, first],
        ) == first.compositeId)
    }
}

private func approval(_ id: String, at seconds: TimeInterval) -> LiveActivityApproval {
    LiveActivityApproval(
        requestId: id,
        sessionId: "session-\(id)",
        tool: "Bash",
        detail: "fixture",
        hostId: "host",
        requestedAt: Date(timeIntervalSince1970: seconds),
    )
}

private actor BlockedActivityRoute: WebSocketTransport {
    var pending: CheckedContinuation<Void, any Error>?
    var closed = false
    func connect(url: URL, headers: [String: String]) async throws {
        if closed { throw CancellationError() }
        try await withCheckedThrowingContinuation { pending = $0 }
    }
    func send(text: String) async throws { throw CancellationError() }
    func receive() async throws -> WebSocketFrame? { nil }
    func close() async { closed = true; pending?.resume(throwing: CancellationError()); pending = nil }
}

extension LiveActivityRoutingTests {
    @Test func unreachableLANDoesNotDelayWorkingRelay() async throws {
        let blocked = BlockedActivityRoute()
        let relay = StubTransport { text in frameType(of: text) == "hello" ? [welcomeFrame()] : [] }
        let host = PairedHost(hostId: "host-1", hostName: "mac", authority: "10.0.0.1:19390", deviceId: "d", deviceToken: "test", baseURL: "https://relay.invalid/tunnel/a")
        let clock = ContinuousClock()
        let start = clock.now
        let connection = await LiveActivityHostConnection.open(
            host: host,
            routeSettings: .init(localNetworkFirst: true, directConnection: false),
        ) { configuration in
            MizarConnection(configuration: configuration, makeTransport: { configuration.baseURL == nil ? blocked as any WebSocketTransport : relay as any WebSocketTransport })
        }
        #expect(connection != nil)
        #expect(start.duration(to: clock.now) < .seconds(1))
        #expect(await blocked.closed)
        #expect(!(await relay.sent).contains { $0.contains("state.subscribe") })
        await connection?.disconnect()
    }
}

extension LiveActivityRoutingTests {
    @Test func fourDesktopPayloadsStayInsideActivityBudget() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let rows = (0..<8).map { index in
            LiveActivityRow(id: "same-\(index)", prompt: "private prompt", title: String(repeating: "很长的中文会话标题👩🏽‍💻", count: 80), elapsed: 10,
                            countingSince: now, hostId: "host-\(index)", hostName: String(repeating: "设备", count: 60), status: .waitingApproval)
        }
        let approvals = rows.map { row in
            LiveActivityApproval(requestId: "approval-\(row.id)", sessionId: row.id, tool: "Bash", detail: String(repeating: "完整命令和路径", count: 400), hostId: row.hostId, hostName: row.hostName)
        }
        let state = LiveActivityState(rows: rows, approvals: approvals).boundedForActivity()
        #expect(try JSONEncoder().encode(state).count <= 3_500)
        #expect(state.totalCount == 8 && state.approvalCount == 8)
        #expect(state.rows.count <= 4 && state.approvals.count <= 4)
        for approval in state.approvals {
            #expect(approval.requiresDetail)
            #expect(approvals.contains { $0.compositeId == approval.compositeId && $0.sessionId == approval.sessionId })
        }
        #expect(!LiveActivityState(totalCount: 8, approvalCount: 8).isFinished)
    }
}

extension LiveActivityRoutingTests {
    @Test func approvalAndHostChangesOnUnchangedSessionsAreNeverSuppressed() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        func row(host: String, status: LiveActivitySessionStatus = .running) -> LiveActivityRow {
            .init(id: "same", prompt: "", title: "Task", elapsed: 10, countingSince: date, hostId: host, hostName: host, status: status)
        }
        let original = LiveActivityState(rows: [row(host: "a")])
        let pending = LiveActivityApproval(requestId: "r", sessionId: "same", tool: "Edit", detail: "File", hostId: "a")
        #expect(!original.hasSamePresentation(as: .init(rows: original.rows, approvals: [pending])))
        #expect(!original.hasSamePresentation(as: .init(rows: [row(host: "b")])))
        #expect(!original.hasSamePresentation(as: .init(rows: [row(host: "a", status: .waitingAnswer)])))
        #expect(original.hasSamePresentation(as: .init(rows: original.rows, revision: 100)))
    }
}
