//
//  MizarSettingsTests.swift
//  MizarKitTests
//
//  The two decisions the Settings screen rests on: which notification a push is,
//  and whether the operator wants it.
//
//  Both are tested here rather than through the screen, because the screen can
//  only be as honest as these two functions -- and a switch that is drawn in the
//  right position while the app consults something else is the exact failure a UI
//  test cannot see.
//

import Foundation
import Testing
@testable import MizarKit

@Suite("Notification kinds")
struct NotificationKindTests {
    @Test("names the three wire kinds the plugin sends")
    func wireKinds() {
        #expect(NotificationKind.classify(kind: "approval", title: "需要你的许可") == .approval)
        #expect(NotificationKind.classify(kind: "question", title: "模型有问题要问你") == .question)
        #expect(NotificationKind.classify(kind: "turn-complete", title: "任务完成") == .turnFinished)
    }

    @Test(
        "folds the failure wordings into the interrupted kind",
        arguments: [
            "任务出错", "任务已停止", "Task failed", "Task stopped",
        ],
    )
    func interruptedWordings(title: String) {
        #expect(NotificationKind.classify(kind: "turn-complete", title: title) == .turnInterrupted)
    }

    @Test(
        "reads a settled turn as an ending rather than a failure",
        arguments: ["任务已结束", "Task finished"],
    )
    func settledIsAnEnding(title: String) {
        // The plugin's `settled` case -- a turn that ended with no recorded
        // reason -- is not an abort, and filing it under 任务中断 would make that
        // switch mean "turns I did not expect".
        #expect(NotificationKind.classify(kind: "turn-complete", title: title) == .turnFinished)
    }

    @Test("takes a reason when a host sends one, ahead of the wording")
    func reasonWins() {
        // A future host can be more precise than a localized title, and this is
        // where that precision is picked up without a new build.
        #expect(
            NotificationKind.classify(kind: "turn-complete", title: "任务完成", reason: "aborted")
                == .turnInterrupted,
        )
        #expect(
            NotificationKind.classify(kind: "turn-complete", title: "任务出错", reason: "completed")
                == .turnFinished,
        )
    }

    @Test("accepts a finer wire name from a later host")
    func finerNames() {
        #expect(NotificationKind.classify(kind: "turn-interrupted", title: nil) == .turnInterrupted)
        #expect(NotificationKind.classify(kind: "turn-finished", title: nil) == .turnFinished)
    }

    @Test("does not know a kind it has never seen, so the caller shows it")
    func unknownIsUnknown() {
        // Nil rather than a default. A push from a newer host must not be
        // silenced by a build that has no switch for it.
        #expect(NotificationKind.classify(kind: "digest", title: "Later") == nil)
        #expect(NotificationKind.classify(kind: nil, title: "No kind at all") == nil)
        #expect(NotificationKind.classify(kind: "   ", title: nil) == nil)
    }

    @Test("tolerates the casing and padding a transport might add")
    func tolerantParsing() {
        #expect(NotificationKind.classify(kind: " APPROVAL ", title: nil) == .approval)
        #expect(NotificationKind.classify(kind: "Turn-Complete", title: "Task failed") == .turnInterrupted)
    }

    @Test("treats a turn-complete with no wording as finished")
    func bareTurnComplete() {
        // The plugin always writes a title; a host that did not would otherwise
        // lose the notification entirely.
        #expect(NotificationKind.classify(kind: "turn-complete", title: nil) == .turnFinished)
    }
}

@Suite("Notification preferences")
struct NotificationPreferencesTests {
    @Test("starts with everything on")
    func defaultsAreOn() {
        let preferences = NotificationPreferences()
        for kind in NotificationKind.allCases {
            #expect(preferences.isEnabled(kind))
        }
        #expect(preferences.suppressed.isEmpty)
    }

    @Test("switches one kind without touching the others")
    func switchesOneKind() {
        var preferences = NotificationPreferences()
        preferences.set(false, for: .question)
        #expect(!preferences.isEnabled(.question))
        #expect(preferences.isEnabled(.approval))
        #expect(preferences.isEnabled(.turnFinished))
        #expect(preferences.isEnabled(.turnInterrupted))
        #expect(preferences.suppressed == [.question])
        preferences.set(true, for: .question)
        #expect(preferences.isEnabled(.question))
    }

