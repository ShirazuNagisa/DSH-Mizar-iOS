//
//  SidebarRows.swift
//  DSH-Mizar
//
//  One workspace in the sidebar, and the sessions inside it.
//

import SwiftUI
import MizarKit
import UIKit

/// A workspace: its heading, and when open, its sessions.
struct WorkspaceSection: View {
    let group: WorkspaceGroup
    /// The sessions to draw -- all of them, or a search's matches.
    let sessions: [SessionRow]
    let isOpen: Bool
    let limit: Int
    let query: String
    let selection: Namespace.ID
    let onToggle: () -> Void
    let onMore: () -> Void
    let onCollapseOthers: () -> Void
    let onNewHere: () -> Void

    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            heading
            if isOpen {
                let shown = Array(sessions.prefix(limit))
                ForEach(Array(shown.enumerated()), id: \.element.sessionId) { index, session in
                    SessionRowButton(
                        session: session,
                        title: model.titles[session.sessionId],
                        query: query,
                        selection: selection,
                    )
                    // One after another on the way in, and last-first on the way
                    // out, so the group unfolds and folds like a list being
                    // drawn rather than a block appearing.
                    .transition(
                        AsymmetricTransition(
                            insertion: RiseTransition(distance: 8, blur: 4)
                                .animation(Motion.pick(.mizarSmooth).delay(Double(min(index, 12)) * 0.028)),
                            removal: RiseTransition(distance: 4, blur: 3)
                                .animation(Motion.pick(.mizarSnappy).delay(Double(max(0, min(shown.count, 12) - index)) * 0.012)),
                        ),
                    )
                }
                if sessions.count > shown.count {
                    Button(action: onMore) {
                        HStack(spacing: 6) {
                            Image(systemName: "ellipsis")
                                .font(.caption.weight(.bold))
                            Text("Show \(min(10, sessions.count - shown.count)) more")
                                .font(.footnote.weight(.medium))
                        }
                        .foregroundStyle(.secondary)
                        .padding(.leading, 42)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.pressable(scale: 0.98, dims: true))
                    .accessibilityIdentifier("workspace.more.\(group.path)")
                    .transition(.rise)
                }
                if sessions.isEmpty {
                    Text("No sessions here yet")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 42)
                        .padding(.vertical, 8)
                        .transition(.rise)
                }
            }
        }
        .padding(.bottom, isOpen ? 8 : 0)
    }

    /// The heading: a button whose first text is the workspace's name.
    ///
    /// Everything else in it is drawn -- the chevron, the folder, the turning mark,
    /// the count -- so the title stays the first thing a test or VoiceOver finds
    /// inside it, and the only text before the count.
    private var heading: some View {
        Button(action: onToggle) {
            HStack(spacing: 10) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .frame(width: 12)
                Image(systemName: group.isUnclaimed ? "tray" : (isOpen ? "folder.fill" : "folder"))
                    .font(.body)
                    .foregroundStyle(isOpen ? Theme.accentText : Color.secondary)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 22)
                // The leftover group is drawn as what it is. It is not a
                // workspace DSH has -- the heading says so in words, and the tray
                // says so without them.
                Text(group.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .foregroundStyle(group.isUnclaimed ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                // Whose folder this is, when the list holds more than one
                // agent's. A scoped connection draws nothing: every row under a
                // DSH capsule saying "DSH" is noise, and the capsule over the
                // list already says it once.
                if model.engineScope == nil,
                   let agent = group.engine.flatMap(AgentEngine.init(rawValue:)) {
                    Text(agent.shortTitle)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .frame(height: 16)
                        .background(.fill.quaternary, in: Capsule())
                        .accessibilityIdentifier("workspace.engine.\(group.path)")
                }
                Spacer(minLength: 8)
                if !isOpen, group.sessions.contains(where: \.running) {
                    // Work is going on in here, said without opening it.
                    MizarRing(ink: 15, motion: .running)
                        .transition(.pop)
                }
                if waiting > 0 {
                    // Pulses only while the drawers are still: the frames a
                    // drawer is moving belong to the card.
                    WaitingPulseGlyph()
                        .transition(.pop)
                }
                Text("\(group.sessions.count)")
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(.tertiary)
                    .contentTransition(.numericText())
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.pressable(scale: 0.985))
        .mizarFeedback(.selection, trigger: isOpen)
        .accessibilityIdentifier("workspace.\(group.path)")
        .accessibilityValue(Text(isOpen ? "Expanded" : "Collapsed"))
        .contextMenu {
            if !group.isUnclaimed {
                Button(action: onNewHere) {
                    Label("New session here", systemImage: "square.and.pencil")
                }
            }
            Button(action: onCollapseOthers) {
                Label("Collapse others", systemImage: "rectangle.compress.vertical")
            }
        }
    }

    /// Requests waiting on the operator inside this workspace.
    private var waiting: Int {
        guard let pending = model.pending else { return 0 }
        let ids = Set(group.sessions.map(\.sessionId))
        return pending.approvals.count { $0.sessionId.map(ids.contains) ?? false }
            + pending.questions.count { $0.sessionId.map(ids.contains) ?? false }
    }
}

