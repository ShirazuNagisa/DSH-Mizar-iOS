//
//  AppSettings.swift
//  DSH-Mizar
//
//  The live copy of what the operator has switched on.
//
//  `MizarKit` owns the model -- the value, the storage keys, the defaults, and
//  which notification is which kind. This owns the object the app reads: one
//  instance, written through one property, persisted on every write.
//
//  It is a single shared object on purpose. Two things consult it that have no
//  relationship to each other: the Settings screen, which writes it, and the
//  notification delegate, which reads it at the moment a push arrives -- and the
//  delegate is created by UIKit before any of this app's views exist. A copy per
//  caller would mean a switch that changes the screen and not the behaviour,
//  which is the one failure this whole file exists to prevent.
//
//  Written through `values` rather than through a setter per switch: `didSet`
//  fires for a nested write as well (`values.notifications.set(false, for:)`),
//  so persistence and logging happen exactly once no matter which switch moved.
//

import Foundation
import Observation
import MizarKit

@MainActor
@Observable
final class AppSettings {
    /// The settings the app runs on.
    static let shared = AppSettings()

    /// Every setting, as one value.
    ///
    /// Assigning to it -- or to anything inside it -- writes to storage and logs
    /// the change. There is no other way to change a setting.
    var values: MizarSettings {
        didSet {
            guard values != oldValue else { return }
            values.save(to: storage)
            note(changeFrom: oldValue)
        }
    }

    private let storage: any SettingsStorage

    /// Called once after a notification switch has moved.
    ///
    /// The switches used to be a purely local decision, and locally is where
    /// they are read when a push arrives while the app is on screen: the
    /// delegate asks ``isEnabled(_:)`` and drops what the operator does not
    /// want. A *background* push is different -- iOS draws the banner itself
    /// and never asks this app -- so a switch that only lives here stops
    /// nothing on the Lock Screen. The one other place that can stop it is the
    /// host, and the host is reachable only through ``AppModel``.
    ///
    /// A closure rather than a direct call for the reason every other hook in
    /// this app is one: this object is a value holder that `MizarKit` types and
    /// the notification delegate also use, and it must not know that a
    /// connection, a model, or a socket exists. Nil in a test, which is the
    /// point -- a settings screen exercised without a model behaves exactly as
    /// it did before this hook existed.
    ///
    /// Not observed by SwiftUI: nothing draws it, and reading it from a view
    /// body would only make every settings write invalidate that view.
    @ObservationIgnored
    var onNotificationKindsChanged: (() -> Void)?

    /// - Parameter storage: where the values are kept. `UserDefaults` in the app;
    ///   a dictionary in a test.
    init(storage: any SettingsStorage = UserDefaultsSettingsStorage()) {
        self.storage = storage
        values = MizarSettings.load(from: storage)
    }

    /// Whether one kind of notification should be shown.
    /// - Parameter kind: the kind to ask about.
    /// - Returns: whether the operator wants it.
    func isEnabled(_ kind: NotificationKind) -> Bool {
        values.notifications.isEnabled(kind)
    }

    /// Whether the Live Activity may run.
    var liveActivitiesEnabled: Bool { values.liveActivitiesEnabled }

    /// Whether a reconnect should ask the local network before the relay.
    ///
    /// The switch that decides whether a `direct` route may be dialled at all
    /// (see ``RoutePolicy``), which is why a test launch against a loopback
    /// fixture needs it: the fixture is a `direct` endpoint and the switch
    /// defaults to off. `-mizarLocalNetwork` is a different flag -- it reports
    /// a LAN link for the paid-feature tests -- so this one is its own name.
    var localNetworkFirst: Bool {
        values.localNetworkFirst || ProcessInfo.processInfo.arguments.contains("-mizarLocalNetworkRoute")
    }

    /// Whether a reconnect may try the punched direct path.
    ///
    /// The fixture a UI test runs against is reached over loopback, and this
    /// switch defaults to off -- so a launch that pairs with `-mizarPairURI`
    /// landed on "The transport switches are off" and could never open a
    /// conversation. The flag is the launch saying it wants the direct route;
    /// the operator's own switch is untouched when it is absent. Read here
    /// rather than written in `init`, because a mutation inside the initialiser
    /// does not reach storage (the observer that saves it has not been armed
    /// yet) -- which is why the first version of this changed nothing.
    var directConnection: Bool {
        values.directConnection || ProcessInfo.processInfo.arguments.contains("-mizarDirectConnection")
    }

    /// Whether a send into a running turn is handed over as guidance at once.
    ///
    /// The one place the composer asks, so the switch on the Settings screen and
    /// the send path cannot disagree -- the failure this file exists to prevent.
    var guidedSendByDefault: Bool { values.guidedSendByDefault }

    /// Whether the prompt rewriter asks the desktop's model instead of this
    /// phone's. Read by the composer at the moment the entry is used, so the
    /// switch and the behaviour cannot disagree.
    var enhanceWithDesktopModel: Bool {
        values.enhanceWithDesktopModel
            || ProcessInfo.processInfo.arguments.contains("-mizarDesktopEnhance")
    }

    /// Write a change to the log.
    ///
    /// One line per switch that moved, and none for the ones that did not: this
    /// is the answer to "I turned that off, why did it still arrive", and a log
    /// that recorded four lines for every tap would be one nobody reads.
    private func note(changeFrom old: MizarSettings) {
        if old.liveActivitiesEnabled != values.liveActivitiesEnabled {
            ActivityLog.shared.add(.settings, "live activity \(values.liveActivitiesEnabled ? "on" : "off")")
        }
        if old.localNetworkFirst != values.localNetworkFirst {
            ActivityLog.shared.add(
                .settings,
                "local network first \(values.localNetworkFirst ? "on" : "off")",
            )
        }
        if old.directConnection != values.directConnection {
            ActivityLog.shared.add(
                .settings,
                "direct connection \(values.directConnection ? "on" : "off")",
            )
        }
        if old.guidedSendByDefault != values.guidedSendByDefault {
            ActivityLog.shared.add(
                .settings,
                "guided send \(values.guidedSendByDefault ? "on" : "off")",
            )
        }
        if old.enhanceWithDesktopModel != values.enhanceWithDesktopModel {
            ActivityLog.shared.add(
                .settings,
                "prompt enhancement \(values.enhanceWithDesktopModel ? "desktop" : "on-device")",
            )
        }
        for kind in NotificationKind.allCases
        where old.notifications.isEnabled(kind) != values.notifications.isEnabled(kind) {
            let state = values.notifications.isEnabled(kind) ? "on" : "off"
            ActivityLog.shared.add(.settings, "notifications: \(kind.rawValue) \(state)")
        }
        // After the log lines, so a push whose arrival is being investigated
        // finds the switch's move recorded before the registration it caused.
        // Once for the tap, not once per kind: one switch and four switches are
        // the same event as far as the host is concerned, and it is told the
        // whole set either way.
        if old.notifications != values.notifications {
            onNotificationKindsChanged?()
        }
    }
}
