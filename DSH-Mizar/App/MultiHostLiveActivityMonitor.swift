import Foundation
import MizarKit

/// Reads every paired host without changing the app's selected connection.
///
/// Keep one monitor instance for the life of the app model so a host's turn
/// start survives subsequent `session.list` updates and temporary disconnects.
@MainActor
final class MultiHostLiveActivityMonitor {
    private struct HostSnapshot: Sendable {
        var rows: [LiveActivityRow]
        var approvals: [LiveActivityApproval]
        var turnStarts: [String: Date]
        var isOnline: Bool
    }

    private struct HostRefreshResult: Sendable {
        let hostId: String
        let snapshot: HostSnapshot?
        let registeredPayload: JSONValue?
        let registeredAt: Date?
    }

    /// `turnStartedAt` is additive and uses the session list's epoch-millisecond
    /// convention. Older hosts omit it; the in-memory fallback below then keeps
    /// a previously observed start stable across ordinary `updatedAt` changes.
    private struct MonitorSessionList: Decodable, Sendable { let items: [MonitorSessionRow] }

    private struct MonitorSessionRow: Decodable, Sendable {
        let sessionId: String
        let updatedAt: Double
        let running: Bool
        let blank: Bool
        let cwd: String?
        let origin: String?
        let title: String?
        let turnStartedAt: Double?

        var updatedDate: Date { Date(timeIntervalSince1970: updatedAt / 1_000) }
        var turnStartedDate: Date? { turnStartedAt.map { Date(timeIntervalSince1970: $0 / 1_000) } }
    }

    private var snapshots: [String: HostSnapshot] = [:]
    private var registeredPayloads: [String: JSONValue] = [:]
    private var registeredAt: [String: Date] = [:]
    private var authorizationRevision: UInt64 = 0
    private var revision = 0
    private var lastState: LiveActivityState?
    private var isRefreshing = false
    private var refreshWaiters: [CheckedContinuation<Void, Never>] = []

    init() {}

    /// Refresh every paired host and return the latest confirmed aggregate.
    ///
    /// `nil` means no host has supplied a confirmed snapshot yet; callers must
    /// keep their existing activity state in that case. Hosts that fail to
    /// connect retain their last rows and approvals, with rows marked offline.
    func refresh(
        hosts: [PairedHost],
        relayHeaders: [String: String],
        accountId: String?,
        routeSettings: LiveActivityHostConnection.RouteSettings,
    ) async -> LiveActivityState? {
        guard !isRefreshing else { return lastState }
        isRefreshing = true
        let refreshAuthorizationRevision = authorizationRevision
        defer {
            isRefreshing = false
            let waiters = refreshWaiters
            refreshWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }

        let hostIds = Set(hosts.map(\.hostId))
        snapshots = snapshots.filter { hostIds.contains($0.key) }
        registeredPayloads = registeredPayloads.filter { hostIds.contains($0.key) }
        registeredAt = registeredAt.filter { hostIds.contains($0.key) }

        if hosts.isEmpty {
            snapshots.removeAll()
            registeredPayloads.removeAll()
            registeredAt.removeAll()
            revision += 1
            let empty = LiveActivityState(revision: revision)
            lastState = empty
            return empty
        }

        let now = Date()
        let registrationPayload = Self.registrationPayload()
        let results = await withTaskGroup(of: HostRefreshResult.self, returning: [HostRefreshResult].self) { group in
            for host in hosts {
                let previous = snapshots[host.hostId]
                let lastRegisteredPayload = registeredPayloads[host.hostId]
                let lastRegisteredAt = registeredAt[host.hostId]
                let shouldRegister = registrationPayload.map { payload in
                    payload != lastRegisteredPayload || lastRegisteredAt == nil
                } ?? false
                group.addTask {
                    await Self.refreshHost(
                        host,
                        relayHeaders: relayHeaders,
                        accountId: accountId,
                        routeSettings: routeSettings,
                        registrationPayload: registrationPayload,
                        shouldRegister: shouldRegister,
                        now: now,
                        previous: previous,
                    )
                }
            }
            var completed: [HostRefreshResult] = []
            for await result in group { completed.append(result) }
            return completed
        }

        // Forget/unpair may happen while sockets are in flight. Their results
        // (including a completed push.register) belong to the old authorization.
        guard authorizationRevision == refreshAuthorizationRevision else { return lastState }

        for result in results {
            // A pairing may have been removed while this refresh was awaiting
            // network responses. Never let that late response restore its
            // snapshot or push-registration cache.
            guard hostIds.contains(result.hostId) else { continue }
            if let snapshot = result.snapshot {
                snapshots[result.hostId] = snapshot
                if let payload = result.registeredPayload {
                    registeredPayloads[result.hostId] = payload
                }
                if let date = result.registeredAt {
                    registeredAt[result.hostId] = date
                }
            } else if let previous = snapshots[result.hostId] {
                snapshots[result.hostId] = Self.offline(previous, asOf: now)
            }
        }

        let hasSuccessfulRead = results.contains { $0.snapshot != nil }
        let hasOfflineHost = results.contains { $0.snapshot == nil }
        guard hasSuccessfulRead || !snapshots.isEmpty else { return nil }

        let state = aggregate(hostCount: hosts.count)
        // An empty response from one reachable machine cannot prove that an
        // unreachable machine has no work when this process has never seen it.
        guard !(hasOfflineHost && state.rows.isEmpty && state.approvals.isEmpty) else {
            return nil
        }

        revision += 1
        let revised = LiveActivityState(
            rows: state.rows,
            approvals: state.approvals,
            totalCount: state.totalCount,
            deviceCount: state.deviceCount,
            approvalCount: state.approvalCount,
            longestRunningSince: state.longestRunningSince,
            revision: revision,
            presentationRevision: state.presentationRevision,
        )
        lastState = revised
        return revised
    }

