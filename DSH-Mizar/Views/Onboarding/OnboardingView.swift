//
//  OnboardingView.swift
//  DSH-Mizar
//
//  The first-run guide: welcome, install the desktop app, account, transport,
//  on-device agent, notifications, plan, refresh, and a summary. Full window, no sidebar. Every choice
//  writes the same setting the Settings screen writes, so the guide cannot
//  disagree with the app it hands over to.
//

import MizarKit
import SwiftUI

/// Where the first-run answer lives.
enum OnboardingKeys {
    static let done = "mizar.onboarding.done"
    static let started = "mizar.onboarding.started"
    /// The version of the guide the operator walked through.
    ///
    /// Written when the guide finishes. A phone that was carrying an older
    /// guide has no value here, and walks this one again -- the account and
    /// the settings it already has are kept; the guide is a walk-through, not
    /// a reset.
    static let version = "mizar.onboarding.version"
    /// The guide this build wants walked.
    ///
    /// 0.9.11 is the one that adds the server page and the self-hosted walk:
    /// every phone walks the guide once more, so an existing operator is
    /// asked which relay to use and is shown the page that connects it.
    static let requiredVersion = "0.9.11"

    /// Whether the guide has been walked in the version this build wants.
    static func isComplete(storedVersion: String?) -> Bool {
        guard let storedVersion, !storedVersion.isEmpty else { return false }
        return storedVersion.compare(requiredVersion, options: .numeric) != .orderedAscending
    }
}

struct OnboardingView: View {
    /// Whether this phone has been here before.
    ///
    /// A phone that walks the guide again -- every phone that came from an
    /// older build -- keeps the account and the settings it has, and must not
    /// be asked to sign in again.
    var isUpdate: Bool = false
    let onShowDemo: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL
    @AppStorage(OnboardingKeys.done) private var done = false
    @AppStorage(OnboardingKeys.started) private var started = false
    @AppStorage(OnboardingKeys.version) private var guideVersion = ""
    @State private var wantsLocalAgent = false
    /// Whether the download link is on the clipboard, for the page to say so.
    @State private var releaseLinkCopied = false

    @State private var step: OnboardingStep = Self.debugInitialStep
    @State private var direction = 1
    @State private var accountSheet: AccountSheet?
    @State private var showingModels = false
    @State private var appeared = false

    // The server page's draft. Kept as view state while the operator types;
    // every change is also written to the model, so a mid-guide relaunch comes
    // back to what they entered.
    @State private var serverChoice: ServerMode = .official
    @State private var serverDomain = ""
    @State private var serverPin = ""
    @State private var serverCheck: OnboardingServerCheck = .idle
    @State private var verifiedOrigin: String?
    @State private var checkTask: Task<Void, Never>?

    // The connect page's list and its one pair attempt.
    @State private var directory: DirectoryState = .loading
    @State private var selectedDesktop: SelfHostedDesktop?
    @State private var pairingCode = ""
    @State private var pairingInFlight = false
    @State private var pairedName: String?
    @State private var pairFailure: String?

    /// Everything the connect page's directory read can be doing.
    private enum DirectoryState: Equatable {
        case loading
        case loaded([SelfHostedDesktop])
        case failed(String)
    }

    /// The pages this phone walks, in order.
    ///
    /// The official guide signs in -- the relay's account is what attributes
    /// its traffic -- and shows the plan. The self-hosted guide has no account
    /// and no plan to show, and gains the one page that server needs: pairing
    /// a computer found in its own directory.
    private var visibleSteps: [OnboardingStep] {
        OnboardingNavigation.visibleSteps(mode: model.serverSelection.mode)
    }

    /// Where the current page is in the walk above.
    private var stepIndex: Int {
        OnboardingNavigation.progressIndex(for: step, in: visibleSteps)
    }

    private struct AccountSheet: Identifiable {
        let id = UUID()
        let mode: AccountScreen.Mode
    }

