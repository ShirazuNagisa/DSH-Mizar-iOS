import ActivityKit
import MizarKit
import SwiftUI
import UIKit
import WidgetKit

// The approved 2026-11-18 refinement draws one focus at a time: the session that
// has been running longest, or the request the operator is being asked about.
// The compact presentation is deliberately unchanged apart from its clock, which
// no longer reserves the width of a hidden "0:00:00".
//
// Every number below describes the leaf view's inset from the system shell. The
// shell owns the outer corner radius and the camera cut-out, so nothing here
// draws a second background or a second rounded shell behind them.

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
            let focus = IslandFocus(state: state, approval: selected, presentation: presentation)

            return DynamicIsland {
                // The inset is declared as padding on the content itself, never as
                // a region `contentMargins`: the margin form did not keep the leaf
                // view inside the system shell (the first glyph, the host name and
                // the last clock digit were all clipped by the shell's curve).
                // Padding on the content is measured against the region's own box,
                // so the system keeps its base inset and the text lands inside the
                // visible capsule.
                DynamicIslandExpandedRegion(.leading) {
                    IslandMark(diameter: IslandMetrics.brandSize)
                        .padding(.leading, IslandMetrics.horizontalInset)
                        .padding(.top, IslandMetrics.sideTopGap)
                }

                DynamicIslandExpandedRegion(.trailing) {
                    WidthLimitedContent { limitedWidth in
                        IslandTopTrailing(focus: focus, limitedWidth: limitedWidth)
                    }
                    .padding(.trailing, IslandMetrics.horizontalInset)
                    .padding(.top, IslandMetrics.sideTopGap)
                }

                DynamicIslandExpandedRegion(.bottom) {
                    WidthLimitedContent { limitedWidth in
                        IslandFocusBody(focus: focus, limitedWidth: limitedWidth)
                    }
                    .padding(.horizontal, IslandMetrics.horizontalInset)
                    .padding(.top, IslandMetrics.bodyTopGap)
                    .padding(.bottom, IslandMetrics.bottomInset)
                }
            } compactLeading: {
                // The system proposes a small leading slot and will compress a
                // flexible stack to nothing when the trailing clock is wide. The
                // approved composition is a fixed small mark plus a count, so
                // ask for exactly that width and keep it white on the black pill.
                HStack(spacing: 3) {
                    IslandMark()
                    if state.totalCount > 1 { Text(verbatim: "\(state.totalCount)").font(.caption2.weight(.semibold)) }
                    if state.approvalCount > 0 { Circle().fill(.orange).frame(width: 4, height: 4) }
                }
                .foregroundStyle(.white)
                .fixedSize(horizontal: true, vertical: false)
            } compactTrailing: {
                // The same system limited-width flag the expanded regions use:
                // when the capsule cannot afford the clock's digits, fall back
                // to a static signal instead of letting the timer be clipped.
                WidthLimitedContent { limitedWidth in
                    CompactLongestRunning(state: state, limitedWidth: limitedWidth)
                }
            } minimal: {
                IslandMinimal(state: state)
            }
            .widgetURL(LiveActivityLinks.overview())
            // The expanded island keeps the system's own margins: zeroing them and
            // re-adding the inset per region is what let the content drift outside
            // the shell. Only the compact trailing slot is normalized, so its clock
            // sits on the single 6 pt inset it asks for.
            .contentMargins(.trailing, 0, for: .compactTrailing)
            .keylineTint(.white.opacity(0.25))
        }
    }
}

// MARK: - Geometry