    /// Drop one host's retained snapshot and registration cache immediately.
    /// The next aggregate is therefore incapable of displaying that host or
    /// treating its old registration payload as current.
    func forget(hostId: String) -> LiveActivityState {
        authorizationRevision &+= 1
        snapshots.removeValue(forKey: hostId)
        registeredPayloads.removeValue(forKey: hostId)
        registeredAt.removeValue(forKey: hostId)
        revision += 1
        let state = aggregate(hostCount: snapshots.count)
        let revised = LiveActivityState(
            rows: state.rows,
            approvals: state.approvals,
            totalCount: state.totalCount,
            deviceCount: state.deviceCount,
            approvalCount: state.approvalCount,
            longestRunningSince: state.longestRunningSince,
            revision: revision,
            presentationRevision: state.presentationRevision,
        )
        lastState = revised
        return revised
    }

    func forgetAll() -> LiveActivityState {
        authorizationRevision &+= 1
        snapshots.removeAll()
        registeredPayloads.removeAll()
        registeredAt.removeAll()
        revision += 1
        let state = LiveActivityState(revision: revision)
        lastState = state
        return state
    }

    /// Teardown uses this after invalidating cached state and before remote
    /// unregister, so an older in-flight `push.register` cannot win afterward.
    func waitForRefreshCompletion() async {
        guard isRefreshing else { return }
        await withCheckedContinuation { continuation in
            refreshWaiters.append(continuation)
        }
    }

    /// Best-effort removal of this phone's push endpoint from one host.
    /// Uses that host's own credentials and route; never falls through to the
    /// currently selected host when it cannot connect.
    static func unregisterPushRegistration(
        from host: PairedHost,
        relayHeaders: [String: String],
        accountId: String?,
        routeSettings: LiveActivityHostConnection.RouteSettings,
    ) async {
        guard let connection = await LiveActivityHostConnection.open(
            host: host,
            relayHeaders: relayHeaders,
            accountId: accountId,
            routeSettings: routeSettings,
        ) else { return }
        _ = try? await connection.call("push.unregister", as: PushUnregisterResult.self)
        await connection.disconnect()
    }

