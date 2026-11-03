//
//  HostListView.swift
//  DSH-Mizar
//
//  The machines this phone is paired with, and the way to add another.
//
//  This is the first screen once anything is paired, and the only screen when
//  nothing is. A phone that manages one computer is the common case and gets a list
//  of one; a phone that manages three should not have to unpair to switch, which
//  is what the first version required.
//
//  Naming lives here rather than on the host. `Shirazus-Mac-mini.local` is fine
//  once and useless three times, and a name the operator typed on this phone is
//  theirs to change without touching a machine.
//

import SwiftUI
import MizarKit

/// Every paired machine, with a way to add more.
///
/// The window that drops out of the computer's name at the top of the sidebar.
/// Choosing a row switches to that computer, and renaming one goes deeper inside
/// the same window rather than opening another on top of it. Adding one is the
/// exception: the pairing card is a sheet, because it has to grow for its
/// camera and a popover cannot (see ``PairingSheet``).
struct HostListView: View {
    @Environment(AppModel.self) private var model
    @State private var path: [HostRoute] = []
    /// The computer whose agent is being chosen, if any.
    ///
    /// Both kinds of row end here: a computer the account found, and one this
    /// phone paired with by scanning a code. They differ in how the token is
    /// minted, not in the question -- a computer runs three agents and a phone
    /// that opens one has to say which.
    @State private var choosingEngine: AgentChoice?
    /// Which connection is being opened, so the sheet can show a spinner.
    @State private var openingEngine: AgentEngine?
    /// The account computer whose local name is being edited.
    @State private var renamingAccount: AccountDesktop?
    /// Whether the computer list is being read again.
    @State private var refreshing = false

    /// A computer waiting for its agent to be chosen.
    private enum AgentChoice: Identifiable {
        case account(AccountDesktop)
        case paired(PairedHost)

        var id: String {
            switch self {
            case .account(let desktop): return "account-\(desktop.deviceId)"
            case .paired(let host): return "paired-\(host.hostId)"
            }
        }

        var name: String {
            switch self {
            case .account(let desktop): return desktop.name
            case .paired(let host): return host.displayName
            }
        }

        /// The agents to offer, when the computer has said which it serves.
        var engines: [AgentEngine] {
            switch self {
            // The account's computers run this desktop, which serves all three.
            case .account: return AgentEngine.allCases
            case .paired(let host):
                return host.engineChoices.compactMap(AgentEngine.init(rawValue:))
            }
        }

        var current: AgentEngine? {
            switch self {
            case .account: return nil
            case .paired(let host): return host.engine.flatMap(AgentEngine.init(rawValue:))
            }
        }
    }

    /// One row of the account's computers.
    @ViewBuilder
    private func accountRow(_ desktop: AccountDesktop) -> some View {
        Button {
            choosingEngine = .account(desktop)
        } label: {
            AccountDesktopRow(
                desktop: desktop,
                label: model.accountLabel(for: desktop.deviceId)
                    ?? model.hosts.first { $0.hostId == desktop.deviceId }?.label,
            )
        }
        .buttonStyle(.pressable(scale: 0.98))
        .disabled(!desktop.online)
        .accessibilityIdentifier("host.account.\(desktop.deviceId)")
        .contextMenu {
            Button {
                renamingAccount = desktop
            } label: {
                Label("Rename…", systemImage: "pencil")
            }
        }
        .accessibilityAction(named: Text("Rename…")) {
            renamingAccount = desktop
        }
    }

    /// Choose an agent on a computer and open it.
    ///
    /// The token the relay hands back is already scoped to this agent, so the
    /// computer filters the list it sends: the phone never sees another agent's
    /// sessions even for a moment.
    private func connect(_ desktop: AccountDesktop, engine: AgentEngine) async {
        openingEngine = engine
        defer { openingEngine = nil }
        do {
            let connection = try await model.account.connect(to: desktop, engine: engine)
            guard let origin = URL(string: RelayTier.paidBaseURL) else { return }
            await model.openAccountDesktop(
                desktop,
                using: connection,
                at: origin,
                engine: engine,
            )
        } catch {
            model.reportAccountFailure(error)
        }
    }

