//
//  TransferSettingsView.swift
//  DSH-Mizar
//
//  Which routes this phone may use.
//
//  These two are rules, not preferences: the model closes a link that is using a
//  route the moment its switch is turned off, and neither switch's route is
//  dialled or probed again until it is turned back on. The footers say so
//  plainly, because a switch that only changes the next reconnect is how "I
//  turned that off" became a bug report.
//

import MizarKit
import SwiftUI

struct TransferSettingsView: View {
    @Environment(AppModel.self) private var model
    /// Closes the settings sheet this page was pushed in.
    var onDone: (() -> Void)?

    var body: some View {
        SettingsPage(title: "Transfer", onDone: onDone) {
            List {
                Section {
                    Toggle(isOn: Binding(
                        get: { model.settings.values.localNetworkFirst },
                        set: { enabled in
                            model.settings.values.localNetworkFirst = enabled
                            if enabled { Task { await Permissions.requestLocalNetwork() } }
                        },
                    )) {
                        SettingsRowLabel("Local network first", systemImage: "wifi")
                    }
                    .accessibilityIdentifier("settings.transfer.lanPriority")

                    // Off by default, and the footer says what it costs rather
                    // than what it promises: a punch that fails adds seconds to
                    // a reconnect that would otherwise have been the relay
                    // straight away.
                    Toggle(isOn: Binding(
                        get: { model.settings.values.directConnection },
                        set: { model.settings.values.directConnection = $0 },
                    )) {
                        SettingsRowLabel(
                            "P2P direct connection (Experimental)",
                            systemImage: "point.topleft.down.to.point.bottomright.curvepath",
                        )
                    }
                    .accessibilityIdentifier("settings.transfer.directConnection")
                } header: {
                    SettingsSectionHeader("Transfer")
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(
                            String(
                                localized: "Off is a rule, not a preference: this phone does not use the computer's local address at all. An open local link is closed at once and reconnects use the relay, which also makes every reconnect faster.",
                            ),
                        )
                        Text(
                            String(
                                localized: "P2P direct connection asks this computer and your phone to reach each other without the relay, falling back to the relay when the two networks will not allow it. Off closes a punched link and never attempts another.",
                            ),
                        )
                    }
                }
            }
        }
    }
}
