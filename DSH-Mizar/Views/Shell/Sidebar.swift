//
//  Sidebar.swift
//  DSH-Mizar
//
//  The computer's sessions, grouped the way DSH groups them.
//
//  Top to bottom: the computer's name and a refresh, a search field, "New session",
//  then one row per workspace. Workspaces start folded -- a list of five
//  workspaces each holding a dozen sessions is not a list anybody can read --
//  and open with a tap, their sessions rising into place one after another. The
//  workspace holding the session on screen opens by itself, so the operator can
//  always see where they are.
//
//  The shape mirrors the computer's own sidebar because that is what the operator is
//  looking at when they reach for their phone, and a phone that arranges the
//  same sessions differently is a second thing to learn.
//
//  Subagents are left out. They are real sessions, but they are the agent's
//  bookkeeping rather than the operator's work, and a list where half the rows
//  are delegated children is a list nobody can scan. The arrangement itself is
//  `MizarKit.WorkspaceCatalog`'s, shared with the new-session picker.
//

import SwiftUI
import MizarKit
import UIKit

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(ShellState.self) private var shell
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var query = ""
    @FocusState private var searching: Bool
    /// How many sessions each workspace shows before offering more.
    @State private var limits: [String: Int] = [:]
    /// The selection highlight's namespace: one highlight that slides from row
    /// to row rather than one per row that blinks.
    @Namespace private var selection

    /// Which small window is out of which control. One at a time, as the
    /// system's own are.
    @State private var showingComputers = false
    @State private var showingSync = false
    /// Whether the "cannot reach the desktop" note is out.
    @State private var showingUnreachable = false
    @State private var showingNewSession = false
    @State private var showingNewWorkspace = false
    /// The name-a-folder sheet the on-device agent uses instead.
    @State private var showingLocalWorkspace = false
    /// Which agent this computer's list is showing, when it serves more than one.
    @State private var showingAgentPicker = false
    @State private var showingConnection = false
    @State private var showingSettings = false

    private static let pageSize = 10

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                newSession
                    .padding(.top, 6)
                workspaces
                    .padding(.top, 22)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.immediately)
        .scrollIndicators(.hidden)
        // A pull is the operator asking "is it still there", and the first half
        // of that answer is which way there is: the model scans the local network
        // once before it re-reads the list, so a phone that came home to the same
        // network switches to the direct link instead of staying on the relay.
        .refreshable { await model.manualRefresh() }
        // The computer, the refresh and the search stay put at the top; the
        // sessions slide underneath them, softened by the bar's edge as they go.
        .safeAreaBar(edge: .top, spacing: 0) {
            pinned
        }
        .safeAreaBar(edge: .bottom, spacing: 0) {
            SidebarFooter(showingConnection: $showingConnection, showingSettings: $showingSettings)
        }
        .scrollEdgeEffectStyle(.soft, for: .vertical)
        .background(Theme.sidebarBackground)
        .onChange(of: model.selectedSessionId, initial: true) { _, selected in
            revealSelection(selected)
        }
        .onChange(of: query) { old, new in
            // Titles are one request each and are normally fetched only for a
            // workspace being opened. A search is a question about every
            // session, so the first keystroke asks for the ones not known yet.
            guard old.isEmpty, !new.isEmpty else { return }
            let unknown = model.workspaceGroups
                .flatMap(\.sessions)
                .map(\.sessionId)
                .filter { model.titles[$0] == nil }
            Task { await model.loadTitles(for: Array(unknown.prefix(40))) }
        }
    }

    /// What stays at the top while the list moves.
    private var pinned: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 8)
                .padding(.top, 6)
            agentRow
            search
                .padding(.top, 12)
                .padding(.bottom, 10)
        }
        .padding(.horizontal, 12)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            computerButton
            Spacer(minLength: 0)
            Button {
                // No socket, no pass: the note says so where the button is,
                // rather than opening a window that would never fill.
                guard model.isConnected else {
                    showingUnreachable = true
                    return
                }
                // The window first, whatever else happens. A pass already on the
                // socket cannot be started a second time, and a tap on the button
                // that started it is how the operator gets its window back after
                // putting it away -- the one tap that used to do nothing at all.
                showingSync = true
                guard !model.isSyncing else { return }
                Task { await model.syncAllConversations() }
            } label: {
                GlassCircleLabel(size: 38) {
                    RefreshGlyph.live(
                        running: refreshing,
                        // A manual pass has a count behind it; an automatic one
                        // has none to report, and says so by turning instead of
                        // filling.
                        fraction: model.isSyncing ? model.syncFraction : nil,
                    )
                }
            }
            .buttonStyle(.plain)
            // An automatic pass has no window of its own to offer, so the button
            // is held down for as long as it runs: it says what is happening and
            // refuses a tap that could only be swallowed.
            .disabled(model.autoRefreshing && !model.isSyncing)
            .accessibilityLabel(Text("Refresh"))
            .accessibilityIdentifier("sessions.refresh")
            .mizarPopover(isPresented: $showingSync) {
                SyncProgressSheet()
            }
            // `.top`, not `.bottom`: the arrow edge names where the arrow sits,
            // so `.bottom` puts the window *above* the button -- and this button
            // is at the top of the screen, where the window is clipped by the
            // safe area. That is what the note looked like: a sentence cut in
            // half above the title bar.
            .mizarPopover(isPresented: $showingUnreachable, arrowEdge: .top) {
                RefreshUnreachableNote()
            }
        }
    }

    /// Who is on this list, and how the phone is reaching them.
    ///
    /// One row because the two facts are read together: whose work this is, and
    /// whether it is arriving. The capsule is the answer to the first question
    /// and the bar to the second; a computer with one agent still names it,
    /// because "which agent" is a fact about the list even when there is only
    /// one answer.
    ///
    /// Nothing is drawn for the on-device agent: its frames never leave the
    /// process, so there is no link to draw, and there is no second agent to
    /// choose between. An unpaired phone has neither fact.
    @ViewBuilder
    private var agentRow: some View {
        if !model.isLocalAgentMode, let link = model.linkStatus {
            HStack(spacing: 8) {
                agentCapsule
                // The bar sits at the row's trailing edge, not against the
                // capsule: the capsule is about the list, the bar is about the
                // link, and the gap says they are two readings rather than one
                // control with a badge.
                Spacer(minLength: 0)
                LinkStatusBar(status: link)
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)
        }
    }

    /// The agent this list belongs to.
    ///
    /// Tappable only when there is a choice to make. With one agent the capsule
    /// still says which one, but it is a label rather than a control -- a
    /// chevron and a press animation on something that cannot open is a button
    /// that lies.
    @ViewBuilder
    private var agentCapsule: some View {
        if let title = agentTitle {
            if model.engineChoices.count > 1 {
                Button {
                    showingAgentPicker = true
                } label: {
                    agentCapsuleLabel(title, showsChevron: true)
                }
                .buttonStyle(.pressable(scale: 0.96))
                .accessibilityIdentifier("sessions.agent")
                .accessibilityValue(Text(model.engineScope?.title ?? String(localized: "All agents")))
                .mizarPopover(isPresented: $showingAgentPicker) {
                    AgentSwitcher()
                }
            } else {
                agentCapsuleLabel(title, showsChevron: false)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(title))
                    .accessibilityIdentifier("sessions.agent")
            }
        }
    }

    /// What the agent capsule says.
    ///
    /// `nil` when this build cannot name the agent: an older host that has not
    /// reported which engines it serves. Showing "All agents" there would be a
    /// sentence about having several, on a computer that may have one.
    private var agentTitle: String? {
        if model.engineChoices.count > 1 {
            return model.engineScope?.shortTitle ?? String(localized: "All agents")
        }
        guard let engines = model.host?.knownEngines?.compactMap(AgentEngine.init(rawValue:)),
              engines.count == 1 else { return nil }
        return (model.engineScope ?? engines[0]).shortTitle
    }

    private func agentCapsuleLabel(_ title: String, showsChevron: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 10, weight: .semibold))
            Text(title)
                .font(.caption2.weight(.semibold))
            if showsChevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .opacity(0.7)
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(.fill.tertiary, in: Capsule())
        .contentShape(.rect)
    }

    /// Whether the refresh button should draw itself as working.
    private var refreshing: Bool { model.isSyncing || model.autoRefreshing }

    /// The computer's name, which is also the way to another computer.
    ///
    /// The name is how the operator knows which machine this is, and it is the
    /// one string on this screen that is theirs rather than the app's -- so it
    /// is the control that chooses the machine, and the chevron beside it turns
    /// to say the window is out.
    /// The name over the session list: the computer it is talking to, or the
    /// agent that lives here. An on-device agent has no machine name to borrow,
    /// and showing the phone's own name would read as a second computer.
    private var headerTitle: String {
        if model.isLocalAgentMode { return String(localized: "On-Device Agent") }
        return model.host?.displayName ?? model.welcome?.hostName ?? String(localized: "Sessions")
    }

    private var computerButton: some View {
        // Read in the body rather than inside the presentation binding, so the
        // prompt is asked about again the moment the drawers stop moving.
        let namingWanted = wantsNamingHere
        return Button {
            showingComputers = true
        } label: {
            HStack(spacing: 8) {
                Text(headerTitle)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .contentTransition(.opacity)
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(showingComputers ? 180 : 0))
                    .frame(width: 22, height: 22)
                    .background(.fill.tertiary, in: Circle())
                    .animation(.mizarBouncy, value: showingComputers)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.pressable(scale: 0.97))
        .accessibilityIdentifier("sessions.hosts")
        .mizarPopover(isPresented: $showingComputers) {
            HostListView()
                .frame(width: PopoverSize.compact.width, height: PopoverSize.compact.height)
        }
        // A switch that has landed puts the window away: the computer was chosen
        // to look at its sessions, not to keep looking at the list. `old` may be
        // nil -- leaving the on-device agent for a computer is exactly that --
        // so only "the same computer again" is not a switch.
        .onChange(of: model.host?.hostId) { old, new in
            guard new != nil, old != new, showingComputers else { return }
            Task {
                try? await Task.sleep(for: .milliseconds(450))
                showingComputers = false
            }
        }
        // The on-device agent has no host id to change, so it needs the same
        // dismissal of its own.
        .onChange(of: model.mode) { _, new in
            guard new == .local, showingComputers else { return }
            Task {
                try? await Task.sleep(for: .milliseconds(450))
                showingComputers = false
            }
        }
        // The one-time "what should this computer be called", out of the name it
        // is about -- when the sidebar is where the operator is looking.
        .background {
            Color.clear
                .mizarPopover(
                    isPresented: Binding(
                        get: { namingWanted },
                        set: { if !$0 { model.pendingNameHostId = nil } },
                    ),
                ) {
                    NamingWindow()
                }
        }
    }

    /// Whether the naming prompt hangs off this name, rather than off the
    /// sidebar button on the conversation.
    ///
    /// Held back while a drawer is moving: a window anchored to a control that
    /// is travelling across the display goes away with the travel, and a
    /// one-time prompt that dismisses itself is a prompt nobody answers.
    private var wantsNamingHere: Bool {
        model.pendingNameHostId != nil && !shell.isSettling && !shell.isDragging
            && (shell.settledOpen || sizeClass == .regular)
    }

    // MARK: - Search

    private var search: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            TextField("Search sessions", text: $query)
                .focused($searching)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .accessibilityIdentifier("sidebar.search")
            if !query.isEmpty {
                Button {
                    withMizarAnimation(.mizarSnappy) { query = "" }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .transition(.pop)
                .accessibilityLabel(Text("Clear search"))
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 42)
        .liquidCapsule()
        .animation(.mizarSnappy, value: query.isEmpty)
    }

    // MARK: - New session / new workspace

    /// Two doors, side by side.
    ///
    /// Starting a session and starting a workspace used to be one button and a
    /// menu, which read as one feature with a footnote: the workspace -- the
    /// directory a project lives in -- is the thing an operator arrives with,
    /// and a session is what they do inside it. Half the width each says they
    /// are two decisions, and neither is buried behind a long press.
    private var newSession: some View {
        HStack(spacing: 8) {
            newWorkButton
            newSessionButton
        }
    }

    /// Start a workspace: a directory on the computer, which DSH then lists.
    private var newWorkButton: some View {
        Button {
            // Two different questions behind one button. A computer already has
            // the directory and a session there is what makes it a workspace; the
            // on-device agent owns its root, so here the workspace *is* the
            // folder, and the sheet asks for a name rather than a path.
            if model.isLocalAgentMode {
                showingLocalWorkspace = true
            } else {
                showingNewWorkspace = true
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "folder.badge.plus")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                Text("New workspace")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .contentShape(.rect)
            .liquidSurface(in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous), interactive: true)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sessions.newWorkspace")
        .mizarPopover(isPresented: $showingNewWorkspace) {
            NewWorkspaceView()
        }
        .sheet(isPresented: $showingLocalWorkspace) {
            LocalWorkspaceView()
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
    }

    /// Start a session, in any of the workspaces the computer has.
    private var newSessionButton: some View {
        Button { showingNewSession = true } label: {
            HStack(spacing: 8) {
                Image(systemName: "square.and.pencil")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                Text("New session")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .contentShape(.rect)
            .liquidSurface(in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous), interactive: true)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sessions.new")
        .mizarPopover(isPresented: $showingNewSession) {
            NewSessionView()
                .frame(width: PopoverSize.compact.width, height: 440)
        }
        // Long-press goes straight to a workspace, for the operator who already
        // knows where the work is.
        .contextMenu {
            ForEach(model.workspaceChoices) { workspace in
                Button {
                    Task { await model.createSession(cwd: workspace.path) }
                } label: {
                    Label(workspace.title, systemImage: "folder")
                }
            }
        }
    }

    // MARK: - Workspaces

    private var workspaces: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(query.isEmpty ? String(localized: "Workspaces") : String(localized: "Results"))
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
                .contentTransition(.opacity)

            let groups = visibleGroups
            if groups.isEmpty, !query.isEmpty {
                Text("Nothing matches “\(query)”")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .transition(.rise)
            }
            ForEach(groups, id: \.group.id) { entry in
                WorkspaceSection(
                    group: entry.group,
                    sessions: entry.sessions,
                    isOpen: entry.forcedOpen || isExpanded(entry.group.path),
                    limit: entry.forcedOpen ? entry.sessions.count : (limits[entry.group.path] ?? Self.pageSize),
                    query: query,
                    selection: selection,
                    onToggle: { toggle(entry.group) },
                    onMore: { more(entry.group) },
                    onCollapseOthers: { collapseOthers(than: entry.group) },
                    onNewHere: { Task { await model.createSession(cwd: entry.group.path) } },
                )
            }
        }
        .animation(.mizarSmooth, value: query)
    }

    /// The groups to draw, with the sessions each shows.
    ///
    /// Searching filters by the workspace's name, the session's title and its
    /// working directory, and opens every group that has a match -- a search
    /// result hidden inside a folded group is not a result.
    private var visibleGroups: [(group: WorkspaceGroup, sessions: [SessionRow], forcedOpen: Bool)] {
        let groups = model.workspaceGroups
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return groups.map { ($0, $0.sessions, false) } }
        return groups.compactMap { group in
            if group.title.localizedCaseInsensitiveContains(needle) {
                return (group, group.sessions, !group.sessions.isEmpty)
            }
            let matches = group.sessions.filter { session in
                SessionTitle.display(for: session, title: model.titles[session.sessionId])
                    .localizedCaseInsensitiveContains(needle)
                    || (session.cwd ?? "").localizedCaseInsensitiveContains(needle)
            }
            return matches.isEmpty ? nil : (group, matches, true)
        }
    }

    // MARK: - Expansion

    private func isExpanded(_ path: String) -> Bool {
        shell.expanded(for: model.host?.hostId).contains(path)
    }

    private func toggle(_ group: WorkspaceGroup) {
        var open = shell.expanded(for: model.host?.hostId)
        withMizarAnimation(.mizarSmooth) {
            if open.contains(group.path) {
                open.remove(group.path)
            } else {
                open.insert(group.path)
            }
            shell.setExpanded(open, for: model.host?.hostId)
        }
        if open.contains(group.path) { loadTitles(for: group) }
    }

    private func more(_ group: WorkspaceGroup) {
        let shown = limits[group.path] ?? Self.pageSize
        withMizarAnimation(.mizarSmooth) {
            limits[group.path] = shown + Self.pageSize
        }
        // The rows just revealed need their titles too. This used to raise the
        // limit and stop, so "Show 10 more" revealed ten rows named by their
        // directory and an id.
        let revealed = group.sessions.dropFirst(shown).prefix(Self.pageSize).map(\.sessionId)
        Task { await model.loadTitles(for: Array(revealed)) }
    }

    private func collapseOthers(than group: WorkspaceGroup) {
        withMizarAnimation(.mizarSmooth) {
            shell.setExpanded([group.path], for: model.host?.hostId)
        }
        loadTitles(for: group)
    }

    private func loadTitles(for group: WorkspaceGroup) {
        let shown = group.sessions.prefix(limits[group.path] ?? Self.pageSize).map(\.sessionId)
        Task { await model.loadTitles(for: Array(shown)) }
    }

    /// Open the workspace holding the session on screen.
    private func revealSelection(_ selected: String?) {
        guard let selected,
              let group = model.workspaceGroups.first(where: { $0.sessions.contains { $0.sessionId == selected } })
        else { return }
        var open = shell.expanded(for: model.host?.hostId)
        guard !open.contains(group.path) else { return }
        open.insert(group.path)
        shell.setExpanded(open, for: model.host?.hostId)
        // Far enough down a long group to be hidden behind "Show more": raise
        // the limit to include it.
        if let index = group.sessions.firstIndex(where: { $0.sessionId == selected }),
           index >= (limits[group.path] ?? Self.pageSize) {
            limits[group.path] = index + 1
        }
        loadTitles(for: group)
    }
}

