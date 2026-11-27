//
//  Pickers.swift
//  DSH-Mizar
//
//  Changing the permission preset.
//
//  The preset is shown as the current value rather than as a menu, because the
//  question an operator actually has is "what is it on now", and that should not
//  require opening anything.
//

import SwiftUI
import MizarKit

// MARK: - What a preset is called

extension PermissionOption {
    /// The preset's name, in the operator's language.
    ///
    /// The host names its presets after their wire values -- `read-only`,
    /// `workspace-write`, `danger-full-access`, `auto` -- which are identifiers,
    /// not words, and they reached the screen as they were. The four DSH ships
    /// with are translated here by value; a preset a later host invents falls
    /// back to whatever that host called it, which is the only name anybody has
    /// for it.
    var title: String {
        Self.title(for: value) ?? name
    }

    /// What the preset allows, in one line.
    ///
    /// The host's own sentence when this app has never heard of the preset, and
    /// nothing at all when the host sent none.
    var detail: String? {
        Self.detail(for: value) ?? description
    }

    /// The name for a preset value, or `nil` for one this app does not know.
    ///
    /// - Parameter value: the preset id, as the host sends it.
    /// - Returns: the name to show, or `nil`.
    static func title(for value: String) -> String? {
        switch value {
        case "read-only": String(localized: "Read only")
        case "workspace-write": String(localized: "Workspace write")
        case "danger-full-access": String(localized: "Full access")
        case "auto": String(localized: "Auto approve")
        default: nil
        }
    }

    /// The description for a preset value, or `nil` for one this app does not
    /// know.
    ///
    /// - Parameter value: the preset id, as the host sends it.
    /// - Returns: the sentence to show under the name, or `nil`.
    static func detail(for value: String) -> String? {
        switch value {
        case "read-only":
            String(localized: "Can look at the workspace, but cannot change it.")
        case "workspace-write":
            String(localized: "Can change files inside the workspace.")
        case "danger-full-access":
            String(localized: "Can run commands and change files anywhere on this computer.")
        case "auto":
            String(localized: "Reviews and approves its own steps, and asks only when a decision needs you.")
        default:
            nil
        }
    }
}

/// Permission presets.
struct PermissionPickerView: View {
    let sessionId: String
    /// The preset the screen behind last saw, when it knows one.
    ///
    /// An input to the resolved value below, not the value itself: the host is
    /// still the authority, and after a switch it has accepted the app's own
    /// record is newer than the stats frame this screen was given.
    var current: String?
    /// Called once the host has taken a switch, before the window closes.
    ///
    /// The toolbar behind is drawn from a stats frame read before the switch;
    /// the screen re-reads its cached copy from here, so the shield is already
    /// right when this window is gone rather than after a full reload.
    var onApplied: () async -> Void = {}

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// The dangerous preset being confirmed, inside this window.
    @State private var confirming: PermissionOption?
    /// Why the last switch did not change anything, when it did not.
    ///
    /// The window stays open on a refusal, and that is only useful if something
    /// says why: the tick has not moved, so without this sentence a tap the host
    /// refused is indistinguishable from a tap that was never heard.
    @State private var failure: String?
    /// The preset whose switch is on its way, while the host has not answered.
    ///
    /// Drawn as a spinner beside the row and never as a tick: a tick means "this
    /// is in force", and a tick drawn for a request that had not been accepted
    /// was the bug this picker is being fixed for.
    @State private var applying: String?
    @Namespace private var tick

