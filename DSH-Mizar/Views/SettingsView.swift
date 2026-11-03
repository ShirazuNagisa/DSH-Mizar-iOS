//
//  SettingsView.swift
//  DSH-Mizar
//
//  The settings sheet: what the app does, what happened, and what it is.
//
//  The sections are in the order somebody needs them: how a message is sent
//  (发送), what this phone will tell you (notifications), what it shows while it
//  is working (the Live Activity), what to send when something is wrong (the log
//  export), and what it is (about, then where its community is, then who wrote
//  it).
//
//  Every switch here is wired to something that reads it, and that is the whole
//  reason this file is not a list of preferences. 发送 asks
//  ``MizarSettings/guidedSendByDefault``, which the composer and the held-prompt
//  bar read; 通知 asks ``NotificationKind`` what arrived and ``PushAppDelegate``
//  refuses what the operator switched off; 实时活动 is
//  ``AppModel/liveActivitiesEnabled``, which the activity reads; 日志 exports what
//  ``ActivityLog`` recorded. A switch nothing consults is worse than no switch,
//  because it teaches the operator that this screen does not work.
//
//  Native throughout -- `List`, `Section`, `Toggle`, `LabeledContent`, the system
//  share sheet -- because every one of these has an accessibility shape the
//  operator already knows and a look that follows the OS forward. Nothing is
//  imitated, and no row is drawn by hand.
//

