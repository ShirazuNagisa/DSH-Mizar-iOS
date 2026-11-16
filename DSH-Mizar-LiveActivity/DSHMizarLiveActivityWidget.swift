import ActivityKit
import AppIntents
import MizarKit
import SwiftUI
import WidgetKit

struct DSHMizarLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DSHMizarActivityAttributes.self) { context in
            let presentation = LiveActivityPresentationStore.read()
            let approvals = orderedApprovals(context.state.approvals)
            let selected = selectedApproval(from: approvals, id: presentation.selectedApprovalId)
            LiveActivityCard(state: context.state, appearance: context.attributes.appearance)
                .widgetURL(LiveActivityLinks.card(state: context.state, selected: selected))
        } dynamicIsland: { context in
            let state = context.state
            let presentation = LiveActivityPresentationStore.read()
            let approvals = orderedApprovals(state.approvals)
            let selected = selectedApproval(from: approvals, id: presentation.selectedApprovalId)

            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    IslandSessionColumn(state: state)
                }
                .contentMargins(.top, 16)
                .contentMargins(.horizontal, 16)
                DynamicIslandExpandedRegion(.trailing) {
                    IslandSessionColumn(state: state, trailing: true)
                }
                .contentMargins(.top, 16)
                .contentMargins(.horizontal, 16)
                DynamicIslandExpandedRegion(.bottom) {
                    IslandBottom(state: state, presentation: presentation, approval: selected)
                }
                .contentMargins(.top, 0)
                .contentMargins(.bottom, 6)
                .contentMargins(.horizontal, 16)
            } compactLeading: {
                HStack(spacing: 3) {
                    IslandMark()
                    if state.totalCount > 1 { Text(verbatim: "\(state.totalCount)").font(.caption2.weight(.semibold)) }
                    if state.approvalCount > 0 { Circle().fill(.orange).frame(width: 4, height: 4) }
                }
            } compactTrailing: {
                CompactLongestRunning(state: state)
            } minimal: {
                IslandMark(diameter: 18)
            }
            .widgetURL(LiveActivityLinks.overview())
            .contentMargins(.vertical, 0, for: .expanded)
            .keylineTint(.white.opacity(0.25))
        }
    }
}

// MARK: - Layout sizing

/// Uses the system's preferred sizes to decide how much content fits. Text is
/// never scaled down to preserve a fixed number of rows.
private struct LiveActivityTypeScale {
    let category: UIContentSizeCategory

    private var traits: UITraitCollection {
        UITraitCollection(preferredContentSizeCategory: category)
    }

    private func font(_ style: UIFont.TextStyle) -> UIFont {
        UIFont.preferredFont(forTextStyle: style, compatibleWith: traits)
    }

    var sessionRowHeight: CGFloat {
        ceil(font(.footnote).lineHeight + font(.caption2).lineHeight)
    }

    var expandedIslandSessionRowHeight: CGFloat {
        max(20, ceil(max(font(.caption1).lineHeight, font(.caption2).lineHeight)))
    }

    var approvalHeaderHeight: CGFloat {
        max(44, ceil(font(.caption2).lineHeight + font(.footnote).lineHeight + 2))
    }

    var decisionHeight: CGFloat {
        max(44, ceil(font(.footnote).lineHeight + 20))
    }

    var runningHeaderHeight: CGFloat {
        max(24, ceil(font(.footnote).lineHeight + 4))
    }

    var approvalSessionCapacity: Int {
        let gridHeight = sessionRowHeight * 2
        let approvalHeight = approvalHeaderHeight + decisionHeight + 2
        if gridHeight + approvalHeight + 12 <= 160 { return 4 }
        if sessionRowHeight + approvalHeight + 12 <= 160 { return 2 }
        return 0
    }

    var expandedIslandShowsFourSessions: Bool {
        let approvalHeight = approvalHeaderHeight + decisionHeight
        let regionInsets: CGFloat = 22
        let sessionRowsHeight = expandedIslandSessionRowHeight * 2
        let totalHeight = sessionRowsHeight + approvalHeight + regionInsets
        return totalHeight <= 160
    }

    var runningCapacity: Int {
        let fixedHeight = runningHeaderHeight + 12
        for count in stride(from: 4, through: 1, by: -1) {
            if CGFloat(count) * sessionRowHeight + fixedHeight <= 160 { return count }
        }
        return 0
    }

