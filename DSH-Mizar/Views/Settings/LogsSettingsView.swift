//
//  LogsSettingsView.swift
//  DSH-Mizar
//
//  What to send when something is wrong.
//
//  The export is a zip with this build and phone, the settings, every request to
//  the computer and how it ended, the connection attempts, the sync progress and
//  the recent host events. Device tokens and pairing codes are removed before the
//  file is written, and conversations are not in it. The row that names the file
//  stays on screen after the share sheet goes away, because "did that work" is a
//  question with an answer, and the answer is not "tap it again".
//

import MizarKit
import SwiftUI

struct LogsSettingsView: View {
    @Environment(AppModel.self) private var model
    /// Closes the settings sheet this page was pushed in.
    var onDone: (() -> Void)?

    /// The archive currently being offered to the share sheet.
    @State private var sharing: LogArchive?
    /// Whether an export is in flight, so the button can say so.
    @State private var exporting = false

    var body: some View {
        SettingsPage(title: "Logs", onDone: onDone) {
            List {
                Section {
                    Button {
                        Task { await export() }
                    } label: {
                        SettingsRowLabel("Export logs", systemImage: "square.and.arrow.up")
                    }
                    .disabled(exporting)
                    .accessibilityIdentifier("settings.logs.export")

                    if exporting {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Packing the log…")
                        }
                        .accessibilityIdentifier("settings.logs.exporting")
                    }

                    if let archive = model.lastLogExport {
                        // The file's name and size, kept on screen after the
                        // share sheet goes away.
                        LabeledContent {
                            Text(archive.readableSize)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(archive.fileName)
                                    .font(.footnote.monospaced())
                                Text("Last export, \(archive.fileCount) files, \(archive.recordCount) entries")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityIdentifier("settings.logs.lastArchive")
                    } else if model.log.count > 0 {
                        // Before the first export, what there is to export.
                        // After one, the file itself is the more useful row.
                        LabeledContent {
                            Text("\(model.log.count)")
                                .monospacedDigit()
                        } label: {
                            SettingsRowLabel("Entries recorded", systemImage: "text.alignleft")
                        }
                        .accessibilityIdentifier("settings.logs.count")
                    }
                } header: {
                    SettingsSectionHeader("Logs")
                } footer: {
                    Text(
                        String(
                            localized: "A zip with this build and phone, the settings above, every request to the computer and how it ended, the connection attempts, the sync progress and the recent host events. Device tokens and pairing codes are removed before the file is written, and conversations are not in it.",
                        ),
                    )
                }
            }
            .sheet(item: $sharing) { archive in
                ShareSheet(items: [archive.url])
            }
        }
    }

    /// Build the archive and offer it to the share sheet.
    private func export() async {
        exporting = true
        // The flag is cleared on every path: an export that failed and left the
        // button disabled would be a page with no way to try again.
        defer { exporting = false }
        sharing = await model.exportLogs()
    }
}
