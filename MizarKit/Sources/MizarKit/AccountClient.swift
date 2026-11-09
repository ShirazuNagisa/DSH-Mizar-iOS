//
//  AccountClient.swift
//  MizarKit
//
//  The account HTTP API, as a client the app can hold.
//
//  The relay serves these routes only when accounts are enabled, and only on the
//  main relay (`https://dshmizar-1.shirazu-nagisa.com/account/v1`). Nothing here
//  is required for the app to work: every free feature runs without a token, so
//  a failure in this file must never be able to break the rest of the app. It
//  reports by throwing ``AccountError``; the caller decides what to say.
//
//  The transport is injected. That is the whole testing story for this file:
//  `URLSession` cannot be made to answer a scripted 401 in a unit test, and the
//  interesting behaviour here — which header is set, whether a 401 is
//  distinguishable from a 500, whether the error body survives — is exactly what
//  a scripted transport can check.
//

import Foundation

/// The account API.
public struct AccountClient: Sendable {
    /// Where the account API lives in production.
    ///
    /// One host on purpose: the account backend runs on 主力1 only, and the
    /// other relay forwards account traffic nowhere. A build that pointed at a
    /// random relay would have a settings screen that never loads.
    public static let productionBaseURL = URL(string: "https://dshmizar-1.shirazu-nagisa.com:8443/account/v1")!

    /// Whether a relay is the host that owns the account store.
    ///
    /// This is the rule that decides where the session token may go. The paid
    /// relay is the account relay, so it is the one host that can verify a
    /// token; a free relay meters by the token's hash and has no store to check
    /// anything against, so handing it the token would be handing out a
    /// credential for no benefit.
    ///
    /// - Parameter baseURL: a relay origin, as the pairing or settings hold it.
    /// - Returns: whether that origin is the account host.
    public static func isAccountHost(_ baseURL: String) -> Bool {
        guard let host = URL(string: baseURL)?.host?.lowercased(),
              let accountHost = productionBaseURL.host?.lowercased()
        else { return false }
        return host == accountHost
    }

    /// A network failure.
    ///
    /// Everything throwable from this type is an ``AccountError``; errors from
    /// the transport are wrapped rather than propagated, so the app has one type
    /// to catch and one `code` to branch on.
    private let baseURL: URL
    private let transport: any HTTPTransport
    /// This install's id, sent as `x-mizar-client-id` when known.
    private let clientId: String?

    /// - Parameters:
    ///   - baseURL: the API root, including `/account/v1`.
    ///   - transport: how to reach it; injectable for tests.
    public init(
        baseURL: URL = AccountClient.productionBaseURL,
        transport: any HTTPTransport = URLSessionHTTPTransport(),
        clientId: String? = nil,
    ) {
        self.baseURL = baseURL
        self.transport = transport
        self.clientId = clientId
    }

    // MARK: - Sign-in

    /// Ask the server to mail a code, without creating the account yet.
    ///
    /// - Parameters:
    ///   - username: the display name the account will have.
    ///   - email: where the code goes.
    ///   - password: the password that will be set, checked for shape now.
    ///   - device: this install.
    /// - Returns: where the code went and how long it lives.
    public func registerStart(
        username: String,
        email: String,
        password: String,
        device: AccountDevicePayload,
    ) async throws -> RegistrationChallenge {
        let body = RegisterBody(username: username, email: email, password: password, code: nil, device: device)
        return try await post("register/start", body: body, as: RegistrationChallenge.self)
    }

    /// Create an account with the code from `registerStart`.
    ///
    /// - Parameters:
    ///   - username: the display name.
    ///   - email: the address the code went to.
    ///   - password: the password.
    ///   - code: the six digits.
    ///   - device: this install, for the device roster.
    /// - Returns: the token and profile.
    /// - Throws: ``AccountError`` with `USERNAME_TAKEN`, `EMAIL_TAKEN`,
    ///   `VERIFICATION_INVALID`, `VERIFICATION_EXPIRED` or `VERIFICATION_ATTEMPTS`.
    public func register(
        username: String,
        email: String,
        password: String,
        code: String,
        device: AccountDevicePayload,
    ) async throws -> AccountAuth {
        let body = RegisterBody(username: username, email: email, password: password, code: code, device: device)
        return try await post("register", body: body, as: AccountAuth.self)
    }