    /// A preview hook: `-mizarOnboardingStep <0...10>` opens the guide on one
    /// page so each page can be looked at without tapping through. Debug only.
    ///
    /// The argument indexes `OnboardingStep.allCases`, not `visibleSteps`: the server
    /// mode is not known until the model has been built, so a fixed number has
    /// to mean one page everywhere. On a self-hosted phone an index for a page
    /// that walk hides (`.connect` / `.account` / `.plan`) still opens it; use
    /// the official walk's pages 0...9 to inspect the shared ones.
    private static var debugInitialStep: OnboardingStep {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-mizarOnboardingStep"),
           arguments.indices.contains(index + 1),
           let raw = Int(arguments[index + 1]),
           let step = OnboardingStep(rawValue: raw) {
            return step
        }
        #endif
        return .welcome
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            background
            VStack(spacing: 0) {
                progress
                ScrollView {
                    ZStack {
                        page
                            .id(step)
                            .transition(pageTransition)
                    }
                    .animation(pageAnimation, value: step)
                    .frame(maxWidth: 640)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, Theme.Space.xxl)
                    .padding(.top, Theme.Space.xxl)
                    .padding(.bottom, Theme.Space.xxl)
                }
                .scrollBounceBehavior(.basedOnSize)
                footer
            }
            .padding(.top, Theme.Space.sm)
        }
        .environment(\.colorScheme, .dark)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            started = true
            // A phone walking the guide again starts from what it already
            // chose: the server it is on, its address and its PIN. A verified
            // self-hosted server stays verified, so the second walk does not
            // ask the operator to prove a working server again.
            serverChoice = model.serverSelection.mode
            serverDomain = model.serverSelection.origin
            serverPin = model.serverSelection.pin
            if model.serverSelection.isSelfHosted {
                verifiedOrigin = model.serverSelection.normalizedOrigin
                serverCheck = verifiedOrigin == nil ? .idle : .success
            }
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-mizarOnboardingLocalAgent") {
                wantsLocalAgent = true
            }
            #endif
            withMizarAnimation(.mizarGentle) { appeared = true }
        }
        .sheet(item: $accountSheet) { sheet in
            NavigationStack {
                AccountScreen(
                    onDone: { accountSheet = nil },
                    initialMode: sheet.mode,
                )
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingModels) {
            NavigationStack {
                LocalAgentModelsView(
                    agent: model.localAgent,
                    onChanged: { model.localAgent.refreshKeyPresence() },
                )
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            showingModels = false
                            model.localAgent.refreshKeyPresence()
                        }
                        .accessibilityIdentifier("onboarding.models.done")
                    }
                }
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .onChange(of: model.account.isLoggedIn) { _, signedIn in
            if signedIn { accountSheet = nil }
        }
    }

    // MARK: - Background and chrome

    private var background: some View {
        ZStack {
            LinearGradient(
                colors: [Theme.navy, Theme.navyDeep],
                startPoint: .top,
                endPoint: .bottom,
            )
            .ignoresSafeArea()
            RadialGradient(
                colors: [Color.accentColor.opacity(0.22), .clear],
                center: .init(x: 0.5, y: 0.22),
                startRadius: 10,
                endRadius: 420,
            )
            .ignoresSafeArea()
        }
    }

    private var progress: some View {
        HStack(spacing: Theme.Space.sm) {
            if stepIndex > 0 {
                Button {
                    goBack()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 38, height: 38)
                }
                .buttonStyle(.glass)
                .accessibilityLabel(Text("Back"))
                .accessibilityIdentifier("onboarding.back")
            }

            HStack(spacing: 5) {
                ForEach(Array(visibleSteps.enumerated()), id: \.element.id) { index, item in
                    Capsule()
                        .fill(index <= stepIndex
                              ? Color.accentColor
                              : Color.white.opacity(0.16))
                        .frame(width: item == step ? 22 : 6, height: 4)
                        .animation(pageAnimation, value: step)
                }
            }
            .accessibilityHidden(true)

            Spacer(minLength: 0)

            Text(verbatim: "\(stepIndex + 1) / \(visibleSteps.count)")
                .font(.caption.weight(.medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.55))
                .accessibilityIdentifier("onboarding.step")
        }
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Theme.Space.xxl)
        .padding(.top, Theme.Space.md)
        .padding(.bottom, Theme.Space.sm)
    }

    @ViewBuilder
    private var page: some View {
        switch step {
        case .welcome:
            welcomePage
        case .server:
            serverPage
        case .desktop:
            desktopPage
        case .connect:
            connectPage
        case .account:
            accountPage
        case .network:
            networkPage
        case .agent:
            agentPage
        case .alerts:
            alertsPage
        case .plan:
            planPage
        case .refresh:
            refreshPage
        case .summary:
            summaryPage
        }
    }

    private var footer: some View {
        VStack(spacing: Theme.Space.md) {
            if step == .welcome || (step == .account && !model.account.isLoggedIn) {
                OfflineDemoButton(action: onShowDemo)
                    .accessibilityIdentifier("onboarding.demo")
            }
            if step == .account, !model.account.isLoggedIn {
                Text(isUpdate
                    ? String(localized: "You can continue without an account.")
                    : String(localized: "Sign in to continue."))
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }
            Button {
                advance()
            } label: {
                Group {
                    if step == .summary {
                        Text("Start using DSH-Mizar")
                    } else {
                        Text("Continue")
                    }
                }
                .font(.headline)
                    .foregroundStyle(Theme.onAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.extraLarge)
            .tint(Color.accentColor)
            .disabled(!canAdvance)
            .opacity(canAdvance ? 1 : 0.45)
            .accessibilityIdentifier(step == .summary ? "onboarding.done" : "onboarding.next")
        }
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Theme.Space.xxl)
        .padding(.top, Theme.Space.md)
        .padding(.bottom, Theme.Space.lg)
        .animation(pageAnimation, value: step)
    }

    // MARK: - Welcome

    private var welcomePage: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xxl) {
            MizarIconTile(size: 88, motion: .assembling, animationToken: 1)
                .shadow(color: Theme.navy.opacity(0.35), radius: 16, y: 8)
                .frame(maxWidth: .infinity, alignment: .leading)

            pageHeader(
                icon: nil,
                title: "Welcome to DSH-Mizar",
                subtitle: "Your computer does the work. This phone stays in control.",
            )

            VStack(alignment: .leading, spacing: Theme.Space.md) {
                featureRow(
                    icon: "desktopcomputer",
                    title: "Your computer runs the agent",
                    detail: "Sessions, files and models stay on your Mac or PC.",
                )
                featureRow(
                    icon: "iphone",
                    title: "This phone is the remote",
                    detail: "Send prompts, approve actions and watch progress from anywhere.",
                )
                featureRow(
                    icon: "lock.shield",
                    title: "An account keeps the relay safe",
                    detail: "Traffic stays attributable; conversations never pass through the account server.",
                )
            }
        }
    }

    // MARK: - Server

    /// The page after the welcome: which relay this phone talks to.
    ///
    /// Asked before anything that depends on the answer. The account, the
    /// plan and background push belong to the official server; a self-hosted
    /// one replaces them with an address, an optional PIN, and a check that
    /// the address really answers as a relay.
    private var serverPage: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xxl) {
            pageHeader(
                icon: "server.rack",
                title: "Server",
                subtitle: "Where should this phone connect?",
            )

            choiceCard(
                selected: serverChoice == .official,
                icon: "cloud",
                title: "Official server",
                detail: "Accounts, plans and background push. The default.",
                identifier: "onboarding.server.official",
            ) {
                chooseServer(.official)
            }

            choiceCard(
                selected: serverChoice == .selfHosted,
                icon: "server.rack",
                title: "Self-hosted server",
                detail: "Your own relay. No account, no plan, and every paid feature unlocked.",
                identifier: "onboarding.server.self",
            ) {
                chooseServer(.selfHosted)
            }

            if serverChoice == .selfHosted {
                card {
                    VStack(alignment: .leading, spacing: Theme.Space.lg) {
                        serverField(
                            title: "Server address",
                            hint: "A domain or host:port. https:// is added when it is missing.",
                        ) {
                            TextField("relay.example.com", text: $serverDomain)
                                .textContentType(.URL)
                                .keyboardType(.URL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .foregroundStyle(.white)
                                .accessibilityIdentifier("onboarding.server.domain")
                                .onChange(of: serverDomain) { _, _ in serverInputChanged() }
                        }

                        serverField(
                            title: "Server PIN (optional)",
                            hint: "Only if the server was installed with a PIN.",
                        ) {
                            SecureField("PIN", text: $serverPin)
                                .textContentType(.password)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .foregroundStyle(.white)
                                .accessibilityIdentifier("onboarding.server.pin")
                                .onChange(of: serverPin) { _, _ in serverInputChanged() }
                        }

                        Button {
                            verifyServer()
                        } label: {
                            HStack(spacing: 8) {
                                if serverCheck == .checking {
                                    ProgressView().controlSize(.small)
                                }
                                Text(serverCheck == .checking ? "Verifying…" : "Verify connection")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.white)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                        }
                        .buttonStyle(.glass)
                        .disabled(serverDomain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  || serverCheck == .checking)
                        .accessibilityIdentifier("onboarding.server.verify")

                        serverCheckStatus
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Text("The server is where your phone and computer meet. Both can be changed later in Settings.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.48))
                .fixedSize(horizontal: false, vertical: true)
        }
        .animation(pageAnimation, value: serverChoice)
        .animation(pageAnimation, value: serverCheck)
    }

    /// One labelled field on the server page, in the guide's dark card.
    private func serverField(
        title: LocalizedStringKey,
        hint: LocalizedStringKey,
        @ViewBuilder field: () -> some View,
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white.opacity(0.62))
            field()
                .font(.body)
                .padding(.horizontal, Theme.Space.md)
                .padding(.vertical, Theme.Space.sm)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                        .strokeBorder(.white.opacity(0.12), lineWidth: 1),
                )
            Text(hint)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.45))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// What the last verification attempt said.
    @ViewBuilder
    private var serverCheckStatus: some View {
        HStack(alignment: .top, spacing: 8) {
            switch serverCheck {
            case .idle:
                Text("Not verified yet.")
                    .foregroundStyle(.white.opacity(0.5))
            case .checking:
                Text("Checking the server…")
                    .foregroundStyle(.white.opacity(0.65))
            case .success:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.accentColor)
                Text("Connected to your relay.")
                    .foregroundStyle(.white.opacity(0.8))
            case .failure(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.waiting)
                Text(verbatim: message)
                    .foregroundStyle(.white.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.footnote)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("onboarding.server.status")
    }

    /// Pick the server, and carry the walk with it.
    ///
    /// The choice decides which pages exist, so it is written to the model as
    /// it is tapped rather than on Continue: the progress line has to stop
    /// promising an account page the operator is not going to see.
    private func chooseServer(_ mode: ServerMode) {
        guard mode != serverChoice else { return }
        serverChoice = mode
        verifiedOrigin = nil
        serverCheck = .idle
        checkTask?.cancel()
        model.serverSelection = mode == .official
            ? .official
            : ServerSelection(mode: .selfHosted, origin: serverDomain, pin: serverPin)
    }

    /// An edit invalidates the verification: a verified origin is not a
    /// verified PIN, and neither is a different domain.
    private func serverInputChanged() {
        guard serverChoice == .selfHosted else { return }
        checkTask?.cancel()
        verifiedOrigin = nil
        serverCheck = .idle
        model.serverSelection = serverSelectionDraft
    }

    /// Ask the relay whether it is there, and whether the PIN works.
    private func verifyServer() {
        checkTask?.cancel()
        serverCheck = .checking
        let origin = serverDomain
        let pin = serverPin
        checkTask = Task {
            let result = await ServerProbe.check(origin: origin, pin: pin)
            guard !Task.isCancelled else { return }
            switch result {
            case .success:
                guard let normalized = ServerSelection(mode: .selfHosted, origin: origin).normalizedOrigin else {
                    serverCheck = .failure(String(localized: "Enter the server's address, for example relay.example.com."))
                    return
                }
                verifiedOrigin = normalized
                serverCheck = .success
                model.serverSelection = ServerSelection(mode: .selfHosted, origin: normalized, pin: pin)
            case .failure(let error):
                verifiedOrigin = nil
                serverCheck = .failure(Self.message(for: error))
            }
        }
    }

    /// The operator-readable sentence for a failed check.
    /// - Parameter error: the probe's answer.
    /// - Returns: a sentence that names what to fix.
    private static func message(for error: ServerProbeError) -> String {
        switch error {
        case .invalidOrigin:
            String(localized: "Enter the server's address, for example relay.example.com.")
        case .network:
            String(localized: "Could not reach the server. Check the address, the certificate and the port.")
        case .notRelay:
            String(localized: "That address answered, but it is not a DSH-Mizar relay.")
        case .protocolTooOld:
            String(localized: "That relay is too old for this app. Update it and try again.")
        case .pinRequired:
            String(localized: "This server needs its PIN.")
        case .pinInvalid:
            String(localized: "That PIN is not right.")
        case .rateLimited:
            String(localized: "Too many wrong PINs. Wait a few minutes and try again.")
        case .http(let code):
            String(format: String(localized: "The server answered HTTP %lld."), code)
        }
    }

    /// The operator-readable sentence for a directory that did not load.
    /// - Parameter error: the client's answer.
    /// - Returns: a sentence that names what to fix.
    private static func message(for error: SelfHostedDirectoryError) -> String {
        switch error {
        case .invalidOrigin:
            String(localized: "No self-hosted server is configured.")
        case .network:
            String(localized: "Could not reach the server. Check the address, the certificate and the port.")
        case .pinRequired:
            String(localized: "This server needs its PIN. Add it in Settings › Server.")
        case .pinInvalid:
            String(localized: "That PIN is not right. Check it in Settings › Server.")
        case .rateLimited:
            String(localized: "Too many wrong PINs. Wait a few minutes and try again.")
        case .http(let code):
            String(format: String(localized: "The server answered HTTP %lld."), code)
        case .invalidResponse:
            String(localized: "That address answered, but it is not a DSH-Mizar relay.")
        }
    }

    // MARK: - Connect

    /// The self-hosted replacement for the account page: pair a computer.
    ///
    /// Discovery is the server's directory; trust is still the code the
    /// computer shows. One tap on a row selects it, and the code field is the
    /// only thing between discovery and a stored pairing.
    private var connectPage: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xxl) {
            pageHeader(
                icon: "link",
                title: "Connect your computer",
                subtitle: "These computers are online on your server. Pick one, then type the code it shows.",
            )

            switch directory {
            case .loading:
                card {
                    HStack(spacing: Theme.Space.lg) {
                        ProgressView().controlSize(.regular).tint(Color.accentColor)
                        Text("Reading the computers on your server…")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                        Spacer(minLength: 0)
                    }
                }
            case .failed(let message):
                card {
                    VStack(alignment: .leading, spacing: Theme.Space.md) {
                        Label {
                            Text(verbatim: message)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(Theme.waiting)
                        }
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.8))
                        Button("Try again") {
                            Task { await loadDirectory() }
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .accessibilityIdentifier("onboarding.connect.retry")
                    }
                }
            case .loaded(let desktops):
                if desktops.isEmpty {
                    card {
                        VStack(alignment: .leading, spacing: Theme.Space.md) {
                            Text("No computer is online yet.")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                            Text("Open AGI Mizar on the computer, leave it running, then try again.")
                                .font(.footnote)
                                .foregroundStyle(.white.opacity(0.55))
                                .fixedSize(horizontal: false, vertical: true)
                            Button("Try again") {
                                Task { await loadDirectory() }
                            }
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .accessibilityIdentifier("onboarding.connect.retry")
                        }
                    }
                } else {
                    VStack(spacing: Theme.Space.md) {
                        ForEach(desktops) { desktop in
                            desktopRow(desktop)
                        }
                    }
                }
            }

            if let selectedDesktop, pairedName == nil {
                pairingCard(selectedDesktop)
            }

            if let pairedName {
                card {
                    HStack(spacing: Theme.Space.lg) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(Color.accentColor)
                        Text(String(format: String(localized: "Paired with %@"), pairedName))
                            .font(.headline)
                            .foregroundStyle(.white)
                        Spacer(minLength: 0)
                    }
                }
                .accessibilityIdentifier("onboarding.connect.paired")
            }

            Button("Do it later") {
                advance()
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white.opacity(0.62))
            .frame(maxWidth: .infinity)
            .disabled(pairingInFlight)
            .accessibilityIdentifier("onboarding.connect.skip")

            Text("You can pair another computer later from the computer list.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.48))
                .fixedSize(horizontal: false, vertical: true)
        }
        .task { await loadDirectory() }
    }

    /// One computer in the directory.
    private func desktopRow(_ desktop: SelfHostedDesktop) -> some View {
        let selected = selectedDesktop?.id == desktop.id
        return Button {
            withMizarAnimation(.mizarSnappy) {
                selectedDesktop = desktop
                pairingCode = ""
                pairFailure = nil
            }
        } label: {
            HStack(alignment: .top, spacing: Theme.Space.lg) {
                Image(systemName: desktop.platform == "windows" ? "pc" : "desktopcomputer")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(selected ? Theme.onAccent : Color.accentColor)
                    .frame(width: 38, height: 38)
                    .background(
                        selected ? Color.accentColor : Color.accentColor.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 11, style: .continuous),
                    )
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: desktop.name)
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text(verbatim: desktop.platformLabel ?? String(localized: "Online"))
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.55))
                }
                Spacer(minLength: Theme.Space.sm)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? Color.accentColor : .white.opacity(0.28))
            }
            .padding(Theme.Space.xl)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .fill(.white.opacity(selected ? 0.10 : 0.06)),
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor.opacity(0.75) : .white.opacity(0.10), lineWidth: 1),
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("onboarding.connect.desktop.\(desktop.id)")
    }

    /// The code field for the selected computer.
    private func pairingCard(_ desktop: SelfHostedDesktop) -> some View {
        card {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                Text(String(format: String(localized: "Enter the code shown on %@."), desktop.name))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)

                TextField("123456", text: $pairingCode)
                    .font(.body.monospaced().weight(.semibold))
                    .textContentType(.oneTimeCode)
                    .keyboardType(.asciiCapable)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .foregroundStyle(.white)
                    .padding(.horizontal, Theme.Space.md)
                    .padding(.vertical, Theme.Space.sm)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                            .strokeBorder(.white.opacity(0.12), lineWidth: 1),
                    )
                    .accessibilityIdentifier("onboarding.connect.code")
                    .onChange(of: pairingCode) { _, value in
                        // Uppercase and strip what the display form carries;
                        // the computer normalises the rest.
                        var normalized = AppModel.normalizedPairingCode(value)
                        if normalized.count > 12 { normalized = String(normalized.prefix(12)) }
                        if normalized != value { pairingCode = normalized }
                        pairFailure = nil
                    }

                Button {
                    pair(desktop)
                } label: {
                    HStack(spacing: 8) {
                        if pairingInFlight { ProgressView().controlSize(.small) }
                        Text(pairingInFlight ? "Pairing…" : "Pair")
                            .font(.headline)
                            .foregroundStyle(Theme.onAccent)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                    }
                }
                .buttonStyle(.glassProminent)
                .tint(Color.accentColor)
                .disabled(pairingInFlight
                          || !AppModel.isPlausiblePairingCode(AppModel.normalizedPairingCode(pairingCode)))
                .opacity(pairingInFlight
                         || AppModel.isPlausiblePairingCode(AppModel.normalizedPairingCode(pairingCode)) ? 1 : 0.45)
                .accessibilityIdentifier("onboarding.connect.pair")

                if let pairFailure {
                    Text(verbatim: pairFailure)
                        .font(.footnote)
                        .foregroundStyle(Theme.waiting)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("onboarding.connect.failure")
                }
            }
        }
    }

    /// Read the directory that belongs to the configured server.
    private func loadDirectory() async {
        directory = .loading
        let result = await model.selfHostedDesktops()
        switch result {
        case .success(let desktops):
            directory = .loaded(desktops)
        case .failure(let error):
            directory = .failed(Self.message(for: error))
        }
    }

    /// Redeem the code for the selected computer.
    private func pair(_ desktop: SelfHostedDesktop) {
        pairingInFlight = true
        pairFailure = nil
        Task {
            let result = await model.pairSelfHosted(desktop: desktop, code: pairingCode)
            pairingInFlight = false
            switch result {
            case .success(let paired):
                withMizarAnimation(.mizarSmooth) {
                    pairedName = paired.hostName
                    pairingCode = ""
                }
            case .failure(let error):
                switch error {
                case .notConfigured:
                    pairFailure = String(localized: "No self-hosted server is configured.")
                case .invalidCode:
                    pairFailure = String(localized: "That code is not six or more letters and digits.")
                case .pairingFailed(let message):
                    pairFailure = message
                }
            }
        }
    }

    // MARK: - Desktop

    /// Where the desktop application lives.
    ///
    /// The desktop repository's release page is the one place both platforms
    /// start from: the macOS DMG is published there, and the repository says
    /// how the Windows installer is built. Kept as a constant so the page, its
    /// copy button and a test cannot disagree about the address.
    private static let desktopReleaseURL = URL(string: "https://github.com/ShirazuNagisa/AGI-Mizar/releases")!

    /// The second page: the computer comes first.
    ///
    /// The phone is a remote; a phone that walks the rest of the guide before
    /// installing the desktop has nothing to pair with at the end, so the
    /// download is offered here -- before the account, before pairing -- with
    /// the link openable in the browser and copyable for a machine that is not
    /// this phone.
    private var desktopPage: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xxl) {
            pageHeader(
                icon: "desktopcomputer",
                title: "Install AGI Mizar on your computer",
                subtitle: "This phone is the remote. The computer it drives needs AGI Mizar installed and running before the two can be paired.",
            )

            card {
                VStack(alignment: .leading, spacing: Theme.Space.lg) {
                    desktopStep(
                        1,
                        title: "Download",
                        detail: "Open GitHub Releases and take the installer for your platform.",
                    )
                    desktopStep(
                        2,
                        title: "Install and open it",
                        detail: "Run it on the computer you want this phone to drive, and leave it running.",
                    )
                    desktopStep(
                        3,
                        title: "Come back",
                        detail: "The next step pairs this phone with that computer.",
                    )
                }
            }

            VStack(alignment: .leading, spacing: Theme.Space.md) {
                Text(verbatim: "AGI Mizar · GitHub Releases")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.78))
                Text(verbatim: Self.desktopReleaseURL.absoluteString)
                    .font(.caption.monospaced())
                    .foregroundStyle(.white.opacity(0.62))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("onboarding.desktop.url")

                HStack(spacing: Theme.Space.md) {
                    Button {
                        openURL(Self.desktopReleaseURL)
                    } label: {
                        Label("Open download page", systemImage: "arrow.up.right")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                    }
                    .buttonStyle(.glass)
                    .accessibilityIdentifier("onboarding.desktop.open")

                    Button {
                        copyDesktopReleaseLink()
                    } label: {
                        Label(
                            releaseLinkCopied ? "Link copied" : "Copy link",
                            systemImage: releaseLinkCopied ? "checkmark" : "doc.on.doc",
                        )
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                    }
                    .buttonStyle(.glass)
                    .accessibilityIdentifier("onboarding.desktop.copy")
                }

                Text("macOS DMG on Releases; Windows installers are built by the repository's packaging script.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.48))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// One numbered instruction on the download page.
    private func desktopStep(
        _ number: Int,
        title: LocalizedStringKey,
        detail: LocalizedStringKey,
    ) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.lg) {
            Text(verbatim: "\(number)")
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(Theme.onAccent)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.accentColor))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Put the release page's address on the clipboard and say so.
    ///
    /// A copy that leaves no trace reads as a tap that did nothing, so the
    /// button becomes "Link copied" for a couple of seconds. The address is
    /// copied whole rather than shortened: it is what the other machine's
    /// browser needs.
    private func copyDesktopReleaseLink() {
        UIPasteboard.general.string = Self.desktopReleaseURL.absoluteString
        withMizarAnimation(.mizarSmooth) { releaseLinkCopied = true }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withMizarAnimation(.mizarSmooth) { releaseLinkCopied = false }
        }
    }

    // MARK: - Account

    private var accountPage: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xxl) {
            pageHeader(
                icon: "person.crop.circle",
                title: "Account",
                subtitle: "A Mizar account is required for relay access and the paid server.",
            )

            if model.account.isLoggedIn {
                card {
                    HStack(spacing: Theme.Space.lg) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: model.account.user?.username ?? String(localized: "Signed in"))
                                .font(.headline)
                                .foregroundStyle(.white)
                            if let email = model.account.user?.email, !email.isEmpty {
                                Text(verbatim: email)
                                    .font(.subheadline)
                                    .foregroundStyle(.white.opacity(0.6))
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
                .accessibilityIdentifier("onboarding.account.signedIn")
            } else {
                card {
                    VStack(spacing: Theme.Space.md) {
                        Button {
                            accountSheet = AccountSheet(mode: .login)
                        } label: {
                            Label("Sign in", systemImage: "person.crop.circle")
                                .font(.headline)
                                .foregroundStyle(Theme.onAccent)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.glassProminent)
                        .tint(Color.accentColor)
                        .accessibilityIdentifier("onboarding.account.signIn")

                        Button {
                            accountSheet = AccountSheet(mode: .register)
                        } label: {
                            Text("Create account")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.glass)
                        .accessibilityIdentifier("onboarding.account.register")

                        Text("You can also use Sign in with Apple.")
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.5))
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
            }

            Text("No conversations or files are stored on the account server.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.48))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Network

    private var networkPage: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xxl) {
            pageHeader(
                icon: "wifi",
                title: "Network",
                subtitle: "How should this phone reach your computer?",
            )

            VStack(spacing: Theme.Space.md) {
                toggleCard(
                    icon: "wifi",
                    title: "Local network first",
                    detail: "On the same Wi-Fi, connect directly. Faster, and no relay traffic.",
                    isOn: Binding(
                        get: { model.settings.values.localNetworkFirst },
                        set: { enabled in
                            model.settings.values.localNetworkFirst = enabled
                            if enabled { Task { await Permissions.requestLocalNetwork() } }
                        },
                    ),
                    identifier: "onboarding.network.lan",
                )
                toggleCard(
                    icon: "point.topleft.down.to.point.bottomright.curvepath",
                    title: "P2P direct connection (Experimental)",
                    detail: "Try a direct path when the local network is unavailable.",
                    isOn: Binding(
                        get: { model.settings.values.directConnection },
                        set: { model.settings.values.directConnection = $0 },
                    ),
                    identifier: "onboarding.network.p2p",
                )
            }

            Text("Both can be changed later in Settings.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.48))
        }
    }

    // MARK: - On-device agent

    private var agentPage: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xxl) {
            pageHeader(
                icon: "cpu",
                title: "Agent location",
                subtitle: "Where should your sessions run?",
            )

            choiceCard(
                selected: !wantsLocalAgent,
                icon: "desktopcomputer",
                title: "On my computer",
                detail: "Run AGI Mizar on your Mac or PC; this phone controls it.",
                identifier: "onboarding.agent.computer",
            ) {
                withMizarAnimation(.mizarSnappy) { wantsLocalAgent = false }
            }

            choiceCard(
                selected: wantsLocalAgent,
                icon: "iphone.gen3",
                title: "On this iPhone (Experimental)",
                detail: "Needs a model API key. Runs only while the app is open.",
                identifier: "onboarding.agent.local",
            ) {
                withMizarAnimation(.mizarSnappy) { wantsLocalAgent = true }
            }

            if wantsLocalAgent {
                card {
                    HStack(spacing: Theme.Space.lg) {
                        Image(systemName: model.localAgent.hasConfiguredProvider
                              ? "checkmark.seal.fill" : "key")
                            .font(.title3)
                            .foregroundStyle(model.localAgent.hasConfiguredProvider
                                             ? Color.accentColor : .white.opacity(0.6))
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 3) {
                            if model.localAgent.hasConfiguredProvider {
                                Text("Model configured")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.white)
                                Text("The on-device agent can call a model.")
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.55))
                            } else {
                                Text("Add a model provider")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.white)
                                Text("Add an API key now, or later in Settings.")
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.55))
                            }
                        }
                        Spacer(minLength: 0)
                        Button("Configure") {
                            showingModels = true
                        }
                        .font(.footnote.weight(.semibold))
                        .tint(Color.accentColor)
                        .accessibilityIdentifier("onboarding.agent.configure")
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
                .task { model.localAgent.refreshKeyPresence() }
            }

            Text("You can switch between this iPhone and your computers later.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.48))
        }
        .animation(pageAnimation, value: wantsLocalAgent)
    }

    // MARK: - Alerts

    private var alertsPage: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xxl) {
            pageHeader(
                icon: "bell.badge",
                title: "Notifications & Live Activity",
                subtitle: "Choose what reaches you when the app is away.",
            )

            VStack(spacing: Theme.Space.md) {
                toggleCard(
                    icon: "bell",
                    title: "Notifications",
                    detail: "Task finished, permission needed, or the model asks a question.",
                    isOn: Binding(
                        get: { model.settings.values.notifications.suppressed.isEmpty },
                        set: { enabled in
                            for kind in NotificationKind.allCases {
                                model.settings.values.notifications.set(enabled, for: kind)
                            }
                            if enabled {
                                Task {
                                    await Permissions.requestNotifications()
                                    await model.ensurePushRegistration()
                                }
                            }
                        },
                    ),
                    identifier: "onboarding.alerts.notifications",
                )
                toggleCard(
                    icon: "bolt.horizontal.circle",
                    title: "Live Activity",
                    detail: "See a running task on the Lock Screen.",
                    isOn: Binding(
                        get: { model.settings.values.liveActivitiesEnabled },
                        set: { model.settings.values.liveActivitiesEnabled = $0 },
                    ),
                    identifier: "onboarding.alerts.liveActivity",
                )
            }

            if model.isSelfHosted {
                Label(
                    "A self-hosted server does not support background push. These switches only affect what the app shows while it is open.",
                    systemImage: "bell.slash",
                )
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.62))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("onboarding.alerts.selfHosted")
            }

            Text("iOS will ask for notification permission. You can change both later.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.48))
        }
    }

    // MARK: - Plan

    private var planPage: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xxl) {
            pageHeader(
                icon: "star.circle",
                title: "Plan",
                subtitle: "Keep the free account, or add the paid one.",
            )

            planCard(
                title: "Free account",
                detail: "Most cross-network features, and every local-network feature.",
                selected: !model.account.isPaid,
                disabled: false,
                badge: nil,
                identifier: "onboarding.plan.free",
            )
            planCard(
                title: "Paid account",
                detail: "Adds the defined cross-network entitlements.",
                selected: model.account.isPaid,
                disabled: true,
                badge: nil,
                identifier: "onboarding.plan.paid",
            )

            Button("Upgrade to Paid") {}
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.38))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(.white.opacity(0.06), in: Capsule())
                .disabled(true)
                .accessibilityIdentifier("onboarding.plan.upgrade")

            Text("TestFlight version: purchases are temporarily unavailable.")
                .font(.footnote)
                .foregroundStyle(.orange.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)

            Text("You can change plans later in Settings.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.48))
        }
    }

    // MARK: - Summary

    private var summaryPage: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xxl) {
            pageHeader(
                icon: "checkmark.circle",
                title: "You're ready",
                subtitle: "Everything here can be changed later.",
            )

            VStack(spacing: 0) {
                if model.isSelfHosted {
                    summaryRow(
                        icon: "server.rack",
                        title: "Server",
                        value: model.selfHostedOrigin ?? String(localized: "Self-hosted server"),
                    )
                } else {
                    summaryRow(
                        icon: "person.crop.circle",
                        title: "Account",
                        value: model.account.user?.email
                            ?? model.account.user?.username
                            ?? String(localized: "Signed in"),
                    )
                }
                divider
                summaryRow(
                    icon: "wifi",
                    title: "Network",
                    value: networkSummary,
                )
                divider
                summaryRow(
                    icon: "cpu",
                    title: "Agent",
                    value: agentSummary,
                )
                divider
                summaryRow(
                    icon: "bell",
                    title: "Alerts",
                    value: alertsSummary,
                )
                divider
                summaryRow(
                    icon: "star.circle",
                    title: "Plan",
                    value: model.isSelfHosted
                        ? String(localized: "Everything unlocked")
                        : (model.account.isPaid
                            ? String(localized: "Paid account")
                            : String(localized: "Free account")),
                )
            }
            .padding(.vertical, Theme.Space.xs)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(.white.opacity(0.10), lineWidth: 1),
            )
        }
    }

    // MARK: - Refresh

    /// What the metadata reload is doing.
    private enum ReloadState: Equatable {
        case idle
        case running
        case done(AppModel.MetadataReload)
        case failed
    }

    @State private var reloadState: ReloadState = .idle

    /// The page that loads the session information again.
    ///
    /// Everything this phone shows about the sessions is read from the
    /// desktop once more, with the rules the desktop uses today: the cached
    /// pages go first, so nothing an older build left behind is drawn
    /// afterwards. It is the last thing before the summary, because after it
    /// the phone's conversations are the desktop's, not a mixture of two.
    private var refreshPage: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xxl) {
            pageHeader(
                icon: "arrow.triangle.2.circlepath",
                title: "Refresh your conversations",
                subtitle: "Everything this phone shows about your sessions is read again from your computer, with the rules it uses today.",
            )

            card {
                HStack(spacing: Theme.Space.lg) {
                    switch reloadState {
                    case .idle, .running:
                        ProgressView()
                            .controlSize(.regular)
                            .tint(Color.accentColor)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Loading your sessions…")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                            Text("Your account and your settings are kept. Only the session information is loaded again.")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.55))
                        }
                    case .done(let result):
                        Image(systemName: result.reached ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.title3)
                            .foregroundStyle(result.reached ? Color.accentColor : Theme.waiting)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(result.reached
                                ? String(format: String(localized: "%lld sessions loaded"), result.sessions)
                                : String(localized: "Your computer did not answer."))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                            Text("Your account and your settings are kept.")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.55))
                        }
                    case .failed:
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.title3)
                            .foregroundStyle(Theme.waiting)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Your computer did not answer.")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                            Text("You can continue; the sessions are loaded again when it answers.")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.55))
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            .accessibilityIdentifier("onboarding.refresh.state")

            Text("The sessions are loaded again every time you open the guide, so what you see afterwards is what your computer says now.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.48))
        }
        .task(id: step) { await runReload() }
    }

    /// Load the session information again, once.
    private func runReload() async {
        guard reloadState == .idle else { return }
        reloadState = .running
        let result = await model.reloadSessionMetadata()
        withMizarAnimation(.mizarSmooth) {
            reloadState = result.reached ? .done(result) : .failed
        }
    }

    // MARK: - Values

    private var networkSummary: String {
        let lan = model.settings.values.localNetworkFirst
            ? String(localized: "On") : String(localized: "Off")
        let p2p = model.settings.values.directConnection
            ? String(localized: "On") : String(localized: "Off")
        return String(format: String(localized: "LAN %@ · P2P %@"), lan, p2p)
    }

    private var agentSummary: String {
        if wantsLocalAgent {
            return model.localAgent.hasConfiguredProvider
                ? String(localized: "On this iPhone · model ready")
                : String(localized: "On this iPhone · model later")
        }
        return String(localized: "On my computer")
    }

    private var alertsSummary: String {
        let notifications = model.settings.values.notifications.suppressed.isEmpty
            ? String(localized: "On") : String(localized: "Off")
        let live = model.settings.values.liveActivitiesEnabled
            ? String(localized: "On") : String(localized: "Off")
        return String(format: String(localized: "Notifications %@ · Live Activity %@"), notifications, live)
    }

    private var canAdvance: Bool {
        switch step {
        case .account:
            return OnboardingNavigation.accountContinue(
                isSignedIn: model.account.isLoggedIn,
                isUpdate: isUpdate,
            )
        case .server:
            return OnboardingNavigation.serverContinue(
                choice: serverChoice,
                check: serverCheck,
                verifiedOrigin: verifiedOrigin,
                draft: serverSelectionDraft,
            )
        default:
            return true
        }
    }

    /// The server page's fields as a selection value.
    private var serverSelectionDraft: ServerSelection {
        ServerSelection(mode: serverChoice, origin: serverDomain, pin: serverPin)
    }

    // MARK: - Navigation

    private var pageAnimation: Animation {
        reduceMotion ? .mizarFade : .mizarSmooth
    }

    private var pageTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        let insertion: Edge = direction > 0 ? .trailing : .leading
        let removal: Edge = direction > 0 ? .leading : .trailing
        return .asymmetric(
            insertion: .move(edge: insertion).combined(with: .opacity),
            removal: .move(edge: removal).combined(with: .opacity),
        )
    }

    private func advance() {
        guard canAdvance else { return }
        if step == .summary {
            started = true
            let useLocal = wantsLocalAgent && model.localAgent.hasConfiguredProvider
            // The guide this phone has walked is the guide this build wants:
            // the version is what decides whether it is walked again.
            guideVersion = OnboardingKeys.requiredVersion
            withMizarAnimation(.mizarSmooth) { done = true }
            if useLocal {
                Task { await model.enterLocalAgent() }
            }
            return
        }
        let steps = visibleSteps
        guard let next = OnboardingNavigation.nextStep(after: step, in: steps) else { return }
        go(to: next, direction: 1)
    }

    private func goBack() {
        let steps = visibleSteps
        guard let previous = OnboardingNavigation.previousStep(before: step, in: steps) else { return }
        go(to: previous, direction: -1)
    }

    /// Move to one page.
    /// - Parameters:
    ///   - next: the page.
    ///   - direction: `1` forward, `-1` back, which picks the slide.
    private func go(to next: OnboardingStep, direction: Int) {
        self.direction = direction
        withMizarAnimation(pageAnimation) { step = next }
    }

    // MARK: - Building blocks

    private func pageHeader(icon: String?, title: LocalizedStringKey, subtitle: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            if let icon {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                    .padding(.bottom, Theme.Space.xs)
            }
            Text(title)
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            Text(subtitle)
                .font(.body)
                .foregroundStyle(.white.opacity(0.62))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func featureRow(icon: String, title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .center, spacing: Theme.Space.lg) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 24, height: 24)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .offset(y: 5)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
            }
            Text(detail)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 40)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(Theme.Space.xl)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(.white.opacity(0.10), lineWidth: 1),
            )
    }

    private func toggleCard(
        icon: String,
        title: LocalizedStringKey,
        detail: LocalizedStringKey,
        isOn: Binding<Bool>,
        identifier: String,
    ) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.lg) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 34, height: 34)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Theme.Space.sm)
            Toggle("", isOn: isOn)
                .labelsHidden()
                // The dark appearance's accent is white; tinting the switch with
                // it makes an "on" switch a white pill with a white thumb. A
                // neutral gray track keeps the thumb and the state legible.
                .tint(Color(white: 0.38))
                .accessibilityIdentifier(identifier)
        }
        .padding(Theme.Space.xl)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(.white.opacity(0.10), lineWidth: 1),
        )
    }

    private func choiceCard(
        selected: Bool,
        icon: String,
        title: LocalizedStringKey,
        detail: LocalizedStringKey,
        identifier: String,
        action: @escaping () -> Void,
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: Theme.Space.lg) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(selected ? Theme.onAccent : Color.accentColor)
                    .frame(width: 38, height: 38)
                    .background(
                        selected ? Color.accentColor : Color.accentColor.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 11, style: .continuous),
                    )
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Theme.Space.sm)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? Color.accentColor : .white.opacity(0.28))
            }
            .padding(Theme.Space.xl)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .fill(.white.opacity(selected ? 0.10 : 0.06)),
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor.opacity(0.75) : .white.opacity(0.10), lineWidth: 1),
            )
        }
        .buttonStyle(.plain)
        .animation(pageAnimation, value: selected)
        .accessibilityIdentifier(identifier)
    }

    private func planCard(
        title: LocalizedStringKey,
        detail: LocalizedStringKey,
        selected: Bool,
        disabled: Bool,
        badge: LocalizedStringKey?,
        identifier: String,
    ) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.lg) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(selected ? Color.accentColor : .white.opacity(0.28))
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
                if let badge {
                    Text(badge)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Space.xl)
        .background(.white.opacity(selected ? 0.10 : 0.055), in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(selected ? Color.accentColor.opacity(0.75) : .white.opacity(0.10), lineWidth: 1),
        )
        .opacity(disabled ? 0.55 : 1)
        .accessibilityIdentifier(identifier)
    }

    private func summaryRow(icon: String, title: LocalizedStringKey, value: String) -> some View {
        HStack(spacing: Theme.Space.lg) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 24)
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.62))
            Spacer(minLength: Theme.Space.md)
            Text(verbatim: value)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
        .padding(.horizontal, Theme.Space.xl)
        .padding(.vertical, Theme.Space.md)
    }

    private var divider: some View {
        Divider().overlay(.white.opacity(0.08)).padding(.leading, 58)
    }
}