/// The one arc rhythm the approved refinement uses for both expanded states.
///
/// These are leaf-view values: the system shell decides the final capsule width,
/// corner radius and hit region. `horizontalInset` is applied as `.padding` on
/// each region's content, on top of the shell's own base inset, so the visible
/// horizontal gap from the capsule edge is the system inset plus roughly 18 pt
/// (about 28 pt total on the tested shell).
private enum IslandMetrics {
    /// Outer horizontal padding for the expanded regions, added to the system's
    /// own inset rather than replacing it.
    static let horizontalInset: CGFloat = 18
    /// The side regions only carry the brand mark and the count, so they take a
    /// smaller top gap than the body.
    static let sideTopGap: CGFloat = 10
    static let bodyTopGap: CGFloat = 5
    static let bottomInset: CGFloat = 15
    static let actionCornerRadius: CGFloat = 15
    static let actionMinHeight: CGFloat = 44
    static let brandSize: CGFloat = 13
    /// The design's gap between the clock and the compact capsule's trailing
    /// edge. The system's compact trailing margin is zeroed above, so this is
    /// the only trailing space the leaf view asks for.
    static let compactTrailingInset: CGFloat = 6
}

// MARK: - What the card is focused on

/// The single subject of the card, resolved from the state the app sent.
///
/// An approval wins whenever one is pending: a blocked turn is the one thing the
/// operator has to act on. Otherwise the longest-running session is the focus,
/// and a session that is merely waiting or offline is shown as itself rather
/// than as "running".
private struct IslandFocus {
    let state: LiveActivityState
    let approval: LiveActivityApproval?
    let presentation: LiveActivityPresentation

    var showsApproval: Bool { approval != nil || state.approvalCount > 0 }

    var otherSessions: Int { max(0, state.totalCount - 1) }
    var otherApprovals: Int { max(0, state.approvalCount - 1) }

    /// The session that has been running longest. Ties fall back to the
    /// collision-safe identity so two renders cannot disagree about the focus.
    var runningRow: LiveActivityRow? {
        state.rows.filter { $0.status == .running }.min {
            if $0.countingSince != $1.countingSince { return $0.countingSince < $1.countingSince }
            return $0.compositeId < $1.compositeId
        }
    }

    /// The approval's own session, matched on the whole identity: two computers
    /// can run a session with the same local id.
    var approvalRow: LiveActivityRow? {
        guard let approval else { return nil }
        return state.rows.first { $0.hostId == approval.hostId && $0.id == approval.sessionId }
    }

    /// The row to name when nothing is running.
    var restingRow: LiveActivityRow? { state.rows.first }
}

// MARK: - Content and presentation helpers

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

private func displayTitle(of row: LiveActivityRow) -> String {
    let value = row.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? String.localized("Untitled session") : value
}

private func statusText(_ status: LiveActivitySessionStatus) -> String {
    switch status {
    case .running: String.localized("Running")
    case .waitingApproval: String.localized("Waiting for approval")
    case .waitingAnswer: String.localized("Waiting for a reply")
    case .offline: String.localized("Offline")
    }
}

private func feedbackLabel(_ phase: LiveActivityApprovalFeedback.Phase) -> String {
    switch phase {
    case .sending: String.localized("Sending approval")
    case .accepted: String.localized("Approval accepted")
    case .rejected: String.localized("Approval rejected")
    case .failed: String.localized("Approval failed")
    case .unknown: String.localized("Approval result unknown")
    }
}

private func approvalTitle(_ approval: LiveActivityApproval?) -> String {
    guard let approval else { return String.localized("Approval waiting") }
    let detail = approval.detail.trimmingCharacters(in: .whitespacesAndNewlines)
    if !detail.isEmpty { return detail }
    let tool = approval.tool.trimmingCharacters(in: .whitespacesAndNewlines)
    if !tool.isEmpty { return tool }
    return String.localized("Approval waiting")
}

/// The quiet line under the request: a live answer state when one is known, and
/// otherwise the session the request belongs to plus its computer.
private func approvalContext(
    _ approval: LiveActivityApproval?,
    focus: IslandFocus,
) -> String? {
    guard let approval else { return nil }
    if let feedback = focus.presentation.feedback[approval.compositeId],
       feedback.phase != .accepted,
       feedback.phase != .rejected {
        let message = feedback.message.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = feedbackLabel(feedback.phase)
        return message.isEmpty ? label : "\(label) · \(message)"
    }
    let host = approval.hostName.trimmingCharacters(in: .whitespacesAndNewlines)
    if let row = focus.approvalRow {
        return [displayTitle(of: row), host].filter { !$0.isEmpty }.joined(separator: " · ")
    }
    return host.isEmpty ? nil : host
}

