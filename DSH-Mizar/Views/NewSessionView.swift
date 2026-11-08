//
//  NewSessionView.swift
//  DSH-Mizar
//
//  Choosing where to work.
//
//  The list is the host's **workspaces**, not the directories its sessions have
//  used. Those are different lists, and the difference is the whole report this
//  file answers: deleting a workspace removes the host's registry entry and
//  leaves the session log on disk, so a picker built out of working directories
//  kept offering every workspace the operator had ever deleted — "手机app中有许多
//  电脑端dsh已经删除的工作区".
//
//  A text field is kept alongside it for anywhere new: a picker that cannot
//  reach a path is worse than no picker at all.
//

import SwiftUI

struct NewSessionView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var path = ""
    @State private var creating = false

    var body: some View {
        NavigationStack {
            Form {
                if !model.workspaceChoices.isEmpty {
                    // "Workspaces", not "Recent": these are DSH's workspaces, not
                    // a recency-ordered history of anything, and a heading that
                    // says otherwise makes the operator wonder what happened to
                    // the ones they deleted.
                    Section("Workspaces") {
                        ForEach(model.workspaceChoices) { workspace in
                            Button {
                                Task { await create(workspace.path) }
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(workspace.title)
                                        .foregroundStyle(.primary)
                                    Text(workspace.path)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.head)
                                }
                            }
                            // On the row, not on a container: an identifier on a
                            // container does not reach the accessibility tree,
                            // so a test looking for it would report the screen
                            // as empty while it is full.
                            .accessibilityIdentifier("workspace.choice.\(workspace.path)")
                        }
                    }
                }

                // The on-device agent manages its own sandbox: `session.create`
                // answers REMOTE_ERROR for any `cwd` but its workspace root, so
                // the free-form field would be a field that cannot be used. The
                // kernel's own workspace is the row above.
                if !model.isLocalAgentMode {
                    Section("Anywhere else") {
                        TextField("/Users/you/projects/thing", text: $path)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.body.monospaced())
                    }

                    Section {
                        Button("Start session") {
                            Task { await create(path.trimmingCharacters(in: .whitespacesAndNewlines)) }
                        }
                        .tint(Theme.accentText)
                        .disabled(path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || creating)
                    } footer: {
                        Text("The host opens this directory and starts a session in it.")
                    }
                }
            }
            .navigationTitle("New session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .disabled(creating)
        }
    }

    private func create(_ cwd: String) async {
        guard !cwd.isEmpty else { return }
        creating = true
        _ = await model.createSession(cwd: cwd)
        creating = false
        dismiss()
    }
}
