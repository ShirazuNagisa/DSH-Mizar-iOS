//
//  NotificationsSettingsView.swift
//  DSH-Mizar
//
//  What this phone will tell you: the four kinds of notification, whether a
//  running turn shows on the Lock Screen, and whether the phone taps you.
//
//  The three sections sit on one page because they are one question -- "how do
//  I find out that something happened" -- asked three ways. Every switch here
//  is wired to something that reads it, and that is the whole reason this page
//  is not a list of preferences: 通知 asks ``NotificationKind`` what arrived and
//  ``PushAppDelegate`` refuses what the operator switched off; 实时活动 is
//  ``AppModel/liveActivitiesEnabled``, which the activity reads; 触感 is
//  ``Haptics/storageKey``, which every haptic in the app answers to. A switch
//  nothing consults is worse than no switch, because it teaches the operator
//  that this screen does not work.
//

import MizarKit
import SwiftUI

struct NotificationsSettingsView: View {
    @Environment(AppModel.self) private var model
    /// Closes the settings sheet this page was pushed in.
    var onDone: (() -> Void)?

    /// What iOS thinks of this app's notifications, read when the page opens.
    @State private var permission: NotificationPermission?
    /// The one switch every haptic in the app answers to.
    @AppStorage(Haptics.storageKey) private var hapticsEnabled = true

    var body: some View {
        SettingsPage(title: "Notifications & Live Activity", onDone: onDone) {
            List {
                notificationKindsSection
                liveActivitySection
                feelSection
            }
            .task {
                // Asked here rather than at launch: this is the page where the
                // answer is meaningful, and reading it is a call into the
                // notification centre that nothing else needs.
                permission = await NotificationPermission.current()
            }
        }
    }

    // MARK: - 通知

    private var notificationKindsSection: some View {
        Section {
            ForEach(NotificationKind.allCases, id: \.self) { kind in
                Toggle(isOn: binding(for: kind)) {
                    SettingsRowLabel(title(for: kind), systemImage: symbol(for: kind))
                }
                .accessibilityIdentifier(identifier(for: kind))
            }
            LabeledContent {
                Text(permission?.description ?? String(localized: "Checking…"))
                    .foregroundStyle(Theme.accentText)
            } label: {
                SettingsRowLabel("iOS notifications", systemImage: "bell.badge")
            }
            .accessibilityIdentifier("settings.notify.authorization")
        } header: {
            SettingsSectionHeader("Notifications")
        } footer: {
            // `String(localized:)` rather than a literal, and the whole sentence
            // in one piece: `Text` given a concatenation of literals resolves to
            // the `StringProtocol` overload, which is not localized -- and a
            // Chinese screen with an English paragraph in the middle of it is
            // exactly what that looks like.
            Text(
                String(
                    localized: "A notification whose kind is switched off is dropped when it arrives, whatever iOS is set to. The line above is the system permission: if it says notifications are off, no switch here can bring them back.",
                ),
            )
        }
    }

    /// The switch for one kind, written straight through to the stored value.
    ///
    /// Built by hand rather than projected with `@Bindable`, because a kind is an
    /// argument and not a property: there is no key path to a `Bool`. The write
    /// goes through `values`, whose `didSet` persists it and logs it, so a switch
    /// flipped here is on disk before the finger is off the screen.
    ///
    /// - Parameter kind: the notification kind.
    /// - Returns: a binding for its switch.
    private func binding(for kind: NotificationKind) -> Binding<Bool> {
        Binding(
            get: { model.settings.values.notifications.isEnabled(kind) },
            set: { enabled in
                model.settings.values.notifications.set(enabled, for: kind)
                if enabled {
                    Task {
                        await Permissions.requestNotifications()
                        await model.ensurePushRegistration()
                    }
                }
            },
        )
    }

    /// What one kind is called on screen.
    /// - Parameter kind: the notification kind.
    /// - Returns: its label.
    private func title(for kind: NotificationKind) -> LocalizedStringKey {
        switch kind {
        case .turnFinished: "Task complete"
        case .turnInterrupted: "Task interrupted"
        case .question: "Model question"
        case .approval: "Permission needed"
        }
    }

    /// The symbol for one kind.
    /// - Parameter kind: the notification kind.
    /// - Returns: an SF Symbol name.
    private func symbol(for kind: NotificationKind) -> String {
        switch kind {
        case .turnFinished: "checkmark.circle"
        case .turnInterrupted: "exclamationmark.triangle"
        case .question: "questionmark.bubble"
        case .approval: "hand.raised"
        }
    }

    /// The accessibility identifier for one kind's switch.
    ///
    /// Built from the kind's *wire* name rather than from its Swift case name, so
    /// the identifier is one derivation in one place: `settings.notify.turn-finished`,
    /// not `settings.notify.turnFinished`. A UI test asks for the hyphenated form,
    /// and asking for the other one finds nothing at all -- which is how this was
    /// learned.
    ///
    /// - Parameter kind: the notification kind.
    /// - Returns: the identifier a UI test looks for.
    private func identifier(for kind: NotificationKind) -> String {
        "settings.notify.\(kind.rawValue)"
    }

    // MARK: - 实时活动

    private var liveActivitySection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { model.settings.values.liveActivitiesEnabled },
                set: { model.settings.values.liveActivitiesEnabled = $0 },
            )) {
                SettingsRowLabel("Live Activity", systemImage: "bolt.horizontal.circle")
            }
            .accessibilityIdentifier("settings.liveActivity")
        } header: {
            SettingsSectionHeader("Live Activity")
        } footer: {
            Text(
                String(
                    localized: "Shows a running turn on the Lock Screen. Switching it off takes an activity that is up down with it and stops a new one from starting; it does not touch the conversation.",
                ),
            )
        }
    }

    // MARK: - 触感

    private var feelSection: some View {
        Section {
            Toggle(isOn: $hapticsEnabled) {
                SettingsRowLabel("Haptics", systemImage: "hand.tap")
            }
            .accessibilityIdentifier("settings.haptics")
        } header: {
            SettingsSectionHeader("Feel")
        } footer: {
            Text(String(localized: "A light tap when a turn you are watching finishes, when a request is answered, and when a message is sent."))
        }
    }
}
