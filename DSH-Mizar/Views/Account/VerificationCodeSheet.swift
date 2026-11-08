//
//  VerificationCodeSheet.swift
//  DSH-Mizar
//
//  The six digits between "create account" and "account".
//
//  The server creates nothing until this sheet's code is accepted, so cancelling
//  here leaves no half-account and no password at rest -- which is why the
//  username and password are kept by the caller and only sent again with the
//  code.
//
//  The field submits itself at six digits: a code is fixed-length and there is
//  nothing to review, so an extra "submit" tap is a tap that only exists to make
//  the flow feel longer.
//

import MizarKit
import SwiftUI

struct VerificationCodeSheet: View {
    /// What the code is for.
    enum Purpose {
        case register
        case reset

        var title: LocalizedStringKey {
            switch self {
            case .register: "Enter the code"
            case .reset: "Reset your password"
            }
        }

        var action: LocalizedStringKey {
            switch self {
            case .register: "Verify and create account"
            case .reset: "Verify and set password"
            }
        }
    }

    let purpose: Purpose
    let email: String
    let initialResendAfter: Int
    /// Send the code; returns an error sentence, or `nil` when it was accepted.
    let submit: (String) async -> String?
    /// Ask for another code; returns the new challenge, or `nil` on failure.
    let resend: () async -> RegistrationChallenge?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var code = ""
    @State private var error: String?
    @State private var working = false
    @State private var secondsLeft = 0
    @FocusState private var focused: Bool

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(purpose.title)
                        .font(.title3.weight(.semibold))
                    Text(String(format: String(localized: "We sent a 6-digit code to %@. It expires in 10 minutes."), email))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("verify.email")
                }

                TextField("6-digit code", text: $code)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .font(.system(size: 30, weight: .semibold, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .tracking(8)
                    .focused($focused)
                    .padding(.vertical, 14)
                    .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
                    .accessibilityIdentifier("verify.code")
                    .onChange(of: code) { _, new in
                        let digits = new.filter(\.isNumber).prefix(6)
                        if String(digits) != new { code = String(digits) }
                        if code.count == 6, !working {
                            Task { await send() }
                        }
                    }

                if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(Theme.failed)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("verify.error")
                }

                Button {
                    Task { await send() }
                } label: {
                    ZStack {
                        Text(purpose.action).opacity(working ? 0 : 1)
                        if working { ProgressView().controlSize(.small) }
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(Theme.onAccent)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(code.count != 6 || working)
                .accessibilityIdentifier("verify.submit")

                Button {
                    Task { await resendCode() }
                } label: {
                    Text(secondsLeft > 0
                        ? String(format: String(localized: "Resend in %lld s"), secondsLeft)
                        : String(localized: "Resend code"))
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .disabled(secondsLeft > 0 || working)
                .accessibilityIdentifier("verify.resend")

                Spacer(minLength: 0)
            }
            .padding(22)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("verify.cancel")
                }
            }
        }
        .presentationDetents([.height(430)])
        .presentationDragIndicator(.visible)
        .onAppear {
            secondsLeft = initialResendAfter
            focused = true
        }
        .onReceive(ticker) { _ in
            if secondsLeft > 0 { secondsLeft -= 1 }
        }
    }

    private func send() async {
        guard code.count == 6, !working else { return }
        working = true
        error = nil
        defer { working = false }
        if let failure = await submit(code) {
            error = failure
            code = ""
            focused = true
        } else {
            dismiss()
        }
    }

    private func resendCode() async {
        guard !working else { return }
        working = true
        error = nil
        defer { working = false }
        if let challenge = await resend() {
            secondsLeft = challenge.resendAfterSeconds
            code = ""
            focused = true
        } else {
            error = String(localized: "The code could not be sent. Try again shortly.")
        }
    }
}