/// The heading's "someone is waiting" hand, pulsing at rest.
///
/// The drawer gate is read on the glyph rather than by ``WorkspaceSection``:
/// the hold is this decoration's, and the section's insertion transition stays
/// on the call site, where it was.
private struct WaitingPulseGlyph: View {
    @Environment(\.drawersStill) private var drawersStill

    var body: some View {
        Image(systemName: "hand.raised.fill")
            .font(.caption)
            .foregroundStyle(Theme.waiting)
            .symbolEffect(.pulse, options: .repeat(.continuous), isActive: drawersStill)
    }
}

/// One session.
struct SessionRowButton: View {
    let session: SessionRow
    var title: String?
    var query: String = ""
    let selection: Namespace.ID

    @Environment(AppModel.self) private var model

    private var isSelected: Bool { model.selectedSessionId == session.sessionId }

    var body: some View {
        Button {
            // The selection changes with no animation, deliberately. The
            // choosing happens inside the shell's own animation -- the pill
            // slides to the row that was tapped, and that is the one thing
            // worth animating here -- but the same animation reaches the
            // conversation, where the page for the previous session is
            // replaced: both conversations were drawn at once, blurred and
            // one over the other, for as long as it ran. The slide the
            // operator wants is put back on the pill itself below.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                model.selectedSessionId = session.sessionId
            }
        } label: {
            HStack(spacing: 10) {
                indicator
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 2) {
                    // No accessibility label of its own, and not combined with
                    // the date: the row is found by its title text.
                    Text(highlighted)
                        .font(.subheadline.weight(isSelected ? .semibold : .regular))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(session.updatedDate, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if isWaiting {
                    Image(systemName: "hand.raised.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.waiting)
                        .transition(.pop)
                }
            }
            .padding(.leading, 28)
            .padding(.trailing, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: Theme.Radius.sm + 2, style: .continuous)
                        .fill(Theme.selectionFill)
                        .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
                        .matchedGeometryEffect(id: "selection", in: selection)
                }
            }
            .contentShape(.rect)
            // The selection pill's slide, on the pill rather than on
            // everything the tap changes. See the button's action.
            .animation(.mizarSmooth, value: isSelected)
        }
        .buttonStyle(.pressable(scale: 0.98))
        .contextMenu {
            Button {
                UIPasteboard.general.string = session.sessionId
            } label: {
                Label("Copy session ID", systemImage: "doc.on.doc")
            }
            // No confirmation alert, deliberately. Archiving does not delete
            // anything on the computer and does not stop a running turn -- the
            // host refuses to archive one that is running -- so the destructive
            // double-check a confirmation implies would be asking about a
            // deletion that cannot happen. The row leaves when the host has
            // taken the archive; a refusal is said in the list's error line,
            // which is already where a failed refresh is reported.
            Button {
                Task { await model.archiveSession(session.sessionId) }
            } label: {
                Label("Archive this session", systemImage: "archivebox")
            }
        }
    }

    @ViewBuilder private var indicator: some View {
        if session.running {
            MizarRing(ink: 15, motion: .running)
                .transition(.pop)
        } else {
            Circle()
                .fill(.quaternary)
                .frame(width: 5, height: 5)
                .transition(.pop)
        }
    }

    private var isWaiting: Bool {
        guard let pending = model.pending else { return false }
        return pending.approvals.contains { $0.sessionId == session.sessionId }
            || pending.questions.contains { $0.sessionId == session.sessionId }
    }

    /// The title, with what was searched for picked out in the accent.
    private var highlighted: AttributedString {
        var text = AttributedString(SessionTitle.display(for: session, title: title))
        let needle = query.trimmingCharacters(in: .whitespaces)
        if !needle.isEmpty, let range = text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) {
            text[range].foregroundColor = Theme.accentText
            text[range].font = .subheadline.weight(.semibold)
        }
        return text
    }
}