private enum LiveActivityLinks {
    static func overview() -> URL { LiveActivityDestination.overview.url }

    /// An approval can only be opened by its exact host/session/request triple.
    static func hasExactApproval(_ approval: LiveActivityApproval) -> Bool {
        !approval.hostId.isEmpty && !approval.sessionId.isEmpty && !approval.requestId.isEmpty
    }

    static func approval(_ approval: LiveActivityApproval) -> URL {
        guard hasExactApproval(approval) else { return overview() }
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

private extension String {
    static func localized(_ key: String) -> String {
        NSLocalizedString(key, bundle: .main, comment: "")
    }
}

// MARK: - Palette and marks

private struct LiveActivityPalette {
    let appearance: LiveActivityAppearance
    var isDark: Bool { appearance == .dark }
    /// The approved low-saturation deep teal brand ground. On a light phone the
    /// Lock Screen still asks WidgetKit for its vibrant presentation, so the
    /// light variant is only a tinted adaptation for the same composition.
    var background: Color {
        isDark ? Color(red: 0.105, green: 0.196, blue: 0.203)
            : Color(red: 0.929, green: 0.961, blue: 0.961)
    }
    var ink: Color { isDark ? .white : Color(red: 8 / 255, green: 31 / 255, blue: 34 / 255) }
    var secondary: Color { isDark ? .white.opacity(0.64) : ink.opacity(0.62) }
    var tertiary: Color { isDark ? .white.opacity(0.42) : ink.opacity(0.44) }
    /// Amber is reserved for the pending-approval signal.
    var pending: Color {
        isDark ? Color(red: 0.94, green: 0.66, blue: 0.31)
            : Color(red: 0.58, green: 0.33, blue: 0.02)
    }
    var buttonInk: Color { isDark ? Color(red: 0.04, green: 0.12, blue: 0.13) : ink }
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

// MARK: - Clocks

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

/// Running and waiting sessions keep counting from the turn start. Offline rows
/// show the last elapsed value as a frozen sample rather than a live timer.
private struct SessionElapsed: View {
    let row: LiveActivityRow
    let font: Font

    var body: some View {
        Group {
            if row.status == .offline {
                Text(verbatim: Self.format(row.elapsed))
                    .font(font.monospacedDigit())
            } else {
                ActivityClock(since: row.countingSince, font: font.monospacedDigit())
            }
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityHidden(true)
    }

    private static func format(_ elapsed: TimeInterval) -> String {
        let totalSeconds = max(0, Int(elapsed))
        let seconds = totalSeconds % 60
        let minutes = totalSeconds / 60
        if minutes < 60 { return "\(minutes):\(String(format: "%02d", seconds))" }
        return "\(minutes / 60):\(String(format: "%02d", minutes % 60)):\(String(format: "%02d", seconds))"
    }
}

/// The compact trailing clock.
///
/// WidgetKit warns that a `.timer` `Text` is horizontally flexible: it expands
/// to fill whatever width it is offered, and a widget cannot perform layout
/// again after the system archives it. Asking it to `fixedSize` therefore made
/// the flexible text report an unbounded width, which the island host answered
/// by stretching the whole capsule; on the phone the trailing clock was not
/// drawn at all.
///
/// The clock is now given a bounded, trailing-aligned frame measured from the
/// widest value its duration tier can reach. The tier keeps a brand-new turn
/// narrow instead of reserving an hour's digits, and the last two minutes before
/// a rollover use the next tier so a crossing while archived already has room.
/// `minimumScaleFactor` is only the fallback for the one case no local code can
/// pre-measure: a turn that crosses a tier without any activity update.
private struct CompactTimer: View {
    let since: Date
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let elapsed = max(0, Date().timeIntervalSince(since))
        let tier = CompactClockTier.at(elapsed)
        Text(since, style: .timer)
            .font(.caption.monospacedDigit().weight(.semibold))
            .lineLimit(1)
            .multilineTextAlignment(.trailing)
            .minimumScaleFactor(0.72)
            .frame(
                width: CompactClock.width(of: tier.widestSample, dynamicTypeSize: dynamicTypeSize),
                alignment: .trailing,
            )
            .padding(.trailing, IslandMetrics.compactTrailingInset)
            .accessibilityHidden(true)
    }
}

/// The digit tiers the compact clock can be archived in.
private enum CompactClockTier {
    /// `0:00` through `9:59`.
    case minutes
    /// `10:00` through `59:59`.
    case hour
    /// `1:00:00` through `9:59:59`.
    case hours
    /// `10:00:00` and up.
    case manyHours

    /// How close to a boundary the next tier is used. A card archived in this
    /// window has the width the rollover needs, without a second layout pass.
    static let rolloverLead: TimeInterval = 120

    static func at(_ elapsed: TimeInterval) -> CompactClockTier {
        if elapsed < 600 {
            if 600 - elapsed <= rolloverLead { return .hour }
            return .minutes
        }
        if elapsed < 3_600 {
            if 3_600 - elapsed <= rolloverLead { return .hours }
            return .hour
        }
        if elapsed < 36_000 {
            if 36_000 - elapsed <= rolloverLead { return .manyHours }
            return .hours
        }
        return .manyHours
    }

    /// The widest value this tier draws, in the phone's own numerals: the timer
    /// follows the locale, so the measurement has to as well.
    var widestSample: String {
        let colon = ":"
        switch self {
        case .minutes:
            return CompactClock.digits(9, width: 1) + colon + CompactClock.digits(59, width: 2)
        case .hour:
            return CompactClock.digits(59, width: 2) + colon + CompactClock.digits(59, width: 2)
        case .hours:
            return CompactClock.digits(9, width: 1) + colon
                + CompactClock.digits(59, width: 2) + colon + CompactClock.digits(59, width: 2)
        case .manyHours:
            return CompactClock.digits(99, width: 2) + colon
                + CompactClock.digits(59, width: 2) + colon + CompactClock.digits(59, width: 2)
        }
    }
}

private enum CompactClock {
    /// Formats a number the way the system timer does: locale digits, no
    /// grouping, fixed minimum width.
    static func digits(_ value: Int, width: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = .current
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumIntegerDigits = width
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value))
            ?? String(format: "%0\(width)d", value)
    }

    /// Measures the widest tier value with the same system font the timer draws
    /// in, including the widget's Dynamic Type category. Rounded up to a whole
    /// point so the last glyph is never clipped by a fractional advance.
    static func width(of sample: String, dynamicTypeSize: DynamicTypeSize) -> CGFloat {
        let traits = UITraitCollection(
            preferredContentSizeCategory: dynamicTypeSize.uiContentSizeCategory,
        )
        let base = UIFont.preferredFont(forTextStyle: .caption1, compatibleWith: traits)
        let font = UIFont.monospacedDigitSystemFont(ofSize: base.pointSize, weight: .semibold)
        let measured = (sample as NSString).size(withAttributes: [.font: font]).width
        return ceil(measured)
    }
}

private extension DynamicTypeSize {
    var uiContentSizeCategory: UIContentSizeCategory {
        switch self {
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
    }
}

private struct CompactLongestRunning: View {
    let state: LiveActivityState
    var limitedWidth: Bool = false

