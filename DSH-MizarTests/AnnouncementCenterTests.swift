//
//  AnnouncementCenterTests.swift
//  DSH-MizarTests
//
//  The rules behind the banner, without a socket.
//
//  The socket is the relay's job and the pixels are the view's; what sits
//  between them is one decision -- which banner, if any, this phone should show
//  now -- and that decision is where the bugs live (showing the same one twice,
//  showing an expired one, hiding a button the phone cannot place). It is a pure
//  function for exactly that reason.
//

import Foundation
import MizarKit
import Testing
@testable import DSH_Mizar

@MainActor
struct AnnouncementCenterTests {
    private func banner(
        _ id: String,
        at seconds: TimeInterval,
        expiresAt: Date? = nil,
        active: Bool? = true,
    ) -> Announcement {
        Announcement(
            id: id,
            title: "Title \(id)",
            body: "Body",
            createdAt: Date(timeIntervalSince1970: seconds),
            expiresAt: expiresAt,
            active: active,
        )
    }

    @Test("the newest live banner nobody has seen is the one to show")
    func newestWins() {
        let now = Date(timeIntervalSince1970: 10_000)
        let older = banner("old", at: 1_000)
        let newer = banner("new", at: 2_000)
        let next = AnnouncementCenter.next(in: [older, newer], shown: [], now: now)
        #expect(next?.id == "new")
    }

    @Test("a banner this phone already showed is not shown again")
    func shownIsSkipped() {
        let now = Date(timeIntervalSince1970: 10_000)
        let next = AnnouncementCenter.next(
            in: [banner("a", at: 1_000), banner("b", at: 2_000)],
            shown: ["b"],
            now: now,
        )
        #expect(next?.id == "a")
        #expect(AnnouncementCenter.next(in: [banner("b", at: 2_000)], shown: ["b"], now: now) == nil)
    }

    @Test("expired and stopped banners are not candidates")
    func expiredAndStopped() {
        let now = Date(timeIntervalSince1970: 10_000)
        let expired = banner("expired", at: 1_000, expiresAt: Date(timeIntervalSince1970: 9_000))
        let stopped = banner("stopped", at: 2_000, active: false)
        #expect(AnnouncementCenter.next(in: [expired, stopped], shown: [], now: now) == nil)
    }

    @Test("every target the relay may send lands on the shelf the app has")
    func targetMapping() {
        #expect(AnnouncementTarget.account.settingsTopic == nil)
        #expect(AnnouncementTarget.notifications.settingsTopic == .notifications)
        #expect(AnnouncementTarget.sending.settingsTopic == .sending)
        #expect(AnnouncementTarget.transfer.settingsTopic == .transfer)
        #expect(AnnouncementTarget.localAgent.settingsTopic == .localAgent)
        #expect(AnnouncementTarget.files.settingsTopic == .files)
        #expect(AnnouncementTarget.community.settingsTopic == .community)
        #expect(AnnouncementTarget.logs.settingsTopic == .logs)
        #expect(AnnouncementTarget.about.settingsTopic == .about)
    }

    /// The banner's button must be able to reach each shelf by the server's own
    /// name, so the relay's target list and the settings directory cannot drift
    /// apart without a test saying so.
    @Test("every settings shelf has a banner target with the same name")
    func shelvesAreAddressable() {
        let targets = Set(AnnouncementTarget.allRawValues)
        for topic in SettingsTopic.allCases {
            #expect(targets.contains(topic.rawValue), "no announcement target for \(topic.rawValue)")
        }
    }
}
