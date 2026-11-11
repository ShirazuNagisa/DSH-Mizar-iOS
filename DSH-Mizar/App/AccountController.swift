//
//  AccountController.swift
//  DSH-Mizar
//
//  The signed-in account, as the screens read it.
//
//  Three rules shape this file:
//
//  - **The account is optional.** Every free feature works logged out and every
//    method here is safe to call while signed out; nothing in the app may prompt
//    for a login at launch. A phone in a lift keeps its cached profile and says
//    nothing, which is why a failed refresh is not an error state.
//  - **A dead session clears; a slow server does not.** A 401 means the token is
//    gone and the cached profile must stop pretending otherwise. A timeout means
//    the relay is having a moment, and the operator keeps their name and plan.
//  - **The store is written before the UI is told.** If the Keychain write fails,
//    the sign-in failed too, rather than a session that works until the next
//    launch and then silently forgets the token.
//

import Foundation
import MizarKit
import Observation
import UIKit

/// The account, and everything a screen needs to draw it.
@MainActor
@Observable
final class AccountController {
    /// How far the account state has got.
    enum Phase: Equatable {
        /// Nothing has been read from storage yet.
        case idle
        /// Reading the profile from the relay.
        case loading
        /// Storage has been read; the profile may or may not be fresh.
        case ready
        /// The relay could not be reached. Not fatal: the cached profile stays.
        case unreachable
    }

    /// The stored session, when signed in.
    private(set) var session: AccountSession?
    /// The account's computers, as the relay last listed them.
    ///
    /// Empty until fetched; `desktopsError` says why when a fetch failed. The
    /// list is the account's answer, not a cache: a computer that signed out of
    /// the relay disappears from it.
    private(set) var desktops: [AccountDesktop] = []
    /// Why the last desktop listing failed, for the screen to show.
    private(set) var desktopsError: String?
    /// What the screens use to say "signed in", "checking" or "offline".
    private(set) var phase: Phase = .idle
    /// A warning that came with a success — the device limit, for now.
    private(set) var notice: AccountNotice?
    /// The last failure, as a sentence for the screen. Not an alert: the account
    /// section is a row, and a row that throws a modal at launch is a launch
    /// prompt by another name.
    private(set) var lastError: String?
    /// A ban the operator must be told about, out of band.
    ///
    /// A banned account is not a failed request: it is a state the whole app has
    /// to explain, with the address to appeal to. The alert lives on the root
    /// view so it appears whether the ban was discovered at launch or by a login.
    private(set) var banNotice: BanNotice?

    /// What the ban alert says.
    struct BanNotice: Identifiable, Equatable {
        let id = UUID()
        let message: String
        let contact: String?
    }
    /// Whether a sign-in, sign-out or write is in flight.
    private(set) var working = false
    /// A photo the operator picked for this account.
    ///
    /// Sign in with Apple does not hand a third-party app the Apple ID photo --
    /// no API returns it -- so the only way to show the operator's real picture
    /// is to let them choose one. It is kept on this phone, keyed by account id,
    /// and overrides the relay's Gravatar/generated/Apple-monogram fallback.
    private(set) var customAvatar: UIImage?

    /// How a questionnaire fetch went.
    enum SurveyPhase: Equatable {
        case idle
        case loading
        case loaded
        case failed
    }

    /// The questionnaires the relay dispatched, with this account's state.
    ///
    /// Reloaded when the questionnaires page opens and after a submission; the
    /// list is the server's answer rather than a cache, because "已填写" is
    /// decided there.
    private(set) var surveys: [Survey] = []
    private(set) var surveyPhase: SurveyPhase = .idle
    /// Why the last survey fetch failed, for the page to show.
    private(set) var surveyError: String?

    /// The install id: this phone's device id, and the relay client id.
    let installId: String