    enum HostRoute: Hashable {
        case rename(String)
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 6) {
                    // The agent that lives on this phone, above the computers it
                    // can reach: it is the one choice that needs no other device
                    // to be awake.
                    Button {
                        Task { await model.enterLocalAgent() }
                    } label: {
                        LocalAgentRow(
                            state: model.localAgent.state,
                            configured: model.localAgent.hasConfiguredProvider,
                            isOpen: model.isLocalAgentMode,
                        )
                    }
                    .buttonStyle(.pressable(scale: 0.98))
                    .disabled(model.localAgent.state == .starting)
                    .accessibilityIdentifier("host.row.local")

                    sectionHeader("My computers")
                    // Manual pairings are no longer an entrance. In a debug
                    // build launched with a pairing URI they are still drawn
                    // for the UI suite; the product shows the account's list.
                    if AppModel.showsManualPairing {
                    ForEach(model.hosts, id: \.hostId) { host in
                        Button {
                            // A computer that serves three agents is asked which
                            // one first. One that has never said (an older host,
                            // or a pairing made before this existed) opens as it
                            // always did, and the picker appears on the sidebar
                            // once the host has answered.
                            if host.engineChoices.count > 1 {
                                choosingEngine = .paired(host)
                            } else {
                                Task { await model.open(hostId: host.hostId) }
                            }
                        } label: {
                            HostRow(host: host, isOpen: model.host?.hostId == host.hostId, live: model.isConnected)
                        }
                        .buttonStyle(.pressable(scale: 0.98))
                        .accessibilityIdentifier("host.row.\(host.hostId)")
                        .contextMenu {
                            if host.engineChoices.count > 1 {
                                Button {
                                    choosingEngine = .paired(host)
                                } label: {
                                    Label("Choose Agent…", systemImage: "square.stack.3d.up")
                                }
                            }
                            Button {
                                path.append(.rename(host.hostId))
                            } label: {
                                Label("Rename…", systemImage: "pencil")
                            }
                        }
                    }
                    }

                    // The account's computers, in the same section as the
                    // paired ones: to the operator they are one list -- the
                    // machines this phone can open -- and which token reaches
                    // them is this app's business, not theirs.
                    if model.account.session?.isUsable == true {
                        ForEach(model.account.desktops) { desktop in
                            accountRow(desktop)
                        }
                    }
                    if model.account.session?.isUsable != true, model.hosts.isEmpty {
                        Text("Your computers appear here after you sign in.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                    }

                    Text("Tap a computer to choose the agent to connect to.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.top, 4)
                        .padding(.bottom, 2)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .scrollBounceBehavior(.basedOnSize)
            // "Agents", not "Computers": the list now holds one agent that is
            // not a computer at all.
            .navigationTitle("Agents")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task {
                            refreshing = true
                            await model.account.loadDesktops()
                            refreshing = false
                        }
                    } label: {
                        if refreshing {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(refreshing)
                    .accessibilityLabel(Text("Refresh computers"))
                    .accessibilityIdentifier("hosts.refresh")
                }
            }
            .task {
                // One Keychain read per opening, not per render: the red pill is
                // an answer about stored keys, and saving one in Settings is a
                // trip away from this list.
                model.localAgent.refreshKeyPresence()
            }
            .navigationDestination(for: HostRoute.self) { route in
                switch route {
                case .rename(let hostId):
                    if let host = model.hosts.first(where: { $0.hostId == hostId }) {
                        RenameForm(host: host, skipTitle: "Cancel") { name in
                            if let name { Task { await model.rename(hostId: host.hostId, to: name) } }
                            path.removeAll()
                        }
                    }
                }
            }
            .sheet(item: $choosingEngine) { choice in
                EnginePickerSheet(
                    desktopName: choice.name,
                    engines: choice.engines,
                    current: choice.current,
                    allowsAll: choice.current != nil,
                ) { engine in
                    switch choice {
                    case .account(let desktop):
                        guard let engine else { return }
                        Task { await connect(desktop, engine: engine) }
                    case .paired(let host):
                        Task { await model.chooseEngine(engine, for: host.hostId) }
                    }
                }
            }
            .sheet(item: $renamingAccount) { desktop in
                AccountRenameForm(desktop: desktop, current: model.accountLabel(for: desktop.deviceId)) { name in
                    Task { await model.renameAccountComputer(deviceId: desktop.deviceId, to: name) }
                }
            }
        }
    }
}

/// The agent that runs on this phone.
///
/// First in the list because it is the only row that needs no other device to
/// be awake, and drawn with the same measures as a computer so the two read as
/// the same kind of choice. The two capsules are the whole difference: "On-device"
/// says where it runs, and the red one appears only while no model provider has
/// been configured -- see `APIKeyPresence`.
private struct LocalAgentRow: View {
    let state: LocalAgentController.State
    let configured: Bool
    let isOpen: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "cpu")
                .font(.body.weight(.medium))
                .foregroundStyle(isOpen ? Theme.onAccent : Color.secondary)
                .frame(width: 34, height: 34)
                .background(
                    isOpen ? AnyShapeStyle(Color.accentColor.gradient) : AnyShapeStyle(.fill.tertiary),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous),
                )

            VStack(alignment: .leading, spacing: 3) {
                Text("On-Device Agent (Experimental)")
                    .font(.body.weight(isOpen ? .semibold : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    // The title is the part that can be guessed from context;
                    // the capsules are the part that answers "why can't I use
                    // this", so the title yields its width first.
                    .minimumScaleFactor(0.9)

                HStack(spacing: 4) {
                    badge(
                        "On-device",
                        identifier: "host.local.badge.local",
                        tint: .secondary,
                        fill: AnyShapeStyle(.fill.tertiary),
                    )
                    if !configured {
                        badge(
                            "No model configured",
                            identifier: "host.local.badge.unconfigured",
                            tint: .red,
                            fill: AnyShapeStyle(Color.red.opacity(0.15)),
                        )
                    }
                }
                // Capsules keep their full text: a warning that reads "No model
                // configu…" is not a warning.
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)

                if case .failed(let message) = state {
                    // The one state that must not be silent: a tap that did not
                    // work has to say why, in the row it happened in.
                    Text(verbatim: message)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 4)

            if case .starting = state {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityIdentifier("host.local.starting")
            } else if isOpen {
                HStack(spacing: 5) {
                    Circle()
                        .fill(Theme.running)
                        .frame(width: 6, height: 6)
                    Text("connected")
                        .font(.caption2.weight(.medium))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(.fill.quaternary, in: Capsule())
                .transition(.pop)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background {
            if isOpen {
                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                    .fill(Theme.selectionFill)
            }
        }
        .contentShape(.rect)
        .animation(.mizarSmooth, value: isOpen)
    }

    /// One capsule under the title, in the same language as ``HostBadges``.
    private func badge(
        _ text: LocalizedStringKey,
        identifier: String,
        tint: Color,
        fill: AnyShapeStyle,
    ) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(fill, in: Capsule())
            .accessibilityIdentifier(identifier)
    }
}

/// One machine.
private struct HostRow: View {
    let host: PairedHost
    let isOpen: Bool
    let live: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "desktopcomputer")
                .font(.body.weight(.medium))
                .foregroundStyle(isOpen ? Theme.onAccent : Color.secondary)
                .frame(width: 34, height: 34)
                .background(
                    isOpen ? AnyShapeStyle(Color.accentColor.gradient) : AnyShapeStyle(.fill.tertiary),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous),
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(host.displayName)
                    .font(.body.weight(isOpen ? .semibold : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let desktop = host.desktop, !desktop.isEmpty {
                    // What the machine is, rather than another identifier: the
                    // system first, then the desktop product, as two capsules.
                    HostBadges(desktop: desktop)
                        .accessibilityIdentifier("host.desktop.\(host.hostId)")
                } else {
                    // Older hosts cannot answer `desktop`; their own name (or
                    // when they were paired) is still the useful line, and an
                    // empty capsule would be worse than no badge at all.
                    Text(host.label == nil ? host.pairedAt.formatted(.relative(presentation: .named)) : host.hostName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            if isOpen {
                HStack(spacing: 5) {
                    Circle()
                        .fill(live ? Theme.running : Color.secondary)
                        .frame(width: 6, height: 6)
                    Text(live ? "connected" : "offline")
                        .font(.caption2.weight(.medium))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(.fill.quaternary, in: Capsule())
                .transition(.pop)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background {
            if isOpen {
                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                    .fill(Theme.selectionFill)
            }
        }
        .contentShape(.rect)
        .animation(.mizarSmooth, value: isOpen)
    }
}

/// What a computer is: its operating system, then the desktop product.
///
/// Two capsules rather than one string because the facts are independent -- a
/// DSH plugin on Windows and a Codex plugin on macOS are both ordinary -- and a
/// single label would read as one compound product name. The accent fill is the
/// same one the app uses for the open machine, so these read as labels rather
/// than as another line of body text.
private struct HostBadges: View {
    let desktop: HostDesktop

    var body: some View {
        HStack(spacing: 4) {
            ForEach(desktop.labels.indices, id: \.self) { index in
                Text(desktop.labels[index])
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.onAccent)
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 1)
                    .frame(minHeight: 19)
                    .background(Color.accentColor, in: Capsule())
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The name prompt, as the contents of a small window.
///
/// Offered once, immediately after pairing, because that is the moment the
/// operator still knows which machine they just scanned -- out of the
/// computer's name at the top of the sidebar, where the name will be. Offered
/// again from the row's menu when they have thought of a better one.
/// Rename an account computer on this phone.
///
/// Same rule as a paired host's name: it is local, never sent, and leaving it
/// empty falls back to the host name. Account computers have no `PairedHost`
/// row in the product, so the name lives in UserDefaults under the device id.
struct AccountRenameForm: View {
    let desktop: AccountDesktop
    let current: String?
    let onSave: (String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Name this computer")
                .font(.headline)
            TextField(desktop.name, text: $name)
                .textInputAutocapitalization(.words)
                .focused($focused)
                .submitLabel(.done)
                .onSubmit { save() }
                .padding(.horizontal, 14)
                .frame(height: 44)
                .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
                .accessibilityIdentifier("rename.account.field")
            Text("Shown only on this phone. Leave it empty to use the machine's own name, \(desktop.name).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button {
                    onSave(nil)
                    dismiss()
                } label: {
                    Text("Cancel").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .accessibilityIdentifier("rename.account.cancel")
                Button {
                    save()
                } label: {
                    Text("Save").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .accessibilityIdentifier("rename.account.save")
            }
            .controlSize(.large)
            .padding(.top, 4)
        }
        .padding(18)
        .frame(width: 320)
        .onAppear {
            name = current ?? ""
            focused = true
        }
    }

    private func save() {
        onSave(name)
        dismiss()
    }
}

struct RenameForm: View {
    let host: PairedHost
    /// "Skip" right after pairing, "Cancel" from the menu.
    var skipTitle: LocalizedStringKey = "Skip"
    let onSave: (String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Name this computer")
                .font(.headline)
            TextField(host.hostName, text: $name)
                .textInputAutocapitalization(.words)
                .focused($focused)
                .submitLabel(.done)
                .onSubmit { save() }
                .padding(.horizontal, 14)
                .frame(height: 44)
                .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
                .accessibilityIdentifier("rename.field")
            Text("Shown only on this phone. Leave it empty to use the machine's own name, \(host.hostName).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                // "Skip", not "Cancel", after a pairing: naming is optional, and
                // a pairing that has already succeeded must not look like
                // something the operator can back out of from here.
                Button {
                    onSave(nil)
                    dismiss()
                } label: {
                    Text(skipTitle).frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .accessibilityIdentifier("rename.skip")
                Button {
                    save()
                } label: {
                    Text("Save").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .accessibilityIdentifier("rename.save")
            }
            .controlSize(.large)
            .padding(.top, 4)
        }
        .padding(18)
        .frame(width: 320)
        .onAppear {
            name = host.label ?? ""
            focused = true
        }
    }

    private func save() {
        onSave(name)
        dismiss()
    }
}

extension PairedHost: @retroactive Identifiable {
    /// Identity for `popover(item:)`.
    public var id: String { hostId }
}

/// The screen a phone shows when it has never been paired.
///
/// It says what to do rather than showing an empty list, and it is the whole of
/// the first-run experience: there is nothing else this app can usefully do
/// without a machine on the other end. Drawn in the icon's own navy, with the
/// mark sending its signal up and out -- looking for a computer to answer it.
///
/// The mark is injectable so the snapshot suite can pin its resting state
/// (`MizarStar(motion: .still)`, which is what Reduce Motion rests on): the
/// loop runs on a repeating keyframe animator, which no render transaction
/// stops, and `accessibilityReduceMotion` is a get-only environment key the
/// harness cannot set. On screen it is always turning; see the convenience
/// initialiser.
struct UnpairedView<Mark: View>: View {
    /// Optional: the snapshot harness renders this screen without a model, and
    /// an injected-environment read that traps would take the golden with it.
    @Environment(AppModel.self) private var model: AppModel?
    @State private var showingPairing = false
    @State private var opening = false
    /// The mark above the copy. Always the searching mark on screen.
    private let mark: Mark

    /// Whether an account can list this person's computers.
    private var signedIn: Bool {
        model?.account.session?.isUsable == true
    }

    init(mark: Mark) {
        self.mark = mark
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Theme.navy, Theme.navyDeep],
                startPoint: .top,
                endPoint: .bottom,
            )
            .ignoresSafeArea()
            RadialGradient(
                colors: [Color.accentColor.opacity(0.22), .clear],
                center: .init(x: 0.5, y: 0.34),
                startRadius: 10,
                endRadius: 320,
            )
            .ignoresSafeArea()

                VStack(spacing: 0) {
                    Spacer()
                    mark
                        .frame(width: 112)
                        .padding(.bottom, 36)
                    Text(AppModel.showsManualPairing
                        ? "Install the plugin, then scan"
                        : "Choose a computer")
                        .font(.largeTitle.weight(.bold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                        .accessibilityIdentifier("unpaired.choose")
                    if signedIn {
                        // Who this phone thinks it is: a wrong account is the
                        // one failure this screen cannot otherwise show.
                        Text(model?.account.user?.email ?? String(localized: "Signed in"))
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.5))
                            .padding(.top, 6)
                    }
                    if signedIn {
                        Text("Computers signed in to the same account are below; tap one to connect.")
                            .font(.body)
                            .foregroundStyle(.white.opacity(0.7))
                            .multilineTextAlignment(.center)
                            .padding(.top, 12)
                            .padding(.horizontal, 30)
                        computers
                            .padding(.top, 18)
                            .padding(.horizontal, 12)
                        if let error = model?.lastError {
                            Text(error)
                                .font(.footnote)
                                .foregroundStyle(.red.opacity(0.9))
                                .multilineTextAlignment(.center)
                                .padding(.top, 10)
                                .padding(.horizontal, 20)
                        }
                        if let model, !model.account.desktops.isEmpty,
                           model.account.desktops.allSatisfy({ !$0.online }) {
                            Text("The computer is offline. Make sure AGI Mizar is running on it.")
                                .font(.footnote)
                                .foregroundStyle(.white.opacity(0.55))
                                .multilineTextAlignment(.center)
                                .padding(.top, 10)
                                .padding(.horizontal, 20)
                        }
                        Button {
                            Task { await model?.account.loadDesktops() }
                        } label: {
                            Label("Refresh list", systemImage: "arrow.clockwise")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.white.opacity(0.75))
                                .padding(.vertical, 10)
                        }
                        .buttonStyle(.pressable(scale: 0.97, dims: true))
                        .accessibilityIdentifier("unpaired.refresh")
                    } else {
                        Text("Sign in to find the computers on your account.")
                            .font(.body)
                            .foregroundStyle(.white.opacity(0.7))
                            .multilineTextAlignment(.center)
                            .padding(.top, 12)
                            .padding(.horizontal, 30)
                    }
                    Spacer()
                    if AppModel.showsManualPairing {
                        Button {
                            showingPairing = true
                        } label: {
                            Label("Scan the code", systemImage: "qrcode.viewfinder")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.glassProminent)
                        .controlSize(.extraLarge)
                        .accessibilityIdentifier("unpaired.scan")
                        // A card over the navy, which can grow for the camera; see
                        // ``PairingSheet``.
                        .sheet(isPresented: $showingPairing) {
                            PairingSheet()
                        }
                        .padding(.horizontal, 28)
                        Text("Once it is installed, there is nothing else to set up.")
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.5))
                            .padding(.top, 14)
                            .padding(.bottom, 12)
                    } else {
                        Text("The same account is the only way in.")
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.5))
                            .padding(.top, 14)
                            .padding(.bottom, 12)
                    }
                }
        }
        .environment(\.colorScheme, .dark)
    }

    /// The account's computers: no camera, no code, nothing to type.
    private var computers: some View {
        VStack(spacing: 0) {
            let desktops = model?.account.desktops ?? []
            if desktops.isEmpty {
                Text("Reading the computer…")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.vertical, 18)
            } else {
                ForEach(Array(desktops.enumerated()), id: \.element.id) { entry in
                    if entry.offset > 0 {
                        Divider().overlay(.white.opacity(0.08))
                    }
                    Button {
                        Task { await connect(entry.element, engine: nil) }
                    } label: {
                        AccountDesktopRow(desktop: entry.element)
                    }
                    .buttonStyle(.pressable(scale: 0.98))
                    .disabled(!entry.element.online || opening)
                    .accessibilityIdentifier("unpaired.account.\(entry.element.deviceId)")
                }
            }
        }
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
    }

    /// Choose an agent on a computer and open it, the way the agent list does
    /// once something is paired.
    private func connect(_ desktop: AccountDesktop, engine: AgentEngine?) async {
        opening = true
        defer { opening = false }
        do {
            let connection = try await model?.account.connect(to: desktop, engine: engine)
            guard let connection, let origin = URL(string: RelayTier.paidBaseURL) else { return }
            await model?.openAccountDesktop(desktop, using: connection, at: origin, engine: engine)
        } catch {
            model?.reportAccountFailure(error)
        }
    }
}

