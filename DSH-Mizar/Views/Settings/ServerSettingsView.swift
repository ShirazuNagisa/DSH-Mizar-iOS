//
//  ServerSettingsView.swift
//  DSH-Mizar
//
//  Which relay this phone talks to, and where a self-hosted one lives.
//
//  A switch is not an address change: the two servers have different features
//  (an account, a plan and push on the official one; none of them on a
//  self-hosted one), and a pairing's room exists on exactly one of them. So
//  this page says both things before the operator saves, and the model keeps
//  the account and the pairings while closing a connection that belonged to
//  the server being left.
//
//  Verification is the guide's check, not a second rule: the same
//  ``ServerProbe`` and the same PIN header. A self-hosted choice cannot be
//  saved until its own address has answered.
//

import MizarKit
import SwiftUI

struct ServerSettingsView: View {
    @Environment(AppModel.self) private var model
    /// Closes the settings sheet this page was pushed in.
    var onDone: (() -> Void)?

    @State private var mode: ServerMode = .official
    @State private var origin = ""
    @State private var pin = ""
    @State private var check: ServerCheck = .idle
    /// The origin and PIN the last successful check was made with. Together
    /// they are what "verified" means on this page; an edit that changes
    /// either stops it matching, with no change handler to keep in step.
    @State private var verifiedOrigin: String?
    @State private var verifiedPin = ""
    @State private var checkTask: Task<Void, Never>?
    /// What the last save said, until the page is left.
    @State private var notice: String?

    private enum ServerCheck: Equatable {
        case idle
        case checking
        case success
        case failure(String)
    }

    var body: some View {
        SettingsPage(title: "Server", onDone: onDone) {
            List {
                currentSection
                modeSection
                if mode == .selfHosted {
                    addressSection
                }
                saveSection
            }
        }
        .onAppear(perform: loadCurrentSelection)
    }

    // MARK: - Sections

    /// What the app is using right now, as opposed to what is being edited.
    private var currentSection: some View {
        Section {
            LabeledContent("Current server") {
                Text(verbatim: model.isSelfHosted
                    ? (model.selfHostedOrigin ?? String(localized: "Self-hosted server"))
                    : String(localized: "Official server"))
                    .foregroundStyle(Theme.accentText)
            }
            .accessibilityIdentifier("settings.server.current")

            if let notice {
                Text(verbatim: notice)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings.server.notice")
            }
        } header: {
            SettingsSectionHeader("Server")
        }
    }

    /// The official/self-hosted choice, and what it changes.
    private var modeSection: some View {
        Section {
            Picker("Server", selection: $mode) {
                Text("Official server").tag(ServerMode.official)
                Text("Self-hosted server").tag(ServerMode.selfHosted)
            }
            .pickerStyle(.inline)
            .accessibilityIdentifier("settings.server.mode")
        } header: {
            SettingsSectionHeader("Server type")
        } footer: {
            Text(
                String(
                    localized: "Switching keeps your account and your pairings, but changes what is available: an official account, its plan and background push exist only on the official server.",
                ),
            )
        }
    }