    var body: some View {
        if limitedWidth {
            compactSignal
                .padding(.trailing, IslandMetrics.compactTrailingInset)
        } else if let since = state.longestRunningSince {
            // No accessibility label on the timer itself: WidgetKit archives a
            // label combined with timer text badly, and the clock is decorative
            // for VoiceOver (the left mark carries the app).
            CompactTimer(since: since)
        } else if state.approvalCount > 0 {
            Image(systemName: "hand.raised.fill")
                .foregroundStyle(.orange)
                .accessibilityLabel(Text(verbatim: String.localized("Approval waiting")))
        } else {
            Text(verbatim: "0")
                .font(.caption.weight(.semibold))
                .accessibilityLabel(Text(verbatim: String.localized("No running sessions")))
        }
    }

    /// The small static stand-in for the clock. It carries the same meaning as
    /// the full compact trailing view without any digit width of its own.
    private var compactSignal: some View {
        Group {
            if state.approvalCount > 0 {
                Image(systemName: "hand.raised.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
                    .accessibilityLabel(Text(verbatim: String.localized("Approval waiting")))
            } else if state.longestRunningSince != nil {
                Circle()
                    .fill(.white.opacity(0.90))
                    .frame(width: 5, height: 5)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: String.localized("Longest running session")))
            } else {
                Text(verbatim: "0")
                    .font(.caption2.weight(.semibold))
                    .accessibilityLabel(Text(verbatim: String.localized("No running sessions")))
            }
        }
    }
}

private struct IslandMinimal: View {
    let state: LiveActivityState

