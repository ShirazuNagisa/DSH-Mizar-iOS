//
//  AccountModels.swift
//  MizarKit
//
//  The public account shape, as the relay returns it.
//
//  These types are the phone's half of a contract that lives in the relay:
//  `.workbuddy-ai/IMPLEMENTATION-CONTRACTS.md` pins the keys, the account
//  backend in `dsh-relay/src/accounts/types.ts` produces them, and this file
//  decodes them. All three have to agree, which is why the wire names are
//  written out in `CodingKeys` rather than left to a guess about Swift's
//  automatic names.
//
//  Two deliberate choices:
//
//  - **Dates are epoch milliseconds on the wire.** The relay stores `number`s
//    (JavaScript millisecond timestamps) and every field would be off by a
//    factor of 1000 if this used `JSONDecoder`'s default. ``AccountCoding``
//    carries the strategy, and every decoder in this module goes through it.
//  - **Everything but identity is optional with a default.** A public user is
//    assembled by a server that will grow fields; a phone that refuses to draw
//    a profile because one optional key moved is worse than a phone that draws
//    the fields it understands. `id` and `username` are the exceptions: a user
//    without them is not a user.
//

import Foundation

/// The JSON coding used for every account payload.
///
/// Computed rather than stored: `JSONDecoder` and `JSONEncoder` are reference
/// types with no `Sendable` conformance, so a shared instance would be a data
/// race waiting for a background sync. The cost of building one per call is
/// nothing next to an HTTP round trip.
public enum AccountCoding {
    /// A decoder that reads epoch-millisecond dates.
    /// - Returns: the decoder.
    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }

    /// An encoder that writes epoch-millisecond dates.
    /// - Returns: the encoder.
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }
}

// MARK: - Plan

/// Whether an account is paid, as the server computes it.
///
/// The server decides this from `max(grantedPaidUntil, appStore.paidUntil)`; the
/// phone never derives it from the two expiries itself. An unknown string decodes
/// as free on purpose: a server that invents a new plan name must not turn into
/// a phone that refuses to decode the profile at all, and "free" is the safe
/// claim — it unlocks nothing.
public enum AccountPlan: String, Codable, Sendable, CaseIterable {
    /// No paid entitlement.
    case free
    /// Paid through an invite, an admin grant, or the App Store.
    case paid

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AccountPlan(rawValue: raw) ?? .free
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

// MARK: - Avatar

/// How an account's avatar was chosen.
public enum AccountAvatarKind: String, Codable, Sendable, CaseIterable {
    /// A Gravatar URL, when one could be looked up.
    case gravatar
    /// Colours and initials generated from the account.
    case generated

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AccountAvatarKind(rawValue: raw) ?? .generated
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// An account's avatar.
///
/// `colors` and `initials` are always present on the wire, even for a Gravatar
/// account: the relay's contract says a blocked image still has to draw
/// something, and a screen showing an empty circle because a third-party host
/// was unreachable is the failure that sentence exists to prevent.
public struct AccountAvatar: Codable, Sendable, Equatable {
    /// How this avatar was chosen.
    public let kind: AccountAvatarKind
    /// The Gravatar image, when `kind` is `.gravatar`.
    public let url: URL?
    /// A small palette, as hex strings, for the generated fallback.
    public let colors: [String]
    /// One or two characters for the generated fallback.
    public let initials: String

    public init(
        kind: AccountAvatarKind = .generated,
        url: URL? = nil,
        colors: [String] = [],
        initials: String = "",
    ) {
        self.kind = kind
        self.url = url
        self.colors = colors
        self.initials = initials
    }

    /// What to draw when the server said nothing at all.
    public static let blank = AccountAvatar()

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decodeIfPresent(AccountAvatarKind.self, forKey: .kind) ?? .generated
        url = try container.decodeIfPresent(URL.self, forKey: .url)
        colors = try container.decodeIfPresent([String].self, forKey: .colors) ?? []
        initials = try container.decodeIfPresent(String.self, forKey: .initials) ?? ""
    }
}

// MARK: - Device

/// One device signed in to an account.
///
/// Email-only accounts cap at two active devices; Apple-linked accounts are
/// unlimited. The phone is shown the list so the operator can see every place
/// their account is signed in — `current` marks the one holding this session.
public struct AccountDevice: Codable, Sendable, Equatable, Identifiable {
    /// The install id this session was created for.
    public let id: String
    /// The device name as the phone reported it.
    public let name: String
    /// The hardware model, e.g. `iPhone18,1`.
    public let model: String
    /// `ios`, as reported.
    public let platform: String
    /// When this device last signed in, epoch ms on the wire.
    public let loginAt: Date?
    /// When the server last saw a request from this device.
    public let lastSeenAt: Date?
    /// Whether this is the device reading the profile.
    public let current: Bool