import MizarKit
import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    /// The system's browser opener, for the source link.
    @Environment(\.openURL) private var openURL

    /// The archive currently being offered to the share sheet.
    @State private var sharing: LogArchive?
    /// Whether an export is in flight, so the button can say so.
    @State private var exporting = false
    /// What iOS thinks of this app's notifications, read when the screen opens.
    @State private var permission: NotificationPermission?
    /// Bumped after the cache is cleared, so the tap has a haptic to play on.
    @State private var mizarSuccess = false
    /// Whether a tap on the QQ row had to fall back to copying the group
    /// number, because this phone has no QQ to open.
    @State private var qqNumberCopied = false
    /// Closes the sheet this screen is presented in.
    var onDone: (() -> Void)?
    /// The one switch every haptic in the app answers to.
    @AppStorage(Haptics.storageKey) private var hapticsEnabled = true
    /// The paid-plan explanation, from either this screen or the account screen.
    @State private var showingPlanDetail = false
    /// The pairing sheet, kept here as a developer tool while accounts replace it.
    @State private var showingPairing = false
    /// The preview cache, for the 文件 section. Optional because the snapshot
    /// suite renders this screen without the shell's environment around it.
    @Environment(PreviewCenter.self) private var preview: PreviewCenter?
    /// Whether the "clear the on-device agent's data" confirmation is up.
    @State private var confirmingLocalClear = false
    /// What the on-device agent holds, measured when the screen opens.
    ///
    /// Not computed per render: it walks a directory tree, and this screen is
    /// redrawn for every keystroke in the log settings above it.
    @State private var localAgentBytes: Int64?

    var body: some View {
        NavigationStack {
            List {
                header
                accountSection
                planSection
                sendSection
                notificationsSection
                liveActivitySection
                transferSection
                localAgentSection
                filesSection
                feelSection
                logsSection
                aboutSection
                communitySection
                creditsSection
                if AppModel.showsManualPairing {
                    developerSection
                }
            }
            .navigationTitle(Text("Settings"))
            // A small window keeps its title small.
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let onDone {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", action: onDone)
                            .accessibilityIdentifier("settings.done")
                    }
                }
            }
            .refreshable {
                await model.credits.refresh()
            }
            .task {
                // Asked here rather than at launch: this is the screen where the
                // answer is meaningful, and reading it is a call into the
                // notification centre that nothing else needs.
                permission = await NotificationPermission.current()
                await model.credits.start()
                model.localAgent.refreshKeyPresence()
                localAgentBytes = model.localAgent.storedByteCount
            }
            .sheet(item: $sharing) { archive in
                ShareSheet(items: [archive.url])
            }
            .sheet(isPresented: $showingPlanDetail) {
                MizarPaidDetailView()
            }
        }
    }

    /// What the app is talking to, under its name.
    ///
    /// "No computer paired yet" is true and unhelpful while the on-device agent
    /// is the host: nothing is paired, and the thing answering is this phone.
    private var headerSubtitle: String {
        if model.isLocalAgentMode { return String(localized: "On-Device Agent") }
        if let host = model.host {
            return String(format: String(localized: "Paired with %@"), host.displayName)
        }
        return String(localized: "No computer paired yet")
    }

    // MARK: - Header

    /// What this is, before what it does: the icon, the name, the version.
    private var header: some View {
        Section {
            HStack(spacing: 16) {
                // The app's own icon, drawn rather than pasted: the star nudges
                // both layers once as the screen opens, which is the only place
                // in this sheet where the brand is allowed to introduce itself.
                MizarIconTile(size: 64, motion: .flick)
                    .shadow(color: Theme.navy.opacity(0.22), radius: 8, y: 3)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: "DSH-Mizar")
                        .font(.title2.weight(.bold))
                    Text(headerSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.vertical, 6)
            .listRowBackground(Color.clear)
        }
    }

    // MARK: - 账户

    /// The account row: who is signed in, or that nobody is.
    ///
    /// Placed between the header and notifications because it is the second
    /// thing a person looks for in settings, and because it has to be reachable
    /// without signing in — the row is how anybody discovers an account exists.
    /// A blank avatar and 未登录 is not an error state; it is the truth about an
    /// app that works without one.
    private var accountSection: some View {
        Section {
            NavigationLink {
                AccountScreen(onDone: onDone)
            } label: {
                HStack(spacing: 14) {
                    AccountAvatarView(user: model.account.user, image: model.account.customAvatar, size: 44)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.account.isLoggedIn ? model.account.displayName : String(localized: "Not signed in"))
                            .font(.body.weight(.medium))
                            .foregroundStyle(model.account.isLoggedIn ? Color.primary : Color.secondary)
                            .accessibilityIdentifier("settings.account.name")
                        Text(model.account.isPaid ? String(localized: "Paid account") : String(localized: "Free account"))
                            .font(.caption)
                            .foregroundStyle(model.account.isPaid ? Color.accentColor : Color.secondary)
                            .accessibilityIdentifier("settings.account.plan")
                    }
                }
                .padding(.vertical, 2)
            }
            .accessibilityIdentifier("settings.account")
        } header: {
            Text("Account")
        } footer: {
            if !model.account.isLoggedIn {
                Text("A Mizar account is required to use the app. It keeps every relay session attributable to one person.")
            } else if let notice = model.account.noticeMessage {
                Text(notice)
            }
        }
    }

    // MARK: - 付费版

    /// The plan row, and the one honest paragraph about what it pays for.
    ///
    /// It sits directly under the account because "what am I on" and "what would
    /// paying change" are the same question asked twice.
    private var planSection: some View {
        Section {
            LabeledContent {
                Button("Details") { showingPlanDetail = true }
                    .font(.footnote.weight(.medium))
                    .accessibilityIdentifier("settings.plan.detail")
            } label: {
                Label("Mizar Paid", systemImage: "star.circle")
            }
            .accessibilityIdentifier("settings.plan")
        } header: {
            Text("Plan")
        } footer: {
            Text("A high-bandwidth relay, paid for by the people who need it. The free server stays free.")
        }
    }

    // MARK: - 发送

    /// What happens to a message sent while the agent is still working.
    ///
    /// The two behaviours are one switch because they are one decision: hand it
    /// to the running turn as guidance now, or keep it on the phone until the
    /// turn ends. A toggle rather than a picker -- there are two answers, and the
    /// footer says what each one does in plain words, which a picker would only
    /// hide one level down.
    private var sendSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { model.settings.values.guidedSendByDefault },
                set: { model.settings.values.guidedSendByDefault = $0 },
            )) {
                Label("Default to guided send", systemImage: "paperplane")
            }
            .accessibilityIdentifier("settings.send.guidedSend")
        } header: {
            Text("Sending")
        } footer: {
            Text(
                String(
                    localized: "On, a message sent while a turn is running is handed to the model immediately as guidance, without interrupting it. Off, it waits in a bar above the field and is sent when the turn ends; the bar can also send it as guidance now, put it back in the field, or throw it away.",
                ),
            )
        }
    }

    // MARK: - 触感

    private var feelSection: some View {
        Section {
            Toggle(isOn: $hapticsEnabled) {
                Label("Haptics", systemImage: "hand.tap")
            }
            .accessibilityIdentifier("settings.haptics")
        } header: {
            Text("Feel")
        } footer: {
            Text(String(localized: "A light tap when a turn you are watching finishes, when a request is answered, and when a message is sent."))
        }
    }

    // MARK: - 通知

    private var notificationsSection: some View {
        Section {
            ForEach(NotificationKind.allCases, id: \.self) { kind in
                Toggle(isOn: binding(for: kind)) {
                    Label(title(for: kind), systemImage: symbol(for: kind))
                }
                .accessibilityIdentifier(identifier(for: kind))
            }
            LabeledContent {
                Text(permission?.description ?? String(localized: "Checking…"))
            } label: {
                Label("iOS notifications", systemImage: "bell.badge")
            }
            .accessibilityIdentifier("settings.notify.authorization")
        } header: {
            Text("Notifications")
        } footer: {
            // `String(localized:)` rather than a literal, and the whole sentence
            // in one piece: `Text` given a concatenation of literals resolves to
            // the `StringProtocol` overload, which is not localized -- and a
            // Chinese screen with an English paragraph in the middle of it is
            // exactly what that looks like.
            Text(
                String(
                    localized: "A notification whose kind is switched off is dropped when it arrives, whatever iOS is set to. The line above is the system permission: if it says notifications are off, no switch here can bring them back.",
                ),
            )
        }
    }

    /// The switch for one kind, written straight through to the stored value.
    ///
    /// Built by hand rather than projected with `@Bindable`, because a kind is an
    /// argument and not a property: there is no key path to a `Bool`. The write
    /// goes through `values`, whose `didSet` persists it and logs it, so a switch
    /// flipped here is on disk before the finger is off the screen.
    ///
    /// - Parameter kind: the notification kind.
    /// - Returns: a binding for its switch.
    private func binding(for kind: NotificationKind) -> Binding<Bool> {
        Binding(
            get: { model.settings.values.notifications.isEnabled(kind) },
            set: { model.settings.values.notifications.set($0, for: kind) },
        )
    }

    /// What one kind is called on screen.
    /// - Parameter kind: the notification kind.
    /// - Returns: its label.
    private func title(for kind: NotificationKind) -> String {
        switch kind {
        case .turnFinished: String(localized: "Task complete")
        case .turnInterrupted: String(localized: "Task interrupted")
        case .question: String(localized: "Model question")
        case .approval: String(localized: "Permission needed")
        }
    }

    /// The symbol for one kind.
    /// - Parameter kind: the notification kind.
    /// - Returns: an SF Symbol name.
    private func symbol(for kind: NotificationKind) -> String {
        switch kind {
        case .turnFinished: "checkmark.circle"
        case .turnInterrupted: "exclamationmark.triangle"
        case .question: "questionmark.bubble"
        case .approval: "hand.raised"
        }
    }

    /// The accessibility identifier for one kind's switch.
    ///
    /// Built from the kind's *wire* name rather than from its Swift case name, so
    /// the identifier is one derivation in one place: `settings.notify.turn-finished`,
    /// not `settings.notify.turnFinished`. A UI test asks for the hyphenated form,
    /// and asking for the other one finds nothing at all -- which is how this was
    /// learned.
    ///
    /// - Parameter kind: the notification kind.
    /// - Returns: the identifier a UI test looks for.
    private func identifier(for kind: NotificationKind) -> String {
        "settings.notify.\(kind.rawValue)"
    }

    // MARK: - 实时活动

    private var liveActivitySection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { model.settings.values.liveActivitiesEnabled },
                set: { model.settings.values.liveActivitiesEnabled = $0 },
            )) {
                Label("Live Activity", systemImage: "bolt.horizontal.circle")
            }
            .accessibilityIdentifier("settings.liveActivity")
        } header: {
            Text("Live Activity")
        } footer: {
            Text(
                String(
                    localized: "Shows a running turn on the Lock Screen. Switching it off takes an activity that is up down with it and stops a new one from starting; it does not touch the conversation.",
                ),
            )
        }
    }

    // MARK: - 传输

    /// Which routes this phone may use.
    ///
    /// These two are rules, not preferences: the model closes a link that is
    /// using a route the moment its switch is turned off, and neither switch's
    /// route is dialled or probed again until it is turned back on. The footers
    /// say so plainly, because a switch that only changes the next reconnect is
    /// how "I turned that off" became a bug report.
    // MARK: - 本地 Agent

    /// The agent that runs on this phone: one screen, and the promise that it
    /// stops when the app does.
    ///
    /// The promise is the footer rather than a switch, because there is no
    /// switch: iOS suspends the process, and pretending otherwise on a settings
    /// screen would be the one lie this app does not tell.
    private var localAgentSection: some View {
        Section {
            NavigationLink {
                LocalAgentModelsView(agent: model.localAgent) {
                    Task { await model.reloadCatalogs() }
                }
            } label: {
                Label("Model configuration", systemImage: "cpu")
            }
            .accessibilityIdentifier("settings.localAgent.models")

            Button(role: .destructive) {
                confirmingLocalClear = true
            } label: {
                HStack(spacing: 8) {
                    Label("Clear local sessions", systemImage: "trash")
                    Spacer(minLength: 4)
                    if let localAgentBytes {
                        Text(ByteCountFormatter.string(fromByteCount: localAgentBytes, countStyle: .file))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .accessibilityIdentifier("settings.localAgent.clear")
        } header: {
            Text("On-Device Agent (Experimental)")
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                Text("The on-device agent works only while this app is in the foreground. Leaving the app or locking the screen stops a running turn. It does not use the relay and does not consume account credits.")
                Text("Its workspaces are folders in this app's Documents directory: open the Files app, choose On My iPhone, then DSH-Mizar.")
            }
        }
        .confirmationDialog(
            Text("Clear local sessions"),
            isPresented: $confirmingLocalClear,
            titleVisibility: .visible,
        ) {
            Button("Delete", role: .destructive) {
                Task { await clearLocalData() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Sessions written by the on-device agent are kept on this phone. Clearing removes them; the workspace folders and the model configuration are kept.")
        }
    }

    /// Clear the agent's sessions, keeping its configuration and the files.
    private func clearLocalData() async {
        if model.isLocalAgentMode {
            // Leaving the mode drops the connection this screen was reading
            // through; opening the last computer instead of sitting on a
            // screen with nothing behind it is the state the operator was in
            // before they picked the agent.
            await model.leaveLocalAgent()
            if let last = model.hosts.last { await model.open(hostId: last.hostId) }
        }
        try? model.localAgent.clearData()
        localAgentBytes = model.localAgent.storedByteCount
        model.localAgent.refreshKeyPresence()
        mizarSuccess.toggle()
    }

    private var transferSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { model.settings.values.localNetworkFirst },
                set: { model.settings.values.localNetworkFirst = $0 },
            )) {
                Label("Local network first", systemImage: "wifi")
            }
            .accessibilityIdentifier("settings.transfer.lanPriority")

            // Off by default, and the footer says what it costs rather than
            // what it promises: a punch that fails adds seconds to a reconnect
            // that would otherwise have been the relay straight away.
            Toggle(isOn: Binding(
                get: { model.settings.values.directConnection },
                set: { model.settings.values.directConnection = $0 },
            )) {
                Label("P2P direct connection (Experimental)", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
            }
            .accessibilityIdentifier("settings.transfer.directConnection")
        } header: {
            Text("Transfer")
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                Text(
                    String(
                        localized: "Off is a rule, not a preference: this phone does not use the computer's local address at all. An open local link is closed at once and reconnects use the relay, which also makes every reconnect faster.",
                    ),
                )
                Text(
                    String(
                        localized: "P2P direct connection asks this computer and your phone to reach each other without the relay, falling back to the relay when the two networks will not allow it. Off closes a punched link and never attempts another.",
                    ),
                )
            }
        }
    }

    // MARK: - 文件

    /// The files this phone has read, and the way to get the space back.
    ///
    /// A cache the operator cannot see is a cache they cannot trust: the number
    /// is here so "why is the app 300 MB" has an answer on the screen, and the
    /// button is here because the answer to that question should be one tap
    /// away. Nothing in the app depends on these files — every one of them can be
    /// read from the computer again — so clearing them needs no confirmation.
    private var filesSection: some View {
        Section {
            LabeledContent {
                Text(cacheSummary)
                    .monospacedDigit()
                    .accessibilityIdentifier("settings.files.size")
            } label: {
                Label("Previewed files", systemImage: "doc.text.magnifyingglass")
            }

            Button(role: .destructive) {
                Task {
                    await preview?.clearCache()
                    mizarSuccess = true
                }
            } label: {
                Label("Clear file cache", systemImage: "trash")
            }
            .disabled((preview?.cacheFiles ?? 0) == 0)
            .accessibilityIdentifier("settings.files.clear")
            .mizarFeedback(.success, trigger: mizarSuccess)
        } header: {
            Text("Files")
        } footer: {
            Text(
                String(
                    localized: "Files the model delivered are kept on this phone so a second look does not send them again. Clearing them frees the space; the next preview reads the file from the computer.",
                ),
            )
        }
        .task { await preview?.refreshCacheUsage() }
    }

    /// What the cache holds, as one line.
    private var cacheSummary: String {
        let files = preview?.cacheFiles ?? 0
        guard files > 0 else { return String(localized: "Empty") }
        let bytes = preview?.cacheBytes ?? 0
        return String(format: String(localized: "%lld files · %@"), files, Self.size(bytes))
    }

    /// A byte count, the way the log export says it.
    ///
    /// - Parameter bytes: how many bytes.
    /// - Returns: a short human figure.
    static func size(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    // MARK: - 日志

    private var logsSection: some View {
        Section {
            Button {
                Task { await export() }
            } label: {
                Label("Export logs", systemImage: "square.and.arrow.up")
            }
            .disabled(exporting)
            .accessibilityIdentifier("settings.logs.export")

            if exporting {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Packing the log…")
                }
                .accessibilityIdentifier("settings.logs.exporting")
            }

            if let archive = model.lastLogExport {
                // The file's name and size, kept on screen after the share sheet
                // goes away: "did that work" is a question with an answer, and
                // the answer is not "tap it again".
                LabeledContent {
                    Text(archive.readableSize)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(archive.fileName)
                            .font(.footnote.monospaced())
                        Text("Last export, \(archive.fileCount) files, \(archive.recordCount) entries")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("settings.logs.lastArchive")
            } else if model.log.count > 0 {
                // Before the first export, what there is to export. After one,
                // the file itself is the more useful row.
                LabeledContent {
                    Text("\(model.log.count)")
                        .monospacedDigit()
                } label: {
                    Label("Entries recorded", systemImage: "text.alignleft")
                }
                .accessibilityIdentifier("settings.logs.count")
            }
        } header: {
            Text("Logs")
        } footer: {
            Text(
                String(
                    localized: "A zip with this build and phone, the settings above, every request to the computer and how it ended, the connection attempts, the sync progress and the recent host events. Device tokens and pairing codes are removed before the file is written, and conversations are not in it.",
                ),
            )
        }
    }

    /// Build the archive and offer it to the share sheet.
    private func export() async {
        exporting = true
        // The flag is cleared on every path: an export that failed and left the
        // button disabled would be a screen with no way to try again.
        defer { exporting = false }
        sharing = await model.exportLogs()
    }

    // MARK: - 关于

    /// The tools that only exist for testing or for a host without an account.
    ///
    /// Pairing is the old way in. Accounts replaced it for everyday use, but a
    /// developer machine, a relay that has not been flipped to accounts, and a
    /// UI test all still need the code path.
    private var developerSection: some View {
        Section {
            Button("Pair a computer") {
                showingPairing = true
            }
            .accessibilityIdentifier("settings.pair")
        } header: {
            Text("Developer")
        } footer: {
            Text("Pairing with a code is kept for development; sign in above to find your computers by account.")
        }
        .sheet(isPresented: $showingPairing) {
            PairingSheet()
        }
    }

    private var aboutSection: some View {
        Section {
            Button {
                openSource()
            } label: {
                LabeledContent {
                    Image(systemName: "arrow.up.right")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } label: {
                    Label("Source code", systemImage: "chevron.left.forwardslash.chevron.right")
                }
            }
            .accessibilityIdentifier("settings.about.source")

            // 兑换邀请码 lives on the account screen, next to the plan it pays
            // for: an invite is an account thing, and About is about the build.
            LabeledContent {
                Text(AppModel.versionLine)
                    .monospacedDigit()
            } label: {
                Label("Version", systemImage: "number")
            }
            .accessibilityIdentifier("settings.about.version")
        } header: {
            Text("About")
        }
    }

    // MARK: - 社区

    /// Where to find the project and the people using it.
    ///
    /// Two doors, both of which leave the app rather than opening a page of
    /// their own: the website is the operator's own browser (their choice of
    /// one, and its history), and the QQ group is QQ. Nothing is imitated here
    /// -- an in-app web view of a page the app does not own is a second browser
    /// with none of the first one's affordances.
    ///
    /// It sits between 关于 and 开发者鸣谢 because that is the order of the
    /// questions: what this build is, where its community is, who wrote it.
    private var communitySection: some View {
        Section {
            Button {
                openWebsite()
            } label: {
                LabeledContent {
                    Image(systemName: "arrow.up.right")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } label: {
                    Label("Website", systemImage: "globe")
                }
            }
            .accessibilityIdentifier("settings.community.website")

            Button {
                openQQGroup()
            } label: {
                LabeledContent {
                    Image(systemName: "arrow.up.right")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } label: {
                    Label("QQ group", systemImage: "bubble.left.and.bubble.right")
                }
            }
            .accessibilityIdentifier("settings.community.qq")

            // Said only when it happened: a permanent footnote about an app the
            // operator may well have installed would be noise on every visit.
            if qqNumberCopied {
                Text("QQ is not installed. The group number has been copied to the clipboard.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.rise)
                    .accessibilityIdentifier("settings.community.qq.copied")
            }
        } header: {
            Text("Community")
        }
    }

    /// The project's own page, in the operator's browser.
    private func openWebsite() {
        guard let url = URL(string: "https://dsh-mizar.shirazu-nagisa.com") else { return }
        openURL(url)
    }

    /// The feedback group, in QQ.
    ///
    /// QQ answers a group card at `mqqapi://card/show_pslcard`, which opens the
    /// group's own page inside QQ -- one tap from joining, rather than a number
    /// the operator has to copy out and search for. A phone without QQ has no
    /// handler for that scheme at all, so the number goes to the clipboard and
    /// the section says so: a tap that appears to do nothing is the one outcome
    /// worth ruling out.
    private func openQQGroup() {
        let group = "1130443236"
        let card = URL(string: "mqqapi://card/show_pslcard?src_type=internal&version=1&uin=\(group)&card_type=group&source=qrcode")
        if let card, UIApplication.shared.canOpenURL(card) {
            UIApplication.shared.open(card)
            return
        }
        UIPasteboard.general.string = group
        withMizarAnimation(.mizarSmooth) { qqNumberCopied = true }
    }

    // MARK: - 鸣谢

    /// The contributors, one row each, tappable to their GitHub profile.
    private var creditsSection: some View {
        Section {
            if model.credits.contributors.isEmpty {
                HStack(spacing: 10) {
                    if case .loading = model.credits.state {
                        ProgressView().controlSize(.small)
                    }
                    Text(creditsEmptyText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("settings.credits.empty")
                }
                .padding(.vertical, 4)
            } else {
                ForEach(model.credits.contributors) { contributor in
                    Link(destination: contributor.profileURL) {
                        ContributorRow(
                            contributor: contributor,
                            avatar: model.credits.avatar(for: contributor.login),
                        )
                    }
                    .accessibilityIdentifier("settings.credits.row.\(contributor.login)")
                }
            }
        } header: {
            Text("Credits")
        }
    }

    /// What an empty list says, by state.
    private var creditsEmptyText: String {
        switch model.credits.state {
        case .failed(let message): message
        case .loading: String(localized: "Loading contributors…")
        default: String(localized: "No contributors to show yet.")
        }
    }

    /// Open the project in the default browser.
    private func openSource() {
        // The system's own opener, so the operator's browser choice is honoured
        // and nothing here pretends to be a browser view.
        guard let url = URL(string: "https://github.com/ShirazuNagisa/DSH-Mizar") else { return }
        openURL(url)
    }
}

#Preview {
    SettingsView().environment(AppModel())
}

/// One contributor: avatar, name, what they did, and the way to their profile.
struct ContributorRow: View {
    let contributor: Contributor
    let avatar: UIImage?

    var body: some View {
        HStack(spacing: 12) {
            avatarView
                .frame(width: 32, height: 32)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(contributor.name ?? contributor.login)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(contributor.name == nil
                    ? contributor.detail
                    : "@\(contributor.login) · \(contributor.detail)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: "arrow.up.right")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var avatarView: some View {
        if let avatar {
            Image(uiImage: avatar).resizable().scaledToFill()
        } else {
            ZStack {
                Circle().fill(.fill.tertiary)
                Image(systemName: "person.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
