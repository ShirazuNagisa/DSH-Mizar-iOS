import Foundation
import os

private let liveActivityAnswerLog = Logger(subsystem: "me.shirazu.dshmizar", category: "live-activity")

public enum LiveActivityAnswers {
    struct Acceptance: Decodable, Sendable { let accepted: Bool? }
    public enum Result: Sendable, Equatable { case accepted, rejected, unavailable, unknown }

    struct ConnectionIdentity: Sendable, Equatable {
        let relayHeaders: [String: String]
        let accountId: String?

        static func resolve(
            clientId: String,
            accountToken: String?,
            accountId: String?,
            serverSelection: ServerSelection,
        ) -> Self {
            guard !serverSelection.isSelfHosted else {
                return Self(
                    relayHeaders: RelayIdentity.guest(clientId: clientId).headers,
                    accountId: nil,
                )
            }

            let identity = RelayIdentity(clientId: clientId, accountToken: accountToken)
            var headers = identity.headers
            headers.merge(identity.sessionHeaders) { _, new in new }
            return Self(relayHeaders: headers, accountId: accountId)
        }
    }

    /// Legacy cards are actionable only when their device identity is unambiguous.
    public static func target(hostId: String, hosts: [PairedHost]) -> PairedHost? {
        if hostId.isEmpty { return hosts.count == 1 ? hosts.first : nil }
        return hosts.first { $0.hostId == hostId }
    }

    public static func answer(requestId: String, hostId: String = "", sessionId: String = "", outcome: ApprovalOutcome) async -> Bool {
        await send(requestId: requestId, hostId: hostId, sessionId: sessionId, outcome: outcome) == .accepted
    }

    public static func send(requestId: String, hostId: String, sessionId: String, outcome: ApprovalOutcome) async -> Result {
        liveActivityAnswerLog.notice("answer intent started")
        guard !requestId.isEmpty, let hosts = try? await KeychainCredentialStore().loadAll(),
              let host = target(hostId: hostId, hosts: hosts) else { return .unavailable }
        let clock = ContinuousClock()
        let started = clock.now
        let account = KeychainAccountStore()
        let session = account.load()
        let identity = ConnectionIdentity.resolve(
            clientId: account.installId,
            accountToken: session?.token,
            accountId: session?.profile.id,
            serverSelection: MizarSettings.load(from: UserDefaultsSettingsStorage()).serverSelection,
        )
        guard let connection = await LiveActivityHostConnection.open(
            host: host,
            relayHeaders: identity.relayHeaders,
            accountId: identity.accountId,
        ) else {
            liveActivityAnswerLog.error("answer route unavailable; elapsed=\(String(describing: started.duration(to: clock.now)), privacy: .public)")
            return .unavailable
        }
        // Re-read before sending: a remotely resolved request must never act on
        // another request merely because it occupies the same presentation slot.
        guard let pending = try? await connection.call("interactions.pending", as: PendingInteractions.self) else {
            await connection.disconnect()
            return .unavailable
        }
        guard pending.approvals.contains(where: { $0.requestId == requestId && (sessionId.isEmpty || $0.sessionId == sessionId) }) else {
            await connection.disconnect()
            liveActivityAnswerLog.notice("answer preflight refused; elapsed=\(String(describing: started.duration(to: clock.now)), privacy: .public)")
            return .rejected
        }
        let result: Result
        do {
            let acceptance = try await connection.call("approval.answer", payload: .object([
                "requestId": .string(requestId), "outcome": .string(outcome.rawValue),
            ]), as: Acceptance.self)
            if let accepted = acceptance.accepted { result = accepted ? .accepted : .rejected }
            else { result = .unknown }
        } catch {
            // The request may have reached the desktop. Retrying automatically
            // would invent a decision from a lost acknowledgement.
            result = .unknown
        }
        await connection.disconnect()
        liveActivityAnswerLog.notice("answer completed; result=\(String(describing: result), privacy: .public) elapsed=\(String(describing: started.duration(to: clock.now)), privacy: .public)")
        return result
    }
}

#if os(iOS) && canImport(ActivityKit) && canImport(AppIntents)
import ActivityKit
import AppIntents

public struct AllowOnceIntent: LiveActivityIntent {
    @Parameter(title: "request") public var requestId: String
    @Parameter(title: "host") public var hostId: String
    @Parameter(title: "session") public var sessionId: String
    public init() { requestId = ""; hostId = ""; sessionId = "" }
    public init(requestId: String, hostId: String = "", sessionId: String = "") {
        self.requestId = requestId; self.hostId = hostId; self.sessionId = sessionId
    }
    public static var title: LocalizedStringResource { "Allow once" }
    public static var authenticationPolicy: IntentAuthenticationPolicy { .requiresLocalDeviceAuthentication }
    public func perform() async throws -> some IntentResult {
        await LiveActivityActionCoordinator.shared.answer(requestId: requestId, hostId: hostId, sessionId: sessionId, outcome: .allowedOnce)
        return .result()
    }
}
public struct RejectIntent: LiveActivityIntent {
    @Parameter(title: "request") public var requestId: String
    @Parameter(title: "host") public var hostId: String
    @Parameter(title: "session") public var sessionId: String
    public init() { requestId = ""; hostId = ""; sessionId = "" }
    public init(requestId: String, hostId: String = "", sessionId: String = "") {
        self.requestId = requestId; self.hostId = hostId; self.sessionId = sessionId
    }
    public static var title: LocalizedStringResource { "Reject" }
    public static var authenticationPolicy: IntentAuthenticationPolicy { .requiresLocalDeviceAuthentication }
    public func perform() async throws -> some IntentResult {
        await LiveActivityActionCoordinator.shared.answer(requestId: requestId, hostId: hostId, sessionId: sessionId, outcome: .rejected)
        return .result()
    }
}
public struct NextApprovalIntent: LiveActivityIntent {
    public init() {}
    public static var title: LocalizedStringResource { "Next approval" }
    public func perform() async throws -> some IntentResult {
        liveActivityAnswerLog.notice("next intent started")
        await LiveActivityActionCoordinator.shared.next()
        liveActivityAnswerLog.notice("next intent updated")
        return .result()
    }
}