    /// Whether this is a phone or tablet, as opposed to a desktop install.
    ///
    /// The account's device list is the sign-in ledger, not the computer list:
    /// desktops have their own rows and their own `AccountDesktop` model. The
    /// device section filters on this so a Mac never appears twice.
    public var isMobile: Bool {
        platform.caseInsensitiveCompare("ios") == .orderedSame
    }

    public init(
        id: String,
        name: String,
        model: String = "",
        platform: String = "ios",
        loginAt: Date? = nil,
        lastSeenAt: Date? = nil,
        current: Bool = false,
    ) {
        self.id = id
        self.name = name
        self.model = model
        self.platform = platform
        self.loginAt = loginAt
        self.lastSeenAt = lastSeenAt
        self.current = current
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? ""
        platform = try container.decodeIfPresent(String.self, forKey: .platform) ?? "ios"
        loginAt = try container.decodeIfPresent(Date.self, forKey: .loginAt)
        lastSeenAt = try container.decodeIfPresent(Date.self, forKey: .lastSeenAt)
        current = try container.decodeIfPresent(Bool.self, forKey: .current) ?? false
    }
}

// MARK: - App Store entitlement

/// The App Store side of an account's paid state, as the relay verified it.
///
/// Deliberately not the raw transaction: the relay keeps the JWS, the original
/// transaction id and the Apple-issued identifiers, and publishes only what the
/// phone needs to draw the subscription row.
public struct AppStoreEntitlement: Codable, Sendable, Equatable {
    /// End of the paid period, or `nil` after a revocation.
    public let paidUntil: Date?
    /// The subscription product this entitlement is for.
    public let productId: String?
    /// `Production` or `Sandbox`, as Apple reported it.
    public let environment: String?
    /// Whether Apple says the subscription renews.
    public let autoRenew: Bool?
    /// When Apple revoked or refunded it, if it did.
    public let revokedAt: Date?

    public init(
        paidUntil: Date? = nil,
        productId: String? = nil,
        environment: String? = nil,
        autoRenew: Bool? = nil,
        revokedAt: Date? = nil,
    ) {
        self.paidUntil = paidUntil
        self.productId = productId
        self.environment = environment
        self.autoRenew = autoRenew
        self.revokedAt = revokedAt
    }

    /// Whether this entitlement is revoked.
    public var isRevoked: Bool { revokedAt != nil }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        paidUntil = try container.decodeIfPresent(Date.self, forKey: .paidUntil)
        productId = try container.decodeIfPresent(String.self, forKey: .productId)
        environment = try container.decodeIfPresent(String.self, forKey: .environment)
        autoRenew = try container.decodeIfPresent(Bool.self, forKey: .autoRenew)
        revokedAt = try container.decodeIfPresent(Date.self, forKey: .revokedAt)
    }
}

// MARK: - User

/// The account profile the relay publishes.
///
/// This is the exact shape in the implementation contract; the account backend's
/// `PublicUser` in `dsh-relay` produces it. Private fields — password hash, token
/// hash, Apple `sub`, transaction JWS — are never in it, and this type has no
/// property that could hold one.
public struct AccountUser: Codable, Sendable, Equatable, Identifiable {
    /// The account id. It is a UUID, and it is the StoreKit `appAccountToken`.
    public let id: String
    /// The unique display name.
    public let username: String
    /// The email, when the account has one.
    public let email: String?
    /// Whether the email has been verified.
    public let emailVerified: Bool
    /// `free` or `paid`, as the server computed it.
    public let plan: AccountPlan
    /// The later of the two entitlement expiries.
    public let paidUntil: Date?
    /// Which sources currently make this account paid: `invite`, `admin`,
    /// `appstore`.
    public let paidSources: [String]
    /// The invite/admin grant expiry alone.
    public let grantedPaidUntil: Date?
    /// The App Store side, or `nil` when there has never been a subscription.
    public let appStore: AppStoreEntitlement?
    /// The avatar, as chosen by the server.
    public let avatar: AccountAvatar
    /// Whether the account is linked to Sign in with Apple.
    ///
    /// The relay has sent this since it began publishing `apple` on the public
    /// user; an older relay simply omits it, and the account reads as an email
    /// one — which is the right fallback, because the only thing the flag
    /// changes is how the avatar is drawn.
    public let appleLinked: Bool
    /// When the account was created.
    public let createdAt: Date?
    /// When the server last saw the account.
    public let lastSeenAt: Date?
    /// Every device currently signed in.
    public let devices: [AccountDevice]