    static func current(_ size: DynamicTypeSize) -> LiveActivityTypeScale {
        let category: UIContentSizeCategory = switch size {
        case .xSmall: .extraSmall
        case .small: .small
        case .medium: .medium
        case .large: .large
        case .xLarge: .extraLarge
        case .xxLarge: .extraExtraLarge
        case .xxxLarge: .extraExtraExtraLarge
        case .accessibility1: .accessibilityMedium
        case .accessibility2: .accessibilityLarge
        case .accessibility3: .accessibilityExtraLarge
        case .accessibility4: .accessibilityExtraExtraLarge
        case .accessibility5: .accessibilityExtraExtraExtraLarge
        @unknown default: .large
        }
        return LiveActivityTypeScale(category: category)
    }
}

// MARK: - Shared content and presentation helpers

private func orderedApprovals(_ approvals: [LiveActivityApproval]) -> [LiveActivityApproval] {
    let presentation = LiveActivityPresentationStore.read()
    return approvals.filter { approval in
        guard let feedback = presentation.feedback[approval.compositeId],
              feedback.phase == .accepted || feedback.phase == .rejected else { return true }
        return Date().timeIntervalSince(feedback.updatedAt) < 0.85
    }.sorted {
        let left = $0.requestedAt ?? .distantPast
        let right = $1.requestedAt ?? .distantPast
        if left != right { return left < right }
        return $0.compositeId < $1.compositeId
    }
}

private func selectedApproval(
    from approvals: [LiveActivityApproval],
    id: String?,
) -> LiveActivityApproval? {
    guard !approvals.isEmpty else { return nil }
    if let id, let match = approvals.first(where: { $0.compositeId == id }) { return match }
    return approvals.first
}

private func visibleRows(_ state: LiveActivityState) -> [LiveActivityRow] {
    state.rows
}

/// Similar leading titles on the same device switch together to middle
/// truncation so the distinguishing suffix can remain visible. Identical
/// titles stay identical; their links still carry the exact session identity.
private func sessionTitleTruncationMode(
    for row: LiveActivityRow,
    among visibleRows: [LiveActivityRow],
) -> Text.TruncationMode {
    let title = row.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    guard !title.isEmpty else { return .tail }
    let titleCharacters = Array(title)
    let collides = visibleRows.contains { peer in
        guard peer.hostId == row.hostId, peer.id != row.id else { return false }
        let peerTitle = peer.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        guard !peerTitle.isEmpty, peerTitle != title else { return false }
        let sharedPrefix = zip(titleCharacters, Array(peerTitle)).prefix { $0 == $1 }.count
        return sharedPrefix >= 5
    }
    return collides ? .middle : .tail
}

private enum LiveActivityLinks {
    static func overview() -> URL { LiveActivityDestination.overview.url }

    static func session(_ row: LiveActivityRow) -> URL {
        guard !row.hostId.isEmpty, !row.id.isEmpty else { return overview() }
        return LiveActivityDestination.session(hostId: row.hostId, sessionId: row.id).url
    }

    static func approval(_ approval: LiveActivityApproval) -> URL {
        guard !approval.hostId.isEmpty,
              !approval.sessionId.isEmpty,
              !approval.requestId.isEmpty
        else { return overview() }
        return LiveActivityDestination.approval(
            hostId: approval.hostId,
            sessionId: approval.sessionId,
            requestId: approval.requestId,
        ).url
    }

    static func card(state: LiveActivityState, selected: LiveActivityApproval? = nil) -> URL {
        if let selected { return approval(selected) }
        return overview()
    }
}

private extension Text {
    static func localized(_ key: String) -> Text {
        Text(verbatim: NSLocalizedString(key, bundle: .main, comment: ""))
    }
}

private extension String {
    static func localized(_ key: String) -> String {
        NSLocalizedString(key, bundle: .main, comment: "")
    }
}