    /// The self-hosted address, its PIN, and the check that it answers.
    private var addressSection: some View {
        Section {
            TextField("relay.example.com", text: $origin)
                .textContentType(.URL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("settings.server.origin")

            SecureField("PIN (optional)", text: $pin)
                .textContentType(.password)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("settings.server.pin")

            Button {
                verify()
            } label: {
                HStack(spacing: 8) {
                    if check == .checking { ProgressView().controlSize(.small) }
                    Text(check == .checking ? "Verifying…" : "Verify connection")
                }
            }
            .disabled(origin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || check == .checking)
            .accessibilityIdentifier("settings.server.verify")

            checkStatus
        } header: {
            SettingsSectionHeader("Self-hosted server")
        } footer: {
            Text("A domain or host:port. https:// is added when it is missing. The PIN is only sent to this server's computer list.")
        }
    }

    /// The save button, and the sentence about re-pairing.
    private var saveSection: some View {
        Section {
            Button {
                save()
            } label: {
                Text("Save")
                    .frame(maxWidth: .infinity)
            }
            .disabled(!canSave)
            .accessibilityIdentifier("settings.server.save")
        } footer: {
            if requiresRepair {
                Text(
                    "The pairings on your phone belong to the server they were made through. After saving this switch, pair your computer again for the new server; the account and the old pairings are kept.",
                )
            }
        }
    }

    /// What the last check said.
    @ViewBuilder
    private var checkStatus: some View {
        HStack(alignment: .top, spacing: 8) {
            switch effectiveCheck {
            case .idle:
                Text("Not verified yet.")
                    .foregroundStyle(.secondary)
            case .checking:
                Text("Checking the server…")
                    .foregroundStyle(.secondary)
            case .success:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.accentText)
                Text("Connected to your relay.")
            case .failure(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(verbatim: message)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.footnote)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("settings.server.status")
    }

    // MARK: - State

    /// The check as it applies to the fields as they stand.
    ///
    /// A success from an earlier origin or PIN is not a statement about these;
    /// it is dropped here rather than through a change handler, so no edit can
    /// leave a stale "Connected" behind.
    private var effectiveCheck: ServerCheck {
        if verificationMatches { return .success }
        switch check {
        case .checking: return .checking
        case .failure: return check
        case .idle, .success: return .idle
        }
    }

    private var normalizedDraftOrigin: String? {
        ServerSelection(mode: .selfHosted, origin: origin).normalizedOrigin
    }

    private var verificationMatches: Bool {
        guard mode == .selfHosted,
              let normalized = normalizedDraftOrigin,
              let verifiedOrigin
        else { return false }
        return verifiedOrigin == normalized && verifiedPin == pin
    }

    private var canSave: Bool {
        guard mode == .selfHosted else { return true }
        return verificationMatches
    }

    /// Whether saving would move the phone to a server that cannot answer for
    /// the pairings it already has.
    private var requiresRepair: Bool {
        if mode != model.serverSelection.mode { return true }
        guard mode == .selfHosted else { return false }
        return normalizedDraftOrigin != model.serverSelection.normalizedOrigin
    }

    // MARK: - Actions

    private func loadCurrentSelection() {
        mode = model.serverSelection.mode
        origin = model.serverSelection.origin
        pin = model.serverSelection.pin
        notice = nil
        if model.serverSelection.isSelfHosted {
            verifiedOrigin = model.serverSelection.normalizedOrigin
            verifiedPin = model.serverSelection.pin
        }
    }

    private func verify() {
        checkTask?.cancel()
        check = .checking
        let origin = origin
        let pin = pin
        checkTask = Task {
            let result = await ServerProbe.check(origin: origin, pin: pin)
            guard !Task.isCancelled else { return }
            switch result {
            case .success:
                guard let normalized = ServerSelection(mode: .selfHosted, origin: origin).normalizedOrigin else {
                    check = .failure(String(localized: "Enter the server's address, for example relay.example.com."))
                    return
                }
                verifiedOrigin = normalized
                verifiedPin = pin
                check = .success
            case .failure(let error):
                verifiedOrigin = nil
                verifiedPin = ""
                check = .failure(Self.message(for: error))
            }
        }
    }

    private func save() {
        let selection: ServerSelection
        if mode == .official {
            selection = .official
        } else {
            guard let normalized = normalizedDraftOrigin else { return }
            selection = ServerSelection(mode: .selfHosted, origin: normalized, pin: pin)
        }
        guard model.updateServerSelection(selection) else {
            check = .failure(String(localized: "Enter the server's address, for example relay.example.com."))
            return
        }
        notice = model.serverChangeNotice ?? String(localized: "Saved.")
        model.clearServerChangeNotice()
        // Show what was actually stored: normalisation may have changed the
        // text, and a successful save is also a successful verification.
        mode = model.serverSelection.mode
        origin = model.serverSelection.origin
        pin = model.serverSelection.pin
        if model.serverSelection.isSelfHosted {
            verifiedOrigin = model.serverSelection.normalizedOrigin
            verifiedPin = model.serverSelection.pin
        }
    }

    /// The operator-readable sentence for a failed check.
    /// - Parameter error: the probe's answer.
    /// - Returns: a sentence that names what to fix.
    private static func message(for error: ServerProbeError) -> String {
        switch error {
        case .invalidOrigin:
            String(localized: "Enter the server's address, for example relay.example.com.")
        case .network:
            String(localized: "Could not reach the server. Check the address, the certificate and the port.")
        case .notRelay:
            String(localized: "That address answered, but it is not a DSH-Mizar relay.")
        case .protocolTooOld:
            String(localized: "That relay is too old for this app. Update it and try again.")
        case .pinRequired:
            String(localized: "This server needs its PIN.")
        case .pinInvalid:
            String(localized: "That PIN is not right.")
        case .rateLimited:
            String(localized: "Too many wrong PINs. Wait a few minutes and try again.")
        case .http(let code):
            String(format: String(localized: "The server answered HTTP %lld."), code)
        }
    }
}

#Preview {
    NavigationStack {
        ServerSettingsView().environment(AppModel())
    }
}