    var body: some View {
        if state.approvalCount > 0 {
            HStack(spacing: 1) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(LiveActivityPalette.island.pending)
                if state.approvalCount > 1 {
                    Text(verbatim: "\(state.approvalCount)")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.72))
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: "\(String.localized("Pending approval")) · \(state.approvalCount)"))
        } else {
            IslandMark(diameter: 18)
        }
    }
}

// MARK: - Width-limited presentations

/// Reads the island's limited-width flag where the SDK provides it (iOS 27+) and
/// falls back to the ordinary layout elsewhere. The flag is the system's own
/// signal for a horizontally constrained island, so no device class is guessed.
private struct WidthLimitedContent<Content: View>: View {
    let content: (Bool) -> Content

    var body: some View {
        if #available(iOS 27.0, *) {
            WidthLimitedProbe(content: content)
        } else {
            content(false)
        }
    }
}

@available(iOS 27.0, *)
private struct WidthLimitedProbe<Content: View>: View {
    @Environment(\.isDynamicIslandLimitedInWidth) private var isLimited
    let content: (Bool) -> Content

    var body: some View { content(isLimited) }
}

// MARK: - Expanded island

/// The top-right corner: one count, and never a second copy of it.
private struct IslandTopTrailing: View {
    let focus: IslandFocus
    let limitedWidth: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var isAccessibility: Bool { dynamicTypeSize.isAccessibilitySize }

    var body: some View {
        if focus.showsApproval {
            approvalChip
        } else if focus.runningRow != nil,
                  !isAccessibility,
                  !limitedWidth,
                  focus.otherSessions > 0 {
            Text(verbatim: String(format: String.localized("Other sessions"), focus.otherSessions))
                .font(.caption)
                .foregroundStyle(.white.opacity(0.64))
                .lineLimit(1)
        }
    }

    private var approvalChip: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(LiveActivityPalette.island.pending)
                .frame(width: 5, height: 5)
            Text(verbatim: approvalLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(LiveActivityPalette.island.pending)
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: approvalAccessibilityLabel))
    }

    private var approvalLabel: String {
        let status = String.localized("Pending approval")
        guard focus.state.approvalCount > 1, !isAccessibility, !limitedWidth else { return status }
        return "\(status) · \(focus.state.approvalCount)"
    }

    private var approvalAccessibilityLabel: String {
        let status = String.localized("Pending approval")
        guard focus.state.approvalCount > 1 else { return status }
        return "\(status) · \(focus.state.approvalCount)"
    }
}

/// The one inset action row: neutral, 44 pt tall, 15 pt continuous corners.
private struct IslandActionRow: View {
    let label: String
    let destination: URL
    var accessibilityLabel: String?