private actor LiveActivityActionCoordinator {
    static let shared = LiveActivityActionCoordinator()
    private var busy = Set<String>()
    func answer(requestId: String, hostId: String, sessionId: String, outcome: ApprovalOutcome) async {
        let key = LiveActivityApproval(requestId: requestId, sessionId: sessionId, tool: "", detail: "", hostId: hostId).compositeId
        guard !busy.contains(key) else { return }
        var presentation = LiveActivityPresentationStore.read()
        if let feedback = presentation.feedback[key], [.accepted, .rejected, .unknown].contains(feedback.phase) { return }
        busy.insert(key)
        presentation.selectedApprovalId = key
        presentation.feedback[key] = .init(phase: .sending, message: String(localized: "Sending…"))
        LiveActivityPresentationStore.write(presentation)
        await LiveActivityCards.redraw()
        let result = await LiveActivityAnswers.send(requestId: requestId, hostId: hostId, sessionId: sessionId, outcome: outcome)
        await LiveActivityAnswerPresentation.record(
            requestId: requestId,
            hostId: hostId,
            outcome: outcome,
            result: result,
        )
        busy.remove(key)
    }
    func next() async {
        for activity in Activity<DSHMizarActivityAttributes>.activities where activity.activityState == .active || activity.activityState == .stale {
            var presentation = LiveActivityPresentationStore.read()
            let approvals = activity.content.state.approvals.filter { approval in
                guard let feedback = presentation.feedback[approval.compositeId] else { return true }
                return feedback.phase != .accepted && feedback.phase != .rejected
            }
            guard approvals.count > 1 else { continue }
            let index = approvals.firstIndex { $0.compositeId == presentation.selectedApprovalId } ?? 0
            presentation.selectedApprovalId = approvals[(index + 1) % approvals.count].compositeId
            LiveActivityPresentationStore.write(presentation)
            break
        }
        await LiveActivityCards.redraw()
    }
}

public enum LiveActivityAnswerPresentation {
    public static func key(hostId: String, requestId: String) -> String {
        LiveActivityApproval(
            requestId: requestId,
            sessionId: "",
            tool: "",
            detail: "",
            hostId: hostId,
        ).compositeId
    }

    public static func record(
        requestId: String,
        hostId: String,
        outcome: ApprovalOutcome,
        result: LiveActivityAnswers.Result,
    ) async {
        let key = key(hostId: hostId, requestId: requestId)
        var presentation = LiveActivityPresentationStore.read()
        presentation.selectedApprovalId = key
        presentation.feedback[key] = LiveActivityApprovalFeedback.answerResult(result, outcome: outcome)
        presentation.feedback = presentation.feedback.filter { Date().timeIntervalSince($0.value.updatedAt) < 86_400 }
        LiveActivityPresentationStore.write(presentation)
        await LiveActivityCards.redraw()
        if result == .accepted {
            try? await Task.sleep(for: .milliseconds(850))
            await LiveActivityCards.dropApproval(requestId, hostId: hostId)
        }
    }
}

public enum LiveActivityCards {
    public static func redraw() async {
        for activity in Activity<DSHMizarActivityAttributes>.activities where activity.activityState == .active || activity.activityState == .stale {
            var state = activity.content.state
            state.presentationRevision += 1
            await activity.update(ActivityContent(state: state, staleDate: activity.content.staleDate))
        }
    }
    public static func dropApproval(_ requestId: String, hostId: String = "") async {
        for activity in Activity<DSHMizarActivityAttributes>.activities where activity.activityState == .active || activity.activityState == .stale {
            var state = activity.content.state
            let removed = state.approvals.filter { $0.requestId == requestId && (hostId.isEmpty || $0.hostId == hostId) }
            guard !removed.isEmpty else { continue }
            state.approvals.removeAll { $0.requestId == requestId && (hostId.isEmpty || $0.hostId == hostId) }
            state.approvalCount = max(0, state.approvalCount - removed.count)
            state.presentationRevision += 1
            // A resolved approval does not prove that its turn finished. Leave
            // its session until an authoritative host snapshot says otherwise.
            await activity.update(ActivityContent(state: state, staleDate: nil))
        }
    }
}
#endif