/// What to call a session.
///
/// The host's title first, because it describes the conversation. Falling back
/// to the working directory alone makes every row in a workspace read the same
/// -- five sessions all called "DSH-Mizar" -- so a shortened id goes with it:
/// not a name, but still a way to tell one row from the next.
enum SessionTitle {
    static func display(for session: SessionRow, title: String?) -> String {
        if let title, !title.isEmpty { return title }
        if let cwd = session.cwd {
            let name = (cwd as NSString).lastPathComponent
            return "\(name) · \(session.sessionId.prefix(8))"
        }
        return session.sessionId
    }
}

// MARK: - Footer

/// How the phone is reaching the computer, and the way to the settings.
private struct SidebarFooter: View {
    @Binding var showingConnection: Bool
    @Binding var showingSettings: Bool
    @State private var showingBalance = false
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            Button {
                showingConnection = true
            } label: {
                HStack(spacing: 7) {
                    ConnectionDot(live: model.isConnected)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(status)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .contentTransition(.opacity)
                        Text(route)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .layoutPriority(1)
                    Spacer(minLength: 4)
                    if model.runningPollIsActive {
                        // The poll is up: something is running and the phone is
                        // following it.
                        MizarStar(ink: 14, motion: .running)
                            .transition(.pop)
                    }
                    Image(systemName: "chevron.up")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(showingConnection ? 180 : 0))
                        .animation(.mizarBouncy, value: showingConnection)
                }
                .padding(.horizontal, 10)
                .frame(height: 54)
                .contentShape(.capsule)
                .liquidCapsule(interactive: true)
            }
            .buttonStyle(.plain)
            // One label for the whole capsule: a button is one accessibility
            // element, so the route drawn under the status is not separately
            // voiced and would otherwise be left out of it. The route goes into
            // the catalogue's existing `Connection, %@` sentence rather than a
            // second format argument -- both halves are already localised
            // words, and a new key for the same sentence would be one more
            // translation nobody needs.
            .accessibilityLabel(Text(String(
                format: String(localized: "Connection, %@"),
                "\(status), \(route)",
            )))
            .accessibilityIdentifier("sidebar.connection")
            .mizarPopover(isPresented: $showingConnection, arrowEdge: .bottom) {
                ConnectionPanel()
            }

            Button {
                showingBalance = true
            } label: {
                GlassCircleLabel(size: 54) {
                    Text("¥")
                        .font(.system(size: 23, weight: .medium))
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("balance.title"))
            .accessibilityIdentifier("sidebar.balance")
            .mizarPopover(isPresented: $showingBalance, arrowEdge: .bottom) {
                BalanceView()
            }

            Button {
                showingSettings = true
            } label: {
                // Signed in, the button is the account's avatar: who is signed
                // in is the first thing settings answers, and the gear can say
                // it without opening anything. Signed out, it stays a gear.
                if model.account.isLoggedIn {
                    AccountAvatarView(user: model.account.user, image: model.account.customAvatar, size: 54)
                } else {
                    GlassCircleLabel(size: 54) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 19, weight: .medium))
                            .rotationEffect(.degrees(showingSettings ? 60 : 0))
                            .animation(.mizarBouncy, value: showingSettings)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Settings"))
            .accessibilityIdentifier("sidebar.settings")
            // The one window that is a sheet rather than a popover: settings is
            // a place, not a note about the button, and the system's own pages
            // of this kind pull up as a card that leaves the screen behind it
            // visible along the top.
            .sheet(isPresented: $showingSettings) {
                SettingsView(onDone: { showingSettings = false })
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .animation(.mizarSmooth, value: model.isConnected)
        .animation(.mizarSmooth, value: model.runningPollIsActive)
    }

    private var status: String {
        if model.isConnected { return String(localized: "Connected") }
        if model.reconnecting { return String(localized: "Connecting…") }
        return String(localized: "Offline")
    }

    private var route: String {
        guard model.isConnected else {
            return model.hasStoredIndex ? String(localized: "Showing saved history") : String(localized: "Not reachable")
        }
        // A direct link on the operator's own network is the one route worth a
        // name of its own: it costs no relay bandwidth, and it is the reason the
        // paid features are open. The model owns that classification so this
        // line and everything gated on the same fact cannot drift apart.
        // The on-device agent is neither a relay nor the local network: it is
        // this process, and saying "LAN communication" would send somebody
        // looking for a cable.
        if model.isLocalAgentMode { return String(localized: "On this device") }
        if model.isLocalCommunication { return String(localized: "LAN communication") }
        switch model.activeEndpoint {
        case .relay: return String(localized: "Through the relay")
        case .direct(let authority): return authority
        case .p2p: return String(localized: "P2P direct connection")
        case nil: return model.host?.authority ?? ""
        }
    }
}

/// The one-time naming prompt, for whichever control it hangs from.
struct NamingWindow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let host = model.pendingNameHostId.flatMap({ id in model.hosts.first { $0.hostId == id } }) {
            RenameForm(host: host) { name in
                Task { await model.rename(hostId: host.hostId, to: name) }
                model.pendingNameHostId = nil
            }
        }
    }
}