    @Test("writes one entry per kind, by name")
    func encodesReadably() throws {
        var preferences = NotificationPreferences()
        preferences.set(false, for: .turnInterrupted)
        let encoded = try JSONEncoder().encode(preferences)
        let text = String(decoding: encoded, as: UTF8.self)
        #expect(text.contains("\"turn-interrupted\":false"))
        #expect(text.contains("\"approval\":true"))
        let decoded = try JSONDecoder().decode(NotificationPreferences.self, from: encoded)
        #expect(decoded == preferences)
    }

    @Test("reads a kind the file does not mention as switched on")
    func missingKindIsOn() throws {
        // What a settings.json written by an older build looks like once a kind
        // is added: the absent entry must not read as "off".
        let text = #"{"approval":false}"#
        let decoded = try JSONDecoder().decode(NotificationPreferences.self, from: Data(text.utf8))
        #expect(!decoded.isEnabled(.approval))
        #expect(decoded.isEnabled(.question))
        #expect(decoded.isEnabled(.turnFinished))
        #expect(decoded.isEnabled(.turnInterrupted))
    }
}

@Suite("Muted kinds on the wire")
struct NotificationMuteWireTests {
    /// What one position of the switches turns into in `push.register`.
    ///
    /// Written as the *whole array* rather than as `contains`, because the
    /// contract is an exact value: a field the host compares, caches and (in
    /// the tests on its side) asserts.
    private func wire(_ off: Set<NotificationKind>) -> [String] {
        NotificationPreferences(off: off).mutedKinds
    }

    @Test("sends nothing for an empty set, so an untouched install costs no field")
    func nothingOff() {
        #expect(wire([]) == [])
    }

    @Test("carries approval under the name the host uses")
    func approvalOnly() {
        #expect(wire([.approval]) == ["approval"])
    }

    @Test("carries the two one-to-one kinds together, in order")
    func approvalAndQuestion() {
        // Alphabetical, so one setting has one array: the empty case, one kind,
        // two kinds -- and never the order a `Set` happened to iterate in.
        #expect(wire([.question, .approval]) == ["approval", "question"])
    }

    @Test("folds a turn that is off both ways into turn_end")
    func bothTurnSwitchesOff() {
        #expect(wire([.turnFinished, .turnInterrupted]) == ["turn_end"])
        #expect(
            wire([.approval, .question, .turnFinished, .turnInterrupted])
                == ["approval", "question", "turn_end"],
        )
    }

    @Test("does not send turn_end when only half of it is off")
    func halfATurnIsNotMuted() {
        // The host has one switch where this phone has two, and an intersection
        // is the only safe reading: sending `turn_end` here would silence the
        // endings the operator still has on. An extra push the app drops on
        // arrival is strictly better than a missing one.
        #expect(wire([.turnFinished]) == [])
        #expect(wire([.turnInterrupted]) == [])
        #expect(wire([.approval, .turnFinished]) == ["approval"])
        #expect(wire([.approval, .turnInterrupted]) == ["approval"])
    }

    @Test("turns back into nothing when the switch is switched back on")
    func reenabled() {
        var preferences = NotificationPreferences(off: [.approval, .question])
        preferences.set(true, for: .approval)
        preferences.set(true, for: .question)
        #expect(preferences.mutedKinds == [])
    }
}

@Suite("Mizar settings")
struct MizarSettingsTests {
    /// A store that keeps what it is given, for tests.
    ///
    /// `UserDefaults` itself is not suitable here: a test that writes to the real
    /// defaults leaves state behind for the next one, and the whole point of the
    /// "absent means on" rule is that a *fresh* store behaves differently from
    /// one holding a `false`.
    private final class MemoryStorage: SettingsStorage {
        private var values: [String: Bool] = [:]
        private var strings: [String: String] = [:]

        init(values: [String: Bool] = [:]) {
            self.values = values
        }

        func bool(forKey key: String) -> Bool? { values[key] }

        func set(_ value: Bool, forKey key: String) { values[key] = value }

