import SwiftUI
import MizarKit

struct LiveActivityDetailView: View {
    let destination: LiveActivityDestination
    let hosts: [PairedHost]
    let relayHeaders: [String: String]
    let accountId: String?
    let routeSettings: LiveActivityHostConnection.RouteSettings

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var snapshots: [String: HostSnapshot] = [:]
    @State private var path: [LiveActivityDestination] = []
    @State private var isLoading = true
    @State private var approvalStates: [String: ApprovalState] = [:]
    @State private var loadedKey: LoadKey?
    @State private var activeHostOperations = Set<String>()
    @State private var refreshingHosts = Set<String>()
    @State private var isVisible = false

    init(
        destination: LiveActivityDestination,
        hosts: [PairedHost],
        relayHeaders: [String: String],
        accountId: String?,
        routeSettings: LiveActivityHostConnection.RouteSettings,
    ) {
        self.destination = destination
        self.hosts = hosts
        self.relayHeaders = relayHeaders
        self.accountId = accountId
        self.routeSettings = routeSettings
    }

    private var loadKey: LoadKey {
        LoadKey(
            destination: destination,
            hosts: hosts,
            relayHeaders: relayHeaders,
            accountId: accountId,
            routeSettings: routeSettings,
        )
    }

    var body: some View {
        NavigationStack(path: $path) {
            page(for: destination)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
                .navigationDestination(for: LiveActivityDestination.self) { next in
                    page(for: next)
                }
        }
        .task(id: RefreshKey(loadKey: loadKey, isActive: scenePhase == .active)) {
            guard scenePhase == .active else {
                isVisible = false
                await disconnectIdleHosts()
                return
            }
            isVisible = true
            if loadedKey != loadKey {
                await disconnectIdleHosts()
                snapshots = [:]
                approvalStates = [:]
                isLoading = true
                await loadHosts()
                guard !Task.isCancelled else { return }
                loadedKey = loadKey
            }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(4))
                } catch {
                    break
                }
                guard !Task.isCancelled, scenePhase == .active else { break }
                await refreshHosts()
            }
        }
        .onDisappear {
            isVisible = false
            Task { await disconnectIdleHosts() }
        }
    }

    @ViewBuilder
    private func page(for destination: LiveActivityDestination) -> some View {
        switch destination {
        case .overview:
            overview
        case let .session(hostId, sessionId):
            sessionPage(hostId: hostId, sessionId: sessionId)
        case let .approval(hostId, sessionId, requestId):
            approvalPage(hostId: hostId, sessionId: sessionId, requestId: requestId)
        }
    }

    private var overview: some View {
        List {
            if isLoading && snapshots.isEmpty {
                ProgressView("Connecting to paired hosts…")
            }

            let active = hosts.flatMap { activityRows(for: $0, snapshot: snapshots[$0.hostId]) }.sorted { left, right in
                let a = left.approvals.isEmpty ? (left.questions.isEmpty ? 2 : 1) : 0
                let b = right.approvals.isEmpty ? (right.questions.isEmpty ? 2 : 1) : 0
                if a != b { return a < b }
                return (left.startedAt ?? .distantFuture) < (right.startedAt ?? .distantFuture)
            }
            ForEach(active) { row in
                Button { path.append(.session(hostId: row.host.hostId, sessionId: row.session.sessionId)) } label: {
                    SessionRowView(row: row)
                }.buttonStyle(.plain)
            }
            if active.isEmpty && !isLoading && !hosts.isEmpty {
                Text("No active sessions or pending requests")
                    .foregroundStyle(.secondary)
            }
            ForEach(hosts.filter { snapshots[$0.hostId]?.sessions == nil }) { host in
                Label(host.displayName, systemImage: "wifi.slash")
                    .foregroundStyle(.secondary)
            }

            if hosts.isEmpty {
                ContentUnavailableView(
                    "No paired hosts",
                    systemImage: "desktopcomputer",
                    description: Text("Pair a host to see its active sessions."),
                )
            }
        }
        .navigationTitle("Live Activity")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func sessionPage(hostId: String, sessionId: String) -> some View {
        let host = hosts.first { $0.hostId == hostId }
        let snapshot = snapshots[hostId]
        let row = snapshot?.sessions?.first { $0.sessionId == sessionId }
        let pendingApprovals = snapshot?.pending?.approvals.filter { $0.sessionId == sessionId } ?? []
        let pendingQuestions = snapshot?.pending?.questions.filter { $0.sessionId == sessionId } ?? []
        let context = snapshot?.messages[sessionId]?.conversationItems() ?? []

        return List {
            Section("Host") {
                Text(host.map(displayName(for:)) ?? "Host unavailable")
            }

            Section("Session") {
                Text(row?.title ?? String(localized: "Untitled session"))
                    .font(.headline)
                if let row, row.running {
                    if let start = runningStart(for: sessionId, in: snapshot) {
                        Label {
                            Text(start, style: .timer)
                                .monospacedDigit()
                        } icon: {
                            Image(systemName: "clock")
                        }
                        .foregroundStyle(.green)
                        .accessibilityLabel("Total elapsed time")
                    } else {
                        Label("Running · elapsed time unavailable", systemImage: "clock")
                            .foregroundStyle(.green)
                    }
                } else if row == nil && snapshot?.sessions == nil {
                    Text("Session status is unavailable while this host is offline.")
                        .foregroundStyle(.secondary)
                }
            }

            if !pendingApprovals.isEmpty {
                Section("Approvals") {
                    ForEach(pendingApprovals) { approval in
                        Button {
                            path.append(.approval(
                                hostId: hostId,
                                sessionId: sessionId,
                                requestId: approval.requestId,
                            ))
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(approval.toolName)
                                    .font(.headline)
                                Text(approval.reasonText(preferring: Locale.current.language.languageCode?.identifier ?? "en") ?? "Reason not provided")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if !pendingQuestions.isEmpty {
                Section("Questions") {
                    ForEach(pendingQuestions) { question in
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Waiting for an answer")
                                .font(.headline)
                            ForEach(question.questions) { item in
                                Text(item.question)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                }
            }

            Section("Recent session context") {
                if let snapshot, snapshot.messages[sessionId] != nil {
                    if context.isEmpty {
                        Text("No recent messages were returned.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(context.suffix(12)) { item in
                            ConversationItemView(item: item)
                        }
                    }
                } else if snapshot?.connection == nil {
                    Text("Session context is unavailable while this host is offline.")
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView("Loading recent messages…")
                }
            }
        }
        .navigationTitle(row?.title ?? String(localized: "Session"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func approvalPage(hostId: String, sessionId: String, requestId: String) -> some View {
        let host = hosts.first { $0.hostId == hostId }
        let snapshot = snapshots[hostId]
        let approval = snapshot?.pending?.approvals.first {
            $0.requestId == requestId && $0.sessionId == sessionId
        }
        let session = snapshot?.sessions?.first { $0.sessionId == sessionId }
        let context = Array((snapshot?.messages[sessionId]?.conversationItems() ?? []).suffix(12))
        let state = approvalStates[approvalKey(hostId: hostId, sessionId: sessionId, requestId: requestId)] ?? .ready

        return List {
            if isLoading && snapshot == nil {
                ProgressView("Connecting to host…")
            } else if host == nil {
                unavailableSection("This approval’s host is not available in the paired host list.")
            } else if snapshot?.connection == nil {
                unavailableSection("Host unavailable. This exact approval has not been redirected to another host.")
            } else if snapshot?.pending == nil {
                unavailableSection("Could not verify this approval with the host.")
            } else if approval == nil {
                Section {
                    Label("This request is no longer pending on this host.", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                }
            } else if let approval {
                Section("Approval request") {
                    detailField("Tool", value: approval.toolName)
                    detailField(
                        "Reason",
                        value: approval.reasonText(preferring: Locale.current.language.languageCode?.identifier ?? "en") ?? "No reason was supplied.",
                        privacySensitive: true,
                    )
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Requested")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(Date(timeIntervalSince1970: approval.requestedAt / 1_000), format: .dateTime.year().month().day().hour().minute().second())
                            .font(.body.monospacedDigit())
                    }
                    // PendingApproval has no command/arguments field in the current wire model.
                    Text("The host did not include command details in this approval record.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Session context · \(host.map(displayName(for:)) ?? "Host")") {
                    NavigationLink(value: LiveActivityDestination.session(hostId: hostId, sessionId: sessionId)) {
                        Text(session?.title ?? String(localized: "Untitled session")).font(.headline)
                    }
                    if session?.running == true, let start = runningStart(for: sessionId, in: snapshot) {
                        Label {
                            Text(start, style: .timer)
                                .monospacedDigit()
                        } icon: {
                            Image(systemName: "clock")
                        }
                        .foregroundStyle(.green)
                    }
                    if snapshot?.messages[sessionId] != nil {
                        if context.isEmpty {
                            Text("No recent messages were returned.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(Array(context)) { item in
                                ConversationItemView(item: item)
                            }
                        }
                    } else {
                        Text("Recent session messages are unavailable.")
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    approvalStatus(state)
                    switch state {
                    case .ready, .confirmedPending:
                        Button("Allow once", systemImage: "checkmark.shield") {
                            Task { await answer(hostId: hostId, sessionId: sessionId, requestId: requestId, outcome: .allowedOnce) }
                        }
                        .tint(.green)
                        Button("Reject", systemImage: "xmark.shield") {
                            Task { await answer(hostId: hostId, sessionId: sessionId, requestId: requestId, outcome: .rejected) }
                        }
                        .tint(.red)
                    case .unknownNeedsCheck, .notAccepted, .checkUnavailable:
                        Button("Recheck request status", systemImage: "arrow.clockwise") {
                            Task { await recheck(hostId: hostId, sessionId: sessionId, requestId: requestId) }
                        }
                    case .sending, .accepted, .rejected, .handled:
                        EmptyView()
                    }
                } footer: {
                    Text("Opening this screen never makes a decision. Allow once grants only this request.")
                }
            }
        }
        .navigationTitle("Approval")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func unavailableSection(_ message: String) -> some View {
        Section {
            Label(message, systemImage: "exclamationmark.circle")
                .foregroundStyle(.secondary)
        }
    }

    private func detailField(_ title: String, value: String, privacySensitive: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .privacySensitive(privacySensitive)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private func approvalStatus(_ state: ApprovalState) -> some View {
        switch state {
        case .ready:
            EmptyView()
        case .sending:
            HStack { ProgressView(); Text("Sending decision…") }
        case .accepted:
            Label("Host accepted the decision.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .rejected:
            Label("Rejected", systemImage: "xmark.circle")
                .foregroundStyle(.secondary)
        case .notAccepted:
            Label("Host did not accept the decision.", systemImage: "xmark.circle")
                .foregroundStyle(.secondary)
        case .handled:
            Label("This request is no longer pending on this host.", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        case .unknownNeedsCheck:
            Label("The acknowledgement was unknown. Recheck before deciding whether to retry.", systemImage: "questionmark.circle")
                .foregroundStyle(.orange)
        case .confirmedPending:
            Label("The request is still pending. You may explicitly retry your decision.", systemImage: "exclamationmark.circle")
                .foregroundStyle(.orange)
        case .checkUnavailable:
            Label("Could not recheck the request. No decision was resent.", systemImage: "wifi.exclamationmark")
                .foregroundStyle(.orange)
        }
    }

    private func activityRows(for host: PairedHost, snapshot: HostSnapshot?) -> [ActivityRow] {
        guard let snapshot, let sessions = snapshot.sessions else { return [] }
        let approvals = snapshot.pending?.approvals ?? []
        let questions = snapshot.pending?.questions ?? []
        return sessions
            .filter { row in
                !row.isSubagent && (row.running
                    || approvals.contains(where: { $0.sessionId == row.sessionId })
                    || questions.contains(where: { $0.sessionId == row.sessionId }))
            }
            .map { row in
                ActivityRow(
                    host: host,
                    session: row,
                    approvals: approvals.filter { $0.sessionId == row.sessionId },
                    questions: questions.filter { $0.sessionId == row.sessionId },
                    startedAt: runningStart(for: row.sessionId, in: snapshot),
                )
            }
            .sorted { $0.session.updatedAt > $1.session.updatedAt }
    }

    private func runningStart(for sessionId: String, in snapshot: HostSnapshot?) -> Date? {
        if let startedAt = snapshot?.sessions?.first(where: { $0.sessionId == sessionId })?.turnStartedAt {
            return Date(timeIntervalSince1970: startedAt / 1_000)
        }
        guard let page = snapshot?.messages[sessionId],
              let running = page.conversationTurns().last(where: \.isRunning) else { return nil }
        return running.beganAt
    }

    private func displayName(for host: PairedHost) -> String {
        let label = host.label?.trimmingCharacters(in: .whitespacesAndNewlines)
        return label?.isEmpty == false ? label! : host.hostName
    }

    private func loadHosts() async {
        guard !hosts.isEmpty else { isLoading = false; return }
        await withTaskGroup(of: HostSnapshot.self) { group in
            for host in hosts {
                group.addTask {
                    await Self.readHost(
                        host,
                        relayHeaders: relayHeaders,
                        accountId: accountId,
                        routeSettings: routeSettings,
                        refreshSessionId: selectedDetailSessionId,
                    )
                }
            }
            for await snapshot in group {
                guard !Task.isCancelled else {
                    if let connection = snapshot.connection { await connection.disconnect() }
                    continue
                }
                snapshots[snapshot.host.hostId] = snapshot
            }
        }
        isLoading = false
    }

    private func refreshHosts() async {
        let candidates = hosts.filter {
            !activeHostOperations.contains($0.hostId)
        }
        guard !candidates.isEmpty else { return }
        let previous = snapshots
        await withTaskGroup(of: HostSnapshot.self) { group in
            for host in candidates {
                refreshingHosts.insert(host.hostId)
                group.addTask {
                    await Self.refreshHost(
                        host,
                        previous: previous[host.hostId],
                        relayHeaders: relayHeaders,
                        accountId: accountId,
                        routeSettings: routeSettings,
                        refreshSessionId: selectedDetailSessionId,
                    )
                }
            }
            for await snapshot in group {
                let hostId = snapshot.host.hostId
                let oldConnection = previous[hostId]?.connection
                refreshingHosts.remove(hostId)
                if !Task.isCancelled && !activeHostOperations.contains(hostId) {
                    snapshots[hostId] = snapshot
                    await disconnectReplacedConnection(oldConnection, with: snapshot.connection)
                } else {
                    await disconnectUncommittedConnection(snapshot.connection, keeping: oldConnection)
                }
                if !shouldKeepConnections {
                    await disconnectHost(hostId)
                }
            }
        }
    }

    private static func readHost(
        _ host: PairedHost,
        relayHeaders: [String: String],
        accountId: String?,
        routeSettings: LiveActivityHostConnection.RouteSettings,
        existingMessages: [String: SessionMessagesResult] = [:],
        previous: HostSnapshot? = nil,
        refreshSessionId: String? = nil,
    ) async -> HostSnapshot {
        guard let connection = await LiveActivityHostConnection.open(
            host: host,
            relayHeaders: relayHeaders,
            accountId: accountId,
            routeSettings: routeSettings,
        ) else {
            return HostSnapshot(host: host, connection: nil, sessions: nil, pending: nil, messages: [:])
        }

        return await withTaskCancellationHandler {
            async let sessions = try? await connection.call("session.list", as: SessionListResult.self)
            async let pending = try? await connection.call("interactions.pending", as: PendingInteractions.self)
            let (sessionResult, pendingResult) = await (sessions, pending)
            guard !Task.isCancelled else {
                await connection.disconnect()
                return HostSnapshot(host: host, connection: nil, sessions: nil, pending: nil, messages: [:])
            }

            return await snapshot(
                host: host,
                connection: connection,
                sessions: sessionResult?.items,
                pending: pendingResult,
                existingMessages: existingMessages,
                previousSessions: previous?.sessions,
                previousPending: previous?.pending,
                refreshSessionId: refreshSessionId,
            )
        } onCancel: {
            Task { await connection.disconnect() }
        }
    }

    private static func refreshHost(
        _ host: PairedHost,
        previous: HostSnapshot?,
        relayHeaders: [String: String],
        accountId: String?,
        routeSettings: LiveActivityHostConnection.RouteSettings,
        refreshSessionId: String?,
    ) async -> HostSnapshot {
        if let previous, let connection = previous.connection,
           case .ready = await connection.currentState {
            async let sessions = try? await connection.call("session.list", as: SessionListResult.self)
            async let pending = try? await connection.call("interactions.pending", as: PendingInteractions.self)
            let (sessionResult, pendingResult) = await (sessions, pending)
            guard !Task.isCancelled else { return previous }
            guard let sessionResult, let pendingResult else {
                return HostSnapshot(
                    host: host,
                    connection: connection,
                    sessions: nil,
                    pending: nil,
                    messages: previous.messages,
                )
            }
            return await snapshot(
                host: host,
                connection: connection,
                sessions: sessionResult.items,
                pending: pendingResult,
                existingMessages: previous.messages,
                previousSessions: previous.sessions,
                previousPending: previous.pending,
                refreshSessionId: refreshSessionId,
            )
        }

        return await readHost(
            host,
            relayHeaders: relayHeaders,
            accountId: accountId,
            routeSettings: routeSettings,
            existingMessages: previous?.messages ?? [:],
            previous: previous,
            refreshSessionId: refreshSessionId,
        )
    }

    private static func snapshot(
        host: PairedHost,
        connection: MizarConnection,
        sessions: [SessionRow]?,
        pending: PendingInteractions?,
        existingMessages: [String: SessionMessagesResult],
        previousSessions: [SessionRow]?,
        previousPending: PendingInteractions?,
        refreshSessionId: String?,
    ) async -> HostSnapshot {
        var messages = existingMessages
        if let sessions {
            let approvals = pending?.approvals ?? []
            let questions = pending?.questions ?? []
            let previousApprovals = previousPending?.approvals ?? []
            let previousQuestions = previousPending?.questions ?? []
            let missing = sessions.filter { row in
                guard !row.isSubagent,
                      row.running
                        || approvals.contains(where: { $0.sessionId == row.sessionId })
                        || questions.contains(where: { $0.sessionId == row.sessionId }) else { return false }
                let oldApprovals = previousApprovals.filter { $0.sessionId == row.sessionId }
                let newApprovals = approvals.filter { $0.sessionId == row.sessionId }
                let oldQuestions = previousQuestions.filter { $0.sessionId == row.sessionId }
                let newQuestions = questions.filter { $0.sessionId == row.sessionId }
                let previousUpdatedAt = previousSessions?.first { $0.sessionId == row.sessionId }?.updatedAt
                return messages[row.sessionId] == nil
                    || previousUpdatedAt != row.updatedAt
                    || oldApprovals != newApprovals
                    || oldQuestions != newQuestions
                    || refreshSessionId == row.sessionId
            }
            let requests = missing.map { row in
                (
                    id: row.sessionId,
                    method: "session.messages",
                    payload: JSONValue.object([
                        "sessionId": .string(row.sessionId),
                        "maxMessages": .number(40),
                    ]),
                )
            }
            let results = await connection.requestAll(requests, concurrency: 4)
            for row in missing {
                guard let value = results[row.sessionId]?.value,
                      let page = try? value.decoded(as: SessionMessagesResult.self) else { continue }
                messages[row.sessionId] = page
            }
        }
        return HostSnapshot(host: host, connection: connection, sessions: sessions, pending: pending, messages: messages)
    }

    private func answer(
        hostId: String,
        sessionId: String,
        requestId: String,
        outcome: ApprovalOutcome,
    ) async {
        let key = approvalKey(hostId: hostId, sessionId: sessionId, requestId: requestId)
        guard !activeHostOperations.contains(hostId) else { return }
        guard let connection = snapshots[hostId]?.connection else {
            approvalStates[key] = .checkUnavailable
            await recordAnswerPresentation(hostId: hostId, requestId: requestId, outcome: outcome, result: .unavailable)
            return
        }
        activeHostOperations.insert(hostId)
        defer { finishHostOperation(hostId) }

        approvalStates[key] = .sending
        let fresh: PendingInteractions
        do {
            fresh = try await connection.call("interactions.pending", as: PendingInteractions.self)
        } catch {
            approvalStates[key] = .checkUnavailable
            await recordAnswerPresentation(hostId: hostId, requestId: requestId, outcome: outcome, result: .unavailable)
            return
        }
        guard fresh.approvals.contains(where: { $0.requestId == requestId && $0.sessionId == sessionId }) else {
            approvalStates[key] = .handled
            updatePending(fresh, for: hostId)
            await recordAnswerPresentation(hostId: hostId, requestId: requestId, outcome: outcome, result: .rejected)
            return
        }
        updatePending(fresh, for: hostId)

        do {
            let result = try await connection.call(
                "approval.answer",
                payload: .object([
                    "requestId": .string(requestId),
                    "outcome": .string(outcome.rawValue),
                ]),
                as: AcceptanceResult.self,
            )
            guard result.accepted else {
                approvalStates[key] = .notAccepted
                await recordAnswerPresentation(hostId: hostId, requestId: requestId, outcome: outcome, result: .rejected)
                return
            }
            approvalStates[key] = outcome == .allowedOnce ? .accepted : .rejected
            await recordAnswerPresentation(hostId: hostId, requestId: requestId, outcome: outcome, result: .accepted)
            if let refreshed = try? await connection.call("interactions.pending", as: PendingInteractions.self) {
                updatePending(refreshed, for: hostId)
                if !refreshed.approvals.contains(where: { $0.requestId == requestId && $0.sessionId == sessionId }) {
                    approvalStates[key] = .handled
                }
            }
        } catch {
            approvalStates[key] = .unknownNeedsCheck
            await recordAnswerPresentation(hostId: hostId, requestId: requestId, outcome: outcome, result: .unknown)
        }
    }

    private func recheck(hostId: String, sessionId: String, requestId: String) async {
        let key = approvalKey(hostId: hostId, sessionId: sessionId, requestId: requestId)
        guard !activeHostOperations.contains(hostId) else { return }
        guard let connection = snapshots[hostId]?.connection else {
            approvalStates[key] = .checkUnavailable
            return
        }
        activeHostOperations.insert(hostId)
        defer { finishHostOperation(hostId) }
        do {
            let fresh = try await connection.call("interactions.pending", as: PendingInteractions.self)
            updatePending(fresh, for: hostId)
            approvalStates[key] = fresh.approvals.contains(where: {
                $0.requestId == requestId && $0.sessionId == sessionId
            }) ? .confirmedPending : .handled
        } catch {
            approvalStates[key] = .checkUnavailable
        }
    }

    private func updatePending(_ pending: PendingInteractions, for hostId: String) {
        guard var snapshot = snapshots[hostId] else { return }
        snapshot.pending = pending
        snapshots[hostId] = snapshot
    }

    private func recordAnswerPresentation(
        hostId: String,
        requestId: String,
        outcome: ApprovalOutcome,
        result: LiveActivityAnswers.Result,
    ) async {
        await LiveActivityAnswerPresentation.record(
            requestId: requestId,
            hostId: hostId,
            outcome: outcome,
            result: result,
        )
    }

    private var shouldKeepConnections: Bool {
        isVisible && scenePhase == .active
    }

    private var selectedDetailSessionId: String? {
        switch path.last ?? destination {
        case .overview: return nil
        case let .session(_, sessionId), let .approval(_, sessionId, _): return sessionId
        }
    }

    private func finishHostOperation(_ hostId: String) {
        activeHostOperations.remove(hostId)
        guard !shouldKeepConnections else { return }
        Task { await disconnectHost(hostId) }
    }

    private func disconnectIdleHosts() async {
        for hostId in Array(snapshots.keys) {
            await disconnectHost(hostId)
        }
    }

    private func disconnectHost(_ hostId: String) async {
        guard !activeHostOperations.contains(hostId), !refreshingHosts.contains(hostId),
              var snapshot = snapshots[hostId], let connection = snapshot.connection else { return }
        snapshot.connection = nil
        snapshots[hostId] = snapshot
        await connection.disconnect()
    }

    private func disconnectReplacedConnection(_ old: MizarConnection?, with new: MizarConnection?) async {
        guard let old else { return }
        if let new, old === new { return }
        await old.disconnect()
    }

    private func disconnectUncommittedConnection(_ new: MizarConnection?, keeping old: MizarConnection?) async {
        guard let new else { return }
        if let old, old === new { return }
        await new.disconnect()
    }

    private func approvalKey(hostId: String, sessionId: String, requestId: String) -> String {
        "\(hostId.utf8.count):\(hostId)\(sessionId.utf8.count):\(sessionId)\(requestId.utf8.count):\(requestId)"
    }
}

private struct LoadKey: Equatable {
    let destination: LiveActivityDestination
    let hosts: [PairedHost]
    let relayHeaders: [String: String]
    let accountId: String?
    let routeSettings: LiveActivityHostConnection.RouteSettings
}

private struct RefreshKey: Equatable {
    let loadKey: LoadKey
    let isActive: Bool
}

private struct HostSnapshot {
    let host: PairedHost
    var connection: MizarConnection?
    var sessions: [SessionRow]?
    var pending: PendingInteractions?
    var messages: [String: SessionMessagesResult]
}

private struct ActivityRow: Identifiable {
    let host: PairedHost
    let session: SessionRow
    let approvals: [PendingApproval]
    let questions: [PendingQuestion]
    let startedAt: Date?

    var id: String { "\(host.hostId.utf8.count):\(host.hostId)\(session.sessionId.utf8.count):\(session.sessionId)" }
}

private enum ApprovalState {
    case ready
    case sending
    case accepted
    case rejected
    case notAccepted
    case handled
    case unknownNeedsCheck
    case confirmedPending
    case checkUnavailable
}

private struct SessionRowView: View {
    let row: ActivityRow

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.session.title ?? String(localized: "Untitled session"))
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            HStack(spacing: 10) {
                Text(row.host.label?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? row.host.hostName)
                    .lineLimit(1)
                if row.session.running || !row.approvals.isEmpty || !row.questions.isEmpty {
                    if let startedAt = row.startedAt {
                        Text(startedAt, style: .timer)
                            .monospacedDigit()
                    } else {
                        Text("Running")
                    }
                }
                if !row.approvals.isEmpty {
                    Label("Approval", systemImage: "hand.raised.fill")
                        .foregroundStyle(.orange)
                }
                if !row.questions.isEmpty {
                    Label("Question", systemImage: "questionmark.circle.fill")
                        .foregroundStyle(.blue)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

private struct ConversationItemView: View {
    let item: ConversationItem

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(roleTitle)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(bodyText)
                .font(.subheadline)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }

    private var roleTitle: String {
        switch item {
        case .message(_, let role, _, _):
            switch role {
            case .user: "You"
            case .assistant: "Agent"
            case .system: "System"
            }
        case .failure: "Turn ended"
        case .notice: "Notice"
        }
    }

    private var bodyText: String {
        switch item {
        case .message(_, _, let text, _): text
        case .failure(_, let message, _): message
        case .notice(_, let text, _): text
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