    /// The preset in force, as the app and the host agree on it.
    ///
    /// `AppModel` decides which answer wins -- its own record of a switch the
    /// host accepted, or the last stats frame -- so this window and the toolbar
    /// behind it cannot disagree about what the session may do.
    private var inForce: String? {
        model.permissionPreset(for: sessionId, reported: current)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PopoverHeader(title: "Permissions", systemImage: "lock.shield")
            if let catalog = model.permissionCatalog {
                if let inForce, let option = catalog.options.first(where: { $0.value == inForce }) {
                    // What is in force, in words as well as ticked below. The
                    // tick alone is a poor answer to "what is it on now" when
                    // the row carrying it can be a page down -- and this line is
                    // the only one here that can say a refused switch was
                    // refused, because it is drawn from what the app and the
                    // host have agreed on, never from what was last tapped.
                    VStack(alignment: .leading, spacing: 1) {
                        Text("In force")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .textCase(.uppercase)
                        Text(option.title)
                            .font(.subheadline.weight(.medium))
                            .accessibilityIdentifier("permission.current.\(inForce)")
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                VStack(spacing: 4) {
                    ForEach(catalog.options) { option in
                        VStack(spacing: 0) {
                            Button {
                                // One switch at a time: a second tap while the
                                // host has not answered the first would be two
                                // writes the screen could not keep in order.
                                guard applying == nil else { return }
                                if option.isDangerous {
                                    withMizarAnimation(.mizarSmooth) {
                                        confirming = confirming == option ? nil : option
                                    }
                                } else {
                                    Task { await apply(option) }
                                }
                            } label: {
                                optionRow(option)
                            }
                            .buttonStyle(.pressable(scale: 0.98))
                            .accessibilityIdentifier("permission.row.\(option.value)")

                            // A preset that grants unrestricted access to the
                            // machine is never one tap away: the second tap
                            // folds out under the row that asked for it, rather
                            // than an alert in the middle of the screen.
                            if confirming == option {
                                confirmation(for: option)
                                    .transition(.rise(distance: -8, blur: 4))
                            }
                        }
                        .background {
                            RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                                .fill(confirming == option ? Theme.waiting.opacity(0.1) : .clear)
                        }
                    }
                }
                .padding(.horizontal, 8)
                if let failure {
                    // Here, under the rows, and not only in the session list's
                    // banner: the banner is on the screen behind this window.
                    // A refusal reported only there was a message the operator
                    // could not read until they had already given up on this
                    // window and gone back.
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.waiting)
                        Text(failure)
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("permission.error")
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.rise)
                }
                Text("Applies to this session immediately. A running turn is not interrupted.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 18)
                    .padding(.top, 10)
                    .padding(.bottom, 16)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(30)
                    .task { await model.loadCatalogs() }
            }
        }
        .frame(width: 330)
        .task { await model.loadCatalogs() }
    }

    private func confirmation(for option: PermissionOption) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Allow full access?")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.waiting)
            Text("The agent will run commands and change files anywhere on this computer without asking.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button {
                    withMizarAnimation(.mizarSmooth) { confirming = nil }
                } label: {
                    Text("Cancel").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                Button(role: .destructive) {
                    Task { await apply(option) }
                } label: {
                    Text("Allow")
                        .frame(maxWidth: .infinity)
                        .foregroundStyle(Theme.onAccent)
                }
                .buttonStyle(.glassProminent)
                .tint(Theme.waiting)
                .accessibilityIdentifier("permission.confirm")
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    private func optionRow(_ option: PermissionOption) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    // The name in the operator's language, not the host's
                    // identifier for it. See ``PermissionOption/title``.
                    Text(option.title)
                        .font(.body.weight(option.value == inForce ? .semibold : .regular))
                    if option.isDangerous {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.waiting)
                            .font(.caption)
                    }
                }
                if let description = option.detail {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
            }
            Spacer()
            // The one in force, ticked -- and the tick slides to a new choice
            // once the host has taken it. While the switch is in flight the row
            // says so with a spinner instead: the two states must never look
            // alike, because the whole report was that they did.
            if applying == option.value {
                ProgressView()
                    .controlSize(.mini)
                    .transition(.pop)
            } else if option.value == inForce {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.accentText)
                    .matchedGeometryEffect(id: "tick", in: tick)
                    .transition(.pop)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(.rect)
    }

    /// Send a choice, and close only once the host has taken it.
    ///
    /// The window used to close whatever the answer was, with the choice already
    /// drawn as applied. The selection was written down before the call and the
    /// call's failure was swallowed, so a refused switch left the old preset in
    /// force on the computer while the phone showed the new one as ticked --
    /// worse than no picker at all, because it was the only answer the screen
    /// had. The tick now comes from what the app and the host have agreed on,
    /// and a refusal keeps the window open with a sentence saying so.
    ///
    /// - Parameter option: the preset that was tapped.
    private func apply(_ option: PermissionOption) async {
        guard applying == nil else { return }
        withMizarAnimation(.mizarSnappy) {
            confirming = nil
            failure = nil
            applying = option.value
        }
        let result = await model.setPermission(option.value, sessionId: sessionId)
        applying = nil
        // A request that never came back and a host that answered "refused" are
        // the same fact here: nothing changed. Both keep the window where it is
        // so the sentence below can be read.
        guard let result, result.commandResult.succeeded else {
            // The host's own sentence when it gave one, because a refusal that
            // can explain itself should; otherwise the one sentence this screen
            // owns. Not `model.problem`: that is the last thing that went wrong
            // anywhere, and a switch can fail while an older message is still
            // there to be read.
            let hostSaid = result?.commandResult.text?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            withMizarAnimation(.mizarSmooth) {
                failure = !hostSaid.isEmpty
                    ? hostSaid
                    : String(localized: "The permission did not change. Try again.")
            }
            return
        }
        // The screen behind re-reads its figures before this window goes, so the
        // shield it shows is drawn from the accepted switch rather than from the
        // frame before it.
        await onApplied()
        // The old short beat, kept: the tick landing is the confirmation, and
        // closing on the same frame as the answer gives the eye nothing to read.
        try? await Task.sleep(for: .milliseconds(260))
        dismiss()
    }
}