private struct LiveActivityPalette {
    let appearance: LiveActivityAppearance
    var isDark: Bool { appearance == .dark }
    var background: Color {
        isDark ? Color(red: 19 / 255, green: 31 / 255, blue: 61 / 255)
            : Color(red: 0.973, green: 0.984, blue: 0.996)
    }
    var ink: Color { isDark ? .white : Color(red: 8 / 255, green: 17 / 255, blue: 28 / 255) }
    var secondary: Color { isDark ? .white.opacity(0.72) : ink.opacity(0.62) }
    var accent: Color { isDark ? .white : Color(red: 60 / 255, green: 203 / 255, blue: 244 / 255) }
    var surface: Color { isDark ? .white.opacity(0.09) : .black.opacity(0.055) }
    var buttonInk: Color { isDark ? Color(red: 3 / 255, green: 20 / 255, blue: 31 / 255) : ink }
    static let island = LiveActivityPalette(appearance: .dark)
}

private struct IslandMark: View {
    var diameter: CGFloat = 16
    var body: some View {
        Image("MizarIcon")
            .resizable()
            .scaledToFit()
            .frame(width: diameter, height: diameter)
            .accessibilityLabel(Text(verbatim: "DSH-Mizar"))
    }
}

/// The timer stays isolated from accessibility; combining timer text with a
/// label can crash WidgetKit while it archives the rendered tree.
private struct ActivityClock: View {
    let since: Date
    var font: Font = .footnote.monospacedDigit().weight(.semibold)
    private let widest = "0:00:00"

    var body: some View {
        Text(verbatim: widest)
            .font(font)
            .lineLimit(1)
            .hidden()
            .overlay(alignment: .trailing) {
                Text(since, style: .timer)
                    .font(font)
                    .lineLimit(1)
            }
            .accessibilityHidden(true)
    }
}

/// Running and waiting sessions keep counting from the turn start. Offline
/// rows show the last elapsed value as a frozen sample rather than a live timer.
private struct SessionElapsed: View {
    let row: LiveActivityRow
    let font: Font

    var body: some View {
        if row.status == .offline {
            Text(verbatim: Self.format(row.elapsed))
                .font(font.monospacedDigit())
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityHidden(true)
        } else {
            ActivityClock(since: row.countingSince, font: font.monospacedDigit())
        }
    }

    private static func format(_ elapsed: TimeInterval) -> String {
        let totalSeconds = max(0, Int(elapsed))
        let seconds = totalSeconds % 60
        let minutes = totalSeconds / 60
        if minutes < 60 { return "\(minutes):\(String(format: "%02d", seconds))" }
        return "\(minutes / 60):\(String(format: "%02d", minutes % 60)):\(String(format: "%02d", seconds))"
    }
}

private struct CompactLongestRunning: View {
    let state: LiveActivityState

    var body: some View {
        if let since = state.longestRunningSince {
            ActivityClock(since: since, font: .caption.monospacedDigit().weight(.semibold))
                .accessibilityLabel(Text.localized("Longest running session"))
        } else if state.approvalCount > 0 {
            Image(systemName: "hand.raised.fill")
                .foregroundStyle(.orange)
                .accessibilityLabel(Text.localized("Approval waiting"))
        } else {
            Text(verbatim: "0")
                .font(.caption.weight(.semibold))
                .accessibilityLabel(Text.localized("No running sessions"))
        }
    }
}

private struct SessionSummary: View {
    let row: LiveActivityRow
    let palette: LiveActivityPalette
    var compact = false
    var linked = false
    var titleTruncationMode: Text.TruncationMode = .tail
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var statusText: String {
        switch row.status {
        case .running: .localized("Running")
        case .waitingApproval: .localized("Waiting for approval")
        case .waitingAnswer: .localized("Waiting for a reply")
        case .offline: .localized("Offline")
        }
    }

    private var title: String {
        let value = row.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? .localized("Untitled session") : value
    }

