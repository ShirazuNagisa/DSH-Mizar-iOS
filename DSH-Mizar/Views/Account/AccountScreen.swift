//
//  AccountScreen.swift
//  DSH-Mizar
//
//  The account, the subscription, and the two destructive actions.
//
//  One screen with three states, because they are the same question asked at
//  different times: who is signed in (or how to sign in), what they have paid
//  for, and how to stop. The signed-out state is a form; the signed-in state is
//  a profile, the subscription section, the device list and a way out.
//
//  The subscription CTA is the one control in this file that must never be
//  faked: it calls ``SubscriptionController/purchase()``, which calls
//  `Product.purchase(options:)`, which puts Apple's payment sheet on screen. The
//  price beside it comes from `product.displayPrice` -- set in App Store Connect,
//  localised by Apple, and never hard-coded here.
//

import MizarKit
import PhotosUI
import SwiftUI
import UIKit

// MARK: - Avatar

/// An account's avatar: a Gravatar when the relay found one, the Apple account
/// avatar for an Apple-linked account, generated initials otherwise, and an
/// empty person when nobody is signed in.
///
/// Sign in with Apple never hands an app the Apple ID photo, so the Apple
/// avatar is drawn the way iOS itself draws an Apple account without a photo:
/// the white monogram on the system's gray gradient, the way the top of the
/// Settings app looks. The generated fallback is deliberately drawn from the
/// server's palette rather than from a local hash: the admin UI and the phone
/// then show the same colours for the same account, and somebody comparing the
/// two does not conclude they are looking at two accounts.
struct AccountAvatarView: View {
    /// The user, or `nil` when signed out.
    let user: AccountUser?
    /// A locally picked photo. It wins over the relay/Apple fallbacks.
    var image: UIImage? = nil
    /// The diameter.
    var size: CGFloat = 40

    var body: some View {
        content
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.12), lineWidth: 1))
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var content: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        // An Apple-linked account is drawn as Apple draws it, even when the
        // relay also found a Gravatar for the email: the operator asked for
        // the Apple avatar to win for Apple sign-ins.
        } else if let user, user.appleLinked {
            appleMonogram(user)
        } else if let user, user.avatar.kind == .gravatar, let url = user.avatar.url {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    fallback(for: user)
                }
            }
        } else if let user {
            fallback(for: user)
        } else {
            ZStack {
                Circle().fill(.fill.tertiary)
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.42, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Which non-photo avatar this account draws.
    @ViewBuilder
    private func fallback(for user: AccountUser) -> some View {
        if user.appleLinked {
            appleMonogram(user)
        } else {
            generated(user)
        }
    }

    /// The Apple account avatar: the monogram iOS draws for an Apple ID that
    /// has no photo, light gray over dark with the person's initials in white.
    private func appleMonogram(_ user: AccountUser) -> some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(white: 0.72),
                    Color(white: 0.55),
                ],
                startPoint: .top,
                endPoint: .bottom,
            )
            Text(user.displayInitials)
                .font(.system(size: size * 0.42, weight: .medium))
                .foregroundStyle(.white)
        }
    }

    /// The generated fallback: the server's palette, and the server's initials.
    private func generated(_ user: AccountUser) -> some View {
        ZStack {
            if let first = user.avatar.colors.compactMap(Self.color).first {
                if user.avatar.colors.count > 1 {
                    LinearGradient(
                        colors: user.avatar.colors.compactMap(Self.color),
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing,
                    )
                } else {
                    first
                }
            } else {
                Color.accentColor
            }
            Text(user.displayInitials)
                .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.onAccent)
        }
    }

    /// A `#rrggbb` string as a colour.
    ///
    /// - Parameter hex: the server's colour string.
    /// - Returns: the colour, or `nil` when it is not the shape the relay sends.
    private static func color(_ hex: String) -> Color? {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let number = UInt64(value, radix: 16) else { return nil }
        return Color(
            red: Double((number >> 16) & 0xFF) / 255,
            green: Double((number >> 8) & 0xFF) / 255,
            blue: Double(number & 0xFF) / 255,
        )
    }
}