    private static func refreshHost(
        _ host: PairedHost,
        relayHeaders: [String: String],
        accountId: String?,
        routeSettings: LiveActivityHostConnection.RouteSettings,
        registrationPayload: JSONValue?,
        shouldRegister: Bool,
        now: Date,
        previous: HostSnapshot?,
    ) async -> HostRefreshResult {
        guard let connection = await LiveActivityHostConnection.open(
            host: host,
            relayHeaders: relayHeaders,
            accountId: accountId,
            routeSettings: routeSettings,
        ) else {
            return HostRefreshResult(hostId: host.hostId, snapshot: nil, registeredPayload: nil, registeredAt: nil)
        }
        guard let canonicalHostId = (await connection.currentState).welcome?.hostId,
              !canonicalHostId.isEmpty else {
            await connection.disconnect()
            return HostRefreshResult(hostId: host.hostId, snapshot: nil, registeredPayload: nil, registeredAt: nil)
        }

        do {
            async let sessionResult = connection.call("session.list", as: MonitorSessionList.self)
            async let pendingResult = connection.call("interactions.pending", as: PendingInteractions.self)
            let (sessionList, pending) = try await (sessionResult, pendingResult)
            var registeredPayloadValue: JSONValue?
            var registeredAtValue: Date?
            if shouldRegister, let registrationPayload,
               (try? await connection.call("push.register", payload: registrationPayload, as: PushRegistrationResult.self)) != nil {
                registeredPayloadValue = registrationPayload
                registeredAtValue = now
            }
            await connection.disconnect()
            let snapshot = makeSnapshot(
                host: host,
                canonicalHostId: canonicalHostId,
                sessions: sessionList.items,
                pending: pending,
                previous: previous,
                now: now,
            )
            return HostRefreshResult(
                hostId: host.hostId,
                snapshot: snapshot,
                registeredPayload: registeredPayloadValue,
                registeredAt: registeredAtValue,
            )
        } catch {
            await connection.disconnect()
            return HostRefreshResult(hostId: host.hostId, snapshot: nil, registeredPayload: nil, registeredAt: nil)
        }
    }

    private static func makeSnapshot(
        host: PairedHost,
        canonicalHostId: String,
        sessions: [MonitorSessionRow],
        pending: PendingInteractions,
        previous: HostSnapshot?,
        now: Date,
    ) -> HostSnapshot {
        let sessionsById = Dictionary(sessions.map { ($0.sessionId, $0) }, uniquingKeysWith: { _, newer in newer })
        let subagentIds = Set(sessions.filter { $0.origin == "subagent" }.map(\.sessionId))
        let approvalsBySession = Dictionary(grouping: pending.approvals.compactMap { approval -> (String, PendingApproval)? in
            guard let sessionId = approval.sessionId, !sessionId.isEmpty else { return nil }
            guard !subagentIds.contains(sessionId) else { return nil }
            return (sessionId, approval)
        }, by: { $0.0 }).mapValues { $0.map { $0.1 } }
        let questionsBySession = Dictionary(grouping: pending.questions.compactMap { question -> (String, PendingQuestion)? in
            guard let sessionId = question.sessionId, !sessionId.isEmpty else { return nil }
            guard !subagentIds.contains(sessionId) else { return nil }
            return (sessionId, question)
        }, by: { $0.0 }).mapValues { $0.map { $0.1 } }

        var activeIds = Set(sessions.filter { $0.running && $0.origin != "subagent" }.map(\.sessionId))
        activeIds.formUnion(approvalsBySession.keys)
        activeIds.formUnion(questionsBySession.keys)

        var turnStarts: [String: Date] = [:]
        var rows: [LiveActivityRow] = []
        for sessionId in activeIds {
            let session = sessionsById[sessionId]
            let approval = approvalsBySession[sessionId]?.min(by: Self.oldestApprovalFirst)
            let question = questionsBySession[sessionId]?.min(by: Self.oldestQuestionFirst)
            let status: LiveActivitySessionStatus = approval != nil
                ? .waitingApproval
                : question != nil ? .waitingAnswer : .running
            let since = session?.turnStartedDate
                ?? previous?.turnStarts[sessionId]
                ?? session?.updatedDate
                ?? approval.map { Date(timeIntervalSince1970: $0.requestedAt / 1_000) }
                ?? question.map { Date(timeIntervalSince1970: $0.requestedAt / 1_000) }
                ?? now
            let safeSince = min(since, now)
            turnStarts[sessionId] = safeSince
            let title = session?.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let safeTitle = title.flatMap { $0.isEmpty ? nil : $0 }
                ?? String(localized: approval == nil ? "Untitled session" : "Waiting for approval")
            let waitingSince: Date?
            switch status {
            case .waitingApproval:
                waitingSince = approval.map { Date(timeIntervalSince1970: $0.requestedAt / 1_000) }
            case .waitingAnswer:
                waitingSince = question.map { Date(timeIntervalSince1970: $0.requestedAt / 1_000) }
            case .running, .offline:
                waitingSince = nil
            }
            rows.append(LiveActivityRow(
                id: sessionId,
                prompt: "",
                title: safeTitle,
                elapsed: max(0, now.timeIntervalSince(safeSince)),
                countingSince: safeSince,
                hostId: canonicalHostId,
                hostName: host.displayName,
                status: status,
                waitingSince: waitingSince,
            ))
        }

        let approvals = pending.approvals.filter { !subagentIds.contains($0.sessionId ?? "") }.map { approval in
            let detail = approval.reasonText(preferring: Locale.current.identifier) ?? ""
            return LiveActivityApproval(
                requestId: approval.requestId,
                sessionId: approval.sessionId ?? "",
                tool: approval.toolName,
                detail: detail,
                hostId: canonicalHostId,
                hostName: host.displayName,
                requestedAt: Date(timeIntervalSince1970: approval.requestedAt / 1_000),
                requiresDetail: detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            )
        }.sorted(by: Self.oldestApprovalFirst)

        return HostSnapshot(
            rows: rows,
            approvals: approvals,
            turnStarts: turnStarts,
            isOnline: true,
        )
    }