    public init(
        id: String,
        username: String,
        email: String? = nil,
        emailVerified: Bool = false,
        plan: AccountPlan = .free,
        paidUntil: Date? = nil,
        paidSources: [String] = [],
        grantedPaidUntil: Date? = nil,
        appStore: AppStoreEntitlement? = nil,
        avatar: AccountAvatar = .blank,
        appleLinked: Bool = false,
        createdAt: Date? = nil,
        lastSeenAt: Date? = nil,
        devices: [AccountDevice] = [],
    ) {
        self.id = id
        self.username = username
        self.email = email
        self.emailVerified = emailVerified
        self.plan = plan
        self.paidUntil = paidUntil
        self.paidSources = paidSources
        self.grantedPaidUntil = grantedPaidUntil
        self.appStore = appStore
        self.avatar = avatar
        self.appleLinked = appleLinked
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt
        self.devices = devices
    }

    /// Whether the account is paid right now.
    public var isPaid: Bool { plan == .paid }

    /// Whether an App Store subscription is one of the sources.
    public var paidViaAppStore: Bool { paidSources.contains("appstore") }

    /// Whether an invite or an admin grant is one of the sources.
    public var paidViaInvite: Bool {
        paidSources.contains("invite") || paidSources.contains("admin")
    }

    /// Whether the App Store subscription is revoked.
    public var appStoreRevoked: Bool { appStore?.isRevoked ?? false }

    /// The chars to draw in a generated avatar: the server's initials, else the
    /// first character of the username.
    ///
    /// A fallback rather than a replacement: the server's initials are what the
    /// admin UI and every other client show, so disagreeing with them would make
    /// one account look like two.
    public var displayInitials: String {
        let trimmed = avatar.initials.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return String(username.prefix(1)).uppercased()
    }

    /// The user id as a UUID, when the server sent a valid one.
    ///
    /// StoreKit's `appAccountToken` takes a UUID and nothing else, so a malformed
    /// id has to fail before a purchase is attempted rather than at the payment
    /// sheet. The relay generates these with `crypto.randomUUID()`, so this is a
    /// sanity check, not a normal failure.
    public var uuid: UUID? { UUID(uuidString: id) }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        username = try container.decode(String.self, forKey: .username)
        email = try container.decodeIfPresent(String.self, forKey: .email)
        emailVerified = try container.decodeIfPresent(Bool.self, forKey: .emailVerified) ?? false
        plan = try container.decodeIfPresent(AccountPlan.self, forKey: .plan) ?? .free
        paidUntil = try container.decodeIfPresent(Date.self, forKey: .paidUntil)
        paidSources = try container.decodeIfPresent([String].self, forKey: .paidSources) ?? []
        grantedPaidUntil = try container.decodeIfPresent(Date.self, forKey: .grantedPaidUntil)
        appStore = try container.decodeIfPresent(AppStoreEntitlement.self, forKey: .appStore)
        avatar = try container.decodeIfPresent(AccountAvatar.self, forKey: .avatar) ?? .blank
        appleLinked = try container.decodeIfPresent(Bool.self, forKey: .appleLinked) ?? false
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
        lastSeenAt = try container.decodeIfPresent(Date.self, forKey: .lastSeenAt)
        devices = try container.decodeIfPresent([AccountDevice].self, forKey: .devices) ?? []
    }

    /// The wire names, pinned so a Swift rename cannot move a key.
    private enum CodingKeys: String, CodingKey {
        case id
        case username
        case email
        case emailVerified
        case plan
        case paidUntil
        case paidSources
        case grantedPaidUntil
        case appStore
        case avatar
        /// `appleLinked` is `apple` on the wire.
        case appleLinked = "apple"
        case createdAt
        case lastSeenAt
        case devices
    }
}

// MARK: - Session and auth

/// A signed-in session: the bearer token and the profile it belongs to.
///
/// This is the one blob the Keychain holds. The token is the credential; the
/// profile is cached beside it so the settings screen can draw an account row
/// before the relay has answered anything — a phone in a lift must not show
/// "not signed in" to somebody who is.
public struct AccountSession: Codable, Sendable, Equatable {
    /// The bearer token, `mza_…`.
    public let token: String
    /// The profile last returned by the relay.
    public var profile: AccountUser