    @ViewBuilder
    var body: some View {
        if linked {
            Link(destination: LiveActivityLinks.session(row)) { summary }
                .buttonStyle(.plain)
                .accessibilityLabel(accessibilityLabel)
        } else {
            summary
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityLabel)
        }
    }

    private var summary: some View {
        Group {
            if compact {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 4) {
                        Image(systemName: statusSymbol)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(statusColor)
                            .accessibilityHidden(true)
                        Text(verbatim: title)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(palette.ink)
                            .lineLimit(1)
                            .truncationMode(titleTruncationMode)
                    }
                    HStack(spacing: 3) {
                        Text(verbatim: row.hostName)
                            .font(.caption2)
                            .foregroundStyle(palette.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .layoutPriority(1)
                    }
                }
            } else {
                HStack(spacing: 6) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(verbatim: title)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(palette.ink)
                            .lineLimit(1)
                            .truncationMode(titleTruncationMode)
                        Text(verbatim: [row.hostName, statusText].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption2)
                            .foregroundStyle(palette.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if row.status != .offline {
                        SessionElapsed(row: row, font: .body)
                            .foregroundStyle(palette.secondary)
                    } else {
                        SessionElapsed(row: row, font: .caption2)
                            .foregroundStyle(palette.secondary)
                    }
                }
            }
        }
        .padding(.horizontal, compact ? 5 : 6)
        .frame(maxWidth: .infinity, minHeight: LiveActivityTypeScale.current(dynamicTypeSize).sessionRowHeight, alignment: .leading)
        .background(compact ? Color.clear : palette.surface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .contentShape(Rectangle())
    }

    private var accessibilityLabel: Text {
        Text(verbatim: [title, row.hostName, statusText, String.localized(row.status == .offline ? "Last known elapsed" : "Elapsed time")]
            .filter { !$0.isEmpty }
            .joined(separator: ", "))
    }

    private var statusSymbol: String {
        switch row.status {
        case .running: "circle.fill"
        case .waitingApproval: "hand.raised.fill"
        case .waitingAnswer: "questionmark.circle.fill"
        case .offline: "wifi.slash"
        }
    }

    private var statusColor: Color {
        switch row.status {
        case .running: .green
        case .waitingApproval: .orange
        case .waitingAnswer: .yellow
        case .offline: palette.secondary
        }
    }
}

private struct IslandSessionSummary: View {
    let row: LiveActivityRow
    let state: LiveActivityState
    let titleTruncationMode: Text.TruncationMode
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var isSelected: Bool {
        let presentation = LiveActivityPresentationStore.read()
        let selected = selectedApproval(from: orderedApprovals(state.approvals), id: presentation.selectedApprovalId)
        return selected?.hostId == row.hostId && selected?.sessionId == row.id
    }
    var body: some View {
        Link(destination: LiveActivityLinks.session(row)) {
            HStack(spacing: 3) {
                Image(systemName: statusSymbol)
                    .font(.system(size: 8))
                    .foregroundStyle(statusColor)
                    .accessibilityHidden(true)
                Text(verbatim: row.displayTitle)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(titleTruncationMode)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(verbatim: row.hostName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: 44, alignment: .trailing)
                    .layoutPriority(1)
            }
            .frame(minHeight: LiveActivityTypeScale.current(dynamicTypeSize).expandedIslandSessionRowHeight, alignment: .leading)
            .background(isSelected ? Color.white.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: [row.displayTitle, row.hostName, row.status.rawValue].joined(separator: ", ")))
    }

    private var statusSymbol: String {
        switch row.status {
        case .running: "circle.fill"
        case .waitingApproval: "hand.raised.fill"
        case .waitingAnswer: "questionmark.circle.fill"
        case .offline: "wifi.slash"
        }
    }

    private var statusColor: Color {
        switch row.status {
        case .running: .green
        case .waitingApproval: .orange
        case .waitingAnswer: .yellow
        case .offline: Color.white.opacity(0.68)
        }
    }
}

private struct IslandSessionColumn: View {
    let state: LiveActivityState
    var trailing = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if LiveActivityTypeScale.current(dynamicTypeSize).expandedIslandShowsFourSessions {
            VStack(alignment: .leading, spacing: 0) {
                let rows = Array(visibleRows(state).prefix(4))
                let first = trailing ? 1 : 0
                if rows.indices.contains(first) {
                    IslandSessionSummary(
                        row: rows[first],
                        state: state,
                        titleTruncationMode: sessionTitleTruncationMode(for: rows[first], among: rows),
                    )
                }
                if rows.indices.contains(first + 2) {
                    IslandSessionSummary(
                        row: rows[first + 2],
                        state: state,
                        titleTruncationMode: sessionTitleTruncationMode(for: rows[first + 2], among: rows),
                    )
                }
            }
        } else if trailing {
            IslandCount(state: state)
        } else {
            IslandMark(diameter: 14)
        }
    }
}