    var body: some View {
        Link(destination: destination) {
            HStack(spacing: 8) {
                Text(verbatim: label)
                    .font(.headline)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.58))
                    .accessibilityHidden(true)
            }
            .foregroundStyle(.white.opacity(0.95))
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: IslandMetrics.actionMinHeight)
            .background(
                Color.white.opacity(0.16),
                in: RoundedRectangle(cornerRadius: IslandMetrics.actionCornerRadius, style: .continuous),
            )
            .overlay {
                RoundedRectangle(cornerRadius: IslandMetrics.actionCornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.75)
            }
            .contentShape(
                RoundedRectangle(cornerRadius: IslandMetrics.actionCornerRadius, style: .continuous),
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: accessibilityLabel ?? label))
    }
}

private struct IslandFocusBody: View {
    let focus: IslandFocus
    let limitedWidth: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var isAccessibility: Bool { dynamicTypeSize.isAccessibilitySize }
    private var dropsContext: Bool { isAccessibility || limitedWidth }
    private var titleLineLimit: Int { dropsContext ? 1 : 2 }

    var body: some View {
        Group {
            if focus.showsApproval {
                approvalBody
            } else if let row = focus.runningRow ?? focus.restingRow {
                sessionBody(row)
            } else {
                emptyBody
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(.white)
    }

    // MARK: Running / resting

    private func sessionBody(_ row: LiveActivityRow) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: displayTitle(of: row))
                .font(.title3.weight(.semibold))
                .lineLimit(titleLineLimit)
                .truncationMode(.tail)

            if !limitedWidth {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: [row.hostName, statusText(row.status)]
                        .filter { !$0.isEmpty }
                        .joined(separator: " · "))
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.64))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    SessionElapsed(row: row, font: .subheadline.monospacedDigit().weight(.medium))
                        .foregroundStyle(.white.opacity(0.90))
                        .layoutPriority(1)
                }
                .padding(.top, 6)
            }
        }
    }

    /// An older payload can carry a total with no rows at all; that is a count,
    /// not a finish, so it is reported as one.
    private var emptyTitle: String {
        focus.state.totalCount > 0
            ? "\(focus.state.totalCount) \(String.localized("Sessions"))"
            : String.localized("Every session has finished")
    }

    private var emptyBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: emptyTitle)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.80))
                .lineLimit(1)
            IslandActionRow(
                label: String.localized("View overview"),
                destination: LiveActivityLinks.overview(),
            )
            .padding(.top, 8)
        }
    }

    // MARK: Approval

    private var approvalBody: some View {
        let approval = focus.approval
        let entryLabel = String.localized(exactApprovalURL != nil ? "View approval" : "View overview")
        return VStack(alignment: .leading, spacing: 0) {
            // The approved single-line approval template is 159.3 pt tall at the
            // default type size; a second title line plus the context row would
            // overflow the expanded island, so the title stays one line here
            // even though it still scales with the text size.
            Text(verbatim: approvalTitle(approval))
                .font(.title3.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .privacySensitive()

            if !dropsContext, let context = approvalContext(approval, focus: focus) {
                Text(verbatim: context)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.64))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.top, 4)
                    .privacySensitive()
            }

            IslandActionRow(
                label: entryLabel,
                destination: exactApprovalURL ?? LiveActivityLinks.overview(),
                // The title Text is its own accessibility element; the entry
                // must not repeat raw approval content in a combined label.
                accessibilityLabel: entryLabel,
            )
            .padding(.top, 8)
        }
    }

    private var exactApprovalURL: URL? {
        guard let approval = focus.approval, LiveActivityLinks.hasExactApproval(approval) else { return nil }
        return LiveActivityLinks.approval(approval)
    }
}

// MARK: - Lock Screen card