extension UnpairedView where Mark == MizarStar {
    /// The screen as it ships: the mark turning for as long as nothing has
    /// answered, which is exactly what is happening.
    init() {
        self.init(mark: MizarStar(motion: .running, size: 112, palette: .ink(.white)))
    }
}

/// One of the account's computers.
struct AccountDesktopRow: View {
    let desktop: AccountDesktop
    var label: String? = nil

    private var displayName: String {
        guard let label, !label.trimmingCharacters(in: .whitespaces).isEmpty else {
            return desktop.name
        }
        return label
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "desktopcomputer")
                .font(.body.weight(.medium))
                .foregroundStyle(desktop.online ? Color.accentColor : Color.secondary)
                .frame(width: 34, height: 34)
                .background(
                    (desktop.online ? AnyShapeStyle(Color.accentColor.opacity(0.12)) : AnyShapeStyle(.fill.tertiary)),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous),
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(displayName)
                    .font(.body.weight(.medium))
                    .foregroundStyle(desktop.online ? .primary : .secondary)
                    .lineLimit(1)
                Text(desktop.online ? String(localized: "Online · tap to choose an agent") : String(localized: "Offline"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            if desktop.online {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .contentShape(.rect)
    }
}

/// A quiet label above a group of rows.
private func sectionHeader(_ title: LocalizedStringKey) -> some View {
    Text(title)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.top, 10)
}