private struct IslandCount: View {
    let state: LiveActivityState
    var body: some View {
        Text(verbatim: "\(state.totalCount)")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.white)
            .accessibilityLabel(Text.localized("Session count"))
    }
}

// MARK: - Approval

private struct ApprovalFeedbackView: View {
    let approval: LiveActivityApproval
    let presentation: LiveActivityPresentation
    let palette: LiveActivityPalette

    private var feedback: LiveActivityApprovalFeedback? {
        presentation.feedback[approval.compositeId]
    }

    private var label: String {
        guard let feedback else { return "" }
        switch feedback.phase {
        case .sending: return .localized("Sending approval")
        case .accepted: return .localized("Approval accepted")
        case .rejected: return .localized("Approval rejected")
        case .failed: return .localized("Approval failed")
        case .unknown: return .localized("Approval result unknown")
        }
    }

    var body: some View {
        if let feedback, feedback.phase != .accepted && feedback.phase != .rejected {
            Text(verbatim: [label, feedback.message].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.caption2)
                .foregroundStyle(feedback.phase == .failed ? .red : palette.secondary)
                .lineLimit(2)
        } else if let feedback {
            Text(verbatim: [label, feedback.message].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.caption2)
                .foregroundStyle(palette.secondary)
                .lineLimit(2)
        }
    }
}

private struct ApprovalBlock: View {
    let approval: LiveActivityApproval
    let approvals: [LiveActivityApproval]
    let state: LiveActivityState
    let presentation: LiveActivityPresentation
    let palette: LiveActivityPalette
    var compact = false
    @Environment(\.redactionReasons) private var redactionReasons

    private var selectedIndex: Int {
        approvals.firstIndex(where: { $0.compositeId == approval.compositeId }) ?? 0
    }

    private var feedback: LiveActivityApprovalFeedback? {
        presentation.feedback[approval.compositeId]
    }

    private var isSending: Bool { feedback?.phase == .sending }
    private var outcomeUnknown: Bool { feedback?.phase == .unknown }
    private var alreadyAnswered: Bool { feedback?.phase == .accepted || feedback?.phase == .rejected }
    private var staleRequest: Bool {
        guard feedback?.phase == .failed else { return false }
        let message = feedback?.message.lowercased() ?? ""
        return message.contains("changed") || message.contains("details") || message.contains("详情") || message.contains("已变")
    }
    private var mustViewDetails: Bool {
        approval.hostId.isEmpty || approval.sessionId.isEmpty || approval.requestId.isEmpty
            || approval.requiresDetail || staleRequest || session?.status == .offline || session == nil
            || approval.tool.isEmpty || approval.detail.isEmpty || redactionReasons.contains(.privacy)
    }
    private var canDecide: Bool {
        !mustViewDetails && !isSending && !outcomeUnknown && !alreadyAnswered
    }

    private var session: LiveActivityRow? {
        state.rows.first { $0.hostId == approval.hostId && $0.id == approval.sessionId }
    }

