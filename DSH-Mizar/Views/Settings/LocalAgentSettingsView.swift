//
//  LocalAgentSettingsView.swift
//  DSH-Mizar
//
//  The agent that runs on this phone: one page, and the promise that it stops
//  when the app does.
//
//  The promise is the footer rather than a switch, because there is no switch:
//  iOS suspends the process, and pretending otherwise on a settings screen would
//  be the one lie this app does not tell.
//

import MizarKit
import SwiftUI

struct LocalAgentSettingsView: View {
    @Environment(AppModel.self) private var model
    /// Closes the settings sheet this page was pushed in.
    var onDone: (() -> Void)?

    /// Bumped after the agent's data is cleared, so the tap has a haptic to play on.
    @State private var mizarSuccess = false
    /// Whether the "clear the on-device agent's data" confirmation is up.
    @State private var confirmingLocalClear = false
    /// What the on-device agent holds, measured when the page opens.
    ///
    /// Not computed per render: it walks a directory tree, and this page is
    /// redrawn whenever a switch above it moves.
    @State private var localAgentBytes: Int64?

    var body: some View {
        SettingsPage(title: "On-Device Agent (Experimental)", onDone: onDone) {
            List {
                Section {
                    NavigationLink {
                        LocalAgentModelsView(agent: model.localAgent) {
                            Task { await model.reloadCatalogs() }
                        }
                    } label: {
                        SettingsRowLabel("Model configuration", systemImage: "cpu")
                    }
                    .accessibilityIdentifier("settings.localAgent.models")

                    Button(role: .destructive) {
                        confirmingLocalClear = true
                    } label: {
                        HStack(spacing: 8) {
                            Label("Clear local sessions", systemImage: "trash")
                            Spacer(minLength: 4)
                            if let localAgentBytes {
                                Text(ByteCountFormatter.string(fromByteCount: localAgentBytes, countStyle: .file))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .accessibilityIdentifier("settings.localAgent.clear")
                } header: {
                    SettingsSectionHeader("On-Device Agent (Experimental)")
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("The on-device agent works only while this app is in the foreground. Leaving the app or locking the screen stops a running turn. It does not use the relay and does not consume account credits.")
                        Text("Its workspaces are folders in this app's Documents directory: open the Files app, choose On My iPhone, then DSH-Mizar.")
                    }
                }
            }
            .task {
                model.localAgent.refreshKeyPresence()
                localAgentBytes = model.localAgent.storedByteCount
            }
            .confirmationDialog(
                Text("Clear local sessions"),
                isPresented: $confirmingLocalClear,
                titleVisibility: .visible,
            ) {
                Button("Delete", role: .destructive) {
                    Task { await clearLocalData() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Sessions written by the on-device agent are kept on this phone. Clearing removes them; the workspace folders and the model configuration are kept.")
            }
        }
    }

    /// Clear the agent's sessions, keeping its configuration and the files.
    private func clearLocalData() async {
        if model.isLocalAgentMode {
            // Leaving the mode drops the connection this page was reading
            // through; opening the last computer instead of sitting on a page
            // with nothing behind it is the state the operator was in before
            // they picked the agent.
            await model.leaveLocalAgent()
            if let last = model.hosts.last { await model.open(hostId: last.hostId) }
        }
        try? model.localAgent.clearData()
        localAgentBytes = model.localAgent.storedByteCount
        model.localAgent.refreshKeyPresence()
        mizarSuccess.toggle()
    }
}