    /// Called when the bearer token changes, so the host connection can be
    /// redialled with the new relay identity headers.
    ///
    /// A token is attached to the WebSocket upgrade and cannot be changed on a
    /// live socket, so signing in or out has to reconnect. The app calls this
    /// through ``AppModel``; it is a closure rather than a notification so the
    /// ordering is explicit.
    var onIdentityChange: (@MainActor () -> Void)?
    /// Called after a successful sign-in, so the subscription side can sync.
    var onAuthenticated: (@MainActor () async -> Void)?
    /// Called when the account's paid state may have changed.
    ///
    /// The relay tier follows the plan: a paid account should be on the account
    /// relay, a free one on the free relay. This is a closure rather than a
    /// property observation because the move is a network round trip the model
    /// owns, and the ordering (profile stored first, then the host asked) should
    /// be explicit.
    var onPlanChange: (@MainActor () -> Void)?

    private let store: any AccountStoring
    private let client: AccountClient

    /// - Parameters:
    ///   - store: where the session is kept.
    ///   - client: the API; injected so a preview and a test can exist without a
    ///     relay. `nil` builds one against ``resolvedBaseURL``.
    init(store: any AccountStoring = KeychainAccountStore(), client: AccountClient? = nil) {
        self.store = store
        // Read the install id once: it is the device id the account roster and
        // the relay's `x-mizar-client-id` both use, and the account API must
        // carry the same one. Without it `/connect` mints every phone of the
        // account into one "phone" token slot, and two iOS devices take turns
        // revoking each other.
        let installId = store.installId
        self.installId = installId
        self.client = client ?? AccountClient(baseURL: Self.resolvedBaseURL, clientId: installId)
        #if DEBUG
        // UI tests relaunch the same installed app, and the Keychain survives a
        // reinstall-free test run. Clear it synchronously, before any screen can
        // sign in: doing it in `start()` raced a fast sign-in and could wipe the
        // session it had just stored.
        if ProcessInfo.processInfo.arguments.contains("-mizarAccountFreshStart") {
            store.clear()
        }
        #endif
    }

    // MARK: - Read-only answers