// MARK: - Screen

struct AccountScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    /// Closes the settings sheet that pushed this screen.
    ///
    /// The settings popover's Done button lives on the navigation stack's root;
    /// SwiftUI does not carry that toolbar item into a pushed destination. The
    /// account screen is where people actually are after signing in, so it
    /// carries its own copy. `nil` when the screen is presented by the composer's
    /// paywall, which supplies its own Done button.
    var onDone: (() -> Void)? = nil

    /// Which form the signed-out state is showing.
    enum Mode: String, CaseIterable, Identifiable {
        case login
        case register

        var id: String { rawValue }
    }

    @State private var mode: Mode
    @State private var identifier = ""
    @State private var username = ""
    @State private var email = ""
    @State private var password = ""
    @State private var showingDelete = false
    @State private var appleFailure: String?
    @State private var avatarItem: PhotosPickerItem?
    /// The computer whose token is being minted right now.
    @State private var connectingDesktop: String?
    /// Why the last connect attempt failed, for the section's footer.
    @State private var desktopFailure: String?
    @State private var verification: VerificationChallenge?
    @State private var resetChallenge: VerificationChallenge?
    @State private var showingResetForm = false
    @State private var showingDistributionNotice = false
    @FocusState private var focused: Field?

    /// A code sheet's state: which address, and what to do with the digits.
    struct VerificationChallenge: Identifiable {
        let id = UUID()
        let email: String
        let resendAfter: Int
    }

    /// - Parameters:
    ///   - onDone: closes the settings sheet this screen was pushed from.
    ///   - initialMode: which half of the form to show first.
    init(onDone: (() -> Void)? = nil, initialMode: Mode = .login) {
        self.onDone = onDone
        _mode = State(initialValue: initialMode)
    }

    private enum Field: Hashable {
        case identifier
        case username
        case email
        case password
    }

    var body: some View {
        List {
            if model.account.isLoggedIn {
                profileSection
                subscriptionSection
                devicesSection
                computersSection
                redeemSection
                signOutSection
            } else {
                signInSection
                subscriptionTeaserSection
            }
            linksSection
        }
        .navigationTitle("Account")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let onDone {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone)
                        .accessibilityIdentifier("settings.done")
                }
            }
        }
        .task {
            // The price is read even while signed out: a subscription section
            // that shows "…" until somebody signs in reads as broken.
            await model.subscription.load()
            if model.account.isLoggedIn {
                await model.account.loadDesktops()
            }
        }
        .refreshable {
            await model.account.loadDesktops()
        }
        .onChange(of: mode) { _, _ in
            model.account.clearFeedback()
            appleFailure = nil
        }
        .confirmationDialog(
            "Delete this account?",
            isPresented: $showingDelete,
            titleVisibility: .visible,
        ) {
            Button("Delete account", role: .destructive) {
                Task { await model.account.deleteAccount() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone. The account, its devices and its invite records are removed on the server. An App Store subscription is not cancelled by deleting the account; cancel it in your Apple ID subscription settings.")
        }
        .sheet(item: $verification) { challenge in
            VerificationCodeSheet(
                purpose: .register,
                email: challenge.email,
                initialResendAfter: challenge.resendAfter,
                submit: { code in
                    let created = await model.account.completeRegistration(
                        username: username,
                        email: challenge.email,
                        password: password,
                        code: code,
                    )
                    if created {
                        password = ""
                        return nil
                    }
                    return model.account.lastError
                },
                resend: {
                    guard let again = await model.account.beginRegistration(
                        username: username,
                        email: challenge.email,
                        password: password,
                    ) else { return nil }
                    return RegistrationChallenge(
                        email: again.email,
                        expiresAt: again.expiresAt,
                        resendAfterSeconds: again.resendAfterSeconds,
                    )
                },
            )
        }
        .sheet(isPresented: $showingResetForm) {
            PasswordResetSheet()
        }
        .alert("Not available yet", isPresented: $showingDistributionNotice) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The TestFlight build does not support this yet. Stay tuned.")
        }
    }

    // MARK: - Profile

    private var profileSection: some View {
        // Read the account values once. PhotosPicker's label is a Sendable
        // closure; capturing `model` there makes SwiftUI warn that a
        // main-actor-isolated property is crossing into it.
        let accountUser = model.account.user
        let accountAvatar = model.account.customAvatar
        return Section {
            HStack(spacing: 16) {
                PhotosPicker(selection: $avatarItem, matching: .images) {
                    AccountAvatarView(
                        user: accountUser,
                        image: accountAvatar,
                        size: 58,
                    )
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.onAccent)
                            .padding(5)
                            .background(Circle().fill(Color.accentColor))
                            .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                            .offset(x: 2, y: 2)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("account.avatar.picker")
                .accessibilityLabel("Change profile photo")
                .accessibilityHint("Choose a photo from your library.")
                .onChange(of: avatarItem) { _, item in
                    guard let item else { return }
                    Task {
                        if let data = try? await item.loadTransferable(type: Data.self),
                           let image = UIImage(data: data) {
                            model.account.setCustomAvatar(image)
                        }
                        avatarItem = nil
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.account.displayName)
                        .font(.title3.weight(.semibold))
                        .accessibilityIdentifier("account.username")
                    Text(model.account.isPaid ? String(localized: "Paid account") : String(localized: "Free account"))
                        .font(.subheadline)
                        .foregroundStyle(model.account.isPaid ? Theme.accentText : Color.secondary)
                        .accessibilityIdentifier("account.plan")
                }
            }
            .padding(.vertical, 4)

            if let user = model.account.user {
                if let email = user.email {
                    LabeledContent {
                        Text(email)
                            .textSelection(.enabled)
                    } label: {
                        Label("Email", systemImage: "envelope")
                    }
                    .accessibilityIdentifier("account.email")
                }
                if let paidUntil = user.paidUntil {
                    LabeledContent {
                        Text(paidUntil.formatted(date: .abbreviated, time: .omitted))
                    } label: {
                        Label("Paid until", systemImage: "calendar")
                    }
                    .accessibilityIdentifier("account.paidUntil")
                }
                if user.paidViaAppStore {
                    LabeledContent {
                        Text(user.appStore?.autoRenew == false
                            ? String(localized: "On, renewing off")
                            : String(localized: "Auto-renewing"))
                    } label: {
                        Label("App Store subscription", systemImage: "creditcard")
                    }
                    .accessibilityIdentifier("account.appStoreState")
                }
            }

            if let notice = model.account.noticeMessage {
                Label(notice, systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("account.notice")
            }
        } header: {
            Text("Account")
        }
    }

    // MARK: - Sign in

    private var signInSection: some View {
        Section {
            Picker("Mode", selection: $mode) {
                Text("Sign in").tag(Mode.login)
                Text("Create account").tag(Mode.register)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("account.mode")

            if mode == .login {
                TextField("Username or email", text: $identifier)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focused, equals: .identifier)
                    .submitLabel(.next)
                    .onSubmit { focused = .password }
                    .accessibilityIdentifier("account.identifier")
            } else {
                TextField("Username", text: $username)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focused, equals: .username)
                    .submitLabel(.next)
                    .onSubmit { focused = .email }
                    .accessibilityIdentifier("account.username.field")
                TextField("Email", text: $email)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focused, equals: .email)
                    .submitLabel(.next)
                    .onSubmit { focused = .password }
                    .accessibilityIdentifier("account.email.field")
            }

            SecureField("Password", text: $password)
                .textContentType(passwordContentType)
                // A password is not a sentence: the keyboard must not capitalise
                // or autocorrect it. Without these a simulator run whose shift
                // key happened to be up sent `Mizar-test-password` and got a 401,
                // which looked exactly like a wrong fixture.
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focused, equals: .password)
                .submitLabel(.go)
                .onSubmit { submit() }
                .accessibilityIdentifier("account.password")

            Button {
                submit()
            } label: {
                HStack {
                    Spacer()
                    if model.account.working {
                        ProgressView().controlSize(.small)
                    }
                    Text(mode == .login ? String(localized: "Sign in") : String(localized: "Create account"))
                        .fontWeight(.semibold)
                    Spacer()
                }
            }
            .disabled(!canSubmit || model.account.working)
            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
            .accessibilityIdentifier("account.submit")

            if mode == .login {
                Button("Forgot password?") {
                    showingResetForm = true
                }
                .font(.footnote.weight(.medium))
                .tint(Theme.accentText)
                .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                .accessibilityIdentifier("account.forgot")
            }

            AppleSignInView { failure in appleFailure = failure }
        } header: {
            Text("Sign in")
        } footer: {
            if let failure = model.account.lastError ?? appleFailure {
                Text(failure)
                    .foregroundStyle(Theme.failed)
                    .accessibilityIdentifier("account.error")
            } else {
                Text("A Mizar account is required to use the app.")
            }
        }
    }

    /// The AutoFill flavour for the password field.
    ///
    /// `.newPassword` is the right content type for a registration form: it
    /// offers a generated strong password and files it under the right account.
    /// It is not used in Debug, because the iOS 27 simulator's strong-password
    /// overlay intercepts `typeText` and keeps only the first character, which
    /// makes a UI test that types a fixture password unable to register at all.
    /// Release builds keep the better AutoFill behaviour; the field is still a
    /// `SecureField` either way.
    private var passwordContentType: UITextContentType {
        #if DEBUG
        .password
        #else
        mode == .login ? .password : .newPassword
        #endif
    }

    /// Whether the visible form has enough filled in to try.
    private var canSubmit: Bool {
        guard !password.isEmpty else { return false }
        switch mode {
        case .login: return !identifier.isEmpty
        case .register: return !username.isEmpty && !email.isEmpty
        }
    }

    /// Send whichever form is up.
    ///
    /// Registration stops after mailing a code: the account is not created until
    /// the sheet's digits come back, which is the whole point of the flow.
    private func submit() {
        guard canSubmit, !model.account.working else { return }
        focused = nil
        appleFailure = nil
        Task {
            switch mode {
            case .login:
                guard await model.account.login(identifier: identifier, password: password) else { return }
                password = ""
            case .register:
                guard let challenge = await model.account.beginRegistration(
                    username: username,
                    email: email,
                    password: password,
                ) else { return }
                verification = VerificationChallenge(
                    email: challenge.email,
                    resendAfter: challenge.resendAfterSeconds,
                )
            }
        }
    }

    // MARK: - Subscription

    private var subscriptionTeaserSection: some View {
        Section {
            LabeledContent {
                Text(model.subscription.priceText)
                    .monospacedDigit()
            } label: {
                HStack(spacing: 8) {
                    Label("Mizar Paid", systemImage: "star.circle")
                    Text("Sign in to subscribe. The subscription is bound to your account, so the plan follows you to every device.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .accessibilityIdentifier("account.subscription.price")
        } header: {
            Text("Subscription")
        }
    }

    private var subscriptionSection: some View {
        Section {
            LabeledContent {
                Text(model.subscription.priceText)
                    .monospacedDigit()
                    .accessibilityIdentifier("account.subscription.priceValue")
            } label: {
                HStack(spacing: 8) {
                    Label("Mizar Paid", systemImage: "star.circle")
                    Text("Auto-renewing monthly subscription")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .accessibilityIdentifier("account.subscription.price")

            if model.account.isPaid, let user = model.account.user, user.paidViaInvite {
                Label(
                    invitePaidNote(user),
                    systemImage: "ticket",
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            Button {
                if Distribution.isTestFlight {
                    showingDistributionNotice = true
                } else {
                    Task { await model.subscription.purchase() }
                }
            } label: {
                HStack {
                    Spacer()
                    if model.subscription.phase == .purchasing {
                        ProgressView().controlSize(.small)
                    }
                    Text(
                        model.subscription.phase == .purchasing
                            ? String(localized: "Opening the App Store…")
                            : String(format: String(localized: "Subscribe for %@ per month"), model.subscription.priceText),
                    )
                    .fontWeight(.semibold)
                    Spacer()
                }
            }
            .disabled(!model.subscription.canPurchase || model.subscription.phase == .purchasing)
            // The label is a full-width HStack with the title centred between
            // Spacers, so without this the separator starts at the text rather
            // than the card's edge and the divider under the row is only
            // half-width. Pin it to the leading edge, as the sign-in form's
            // submit button does.
            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
            .accessibilityIdentifier("account.subscription.cta")

            Button {
                if Distribution.isTestFlight {
                    showingDistributionNotice = true
                } else {
                    Task { await model.subscription.restore() }
                }
            } label: {
                Label("Restore purchases", systemImage: "arrow.clockwise")
            }
            .disabled(model.subscription.phase == .purchasing || model.subscription.phase == .pending)
            // A Label's text starts after its icon, so the default separator
            // would be inset to the text; pin both subscription buttons to the
            // card's leading edge like the CTA above.
            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
            .accessibilityIdentifier("account.subscription.restore")

            Button {
                openURL(SubscriptionController.manageSubscriptionsURL)
            } label: {
                Label("Manage subscription", systemImage: "arrow.up.right.square")
            }
            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
            .accessibilityIdentifier("account.subscription.manage")

            if let notice = model.subscription.notice {
                Label(notice, systemImage: "checkmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("account.subscription.notice")
            }
            if let error = model.subscription.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(Theme.failed)
                    .accessibilityIdentifier("account.subscription.error")
            }
        } header: {
            Text("Subscription")
        } footer: {
            // The disclosure App Review requires on the screen that offers the
            // purchase: what is charged, how often, that it auto-renews, and
            // where to turn it off.
            Text(
                String(
                    localized: "A recurring monthly subscription. Payment is charged to your Apple ID when you confirm the purchase. It renews automatically for the same period unless it is cancelled at least 24 hours before the current period ends. You can manage or cancel it any time in your Apple ID subscription settings.",
                ),
            )
        }
    }

    /// What to say about a plan paid by an invite code.
    private func invitePaidNote(_ user: AccountUser) -> String {
        let expiry = user.grantedPaidUntil.map { $0.formatted(date: .abbreviated, time: .omitted) }
        if let expiry {
            return String(
                format: String(localized: "Paid by an invite code until %@. You can still subscribe to keep it after that."),
                expiry,
            )
        }
        return String(localized: "Paid by an invite code. You can still subscribe to keep it after that.")
    }

    // MARK: - Devices

    private var devicesSection: some View {
        let devices = (model.account.user?.devices ?? []).filter(\.isMobile)
        return Section {
            if !devices.isEmpty {
                ForEach(devices) { device in
                    HStack(spacing: 12) {
                        Image(systemName: device.platform == "ios" ? "iphone" : "desktopcomputer")
                            .foregroundStyle(.secondary)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.name.isEmpty ? String(localized: "This device") : device.name)
                            Text(deviceDetail(device))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        if device.current {
                            Text("Current")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(Theme.accentText)
                        }
                    }
                    .accessibilityIdentifier("account.device.\(device.id)")
                }
            } else {
                Text("No phones or iPads are signed in.")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("account.devices.empty")
            }
        } header: {
            Text("Devices")
        } footer: {
            Text("Email accounts can be signed in on two devices at a time; the oldest is signed out when a third signs in. Sign in with Apple has no limit.")
        }
    }

    /// One device's line: platform, model, and when it last signed in.
    private func deviceDetail(_ device: AccountDevice) -> String {
        var parts: [String] = []
        if !device.model.isEmpty { parts.append(device.model) }
        if let loginAt = device.loginAt {
            parts.append(String(format: String(localized: "signed in %@"), loginAt.formatted(date: .abbreviated, time: .omitted)))
        }
        return parts.isEmpty ? device.platform : parts.joined(separator: " · ")
    }

    // MARK: - Redeem

    /// The account's computers, and the one thing this screen can do with them.
    ///
    /// A computer that is offline is drawn, not hidden: "the Mac is asleep" is a
    /// fact the operator needs, and a list that loses rows looks like the account
    /// forgot them.
    private var computersSection: some View {
        Section {
            ForEach(model.account.desktops) { desktop in
                HStack(spacing: 12) {
                    Image(systemName: "desktopcomputer")
                        .foregroundStyle(.secondary)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(desktop.name)
                        Text(desktop.online ? String(localized: "Online") : String(localized: "Offline"))
                            .font(.caption)
                            .foregroundStyle(desktop.online ? Theme.accentText : .secondary)
                    }
                    Spacer(minLength: 8)
                    if desktop.online {
                        if connectingDesktop == desktop.deviceId {
                            ProgressView()
                        } else {
                            Button("Connect") {
                                connect(to: desktop)
                            }
                            .buttonStyle(.borderless)
                            .tint(Theme.accentText)
                            .accessibilityIdentifier("account.computer.connect.\(desktop.deviceId)")
                        }
                    }
                }
                .accessibilityIdentifier("account.computer.\(desktop.deviceId)")
            }
            if model.account.desktops.isEmpty {
                Text("No computers are signed in to this account.")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("account.computers.empty")
            }
        } header: {
            Text("Computers")
        } footer: {
            if let desktopFailure {
                Text(desktopFailure)
                    .foregroundStyle(.red)
            } else if let error = model.account.desktopsError {
                Text(error)
                    .foregroundStyle(.secondary)
            } else {
                Text("Computers signed in to this account; a token is minted on connect.")
            }
        }
    }

    /// Mint a token on one computer and open it.
    private func connect(to desktop: AccountDesktop) {
        connectingDesktop = desktop.deviceId
        desktopFailure = nil
        Task {
            defer { connectingDesktop = nil }
            do {
                let connection = try await model.account.connect(to: desktop)
                await model.openAccountDesktop(
                    desktop,
                    using: connection,
                    at: AccountController.origin,
                )
            } catch let error as AccountError {
                desktopFailure = model.account.message(for: error)
            } catch {
                desktopFailure = error.localizedDescription
            }
        }
    }

    private var redeemSection: some View {
        Section {
            NavigationLink {
                RedeemInviteView()
            } label: {
                Label("Redeem invite code", systemImage: "ticket")
            }
            .accessibilityIdentifier("account.redeem")
        }
    }

    // MARK: - Sign out and delete

    private var signOutSection: some View {
        Section {
            Button(role: .destructive) {
                Task { await model.account.signOut() }
            } label: {
                Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
            }
            .disabled(model.account.working)
            .accessibilityIdentifier("account.signout")

            Button(role: .destructive) {
                showingDelete = true
            } label: {
                Label("Delete account", systemImage: "trash")
            }
            .disabled(model.account.working)
            .accessibilityIdentifier("account.delete")
        } footer: {
            if let error = model.account.lastError, model.account.isLoggedIn {
                Text(error)
                    .foregroundStyle(Theme.failed)
                    .accessibilityIdentifier("account.error")
            }
        }
    }

    // MARK: - Links

    private var linksSection: some View {
        Section {
            Link(destination: SubscriptionController.privacyURL) {
                Label("Privacy policy", systemImage: "hand.raised")
            }
            .accessibilityIdentifier("account.privacy")
            Link(destination: SubscriptionController.termsURL) {
                Label("Terms of use", systemImage: "doc.text")
            }
            .accessibilityIdentifier("account.terms")
        } footer: {
            Text("The account server is only used for signing in, the subscription and the paid plan. Attachments and conversations stay between this phone and your computer.")
        }
    }
}

#Preview {
    NavigationStack {
        AccountScreen().environment(AppModel())
    }
}