        func string(forKey key: String) -> String? { strings[key] }

        func set(_ value: String?, forKey key: String) { strings[key] = value }
    }

    @Test("reads a storage that has never been written to as the defaults")
    func freshStore() {
        let settings = MizarSettings.load(from: MemoryStorage())
        #expect(settings.liveActivitiesEnabled)
        #expect(settings.notifications == .allEnabled)
        // The transfer setting is the one default that is off: a phone that has
        // never been asked should reconnect on the saved route, not spend a
        // probe timeout finding out its LAN address is stale.
        #expect(!settings.localNetworkFirst)
        // Guidance into a running turn is a behaviour the operator opts into.
        // Off is the host's queue, which is what every build before this one
        // did, and it is the answer a fresh store must give.
        #expect(!settings.guidedSendByDefault)
        // The desktop rewrite sends the draft off the phone, so a fresh store
        // must not choose it on the operator's behalf.
        #expect(!settings.enhanceWithDesktopModel)
    }

    @Test("round-trips every switch through a store")
    func roundTrip() {
        let storage = MemoryStorage()
        var settings = MizarSettings(liveActivitiesEnabled: false)
        settings.notifications.set(false, for: .approval)
        settings.notifications.set(false, for: .turnInterrupted)
        settings.localNetworkFirst = true
        settings.guidedSendByDefault = true
        settings.enhanceWithDesktopModel = true
        settings.save(to: storage)

        let reloaded = MizarSettings.load(from: storage)
        #expect(reloaded == settings)
        #expect(!reloaded.liveActivitiesEnabled)
        #expect(!reloaded.notifications.isEnabled(.approval))
        #expect(!reloaded.notifications.isEnabled(.turnInterrupted))
        #expect(reloaded.notifications.isEnabled(.question))
        #expect(reloaded.localNetworkFirst)
        #expect(reloaded.guidedSendByDefault)
        #expect(reloaded.enhanceWithDesktopModel)
    }

    @Test("survives a relaunch, which is a second load of the same store")
    func survivesRelaunch() {
        // Exactly what the app does: one process writes, another reads. The
        // store outlives the value, which is the property the UI test checks on a
        // simulator and this checks in a millisecond.
        let storage = MemoryStorage()
        var first = MizarSettings()
        first.notifications.set(false, for: .turnFinished)
        first.save(to: storage)

        let second = MizarSettings.load(from: storage)
        #expect(!second.notifications.isEnabled(.turnFinished))
    }

    @Test("stores each kind under its own key")
    func keysArePerKind() {
        let storage = MemoryStorage()
        var settings = MizarSettings()
        settings.notifications.set(false, for: .question)
        settings.save(to: storage)
        #expect(storage.bool(forKey: MizarSettings.notificationsKey(.question)) == false)
        #expect(storage.bool(forKey: MizarSettings.notificationsKey(.approval)) == true)
        #expect(storage.bool(forKey: MizarSettings.liveActivitiesKey) == true)
        #expect(storage.bool(forKey: MizarSettings.localNetworkFirstKey) == false)
        #expect(storage.bool(forKey: MizarSettings.guidedSendKey) == false)
        #expect(storage.bool(forKey: MizarSettings.enhanceWithDesktopKey) == false)
    }

    @Test("writes and reads the real defaults, distinguishing absent from off")
    func userDefaultsStorage() throws {
        // A scratch suite, never the app's own domain, and removed at the end.
        // Worth doing for real: the difference between "no value" and "false" is
        // the whole design, and `UserDefaults.bool(forKey:)` collapses it.
        let name = "mizar.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let storage = UserDefaultsSettingsStorage(defaults: defaults)

        #expect(storage.bool(forKey: "mizar.settings.liveActivity") == nil)
        #expect(MizarSettings.load(from: storage).liveActivitiesEnabled)

        var settings = MizarSettings()
        settings.notifications.set(false, for: .question)
        settings.liveActivitiesEnabled = false
        settings.save(to: storage)

        let reloaded = MizarSettings.load(from: storage)
        #expect(!reloaded.liveActivitiesEnabled)
        #expect(!reloaded.notifications.isEnabled(.question))
        #expect(reloaded.notifications.isEnabled(.approval))
    }