    /// The profile, when signed in.
    var user: AccountUser? { session?.profile }
    /// Whether there is a stored session.
    var isLoggedIn: Bool { session != nil }
    /// Whether the account is paid.
    ///
    /// The debug launch argument exists only for the ActivityUI test: it lets the
    /// paid-only running-turn feed be exercised without walking the account and
    /// invite screens first. Release builds never read it.
    var isPaid: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-mizarMockPaid") { return true }
        #endif
        return session?.profile.isPaid ?? false
    }
    /// The bearer token, when signed in.
    var token: String? { session?.token }

    /// The name the settings row shows: the username, or nothing.
    var displayName: String { session?.profile.username ?? "" }

    /// The headers the relay reads for traffic attribution.
    ///
    /// Recomputed rather than cached, because it is derived from the token and
    /// the install id and there is exactly one place each comes from.
    var identity: RelayIdentity {
        RelayIdentity(clientId: installId, accountToken: session?.token)
    }

    /// The device descriptor sent with sign-ins.
    ///
    /// The id is the install id, not a random one per sign-in: the server caps
    /// email-only accounts at two active devices and identifies one by this id,
    /// so changing it would make every re-login look like a new phone.
    var device: AccountDevicePayload {
        AccountDevicePayload(
            id: installId,
            name: AppModel.deviceName,
            model: AppModel.deviceModel,
            appVersion: AppModel.appVersion,
        )
    }

    /// The account API root this build talks to.
    ///
    /// The production relay unless a debug build was launched with
    /// `-mizarAccountURL`, which is how the UI tests point at
    /// `scripts/mock-host.mjs`. The override is compiled out of release builds:
    /// a launch argument that redirects account traffic is a testing tool, not a
    /// feature.
    /// The relay origin the account API lives on, for building room URLs.
    ///
    /// ``resolvedBaseURL`` is the API root (`…/account/v1`); a computer's room
    /// hangs off the origin, so the two path components come off again.
    static var origin: URL {
        var url = resolvedBaseURL
        url.deleteLastPathComponent()
        url.deleteLastPathComponent()
        return url
    }

    static var resolvedBaseURL: URL {
        #if DEBUG
        if let override = launchAccountURL { return override }
        #endif
        return AccountClient.productionBaseURL
    }

    #if DEBUG
    /// Read the account URL override from the launch arguments.
    ///
    /// Accepted as `-mizarAccountURL <url>` (the `simctl` / XCUIApplication form)
    /// and as `-mizarAccountURL=<url>`. Ignored when it does not parse, so a
    /// typo in a test invocation fails the test that reads the mock rather than
    /// silently sending the run at production.
    private static var launchAccountURL: URL? {
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-mizarAccountURL"),
           arguments.indices.contains(index + 1),
           let url = URL(string: arguments[index + 1]) {
            return accountAPIURL(from: url)
        }
        for argument in arguments where argument.hasPrefix("-mizarAccountURL=") {
            let value = argument.dropFirst("-mizarAccountURL=".count)
            if let url = URL(string: String(value)) { return accountAPIURL(from: url) }
        }
        return nil
    }

    /// Turn an override origin into the API root the client expects.
    ///
    /// The tests and the docs name the mock by its host
    /// (`http://127.0.0.1:19395`), while ``AccountClient`` appends routes to a
    /// root that already includes `/account/v1`. Accept both spellings so the
    /// launch argument cannot half-work: a 404 from the mock is a confusing
    /// failure, and it is the one this normalisation removes.
    private static func accountAPIURL(from url: URL) -> URL {
        if url.path.hasSuffix("/account/v1") || url.path.hasSuffix("/account/v1/") {
            return url
        }
        return url.appendingPathComponent("account/v1")
    }
    #endif

    // MARK: - Lifecycle

    /// Read the stored session and, if there is one, refresh it.
    ///
    /// Called once from the root view. It never presents anything: the account
    /// is optional, and an app that opens a sign-in sheet on launch is an app
    /// that asks before it is useful.
    func start() async {
        guard phase == .idle else { return }
        if let stored = store.load(), stored.isUsable {
            session = stored
            phase = .ready
            loadCustomAvatar()
            await refresh()
        } else {
            phase = .ready
        }
    }

    /// Re-read the profile for a stored token.
    ///
    /// The call that turns a stalled session into "signed out". A network failure
    /// keeps the cached profile — the plan and the name are the phone's own copy
    /// until the relay says otherwise, and replacing them with "not signed in"
    /// because a lift dropped the signal is the wrong answer to a question
    /// nobody asked.
    func refresh() async {
        guard let token = session?.token else {
            phase = .ready
            return
        }
        phase = .loading
        do {
            let user = try await client.me(token: token)
            apply(user: user)
            phase = .ready
            await loadDesktops()
        } catch let error as AccountError {
            noteBan(error)
            if error.requiresReauthentication {
                signOutLocally(reason: message(for: error), notice: nil)
            } else {
                phase = .unreachable
                lastError = message(for: error)
            }
        } catch {
            phase = .unreachable
            lastError = message(for: AccountError.transport(error))
        }
    }

    /// Refresh on returning to the foreground, when signed in.
    ///
    /// Bounded by nothing but the request timeout, and deliberately silent on
    /// failure: the app has a cached profile and a launch that is already under
    /// way should not gain a spinner in its account row.
    func refreshOnForeground() async {
        guard session != nil, phase != .loading, !working else { return }
        await refresh()
    }

    /// Clear the message and any notice, when the screen is done showing them.
    func clearFeedback() {
        lastError = nil
        notice = nil
    }

    // MARK: - Sign-in

    /// Create an account, step one: ask the server to mail a code.
    ///
    /// Nothing is created here. The username, address and password stay on this
    /// phone until the code is presented, which is what lets the sheet be
    /// cancelled without leaving a half-account behind.
    ///
    /// - Parameters:
    ///   - username: the display name.
    ///   - email: the address.
    ///   - password: the password.
    /// - Returns: where the code went, or `nil` when the request failed.
    func beginRegistration(username: String, email: String, password: String) async -> RegistrationChallenge? {
        working = true
        lastError = nil
        defer { working = false }
        do {
            return try await client.registerStart(
                username: username.trimmingCharacters(in: .whitespacesAndNewlines),
                email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                password: password,
                device: device,
            )
        } catch {
            let accountError = AccountError.transport(error)
            noteBan(accountError)
            lastError = message(for: accountError)
            return nil
        }
    }

    /// Create an account, step two: present the code.
    ///
    /// - Parameters:
    ///   - username: the display name.
    ///   - email: the address the code went to.
    ///   - password: the password.
    ///   - code: the six digits.
    /// - Returns: whether the account was created and stored.
    @discardableResult
    func completeRegistration(
        username: String,
        email: String,
        password: String,
        code: String,
    ) async -> Bool {
        await perform {
            try await self.client.register(
                username: username.trimmingCharacters(in: .whitespacesAndNewlines),
                email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                password: password,
                code: code,
                device: self.device,
            )
        }
    }

    /// Ask for a password-reset code.
    ///
    /// - Parameter email: the account's address.
    /// - Returns: where the code went, or `nil` when the request failed.
    func beginPasswordReset(email: String) async -> RegistrationChallenge? {
        working = true
        lastError = nil
        defer { working = false }
        do {
            return try await client.resetPasswordStart(email: email.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            let accountError = AccountError.transport(error)
            noteBan(accountError)
            lastError = message(for: accountError)
            return nil
        }
    }

    /// Finish a password reset, which also signs this device in.
    ///
    /// - Parameters:
    ///   - email: the address.
    ///   - code: the six digits.
    ///   - password: the new password.
    /// - Returns: whether the password was changed and the session stored.
    @discardableResult
    func completePasswordReset(email: String, code: String, password: String) async -> Bool {
        await perform {
            try await self.client.resetPassword(
                email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                code: code,
                password: password,
                device: self.device,
            )
        }
    }

    /// Dismiss the ban alert.
    func clearBanNotice() {
        banNotice = nil
    }

    /// Turn an `ACCOUNT_DISABLED` into the alert, with its appeal address.
    private func noteBan(_ error: AccountError) {
        guard error.code == AccountErrorCode.accountDisabled else { return }
        banNotice = BanNotice(
            message: String(localized: "This account has been banned."),
            contact: error.contact,
        )
    }

    /// Sign in with a username or an email.
    ///
    /// - Parameters:
    ///   - identifier: the username or email.
    ///   - password: the password.
    /// - Returns: whether the session was established and stored.
    @discardableResult
    func login(identifier: String, password: String) async -> Bool {
        await perform {
            try await self.client.login(
                identifier: identifier.trimmingCharacters(in: .whitespacesAndNewlines),
                password: password,
                device: self.device,
            )
        }
    }

    /// Sign in with a Sign in with Apple identity token.
    ///
    /// - Parameters:
    ///   - identityToken: the compact JWS from `ASAuthorization`.
    ///   - nonce: the raw nonce; the server hashes it to compare with the claim.
    ///   - fullName: the name Apple handed over on a first sign-in, when it did.
    /// - Returns: whether the session was established and stored.
    @discardableResult
    func signInWithApple(identityToken: String, nonce: String, fullName: String?) async -> Bool {
        await perform {
            try await self.client.apple(
                identityToken: identityToken,
                nonce: nonce,
                device: self.device,
                fullName: fullName,
            )
        }
    }

    /// The shared tail of the three sign-ins.
    private func perform(_ attempt: () async throws -> AccountAuth) async -> Bool {
        working = true
        lastError = nil
        defer { working = false }
        do {
            let auth = try await attempt()
            let session = auth.session
            // Stored first, for the reason in the file comment: a session the
            // Keychain refused is a session that is gone at the next launch.
            do {
                try store.save(session)
            } catch {
                lastError = message(for: .init(
                    code: "STORAGE",
                    message: String(localized: "The account could not be saved on this phone."),
                    retryable: true,
                ))
                return false
            }
            self.session = session
            self.notice = auth.notice
            phase = .ready
            loadCustomAvatar()
            onIdentityChange?()
            await onAuthenticated?()
            // The account's computers are part of what signing in means; the
            // screen draws them as soon as it has them.
            await loadDesktops()
            return true
        } catch {
            let accountError = AccountError.transport(error)
            noteBan(accountError)
            lastError = message(for: accountError)
            return false
        }
    }

    // MARK: - Sign-out and account changes

    /// Sign this device out.
    ///
    /// The server call is best effort and the local token is cleared whatever it
    /// says: a failed logout that left the phone signed in would be a phone the
    /// operator cannot hand over.
    /// Read the account's computers and whether each is online.
    ///
    /// Safe to call while signed out: it clears the list instead of failing, so
    /// a signed-out screen never shows machines from a previous session.
    func loadDesktops() async {
        guard let session, session.isUsable else {
            desktops = []
            desktopsError = nil
            return
        }
        do {
            desktops = try await client.desktops(token: session.token)
            desktopsError = nil
        } catch {
            desktopsError = (error as? AccountError).map(message(for:)) ?? error.localizedDescription
        }
    }

    // MARK: - Questionnaires

    /// Read the questionnaires this account may fill in.
    ///
    /// Safe while signed out: it clears the list instead of failing, so a
    /// signed-out page never shows forms from a previous session.
    func loadSurveys() async {
        guard let session, session.isUsable else {
            surveys = []
            surveyError = nil
            surveyPhase = .idle
            return
        }
        surveyPhase = .loading
        do {
            surveys = try await client.surveys(token: session.token)
            surveyError = nil
            surveyPhase = .loaded
        } catch {
            surveyError = (error as? AccountError).map(message(for:)) ?? error.localizedDescription
            surveyPhase = .failed
        }
    }

    /// Submit one questionnaire and collect its reward.
    ///
    /// - Parameters:
    ///   - survey: the questionnaire, as it was handed to the form.
    ///   - answers: one answer per answered question.
    /// - Returns: the paid days granted, or `nil` when the relay refused the
    ///   submission; ``lastError`` says why.
    func submitSurvey(_ survey: Survey, answers: [SurveyAnswer]) async -> Int? {
        guard let session, session.isUsable else {
            lastError = String(localized: "Sign in first to fill in a questionnaire.")
            return nil
        }
        working = true
        lastError = nil
        defer { working = false }
        do {
            let result = try await client.submitSurvey(
                token: session.token,
                surveyID: survey.id,
                answers: answers,
            )
            apply(user: result.user)
            // The server decides "已填写"; ask it again rather than marking the
            // row here, so the page and the server cannot disagree.
            await loadSurveys()
            return result.rewardDays
        } catch {
            lastError = message(for: AccountError.transport(error))
            return nil
        }
    }

    /// Ask one connected computer for a token this phone may use.
    ///
    /// - Parameter desktop: the computer, from ``desktops``.
    /// - Returns: the room and the freshly minted token.
    func connect(
        to desktop: AccountDesktop,
        engine: AgentEngine? = nil,
    ) async throws -> DesktopConnection {
        guard let session, session.isUsable, session.token.isEmpty == false else {
            throw AccountError(
                code: AccountErrorCode.unauthenticated,
                message: "Sign in before connecting to a computer.",
            )
        }
        return try await client.connect(
            token: session.token,
            deviceId: desktop.deviceId,
            engine: engine?.wireName,
        )
    }

    func signOut() async {
        working = true
        defer { working = false }
        defer {
            session = nil
            notice = nil
            lastError = nil
            phase = .ready
            onIdentityChange?()
        }
        if let token = session?.token {
            try? await client.logout(token: token)
        }
    }

    /// Delete the account.
    ///
    /// Only clears the local session when the server confirms; a delete that did
    /// not happen must not look as though it did.
    ///
    /// - Returns: whether the account is gone.
    @discardableResult
    func deleteAccount() async -> Bool {
        guard let token = session?.token else { return false }
        let deletedUserID = session?.profile.id
        working = true
        lastError = nil
        defer { working = false }
        do {
            _ = try await client.delete(token: token)
        } catch {
            lastError = message(for: AccountError.transport(error))
            return false
        }
        if let deletedUserID {
            UserDefaults.standard.removeObject(forKey: Self.avatarKey(for: deletedUserID))
        }
        signOutLocally(reason: nil, notice: nil)
        return true
    }

    // MARK: - Invite

    /// Redeem an invite code for paid time.
    ///
    /// - Parameter code: the code the operator was given.
    /// - Returns: whether the code was accepted and the profile updated.
    @discardableResult
    func redeem(code: String) async -> Bool {
        guard let token = session?.token else {
            lastError = String(localized: "Sign in first to redeem an invite code.")
            return false
        }
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            lastError = String(localized: "Enter an invite code.")
            return false
        }
        working = true
        lastError = nil
        defer { working = false }
        do {
            let user = try await client.redeem(token: token, code: trimmed)
            apply(user: user)
            return true
        } catch {
            lastError = message(for: AccountError.transport(error))
            return false
        }
    }

    // MARK: - App Store

    /// Send one verified transaction to the relay.
    ///
    /// - Parameter signedTransaction: the JWS from StoreKit.
    /// - Returns: whether the server accepted it.
    @discardableResult
    func submitAppStoreTransaction(_ signedTransaction: String) async -> Bool {
        guard let token = session?.token else { return false }
        do {
            let user = try await client.appStoreTransaction(token: token, signedTransaction: signedTransaction)
            apply(user: user)
            return true
        } catch {
            lastError = message(for: AccountError.transport(error))
            return false
        }
    }

    /// Send the transactions the phone currently holds, in one call.
    ///
    /// - Parameter signedTransactions: the JWS strings.
    /// - Returns: whether the server accepted them.
    @discardableResult
    func syncAppStoreTransactions(_ signedTransactions: [String]) async -> Bool {
        guard let token = session?.token, !signedTransactions.isEmpty else { return false }
        do {
            let user = try await client.appStoreSync(token: token, signedTransactions: signedTransactions)
            apply(user: user)
            return true
        } catch {
            lastError = message(for: AccountError.transport(error))
            return false
        }
    }

    // MARK: - Internals

    /// Replace the cached profile with a newer one.
    private func apply(user: AccountUser) {
        guard var session else { return }
        let wasPaid = session.profile.isPaid
        session.profile = user
        self.session = session
        // Best effort: the profile is cosmetic next to the token, and a failed
        // write here must not invalidate a working session.
        try? store.save(session)
        if wasPaid != user.isPaid { onPlanChange?() }
    }

    /// Forget the session locally.
    ///
    /// - Parameters:
    ///   - reason: why, when the operator should be told. `nil` for a deliberate
    ///     sign-out, which needs no explanation.
    ///   - notice: a notice to keep showing.
    private func signOutLocally(reason: String?, notice: AccountNotice?) {
        desktops = []
        desktopsError = nil
        let wasPaid = session?.profile.isPaid ?? false
        store.clear()
        session = nil
        customAvatar = nil
        self.notice = notice
        lastError = reason
        phase = .ready
        onIdentityChange?()
        // A paid computer left on the account relay would strand the free
        // phones paired with it, so signing out moves the tunnel back.
        if wasPaid { onPlanChange?() }
    }

    // MARK: - Custom avatar

    /// The defaults key holding one account's picked avatar.
    private static func avatarKey(for userID: String) -> String {
        "mizar.account.avatar.\(userID)"
    }

    /// Read the picked avatar for the current account, if there is one.
    private func loadCustomAvatar() {
        guard let userID = session?.profile.id,
              let data = UserDefaults.standard.data(forKey: Self.avatarKey(for: userID))
        else {
            customAvatar = nil
            return
        }
        customAvatar = UIImage(data: data)
    }

    /// Pick a new avatar, or clear it with `nil`.
    ///
    /// Stored at no more than 512 px and re-encoded as JPEG: an avatar drawn at
    /// 40–58 pt does not need a 12-megapixel original, and the phone should not
    /// pay that cost on every settings row.
    ///
    /// - Parameter image: the picked image, or `nil` to fall back to the
    ///   relay/Apple avatar.
    func setCustomAvatar(_ image: UIImage?) {
        guard let userID = session?.profile.id else { return }
        let key = Self.avatarKey(for: userID)
        guard let image else {
            customAvatar = nil
            UserDefaults.standard.removeObject(forKey: key)
            return
        }
        let normalized = Self.normalizedAvatar(image)
        customAvatar = normalized
        if let data = normalized.jpegData(compressionQuality: 0.86) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// Shrink an avatar so it is cheap to keep and draw.
    ///
    /// - Parameter image: the picked image.
    /// - Returns: the image, scaled to at most 512 px on its long edge.
    private static func normalizedAvatar(_ image: UIImage) -> UIImage {
        let maximum: CGFloat = 512
        let original = image.size
        guard max(original.width, original.height) > maximum else { return image }
        let scale = maximum / max(original.width, original.height)
        let size = CGSize(width: original.width * scale, height: original.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            UIColor.systemGray.setFill()
            UIBezierPath(rect: CGRect(origin: .zero, size: size)).fill()
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// A failure as a sentence for the account screen.
    ///
    /// Localised by code rather than by the server's English message: the relay
    /// does not know the phone's language, and a Chinese screen with an English
    /// error in it is the seam this mapping hides.
    ///
    /// - Parameter error: the failure.
    /// - Returns: the sentence to show.
    func message(for error: AccountError) -> String {
        switch error.code {
        case AccountErrorCode.usernameTaken:
            String(localized: "That username is already taken.")
        case AccountErrorCode.emailTaken:
            String(localized: "That email already has an account.")
        case AccountErrorCode.invalidInput:
            String(localized: "Those details were not accepted. Check them and try again.")
        case AccountErrorCode.unauthenticated:
            String(localized: "Your sign-in has expired. Sign in again.")
        case AccountErrorCode.sessionRevoked:
            String(localized: "This device was signed out. Sign in again.")
        case AccountErrorCode.accountDisabled:
            String(localized: "This account has been disabled.")
        case AccountErrorCode.rateLimited:
            String(localized: "Too many attempts. Wait a moment and try again.")
        case AccountErrorCode.emailVerificationRequired:
            String(localized: "Enter the code that was emailed to you.")
        case AccountErrorCode.verificationInvalid:
            String(localized: "That code is not right. Try again.")
        case AccountErrorCode.verificationExpired:
            String(localized: "That code has expired. Send a new one.")
        case AccountErrorCode.verificationAttempts:
            String(localized: "Too many attempts. Send a new code.")
        case AccountErrorCode.mailUnavailable:
            String(localized: "Email is unavailable right now. Try again shortly.")
        case AccountErrorCode.appleTokenInvalid:
            String(localized: "Apple could not verify this sign-in. Try again.")
        case AccountErrorCode.appleUnavailable:
            String(localized: "Sign in with Apple is unavailable right now. Try again later.")
        case AccountErrorCode.inviteInvalid:
            String(localized: "That invite code is not valid.")
        case AccountErrorCode.inviteExpired:
            String(localized: "That invite code has expired.")
        case AccountErrorCode.inviteUsedUp:
            String(localized: "That invite code has been used up.")
        case AccountErrorCode.inviteAlreadyUsed:
            String(localized: "This account has already used that invite code.")
        case AccountErrorCode.surveyUnavailable:
            String(localized: "Questionnaires are unavailable right now. Try again later.")
        case AccountErrorCode.surveyNotFound:
            String(localized: "That questionnaire is no longer available.")
        case AccountErrorCode.surveyAlreadyDone:
            String(localized: "You have already filled in this questionnaire.")
        case AccountErrorCode.surveyInvalidAnswers:
            String(localized: "Some answers were not accepted. Check the form and try again.")
        case AccountErrorCode.appStoreTokenInvalid:
            String(localized: "The App Store receipt could not be verified. Try restoring purchases.")
        case AccountErrorCode.appStoreProductMismatch:
            String(localized: "That subscription is not the one this app offers.")
        case AccountErrorCode.appStoreAccountMismatch:
            String(localized: "This subscription is linked to another account.")
        case AccountErrorCode.appStoreTransactionRevoked:
            String(localized: "That App Store transaction was revoked or refunded.")
        case AccountErrorCode.appStoreUnavailable:
            String(localized: "App Store verification is unavailable right now. Try again later.")
        case AccountErrorCode.network:
            error.message.isEmpty
                ? String(localized: "The account server could not be reached.")
                : error.message
        case AccountErrorCode.internalError:
            String(localized: "The account server had a problem. Try again shortly.")
        default:
            error.message.isEmpty
                ? String(localized: "Something went wrong. Try again.")
                : error.message
        }
    }

    /// The sentence for a notice, or `nil` when there is nothing worth saying.
    var noticeMessage: String? {
        guard let notice else { return nil }
        switch notice.code {
        case "DEVICE_LIMIT":
            if let revoked = notice.revokedDevice, !revoked.isEmpty {
                return String(
                    format: String(localized: "An older device (%@) was signed out: email accounts can be signed in on two devices at a time."),
                    revoked,
                )
            }
            return String(localized: "An older device was signed out: email accounts can be signed in on two devices at a time.")
        default:
            return nil
        }
    }
}