    /// Ask for a password-reset code.
    ///
    /// The server answers the same way for an unknown address, so this cannot be
    /// used to find out whether an account exists.
    ///
    /// - Parameter email: the account's address.
    /// - Returns: the lifetime of the code.
    public func resetPasswordStart(email: String) async throws -> RegistrationChallenge {
        let body = EmailBody(email: email)
        let envelope = try await post("password/reset/start", body: body, as: ResetStartEnvelope.self)
        return RegistrationChallenge(
            email: email,
            expiresAt: envelope.expiresAt,
            resendAfterSeconds: envelope.resendAfterSeconds,
        )
    }

    /// Finish a password reset and sign the device in.
    ///
    /// - Parameters:
    ///   - email: the address the code went to.
    ///   - code: the six digits.
    ///   - password: the new password.
    ///   - device: this install.
    /// - Returns: the token and profile.
    public func resetPassword(
        email: String,
        code: String,
        password: String,
        device: AccountDevicePayload,
    ) async throws -> AccountAuth {
        let body = ResetBody(email: email, code: code, password: password, device: device)
        return try await post("password/reset/complete", body: body, as: AccountAuth.self)
    }

    /// Sign in with a username or an email.
    ///
    /// - Parameters:
    ///   - identifier: the username or email.
    ///   - password: the password.
    ///   - device: this install, for the device roster.
    /// - Returns: the token and profile, plus a `DEVICE_LIMIT` notice when a
    ///   third email-only device pushed the oldest one out.
    public func login(
        identifier: String,
        password: String,
        device: AccountDevicePayload,
    ) async throws -> AccountAuth {
        let body = LoginBody(identifier: identifier, password: password, device: device)
        return try await post("login", body: body, as: AccountAuth.self)
    }

    /// Sign in with a Sign in with Apple identity token.
    ///
    /// - Parameters:
    ///   - identityToken: the compact JWS from `ASAuthorizationAppleIDCredential`.
    ///   - nonce: the *raw* nonce the app generated. The server hashes it with
    ///     SHA-256 and compares that against the token's `nonce` claim, so the
    ///     raw value is what travels here.
    ///   - device: this install, for the device roster.
    ///   - fullName: the name Apple gave on a first sign-in, when it did. A
    ///     single string; the server stores what it needs.
    /// - Returns: the token and profile.
    public func apple(
        identityToken: String,
        nonce: String,
        device: AccountDevicePayload,
        fullName: String? = nil,
    ) async throws -> AccountAuth {
        let body = AppleBody(identityToken: identityToken, nonce: nonce, device: device, fullName: fullName)
        return try await post("apple", body: body, as: AccountAuth.self)
    }

    // MARK: - Session

    /// Read the profile for a token.
    ///
    /// Doubles as the liveness check: a 401 here means the stored token is no
    /// longer usable and the app should stop showing a signed-in account.
    ///
    /// - Parameter token: the bearer token.
    /// - Returns: the profile.
    public func me(token: String) async throws -> AccountUser {
        try await get("me", token: token, as: UserEnvelope.self).user
    }

    /// The account's computers, and whether each can be reached now.
    ///
    /// - Parameter token: the bearer token.
    /// - Returns: the desktops, in the account's device order.
    public func desktops(token: String) async throws -> [AccountDesktop] {
        struct Envelope: Decodable, Sendable { let desktops: [AccountDesktop] }
        return try await get("desktops", token: token, as: Envelope.self).desktops
    }

    /// Ask a connected computer for a token this phone may use.
    ///
    /// The computer mints it; the relay only brokers the request. A computer
    /// that is offline or not on this account is refused with a code.
    ///
    /// - Parameters:
    ///   - token: the bearer token.
    ///   - deviceId: the computer's device id, from ``desktops(token:)``.
    /// - Returns: the room and the token.
    public func connect(
        token: String,
        deviceId: String,
        engine: String? = nil,
    ) async throws -> DesktopConnection {
        struct Body: Encodable, Sendable {
            let deviceId: String
            let engine: String?
        }
        return try await post(
            "connect",
            token: token,
            body: Body(deviceId: deviceId, engine: engine),
            as: DesktopConnection.self,
        )
    }