    public init(token: String, profile: AccountUser) {
        self.token = token
        self.profile = profile
    }

    /// Whether this session can still be presented as signed in.
    ///
    /// An empty token is not a session: it would produce an `Authorization: Bearer `
    /// header that the relay answers with 401, and a settings row that claims to
    /// be signed in while every request fails.
    public var isUsable: Bool { !token.isEmpty }
}

/// A device descriptor sent with a login, register or Apple sign-in.
///
/// The id is the install id, generated once per install and stored separately
/// from the session: the server caps email-only accounts at two active devices,
/// and it identifies a device by this id, so losing it on a logout would make
/// every re-login look like a new device.
public struct AccountDevicePayload: Codable, Sendable, Equatable {
    /// The install id.
    public let id: String
    /// The device name, e.g. `iPhone`.
    public let name: String
    /// The hardware model, e.g. `iPhone18,1`.
    public let model: String
    /// `ios`.
    public let platform: String
    /// The app's marketing version.
    public let appVersion: String

    public init(
        id: String,
        name: String,
        model: String,
        platform: String = "ios",
        appVersion: String,
    ) {
        self.id = id
        self.name = name
        self.model = model
        self.platform = platform
        self.appVersion = appVersion
    }
}

/// A notice returned beside a successful sign-in.
///
/// Today the only one is `DEVICE_LIMIT`: a third email-only device signed in and
/// the oldest was revoked. It travels with the success rather than as an error
/// because the sign-in did happen — the operator is signed in somewhere else
/// from the device they were using a minute ago, and only telling them is useful.
public struct AccountNotice: Codable, Sendable, Equatable {
    /// The notice code. `DEVICE_LIMIT` for now.
    public let code: String
    /// What was revoked, when the notice names one.
    public let revokedDevice: String?

    public init(code: String, revokedDevice: String? = nil) {
        self.code = code
        self.revokedDevice = revokedDevice
    }

    /// Whether this is the device-limit notice.
    public var isDeviceLimit: Bool { code == "DEVICE_LIMIT" }
}

/// What a successful register/login/apple call returns.
public struct AccountAuth: Codable, Sendable, Equatable {
    /// The bearer token.
    public let token: String
    /// The account profile.
    public let user: AccountUser
    /// A warning that came with success.
    public let notice: AccountNotice?

    public init(token: String, user: AccountUser, notice: AccountNotice? = nil) {
        self.token = token
        self.user = user
        self.notice = notice
    }

    /// The session this auth result should be stored as.
    public var session: AccountSession { AccountSession(token: token, profile: user) }
}

/// What `/register/start` answers: a code is on its way.
public struct RegistrationChallenge: Codable, Sendable, Equatable {
    /// Where it was sent, echoed so the sheet can name the address.
    public let email: String
    /// When the code stops working.
    public let expiresAt: Date
    /// How long until another code may be requested.
    public let resendAfterSeconds: Int

    public init(email: String, expiresAt: Date, resendAfterSeconds: Int) {
        self.email = email
        self.expiresAt = expiresAt
        self.resendAfterSeconds = resendAfterSeconds
    }
}

// MARK: - Errors