    private var contextText: String {
        [approval.tool, approval.detail].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            content(showDetails: mustViewDetails || outcomeUnknown, fitContext: !mustViewDetails && !outcomeUnknown)
            content(showDetails: true, fitContext: false)
        }
    }

    private func content(showDetails: Bool, fitContext: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 0 : 2) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: statusLabel)
                        .font(.caption2)
                        .foregroundStyle(feedback?.phase == .failed ? .red : palette.secondary)
                        .lineLimit(1)
                    Text(verbatim: feedback?.message ?? contextText)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(palette.ink)
                        .lineLimit(1)
                        .fixedSize(horizontal: fitContext, vertical: false)
                        .privacySensitive()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if state.approvalCount > state.approvals.count {
                    Link(destination: LiveActivityLinks.overview()) {
                        Text.localized("All approvals").font(.caption2.weight(.semibold))
                            .frame(width: 64, height: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                } else if approvals.count > 1 {
                    Button(intent: NextApprovalIntent()) {
                        HStack(spacing: 3) {
                            Text.localized("Next")
                            Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                        }
                        .font(.caption2.weight(.semibold))
                        .frame(width: 64, height: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text.localized("Next approval"))
                }
            }
            .frame(minHeight: 44)
            if showDetails {
                Link(destination: LiveActivityLinks.approval(approval)) {
                    decisionLabel("View approval", palette: palette, primary: true)
                }.buttonStyle(.plain)
            } else {
                HStack(spacing: 8) {
                    Button(intent: RejectIntent(requestId: approval.requestId, hostId: approval.hostId, sessionId: approval.sessionId)) {
                        decisionLabel("Reject", palette: palette, primary: false)
                    }.buttonStyle(.plain).disabled(!canDecide)
                    Button(intent: AllowOnceIntent(requestId: approval.requestId, hostId: approval.hostId, sessionId: approval.sessionId)) {
                        decisionLabel(isSending ? "Sending" : "Allow once", palette: palette, primary: true)
                    }.buttonStyle(.plain).disabled(!canDecide)
                }
            }
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusLabel: String {
        if let feedback {
            switch feedback.phase {
            case .sending: return String.localized("Sending approval")
            case .accepted: return String.localized("Approval accepted")
            case .rejected: return String.localized("Approval rejected")
            case .failed: return String.localized("Approval failed")
            case .unknown: return String.localized("Approval result unknown")
            }
        }
        var label = "\(String.localized("Approval")) \(selectedIndex + 1)/\(max(state.approvalCount, approvals.count))"
        if state.totalCount > state.rows.count { label += " · +\(state.totalCount - state.rows.count)" }
        return label
    }

    private func decisionLabel(_ key: String, palette: LiveActivityPalette, primary: Bool) -> some View {
        Text.localized(key)
            .font(.footnote.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(primary ? palette.accent : palette.surface, in: Capsule())
            .foregroundStyle(primary ? palette.buttonInk : palette.ink)
            .contentShape(Capsule())
    }
}

// MARK: - Lock Screen card

private struct LiveActivityCard: View {
    let state: LiveActivityState
    let appearance: LiveActivityAppearance
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var palette: LiveActivityPalette { LiveActivityPalette(appearance: appearance) }
    private var type: LiveActivityTypeScale { .current(dynamicTypeSize) }
    private var rows: [LiveActivityRow] { visibleRows(state) }
    private var approvals: [LiveActivityApproval] { orderedApprovals(state.approvals) }
    private var presentation: LiveActivityPresentation { LiveActivityPresentationStore.read() }
    private var approval: LiveActivityApproval? { selectedApproval(from: approvals, id: presentation.selectedApprovalId) }

    var body: some View {
        Group {
            if let approval {
                approvalSurface(approval)
            } else {
                runningSurface
            }
        }
        .foregroundStyle(palette.ink)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .activityBackgroundTint(palette.background)
        .activitySystemActionForegroundColor(palette.ink)
    }

    @ViewBuilder
    private func approvalSurface(_ approval: LiveActivityApproval) -> some View {
        let capacity = type.approvalSessionCapacity
        let gridRows = Array(rows.prefix(4))
        VStack(alignment: .leading, spacing: 0) {
            if capacity == 4 {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4)], spacing: 0) {
                    ForEach(gridRows, id: \.compositeId) { row in
                        SessionSummary(
                            row: row,
                            palette: palette,
                            compact: true,
                            titleTruncationMode: sessionTitleTruncationMode(for: row, among: gridRows),
                        )
                            .background(row.compositeId == sessionCompositeId(for: approval) ? palette.accent.opacity(0.18) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
                ApprovalBlock(approval: approval, approvals: approvals, state: state, presentation: presentation, palette: palette)
                    .padding(.top, 0)
            } else if capacity == 2 {
                HStack(spacing: 4) {
                    let selectedRows = state.approvalSurfaceRows(capacity: capacity, selectedApproval: approval)
                    ForEach(selectedRows, id: \.compositeId) { row in
                        SessionSummary(row: row, palette: palette, compact: true,
                                       titleTruncationMode: sessionTitleTruncationMode(for: row, among: selectedRows))
                            .background(row.compositeId == sessionCompositeId(for: approval) ? palette.accent.opacity(0.18) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
                ApprovalBlock(approval: approval, approvals: approvals, state: state, presentation: presentation, palette: palette)
                    .padding(.top, 0)
            } else {
                Text(verbatim: "\(String.localized("Approval waiting")) · \(state.approvalCount)")
                    .font(.footnote.weight(.semibold))
                    .lineLimit(2)
                    .padding(.horizontal, 6)
                detailLink(approval)
            }
        }
    }

    private var runningSurface: some View {
        let capacity = state.totalCount > type.runningCapacity ? max(0, type.runningCapacity - 2) : type.runningCapacity
        return VStack(alignment: .leading, spacing: 0) {
            if capacity == 0 {
                Text(verbatim: "\(state.totalCount) \(String.localized("Sessions"))")
                    .font(.caption2.weight(.semibold)).lineLimit(1)
                Link(destination: LiveActivityLinks.overview()) {
                    Text.localized("View overview")
                        .font(.footnote.weight(.semibold)).lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }.buttonStyle(.plain)
            } else {
            HStack(spacing: 6) {
                Image("MizarIcon")
                    .resizable().scaledToFit().frame(width: 16, height: 16)
                    .accessibilityHidden(true)
                Text(verbatim: "\(state.totalCount) \(String.localized("Sessions"))")
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 2)
                Text(verbatim: "\(state.deviceCount) \(String.localized("Devices"))")
                    .font(.caption2)
                    .foregroundStyle(palette.secondary)
                    .lineLimit(1)
            }
            .frame(minHeight: type.runningHeaderHeight)

            if capacity > 0 {
                let displayRows = Array(rows.prefix(capacity))
                ForEach(displayRows, id: \.compositeId) { row in
                    SessionSummary(row: row, palette: palette,
                                  titleTruncationMode: sessionTitleTruncationMode(for: row, among: displayRows))
                        .frame(minHeight: type.sessionRowHeight, alignment: .leading)
                }
            }
            let hiddenCount = max(0, state.totalCount - min(rows.count, capacity))
            if hiddenCount > 0 {
                Link(destination: LiveActivityLinks.overview()) {
                    Text(verbatim: capacity == 0
                         ? "\(state.totalCount) \(String.localized("Sessions")) · \(String.localized("View overview"))"
                         : "+\(hiddenCount) \(String.localized("More sessions")) · \(String.localized("View overview"))")
                        .font(.footnote.weight(.semibold))
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            }
        }
    }

    private func detailLink(_ approval: LiveActivityApproval) -> some View {
        Link(destination: LiveActivityLinks.approval(approval)) {
            Text.localized("View approval")
                .font(.footnote.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(palette.accent, in: Capsule())
                .foregroundStyle(palette.buttonInk)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func sessionCompositeId(for approval: LiveActivityApproval) -> String? {
        rows.first { $0.hostId == approval.hostId && $0.id == approval.sessionId }?.compositeId
    }
}

// MARK: - Expanded island

private struct IslandBottom: View {
    let state: LiveActivityState
    let presentation: LiveActivityPresentation
    let approval: LiveActivityApproval?
    private var palette: LiveActivityPalette { .island }
    private var rows: [LiveActivityRow] { visibleRows(state) }
    private var approvals: [LiveActivityApproval] { orderedApprovals(state.approvals) }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var type: LiveActivityTypeScale { .current(dynamicTypeSize) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if type.expandedIslandShowsFourSessions {
                if let approval {
                    ApprovalBlock(approval: approval, approvals: approvals, state: state, presentation: presentation, palette: palette, compact: true)
                } else if state.totalCount > rows.prefix(4).count {
                    overviewLink
                }
            } else {
                if let approval, type.sessionRowHeight < 65,
                   let selected = rows.first(where: { $0.hostId == approval.hostId && $0.id == approval.sessionId }) {
                    SessionSummary(row: selected, palette: palette, compact: true, linked: true,
                                   titleTruncationMode: sessionTitleTruncationMode(for: selected, among: rows))
                } else {
                    Text(verbatim: "\(state.totalCount) \(String.localized("Sessions")) · \(state.approvalCount) \(String.localized("Approval"))")
                        .font(.caption2.weight(.semibold)).lineLimit(1)
                }
                Link(destination: approval.map(LiveActivityLinks.approval) ?? LiveActivityLinks.overview()) {
                    Text.localized(approval == nil ? "View overview" : "View approval")
                        .font(.footnote.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
        .foregroundStyle(.white)
    }
    private var overviewLink: some View {
        Link(destination: LiveActivityLinks.overview()) {
            Text(verbatim: "+\(max(0, state.totalCount - rows.count)) \(String.localized("More sessions"))")
                .font(.caption2.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }.buttonStyle(.plain)
    }
}
