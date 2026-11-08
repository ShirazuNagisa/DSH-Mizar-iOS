//
//  PasswordResetSheet.swift
//  DSH-Mizar
//
//  Getting back into an account without the old password.
//
//  Two steps in one sheet: the address and the new password, then the code the
//  server mails. The reset also signs this device in, so a forgotten password no
//  longer strands somebody at the login gate.
//

import MizarKit
import SwiftUI

struct PasswordResetSheet: View {
    private enum Step {
        case request
        case verify
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var password = ""
    @State private var code = ""
    @State private var step: Step = .request
    @State private var error: String?
    @State private var working = false
    @State private var secondsLeft = 0
    @FocusState private var focused: Bool

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text(step == .request ? "Reset your password" : "Enter the code")
                    .font(.title3.weight(.semibold))

                if step == .request {
                    Text("We will email a 6-digit code to the address on your account.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    TextField("Email", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focused)
                        .padding(.horizontal, 14)
                        .frame(height: 46)
                        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
                        .accessibilityIdentifier("reset.email")

                    SecureField("New password", text: $password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(.horizontal, 14)
                        .frame(height: 46)
                        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
                        .accessibilityIdentifier("reset.password")

                    Button {
                        Task { await requestCode() }
                    } label: {
                        ZStack {
                            Text("Send code").opacity(working ? 0 : 1)
                            if working { ProgressView().controlSize(.small) }
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .foregroundStyle(Theme.onAccent)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .disabled(working || email.isEmpty || password.count < 8)
                    .accessibilityIdentifier("reset.send")
                } else {
                    Text(String(format: String(localized: "We sent a 6-digit code to %@. It expires in 10 minutes."), email))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    TextField("6-digit code", text: $code)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .font(.system(size: 30, weight: .semibold, design: .monospaced))
                        .multilineTextAlignment(.center)
                        .tracking(8)
                        .focused($focused)
                        .padding(.vertical, 14)
                        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
                        .accessibilityIdentifier("reset.code")
                        .onChange(of: code) { _, new in
                            let digits = new.filter(\.isNumber).prefix(6)
                            if String(digits) != new { code = String(digits) }
                        }

                    Button {
                        Task { await complete() }
                    } label: {
                        ZStack {
                            Text("Verify and set password").opacity(working ? 0 : 1)
                            if working { ProgressView().controlSize(.small) }
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .foregroundStyle(Theme.onAccent)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .disabled(working || code.count != 6)
                    .accessibilityIdentifier("reset.submit")

                    Button {
                        Task { await requestCode() }
                    } label: {
                        Text(secondsLeft > 0
                            ? String(format: String(localized: "Resend in %lld s"), secondsLeft)
                            : String(localized: "Resend code"))
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .disabled(secondsLeft > 0 || working)
                    .accessibilityIdentifier("reset.resend")
                }

                if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(Theme.failed)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("reset.error")
                }

                Spacer(minLength: 0)
            }
            .padding(22)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("reset.cancel")
                }
            }
        }
        .presentationDetents([.height(460)])
        .presentationDragIndicator(.visible)
        .onAppear { focused = true }
        .onReceive(ticker) { _ in
            if secondsLeft > 0 { secondsLeft -= 1 }
        }
    }

    private func requestCode() async {
        guard !working else { return }
        working = true
        error = nil
        defer { working = false }
        guard let challenge = await model.account.beginPasswordReset(email: email) else {
            error = model.account.lastError
            return
        }
        code = ""
        step = .verify
        secondsLeft = challenge.resendAfterSeconds
        focused = true
    }

    private func complete() async {
        guard !working else { return }
        working = true
        error = nil
        defer { working = false }
        let changed = await model.account.completePasswordReset(
            email: email,
            code: code,
            password: password,
        )
        if changed {
            dismiss()
        } else {
            error = model.account.lastError
        }
    }
}