    /// Sign this session out.
    ///
    /// Best effort on the server side: the local token is cleared whatever this
    /// says, because a failed logout must not leave a phone that still believes
    /// it is signed in.
    ///
    /// - Parameter token: the bearer token.
    public func logout(token: String) async throws {
        // No body at all, rather than a JSON `null`: the route documents none,
        // and some HTTP middleboxes are happier with an empty POST.
        let request = try makeRequest(path: "logout", method: "POST", token: token)
        _ = try await send(request)
    }

    /// Delete the account.
    ///
    /// Destructive and irreversible; the server requires the literal body
    /// `{"confirmation":"DELETE"}` as a guard against an accidental call.
    ///
    /// - Parameter token: the bearer token.
    /// - Returns: the profile as it was, for a farewell line on screen.
    public func delete(token: String) async throws -> AccountUser? {
        // The route answers `{ok:true}` rather than a profile; the cached one is
        // returned by the caller. The return type exists so a future server that
        // includes the profile does not need a client change here.
        _ = try await post("delete", token: token, body: DeleteBody(confirmation: "DELETE"))
        return nil
    }

    /// Redeem an invite code.
    ///
    /// - Parameters:
    ///   - token: the bearer token.
    ///   - code: 4–64 `[A-Z0-9_-]` characters; case is normalised by the server.
    /// - Returns: the updated profile, paid until the grant runs out.
    public func redeem(token: String, code: String) async throws -> AccountUser {
        try await post("invite/redeem", token: token, body: RedeemBody(code: code), as: UserEnvelope.self).user
    }

    // MARK: - App Store

    /// Send one purchased transaction to be verified and applied.
    ///
    /// - Parameters:
    ///   - token: the bearer token.
    ///   - signedTransaction: the JWS from `Transaction.jsonRepresentation`.
    /// - Returns: the updated profile.
    public func appStoreTransaction(token: String, signedTransaction: String) async throws -> AccountUser {
        try await post(
            "appstore/transaction",
            token: token,
            body: AppStoreTransactionBody(signedTransaction: signedTransaction),
            as: UserEnvelope.self,
        ).user
    }

    /// Send the transactions the phone currently holds, in one call.
    ///
    /// What restore and launch sync use: the server applies each idempotently and
    /// answers the resulting profile. The contract caps one call at 100.
    ///
    /// - Parameters:
    ///   - token: the bearer token.
    ///   - signedTransactions: the JWS strings.
    /// - Returns: the updated profile.
    /// - Throws: `INVALID_INPUT` when handed more than the API accepts, or for an
    ///   empty list — there is nothing for the server to do with either.
    public func appStoreSync(token: String, signedTransactions: [String]) async throws -> AccountUser {
        guard !signedTransactions.isEmpty else {
            throw AccountError(
                code: AccountErrorCode.invalidInput,
                message: "There is no transaction to sync.",
            )
        }
        guard signedTransactions.count <= 100 else {
            throw AccountError(
                code: AccountErrorCode.invalidInput,
                message: "At most 100 transactions can be synced at once.",
            )
        }
        return try await post(
            "appstore/sync",
            token: token,
            body: AppStoreSyncBody(signedTransactions: signedTransactions),
            as: UserEnvelope.self,
        ).user
    }

    // MARK: - Surveys

    /// The questionnaires this account may fill in.
    ///
    /// - Parameter token: the bearer token.
    /// - Returns: the open surveys, each carrying whether this account already
    ///   answered it and the reward it pays.
    public func surveys(token: String) async throws -> [Survey] {
        try await get("surveys", token: token, as: SurveyListEnvelope.self).surveys
    }

    /// Submit one filled-in questionnaire.
    ///
    /// - Parameters:
    ///   - token: the bearer token.
    ///   - surveyID: the survey's id.
    ///   - answers: one answer per answered question. Unanswered optional
    ///     questions are simply absent.
    /// - Returns: the updated profile and the reward that was granted.
    public func submitSurvey(
        token: String,
        surveyID: String,
        answers: [SurveyAnswer],
    ) async throws -> SurveySubmission {
        try await post(
            "surveys/submit",
            token: token,
            body: SurveySubmitBody(surveyId: surveyID, answers: answers),
            as: SurveySubmission.self,
        )
    }

    // MARK: - Announcements

    /// The banners live right now.
    ///
    /// The polling twin of the announcement socket: what a phone that cannot
    /// hold a socket reads on the foreground, and what a test asserts against.
    ///
    /// - Parameter token: the bearer token.
    /// - Returns: every live banner, oldest first.
    public func announcements(token: String) async throws -> [Announcement] {
        try await get("announcements", token: token, as: AnnouncementListEnvelope.self).announcements
    }

