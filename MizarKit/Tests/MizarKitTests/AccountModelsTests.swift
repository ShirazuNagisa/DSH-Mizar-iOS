//
//  AccountModelsTests.swift
//  MizarKitTests
//
//  The public user shape is a contract with a server, so these tests pin the
//  two things a silent drift would cost: every key decodes, and every date is
//  epoch milliseconds rather than seconds or an ISO string. A phone that decodes
//  a paidUntil 1000x wrong would show a subscription that expired in 1970 or
//  renews in 1970000, and neither is a visible error.
//

import Foundation
import Testing
@testable import MizarKit

@Suite("AccountModels")
struct AccountModelsTests {
    /// A full public user, exactly as the contract writes it.
    static let publicUser = #"""
    {
      "id": "3f2b8c1e-9a4d-4f6e-8b1a-2c3d4e5f6a7b",
      "username": "shirazu",
      "email": "a@b.com",
      "emailVerified": false,
      "plan": "paid",
      "paidUntil": 1760000000000,
      "paidSources": ["invite", "appstore"],
      "grantedPaidUntil": 1761000000000,
      "appStore": {
        "paidUntil": 1762000000000,
        "productId": "me.shirazu.dshmizar.paid.monthly",
        "environment": "Production",
        "autoRenew": true,
        "revokedAt": null
      },
      "avatar": {"kind": "generated", "colors": ["#5b8def", "#8f6bff", "#2fc7a5"], "initials": "S"},
      "createdAt": 1759000000000,
      "lastSeenAt": 1760500000000,
      "devices": [
        {"id": "install-1", "name": "iPhone", "model": "iPhone18,1", "platform": "ios",
         "loginAt": 1759000000000, "lastSeenAt": 1760500000000, "current": true}
      ]
    }
    """#

    @Test("decodes the whole public user shape")
    func decodesPublicUser() throws {
        let user = try AccountCoding.decoder().decode(AccountUser.self, from: Data(Self.publicUser.utf8))
        #expect(user.id == "3f2b8c1e-9a4d-4f6e-8b1a-2c3d4e5f6a7b")
        #expect(user.username == "shirazu")
        #expect(user.email == "a@b.com")
        #expect(!user.emailVerified)
        #expect(user.plan == .paid)
        #expect(user.isPaid)
        #expect(user.paidSources == ["invite", "appstore"])
        #expect(user.paidViaInvite)
        #expect(user.paidViaAppStore)
        #expect(user.displayInitials == "S")
        #expect(user.uuid != nil)
        #expect(user.devices.count == 1)
        #expect(user.devices.first?.current == true)
        #expect(user.devices.first?.model == "iPhone18,1")
        #expect(user.appStore?.autoRenew == true)
        #expect(!user.appStoreRevoked)
    }

    @Test("reads dates as epoch milliseconds, not seconds or ISO strings")
    func epochMilliseconds() throws {
        let user = try AccountCoding.decoder().decode(AccountUser.self, from: Data(Self.publicUser.utf8))
        // 1760000000000 ms is 2025-10-09T12:53:20Z. Seconds would be 1970; a
        // string would have failed to decode at all.
        let expected = Date(timeIntervalSince1970: 1_760_000_000)
        #expect(user.paidUntil == expected)
        #expect(user.grantedPaidUntil == Date(timeIntervalSince1970: 1_761_000_000))
        #expect(user.appStore?.paidUntil == Date(timeIntervalSince1970: 1_762_000_000))
        #expect(user.createdAt == Date(timeIntervalSince1970: 1_759_000_000))
        #expect(user.devices.first?.loginAt == Date(timeIntervalSince1970: 1_759_000_000))
        #expect(user.appStore?.revokedAt == nil)
    }

    @Test("round-trips the session blob through the storing coder")
    func sessionRoundTrip() throws {
        let user = try AccountCoding.decoder().decode(AccountUser.self, from: Data(Self.publicUser.utf8))
        let session = AccountSession(token: "mza_test", profile: user)
        let data = try AccountCoding.encoder().encode(session)
        let restored = try AccountCoding.decoder().decode(AccountSession.self, from: data)
        #expect(restored == session)
        #expect(restored.profile.paidUntil == user.paidUntil)
        #expect(restored.isUsable)
    }

    @Test("accepts a profile with every optional field absent")
    func tolerantOfMissingOptionals() throws {
        // A server that grows fields, or a fixture that omits the boring ones,
        // must still draw a profile. Identity is the only thing required.
        let json = #"{"id":"u1","username":"minimal"}"#
        let user = try AccountCoding.decoder().decode(AccountUser.self, from: Data(json.utf8))
        #expect(user.plan == .free)
        #expect(!user.isPaid)
        #expect(user.avatar == .blank)
        #expect(user.devices.isEmpty)
        #expect(user.appStore == nil)
        #expect(user.email == nil)
        #expect(user.displayInitials == "M")
    }

    @Test("falls back to free for a plan this build does not know")
    func unknownPlanBreaksNothing() throws {
        let json = #"{"id":"u1","username":"x","plan":"platinum"}"#
        let user = try AccountCoding.decoder().decode(AccountUser.self, from: Data(json.utf8))
        #expect(user.plan == .free)
    }

    @Test("decodes a gravatar avatar and an absent app store entry")
    func gravatarAndNoAppStore() throws {
        let json = #"""
        {
          "id": "u1", "username": "x", "plan": "free",
          "paidUntil": null, "grantedPaidUntil": null, "appStore": null,
          "paidSources": [],
          "avatar": {"kind": "gravatar", "url": "https://gravatar.example/abc?d=404&s=256",
                     "colors": ["#111111"], "initials": "X"}
        }
        """#
        let user = try AccountCoding.decoder().decode(AccountUser.self, from: Data(json.utf8))
        #expect(user.avatar.kind == .gravatar)
        #expect(user.avatar.url?.host() == "gravatar.example")
        #expect(user.appStore == nil)
        #expect(!user.paidViaInvite)
        #expect(!user.paidViaAppStore)
    }

    @Test("decodes a revoked subscription")
    func revokedSubscription() throws {
        let json = #"""
        {
          "id": "u1", "username": "x", "plan": "free", "paidSources": [],
          "appStore": {"paidUntil": null, "productId": "p", "environment": "Sandbox",
                       "autoRenew": false, "revokedAt": 1760000000000}
        }
        """#
        let user = try AccountCoding.decoder().decode(AccountUser.self, from: Data(json.utf8))
        #expect(user.appStore?.isRevoked == true)
        #expect(user.appStoreRevoked)
        #expect(user.appStore?.paidUntil == nil)
    }

    @Test("decodes the auth result with a device-limit notice")
    func authWithNotice() throws {
        let json = #"""
        {"token":"mza_abc","user":{"id":"u1","username":"x","plan":"free"},
         "notice":{"code":"DEVICE_LIMIT","revokedDevice":"old-phone"}}
        """#
        let auth = try AccountCoding.decoder().decode(AccountAuth.self, from: Data(json.utf8))
        #expect(auth.token == "mza_abc")
        #expect(auth.session.token == "mza_abc")
        #expect(auth.notice?.isDeviceLimit == true)
        #expect(auth.notice?.revokedDevice == "old-phone")
    }

    @Test("marks the session states that need signing in again")
    func reauthenticationStates() {
        #expect(AccountError(code: "X", status: 401, message: "no").requiresReauthentication)
        #expect(AccountError(code: "SESSION_REVOKED", status: 403, message: "no").requiresReauthentication)
        #expect(AccountError(code: "ACCOUNT_DISABLED", status: 403, message: "no").requiresReauthentication)
        #expect(!AccountError(code: "USERNAME_TAKEN", status: 409, message: "no").requiresReauthentication)
        #expect(!AccountError(code: "NETWORK", status: 0, message: "no").requiresReauthentication)
    }

    @Test("wraps transport failures as account errors")
    func transportWrapping() {
        let offline = AccountError.transport(URLError(.notConnectedToInternet))
        #expect(offline.code == AccountErrorCode.network)
        #expect(offline.retryable)

        // Cancelling is the app going away, not a network to retry.
        let cancelled = AccountError.transport(URLError(.cancelled))
        #expect(!cancelled.retryable)

        // An account error passes through unchanged.
        let existing = AccountError(code: "INVITE_EXPIRED", status: 410, message: "expired")
        #expect(AccountError.transport(existing) == existing)
    }

    @Test("the device ledger distinguishes phones from desktops")
    func deviceIsMobile() {
        func device(platform: String) -> AccountDevice {
            AccountDevice(id: "d", name: "n", model: "m", platform: platform)
        }
        #expect(device(platform: "ios").isMobile)
        #expect(device(platform: "IOS").isMobile)
        #expect(!device(platform: "macos").isMobile)
        #expect(!device(platform: "windows").isMobile)
    }
}
