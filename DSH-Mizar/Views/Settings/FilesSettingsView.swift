//
//  FilesSettingsView.swift
//  DSH-Mizar
//
//  What this phone keeps, and the two ways to get the space and the staleness
//  back.
//
//  Two different kinds of stored data live behind this one shelf, and they are
//  kept apart on purpose. The file cache is a copy: nothing in the app depends
//  on it, every file can be read from the computer again, so clearing it needs
//  no confirmation. The session data is the list of conversations and the pages
//  behind them: also recoverable, but it is what the screen is made of, so it
//  gets a sentence saying what will happen and a tap that says yes.
//
//  A cache the operator cannot see is a cache they cannot trust: the numbers are
//  here so "why is the app 300 MB" has an answer on the screen, and the buttons
//  are here because the answer to that question should be one tap away.
//

import MizarKit
import SwiftUI

struct FilesSettingsView: View {
    @Environment(AppModel.self) private var model
    /// Closes the settings sheet this page was pushed in.
    var onDone: (() -> Void)?
    /// The preview cache. Optional because the snapshot suite renders settings
    /// views without the shell's environment around them.
    @Environment(PreviewCenter.self) private var preview: PreviewCenter?

    /// Bumped after the cache is cleared, so the tap has a haptic to play on.
    @State private var mizarSuccess = false
    /// Whether the "delete everything on this phone and read it again"
    /// confirmation is up.
    @State private var confirmingSessionReload = false
    /// Whether that reload is running.
    @State private var reloadingSessions = false
    /// What the last reload brought back, kept on screen so "did that work" has
    /// an answer other than "do it again and watch".
    @State private var sessionReload: AppModel.MetadataReload?

    var body: some View {
        SettingsPage(title: "Files & Cache", onDone: onDone) {
            List {
                filesSection
                sessionDataSection
            }
            .task { await preview?.refreshCacheUsage() }
        }
    }

    // MARK: - 文件

    private var filesSection: some View {
        Section {
            LabeledContent {
                Text(cacheSummary)
                    .monospacedDigit()
                    .accessibilityIdentifier("settings.files.size")
            } label: {
                SettingsRowLabel("Previewed files", systemImage: "doc.text.magnifyingglass")
            }

            Button(role: .destructive) {
                Task {
                    await preview?.clearCache()
                    mizarSuccess = true
                }
            } label: {
                Label("Clear file cache", systemImage: "trash")
            }
            .disabled((preview?.cacheFiles ?? 0) == 0)
            .accessibilityIdentifier("settings.files.clear")
            .mizarFeedback(.success, trigger: mizarSuccess)
        } header: {
            SettingsSectionHeader("Files")
        } footer: {
            Text(
                String(
                    localized: "Files the model delivered are kept on this phone so a second look does not send them again. Clearing them frees the space; the next preview reads the file from the computer.",
                ),
            )
        }
    }

    /// What the cache holds, as one line.
    private var cacheSummary: String {
        let files = preview?.cacheFiles ?? 0
        guard files > 0 else { return String(localized: "Empty") }
        let bytes = preview?.cacheBytes ?? 0
        return String(format: String(localized: "%lld files · %@"), files, Self.size(bytes))
    }

    /// A byte count, the way the log export says it.
    ///
    /// - Parameter bytes: how many bytes.
    /// - Returns: a short human figure.
    static func size(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    // MARK: - 会话数据

    /// Throw the phone's stored sessions away and read them from the computer
    /// again.
    ///
    /// This is the button the guide's refresh step does by itself, made
    /// available afterwards: an operator whose list or conversation pages have
    /// drifted from what the computer says should not have to walk the guide
    /// again to make the phone agree with it.
    private var sessionDataSection: some View {
        Section {
            Button(role: .destructive) {
                confirmingSessionReload = true
            } label: {
                HStack(spacing: 8) {
                    Label("Reload all local session data", systemImage: "arrow.triangle.2.circlepath")
                    Spacer(minLength: 4)
                    if reloadingSessions {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .disabled(reloadingSessions)
            .accessibilityIdentifier("settings.sessions.reload")

            if reloadingSessions {
                Text("Loading your sessions…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings.sessions.loading")
            } else if let sessionReload {
                // A read that did not reach the computer is reported as such
                // rather than as an empty list: the sessions were deleted
                // first, and saying "0 sessions" would be a lie about the
                // desktop rather than the truth about the network.
                Text(sessionReload.reached
                    ? String(format: String(localized: "%lld sessions loaded"), sessionReload.sessions)
                    : String(localized: "Your computer did not answer."))
                    .font(.footnote)
                    .foregroundStyle(sessionReload.reached ? Color.secondary : Theme.failed)
                    .accessibilityIdentifier("settings.sessions.status")
            }
        } header: {
            SettingsSectionHeader("Session data")
        } footer: {
            Text(
                String(
                    localized: "Deletes the conversations, the session list and the workspaces this phone kept, then reads them from your computer again. Nothing on the computer changes.",
                ),
            )
        }
        .confirmationDialog(
            Text("Reload all local session data"),
            isPresented: $confirmingSessionReload,
            titleVisibility: .visible,
        ) {
            Button("Reload", role: .destructive) {
                Task { await reloadSessions() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Everything this phone kept about your sessions is deleted first, then read again from your computer. Your account and your settings are kept.")
        }
    }

    /// Empty the two stores and read the list again.
    private func reloadSessions() async {
        reloadingSessions = true
        defer { reloadingSessions = false }
        sessionReload = await model.clearSessionDataAndReload()
    }
}