/// The machine-readable codes the account API documents.
///
/// As constants rather than an enum: the relay may add a code this build does
/// not know, and an app that fails to parse an error body because of an unknown
/// code turns a clear refusal into "something went wrong".
public enum AccountErrorCode {
    public static let invalidInput = "INVALID_INPUT"
    public static let unauthenticated = "UNAUTHENTICATED"
    public static let sessionRevoked = "SESSION_REVOKED"
    public static let accountDisabled = "ACCOUNT_DISABLED"
    public static let usernameTaken = "USERNAME_TAKEN"
    public static let emailTaken = "EMAIL_TAKEN"
    public static let rateLimited = "RATE_LIMITED"
    /// The server now proves the address before it creates the account.
    public static let emailVerificationRequired = "EMAIL_VERIFICATION_REQUIRED"
    public static let verificationInvalid = "VERIFICATION_INVALID"
    public static let verificationExpired = "VERIFICATION_EXPIRED"
    public static let verificationAttempts = "VERIFICATION_ATTEMPTS"
    /// The mail service could not be reached, so no code was sent.
    public static let mailUnavailable = "MAIL_UNAVAILABLE"
    public static let appleTokenInvalid = "APPLE_TOKEN_INVALID"
    public static let appleUnavailable = "APPLE_UNAVAILABLE"
    public static let inviteInvalid = "INVITE_INVALID"
    public static let inviteExpired = "INVITE_EXPIRED"
    public static let inviteUsedUp = "INVITE_USED_UP"
    /// This account already collected what that code gives.
    public static let inviteAlreadyUsed = "INVITE_ALREADY_USED"
    /// Surveys are not configured on the relay, or it could not reach the store.
    public static let surveyUnavailable = "SURVEY_UNAVAILABLE"
    public static let surveyNotFound = "SURVEY_NOT_FOUND"
    /// This account already answered that survey and was already paid for it.
    public static let surveyAlreadyDone = "SURVEY_ALREADY_DONE"
    /// An answer was missing, unknown, or did not fit its question.
    public static let surveyInvalidAnswers = "SURVEY_INVALID_ANSWERS"
    public static let appStoreTokenInvalid = "APPSTORE_TOKEN_INVALID"
    public static let appStoreProductMismatch = "APPSTORE_PRODUCT_MISMATCH"
    public static let appStoreAccountMismatch = "APPSTORE_ACCOUNT_MISMATCH"
    public static let appStoreTransactionRevoked = "APPSTORE_TRANSACTION_REVOKED"
    public static let appStoreUnavailable = "APPSTORE_UNAVAILABLE"
    public static let internalError = "INTERNAL"
    /// Not sent by the server: the request never got an answer.
    public static let network = "NETWORK"
    /// Not sent by the server: the answer was not the documented shape.
    public static let malformedResponse = "MALFORMED_RESPONSE"
}

/// A failed account request.
///
/// Carries the server's own code so the app can say something specific — "that
/// username is taken" rather than "the request failed" — while keeping the
/// server's message as a fallback for codes this build has never heard of.
public struct AccountError: Error, Sendable, Equatable, LocalizedError {
    /// The documented code, or a local one for transport failures.
    public let code: String
    /// The HTTP status, or `0` when no HTTP answer arrived.
    public let status: Int
    /// A human-readable message. English, as a fallback for unknown codes; the
    /// app's own localisation is keyed on ``code``.
    public let message: String
    /// Whether retrying the same request could succeed.
    public let retryable: Bool
    /// An appeal address the server attached to a refusal.
    ///
    /// Only `ACCOUNT_DISABLED` carries one today: a banned account needs
    /// somewhere to write to, and the app cannot invent that address.
    public let contact: String?

    public init(code: String, status: Int = 0, message: String, retryable: Bool = false, contact: String? = nil) {
        self.code = code
        self.status = status
        self.message = message
        self.retryable = retryable
        self.contact = contact
    }

    public var errorDescription: String? { message }

    /// Whether the session behind this request is gone, so the app should clear
    /// its stored token and say so.
    ///
    /// `SESSION_REVOKED` is a deliberate revocation (signed out elsewhere, or the
    /// device was removed); `UNAUTHENTICATED` is the same outcome from an expired
    /// or unknown token. Both mean the cached profile must stop being shown as a
    /// live session. `ACCOUNT_DISABLED` is a different thing — the account exists
    /// but is not allowed to act — and is included because no request can succeed
    /// until an administrator reverses it.
    public var requiresReauthentication: Bool {
        status == 401
            || code == AccountErrorCode.unauthenticated
            || code == AccountErrorCode.sessionRevoked
            || code == AccountErrorCode.accountDisabled
    }

    /// Whether retrying later is the right advice.
    public var isTransient: Bool { retryable }

    /// Wrap any thrown error as an `AccountError`.
    ///
    /// - Parameter error: what was thrown.
    /// - Returns: the account error.
    public static func transport(_ error: any Error) -> AccountError {
        if let accountError = error as? AccountError { return accountError }
        if error is CancellationError {
            return AccountError(
                code: AccountErrorCode.network,
                message: "The request was cancelled.",
            )
        }
        if let urlError = error as? URLError {
            // A cancellation is the app going away, not the network: retrying it
            // is pointless and showing it is noise.
            let retryable = urlError.code != .cancelled
            return AccountError(
                code: AccountErrorCode.network,
                message: urlError.localizedDescription,
                retryable: retryable,
            )
        }
        return AccountError(
            code: AccountErrorCode.network,
            message: error.localizedDescription,
            retryable: true,
        )
    }
}