    // MARK: - Internals

    /// A JSON body to send.
    struct RegisterBody: Codable, Sendable {
        let username: String
        let email: String
        let password: String
        /// The code from `/register/start`; omitted on the start call.
        let code: String?
        let device: AccountDevicePayload
    }

    struct EmailBody: Codable, Sendable {
        let email: String
    }

    struct ResetBody: Codable, Sendable {
        let email: String
        let code: String
        let password: String
        let device: AccountDevicePayload
    }

    struct ResetStartEnvelope: Codable, Sendable {
        let expiresAt: Date
        let resendAfterSeconds: Int
    }

    struct LoginBody: Codable, Sendable {
        let identifier: String
        let password: String
        let device: AccountDevicePayload
    }

    struct AppleBody: Codable, Sendable {
        let identityToken: String
        let nonce: String
        let device: AccountDevicePayload
        let fullName: String?
    }

    struct RedeemBody: Codable, Sendable {
        let code: String
    }

    struct DeleteBody: Codable, Sendable {
        let confirmation: String
    }

    struct AppStoreTransactionBody: Codable, Sendable {
        let signedTransaction: String
    }

    struct AppStoreSyncBody: Codable, Sendable {
        let signedTransactions: [String]
    }

    /// The `{user}` envelope.
    struct UserEnvelope: Codable, Sendable {
        let user: AccountUser
    }

    struct SurveyListEnvelope: Codable, Sendable {
        let surveys: [Survey]
    }

    struct AnnouncementListEnvelope: Codable, Sendable {
        let announcements: [Announcement]
    }

    struct SurveySubmitBody: Codable, Sendable {
        let surveyId: String
        let answers: [SurveyAnswer]
    }

    /// The error body the account API documents.
    struct ErrorBody: Codable, Sendable {
        let error: String
        let message: String?
        /// An appeal address, sent with `ACCOUNT_DISABLED`.
        let contact: String?
    }

    /// A POST with a JSON body.
    /// - Parameters:
    ///   - path: the route below the API root.
    ///   - token: the bearer token, when the route needs one.
    ///   - body: the body, or `nil` for none.
    /// - Returns: the response data.
    private func post(
        _ path: String,
        token: String? = nil,
        body: some Encodable,
    ) async throws -> Data {
        var request = try makeRequest(path: path, method: "POST", token: token)
        request.httpBody = try AccountCoding.encoder().encode(body)
        return try await send(request)
    }

    /// A POST decoded into a model.
    private func post<Result: Decodable>(
        _ path: String,
        token: String? = nil,
        body: some Encodable,
        as type: Result.Type,
    ) async throws -> Result {
        let data = try await post(path, token: token, body: body)
        return try decode(data, as: type)
    }

    /// A GET with an optional bearer token.
    private func get<Result: Decodable>(
        _ path: String,
        token: String?,
        as type: Result.Type,
    ) async throws -> Result {
        let request = try makeRequest(path: path, method: "GET", token: token)
        return try decode(try await send(request), as: type)
    }