    private static func offline(_ snapshot: HostSnapshot, asOf now: Date) -> HostSnapshot {
        let rows = snapshot.rows.map { row in
            LiveActivityRow(
                id: row.id,
                prompt: row.prompt,
                title: row.title,
                elapsed: max(row.elapsed, now.timeIntervalSince(row.countingSince)),
                countingSince: row.countingSince,
                hostId: row.hostId,
                hostName: row.hostName,
                status: .offline,
                waitingSince: row.waitingSince,
            )
        }
        // A cached approval may share the canonical host with a live row from
        // a narrower account scope. Keep it, but never let the mixed snapshot
        // present it as directly actionable without opening details.
        let approvals = snapshot.approvals.map { approval in
            LiveActivityApproval(
                requestId: approval.requestId,
                sessionId: approval.sessionId,
                tool: approval.tool,
                detail: approval.detail,
                hostId: approval.hostId,
                hostName: approval.hostName,
                requestedAt: approval.requestedAt,
                requiresDetail: true,
            )
        }
        return HostSnapshot(
            rows: rows,
            approvals: approvals,
            turnStarts: snapshot.turnStarts,
            isOnline: false,
        )
    }

    private func aggregate(hostCount: Int) -> LiveActivityState {
        let rows = Self.displayOrderedRows(Self.uniqueRows(in: snapshots))
        let approvals = Self.uniqueApprovals(in: snapshots).sorted(by: Self.oldestApprovalFirst)
        return LiveActivityState(
            rows: rows,
            approvals: approvals,
            totalCount: rows.count,
            deviceCount: Set(rows.map(\.hostId) + approvals.map(\.hostId)).count,
            approvalCount: approvals.count,
            longestRunningSince: rows.filter { $0.status == .running }.map(\.countingSince).min(),
            revision: revision,
        )
    }

    /// One physical host can have an account pairing and a QR pairing at the
    /// same time. Their rows share the canonical host ID, so deduplicate by
    /// canonical ID + session; a live snapshot wins over an offline cache.
    /// Non-overlapping cached rows from a narrower scope are deliberately kept.
    private static func uniqueRows(in snapshots: [String: HostSnapshot]) -> [LiveActivityRow] {
        var selected: [String: (row: LiveActivityRow, isOnline: Bool)] = [:]
        for alias in snapshots.keys.sorted() {
            guard let snapshot = snapshots[alias] else { continue }
            for row in snapshot.rows {
                let key = identityKey(hostId: row.hostId, itemId: row.id)
                if let current = selected[key] {
                    if snapshot.isOnline && !current.isOnline {
                        selected[key] = (row, true)
                    }
                } else {
                    selected[key] = (row, snapshot.isOnline)
                }
            }
        }
        return selected.keys.sorted().compactMap { selected[$0]?.row }
    }