private struct LiveActivityCard: View {
    let state: LiveActivityState
    let appearance: LiveActivityAppearance
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var palette: LiveActivityPalette { LiveActivityPalette(appearance: appearance) }
    private var isAccessibility: Bool { dynamicTypeSize.isAccessibilitySize }
    private var focus: IslandFocus {
        IslandFocus(state: state, approval: approval, presentation: presentation)
    }
    private var approvals: [LiveActivityApproval] { orderedApprovals(state.approvals) }
    private var presentation: LiveActivityPresentation { LiveActivityPresentationStore.read() }
    private var approval: LiveActivityApproval? {
        selectedApproval(from: approvals, id: presentation.selectedApprovalId)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: isAccessibility ? 6 : 7) {
            header
            if focus.showsApproval {
                approvalBody
            } else {
                sessionBody
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(palette.ink)
        .activityBackgroundTint(palette.background)
        .activitySystemActionForegroundColor(palette.ink)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            IslandMark(diameter: IslandMetrics.brandSize)
            Text(verbatim: headerLeading)
                .font(.caption.weight(.semibold))
                .foregroundStyle(focus.showsApproval ? palette.pending : palette.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let trailing = headerTrailing {
                Text(verbatim: trailing)
                    .font(.caption2)
                    .foregroundStyle(palette.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var headerLeading: String {
        if focus.showsApproval { return String.localized("Pending approval") }
        if state.rows.isEmpty && state.approvals.isEmpty {
            return String.localized("Every session has finished")
        }
        return "\(state.totalCount) \(String.localized("Sessions"))"
    }

    private var headerTrailing: String? {
        if focus.showsApproval {
            guard focus.otherApprovals > 0 else { return nil }
            return String(format: String.localized("Other approvals"), focus.otherApprovals)
        }
        guard focus.otherSessions > 0 else { return nil }
        return String(format: String.localized("Other sessions"), focus.otherSessions)
    }

    // MARK: Running / resting

    var sessionBody: some View {
        let row = focus.runningRow ?? focus.restingRow
        return VStack(alignment: .leading, spacing: isAccessibility ? 6 : 7) {
            if !isAccessibility, focus.runningRow != nil {
                Text(verbatim: String.localized("Longest running"))
                    .font(.caption2)
                    .foregroundStyle(palette.tertiary)
                    .lineLimit(1)
            }
            if let row {
                Text(verbatim: displayTitle(of: row))
                    .font(.title3.weight(.semibold))
                    .lineLimit(isAccessibility ? 1 : 2)
                    .truncationMode(.tail)
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(verbatim: [row.hostName, statusText(row.status)]
                        .filter { !$0.isEmpty }
                        .joined(separator: " · "))
                        .font(.footnote)
                        .foregroundStyle(palette.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    SessionElapsed(row: row, font: .title3.monospacedDigit().weight(.semibold))
                        .foregroundStyle(palette.ink)
                        .layoutPriority(1)
                }
            } else {
                overviewLink
            }
        }
    }

    private var overviewLink: some View {
        Link(destination: LiveActivityLinks.overview()) {
            HStack(spacing: 8) {
                Text(verbatim: String.localized("View overview"))
                    .font(.headline)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .accessibilityHidden(true)
            }
            .foregroundStyle(palette.buttonInk)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(palette.ink, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: Approval

    private var approvalBody: some View {
        let approval = self.approval
        let entryLabel = String.localized(exactApprovalURL != nil ? "View approval" : "View overview")
        return VStack(alignment: .leading, spacing: isAccessibility ? 6 : 7) {
            // Keep the approval title to the single line the approved card
            // template measures; the context row is what gives way first at
            // larger text sizes, and the 44 pt action stays.
            Text(verbatim: approvalTitle(approval))
                .font(.title3.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .privacySensitive()

            if !isAccessibility, let context = approvalContext(approval, focus: focus) {
                Text(verbatim: context)
                    .font(.caption)
                    .foregroundStyle(palette.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .privacySensitive()
            }

            Link(destination: exactApprovalURL ?? LiveActivityLinks.overview()) {
                HStack(spacing: 8) {
                    Text(verbatim: entryLabel)
                        .font(.headline)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .accessibilityHidden(true)
                }
                .foregroundStyle(palette.buttonInk)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(palette.ink, in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            // The title is read on its own; do not fold privacy-sensitive
            // approval content into the entry's label.
            .accessibilityLabel(Text(verbatim: entryLabel))
        }
    }

    private var exactApprovalURL: URL? {
        guard let approval, LiveActivityLinks.hasExactApproval(approval) else { return nil }
        return LiveActivityLinks.approval(approval)
    }
}