    /// Build a request against one route.
    ///
    /// - Parameters:
    ///   - path: the route, relative to ``baseURL``. May contain `/` — the
    ///     contract has `invite/redeem` and `appstore/sync`.
    ///   - method: the HTTP method.
    ///   - token: the bearer token, when the route needs one.
    /// - Returns: the request, with its headers set.
    /// - Throws: ``AccountError`` when the route cannot form a URL.
    private func makeRequest(path: String, method: String, token: String?) throws -> URLRequest {
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "accept")
        if method == "POST" {
            request.setValue("application/json", forHTTPHeaderField: "content-type")
        }
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        }
        if let clientId, !clientId.isEmpty {
            request.setValue(clientId, forHTTPHeaderField: "x-mizar-client-id")
        }
        return request
    }

    /// Send a request and turn every non-success into an ``AccountError``.
    ///
    /// - Parameter request: the request.
    /// - Returns: the body of a successful answer.
    private func send(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.data(for: request)
        } catch {
            throw AccountError.transport(error)
        }
        guard (200..<300).contains(response.statusCode), response.statusCode != 204 else {
            throw Self.error(status: response.statusCode, body: data)
        }
        return data
    }

    /// Decode a successful answer.
    private func decode<Result: Decodable>(_ data: Data, as type: Result.Type) throws -> Result {
        do {
            return try AccountCoding.decoder().decode(type, from: data)
        } catch {
            throw AccountError(
                code: AccountErrorCode.malformedResponse,
                message: "The account server answered something this app could not read.",
            )
        }
    }

    /// Turn a refusal into an error the app can act on.
    ///
    /// - Parameters:
    ///   - status: the HTTP status.
    ///   - body: the response body, which normally names the code.
    /// - Returns: the error.
    static func error(status: Int, body: Data) -> AccountError {
        let reported = try? AccountCoding.decoder().decode(ErrorBody.self, from: body)
        let code = reported?.error ?? defaultCode(for: status)
        // The server's message is written for a person, so it is kept; a body
        // that carried none gets a sentence built from the code instead of an
        // empty string on screen.
        let message = reported?.message.flatMap { $0.isEmpty ? nil : $0 } ?? defaultMessage(for: code, status: status)
        return AccountError(
            code: code,
            status: status,
            message: message,
            retryable: isRetryable(code: code, status: status),
            contact: reported?.contact,
        )
    }

    /// The code to use when the server did not name one.
    private static func defaultCode(for status: Int) -> String {
        switch status {
        case 400: AccountErrorCode.invalidInput
        case 401: AccountErrorCode.unauthenticated
        case 403: AccountErrorCode.accountDisabled
        case 404: AccountErrorCode.malformedResponse
        case 429: AccountErrorCode.rateLimited
        default: status >= 500 ? AccountErrorCode.internalError : AccountErrorCode.invalidInput
        }
    }

    /// Whether retrying a refusal could ever succeed.
    ///
    /// A taken username stays taken; a rate limit and a server outage clear up.
    private static func isRetryable(code: String, status: Int) -> Bool {
        switch code {
        case AccountErrorCode.rateLimited,
             AccountErrorCode.internalError,
             AccountErrorCode.appleUnavailable,
             AccountErrorCode.appStoreUnavailable:
            true
        default:
            status >= 500
        }
    }

    /// A message for a code that arrived without one.
    private static func defaultMessage(for code: String, status: Int) -> String {
        switch code {
        case AccountErrorCode.invalidInput: "The account server could not accept those details."
        case AccountErrorCode.unauthenticated: "Sign in again to continue."
        case AccountErrorCode.sessionRevoked: "This device was signed out. Sign in again."
        case AccountErrorCode.accountDisabled: "This account has been disabled."
        case AccountErrorCode.usernameTaken: "That username is already taken."
        case AccountErrorCode.emailTaken: "That email already has an account."
        case AccountErrorCode.rateLimited: "Too many attempts. Wait a moment and try again."
        case AccountErrorCode.emailVerificationRequired: "Enter the code that was emailed to you."
        case AccountErrorCode.verificationInvalid: "That code is not right."
        case AccountErrorCode.verificationExpired: "That code has expired. Send a new one."
        case AccountErrorCode.verificationAttempts: "Too many attempts. Send a new code."
        case AccountErrorCode.mailUnavailable: "The mail service is unavailable right now."
        case AccountErrorCode.appleTokenInvalid: "Apple could not verify this sign-in. Try again."
        case AccountErrorCode.appleUnavailable: "Sign in with Apple is unavailable right now."
        case AccountErrorCode.inviteInvalid: "That invite code is not valid."
        case AccountErrorCode.inviteExpired: "That invite code has expired."
        case AccountErrorCode.inviteUsedUp: "That invite code has been used up."
        case AccountErrorCode.appStoreTokenInvalid: "The App Store receipt could not be verified."
        case AccountErrorCode.appStoreProductMismatch: "That subscription is not the one this app offers."
        case AccountErrorCode.appStoreAccountMismatch: "This subscription is linked to another account."
        case AccountErrorCode.appStoreTransactionRevoked: "That App Store transaction was revoked or refunded."
        case AccountErrorCode.appStoreUnavailable: "App Store verification is unavailable right now."
        case AccountErrorCode.internalError: "The account server had a problem. Try again shortly."
        case AccountErrorCode.network: "The account server could not be reached."
        default: "The account server answered with status \(status)."
        }
    }
}