    /// Approvals are keyed by canonical host ID + request ID. Keeping the
    /// online copy is what keeps a stale offline cache from doubling the
    /// approval count; an offline-only request remains visible with
    /// `requiresDetail` set by ``offline``.
    private static func uniqueApprovals(in snapshots: [String: HostSnapshot]) -> [LiveActivityApproval] {
        var selected: [String: (approval: LiveActivityApproval, isOnline: Bool)] = [:]
        for alias in snapshots.keys.sorted() {
            guard let snapshot = snapshots[alias] else { continue }
            for approval in snapshot.approvals {
                let key = identityKey(hostId: approval.hostId, itemId: approval.requestId)
                if let current = selected[key] {
                    if snapshot.isOnline && !current.isOnline {
                        selected[key] = (approval, true)
                    }
                } else {
                    selected[key] = (approval, snapshot.isOnline)
                }
            }
        }
        return selected.keys.sorted().compactMap { selected[$0]?.approval }
    }

    private static func identityKey(hostId: String, itemId: String) -> String {
        "\(hostId.utf8.count):\(hostId)\(itemId.utf8.count):\(itemId)"
    }

    private func stateIfAnyOffline() -> LiveActivityState? {
        guard !snapshots.isEmpty else { return nil }
        return aggregate(hostCount: snapshots.count)
    }

    private static func registrationPayload() -> JSONValue? {
        guard let token = PushRegistration.storedToken, !token.isEmpty else { return nil }
        var fields: [String: JSONValue] = [
            "token": .string(token),
            "platform": .string("ios"),
            "environment": .string(PushRegistration.environment),
            "locale": .string(PushRegistration.locale),
            "liveActivityVersion": .number(2),
            "liveActivityTokenObservedAt": .number(LiveActivityPushTokenStore.observedAt),
        ]
        if let token = LiveActivityPushTokenStore.stored() {
            fields["liveActivityToken"] = .string(token)
        }
        if let token = LiveActivityStartTokenStore.stored() {
            fields["liveActivityStartToken"] = .string(token)
        }
        return .object(fields)
    }

    static func displayOrderedRows(_ rows: [LiveActivityRow]) -> [LiveActivityRow] {
        rows.sorted { left, right in
            let leftPriority = statusPriority(left.status)
            let rightPriority = statusPriority(right.status)
            if leftPriority != rightPriority { return leftPriority < rightPriority }
            if left.status == .waitingApproval || left.status == .waitingAnswer {
                switch (left.waitingSince, right.waitingSince) {
                case let (leftDate?, rightDate?) where leftDate != rightDate:
                    return leftDate < rightDate
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                default:
                    break
                }
            }
            if left.status == .running, left.countingSince != right.countingSince {
                return left.countingSince < right.countingSince
            }
            return left.compositeId < right.compositeId
        }
    }

    private static func statusPriority(_ status: LiveActivitySessionStatus) -> Int {
        switch status {
        case .waitingApproval: 0
        case .waitingAnswer: 1
        case .running: 2
        case .offline: 3
        }
    }

    private static func oldestApprovalFirst(_ left: PendingApproval, _ right: PendingApproval) -> Bool {
        if left.requestedAt != right.requestedAt { return left.requestedAt < right.requestedAt }
        return left.requestId < right.requestId
    }

    private static func oldestApprovalFirst(_ left: LiveActivityApproval, _ right: LiveActivityApproval) -> Bool {
        let leftDate = left.requestedAt ?? .distantFuture
        let rightDate = right.requestedAt ?? .distantFuture
        if leftDate != rightDate { return leftDate < rightDate }
        return left.compositeId < right.compositeId
    }

    private static func oldestQuestionFirst(_ left: PendingQuestion, _ right: PendingQuestion) -> Bool {
        if left.requestedAt != right.requestedAt { return left.requestedAt < right.requestedAt }
        return left.callId < right.callId
    }
}
