//
//  SendingSettingsView.swift
//  DSH-Mizar
//
//  What happens to a message sent while the agent is still working.
//
//  The two behaviours are one switch because they are one decision: hand it to
//  the running turn as guidance now, or keep it on the phone until the turn
//  ends. A toggle rather than a picker -- there are two answers, and the footer
//  says what each one does in plain words, which a picker would only hide one
//  level down. The composer and the held-prompt bar read the same value
//  (``MizarSettings/guidedSendByDefault``), which is what makes this a setting
//  and not a picture of one.
//

import MizarKit
import SwiftUI

struct SendingSettingsView: View {
    @Environment(AppModel.self) private var model
    /// Closes the settings sheet this page was pushed in.
    var onDone: (() -> Void)?

    var body: some View {
        SettingsPage(title: "Sending Preferences", onDone: onDone) {
            List {
                Section {
                    Toggle(isOn: Binding(
                        get: { model.settings.values.guidedSendByDefault },
                        set: { model.settings.values.guidedSendByDefault = $0 },
                    )) {
                        SettingsRowLabel("Default to guided send", systemImage: "paperplane")
                    }
                    .accessibilityIdentifier("settings.send.guidedSend")
                } header: {
                    SettingsSectionHeader("Sending")
                } footer: {
                    Text(
                        String(
                            localized: "On, a message sent while a turn is running is handed to the model immediately as guidance, without interrupting it. Off, it waits in a bar above the field and is sent when the turn ends; the bar can also send it as guidance now, put it back in the field, or throw it away.",
                        ),
                    )
                }
            }
        }
    }
}