    @Test("the LAN priority switch round-trips on its own")
    func lanPriorityRoundTrip() {
        // The screen writes exactly this and AppModel reads exactly this; the
        // switch that decides whether a reconnect probes the LAN has to survive
        // a relaunch or the fast path would come back on its own.
        let storage = MemoryStorage()
        var settings = MizarSettings()
        settings.localNetworkFirst = true
        settings.save(to: storage)

        let reloaded = MizarSettings.load(from: storage)
        #expect(reloaded.localNetworkFirst)
        #expect(storage.bool(forKey: MizarSettings.localNetworkFirstKey) == true)

        settings.localNetworkFirst = false
        settings.save(to: storage)
        #expect(!MizarSettings.load(from: storage).localNetworkFirst)
    }

    @Test("the desktop rewrite switch round-trips on its own")
    func desktopEnhanceRoundTrip() {
        // Where the draft goes is the operator's choice; a relaunch that
        // turned it back on would upload a draft they had chosen to keep on
        // the phone, and one that turned it off would strand a phone whose
        // on-device model cannot answer.
        let storage = MemoryStorage()
        var settings = MizarSettings()
        #expect(!settings.enhanceWithDesktopModel)
        settings.enhanceWithDesktopModel = true
        settings.save(to: storage)
        #expect(MizarSettings.load(from: storage).enhanceWithDesktopModel)
        #expect(storage.bool(forKey: MizarSettings.enhanceWithDesktopKey) == true)

        settings.enhanceWithDesktopModel = false
        settings.save(to: storage)
        #expect(!MizarSettings.load(from: storage).enhanceWithDesktopModel)
    }

    @Test("the guided-send switch round-trips on its own")
    func guidedSendRoundTrip() {
        // The switch decides whether a send into a running turn is handed over
        // at once or held for the end of it, so it has to survive a relaunch:
        // coming back on its own would turn a message the operator expected to
        // queue into one that interrupted the model.
        let storage = MemoryStorage()
        var settings = MizarSettings()
        settings.guidedSendByDefault = true
        settings.save(to: storage)

        let reloaded = MizarSettings.load(from: storage)
        #expect(reloaded.guidedSendByDefault)
        #expect(storage.bool(forKey: MizarSettings.guidedSendKey) == true)

        settings.guidedSendByDefault = false
        settings.save(to: storage)
        #expect(!MizarSettings.load(from: storage).guidedSendByDefault)
    }
}

@Suite("The direct-connection switch")
struct DirectConnectionSettingTests {
    /// A store of this test's own; see ``MizarSettingsTests`` for why the real
    /// defaults are not used.
    private final class MemoryStorage: SettingsStorage {
        var values: [String: Bool] = [:]
        var strings: [String: String] = [:]

        func bool(forKey key: String) -> Bool? { values[key] }

        func set(_ value: Bool, forKey key: String) { values[key] = value }

        func string(forKey key: String) -> String? { strings[key] }

        func set(_ value: String?, forKey key: String) { strings[key] = value }
    }

    @Test("is off on a store that has never been written to")
    func offByDefault() {
        // The rollout decision, asserted where the app reads it: a fresh install
        // reconnects on the routes it always had, and the punched attempt is
        // something somebody asked for.
        #expect(!MizarSettings.load(from: MemoryStorage()).directConnection)
    }

    @Test("survives a write and a read")
    func roundTrip() {
        let storage = MemoryStorage()
        var settings = MizarSettings.load(from: storage)
        settings.directConnection = true
        settings.save(to: storage)
        #expect(MizarSettings.load(from: storage).directConnection)
        #expect(storage.values[MizarSettings.directConnectionKey] == true)
    }

    @Test("does not disturb the switch beside it")
    func independentOfLANPriority() {
        let storage = MemoryStorage()
        var settings = MizarSettings.load(from: storage)
        settings.directConnection = true
        settings.save(to: storage)
        // Two switches in the same section, two keys: turning one on must not
        // turn the other on, which is the failure a shared key would produce.
        #expect(!MizarSettings.load(from: storage).localNetworkFirst)
    }
}
