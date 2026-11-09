//
//  OnboardingView.swift
//  DSH-Mizar
//
//  The first-run guide: welcome, account, transport, on-device agent,
//  notifications, plan, and a summary. Full window, no sidebar. Every choice
//  writes the same setting the Settings screen writes, so the guide cannot
//  disagree with the app it hands over to.
//

import MizarKit
import SwiftUI

/// Where the first-run answer lives.
enum OnboardingKeys {
    static let done = "mizar.onboarding.done"
    static let started = "mizar.onboarding.started"
}

struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(OnboardingKeys.done) private var done = false
    @AppStorage(OnboardingKeys.started) private var started = false
    @State private var wantsLocalAgent = false

    @State private var step: Step = Self.debugInitialStep
    @State private var direction = 1
    @State private var accountSheet: AccountSheet?
    @State private var showingModels = false
    @State private var appeared = false

    private enum Step: Int, CaseIterable, Identifiable {
        case welcome, account, network, agent, alerts, plan, summary

        var id: Int { rawValue }

        /// How many pages the progress line draws. One per step.
        static var count: Int { allCases.count }
    }

    private struct AccountSheet: Identifiable {
        let id = UUID()
        let mode: AccountScreen.Mode
    }

    /// A preview hook: `-mizarOnboardingStep <0...6>` opens the guide on one
    /// page so each page can be looked at without tapping through. Debug only.
    private static var debugInitialStep: Step {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-mizarOnboardingStep"),
           arguments.indices.contains(index + 1),
           let raw = Int(arguments[index + 1]),
           let step = Step(rawValue: raw) {
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
            if step != .welcome {
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
                ForEach(Step.allCases) { item in
                    Capsule()
                        .fill(item.rawValue <= step.rawValue
                              ? Color.accentColor
                              : Color.white.opacity(0.16))
                        .frame(width: item == step ? 22 : 6, height: 4)
                        .animation(pageAnimation, value: step)
                }
            }
            .accessibilityHidden(true)

            Spacer(minLength: 0)

            Text(verbatim: "\(step.rawValue + 1) / \(Step.count)")
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
        case .summary:
            summaryPage
        }
    }

    private var footer: some View {
        VStack(spacing: Theme.Space.md) {
            if step == .account, !model.account.isLoggedIn {
                Text("Sign in to continue.")
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
                summaryRow(
                    icon: "person.crop.circle",
                    title: "Account",
                    value: model.account.user?.email
                        ?? model.account.user?.username
                        ?? String(localized: "Signed in"),
                )
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
                    value: model.account.isPaid
                        ? String(localized: "Paid account")
                        : String(localized: "Free account"),
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
        step != .account || model.account.isLoggedIn
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
            withMizarAnimation(.mizarSmooth) { done = true }
            if useLocal {
                Task { await model.enterLocalAgent() }
            }
            return
        }
        guard let next = Step(rawValue: step.rawValue + 1) else { return }
        direction = 1
        withMizarAnimation(pageAnimation) { step = next }
    }

    private func goBack() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        direction = -1
        withMizarAnimation(pageAnimation) { step = previous }
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
