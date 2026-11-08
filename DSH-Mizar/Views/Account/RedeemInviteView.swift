//
//  RedeemInviteView.swift
//  DSH-Mizar
//
//  An invite code turns into paid time.
//
//  One field and one button, reachable from Settings → About and from the
//  account screen. Signed out it explains what to do instead of grading the
//  field: redeeming is an authenticated route, so there is nothing useful a
//  signed-out tap can do but point at the sign-in form.
//

import MizarKit
import SwiftUI
import UIKit

struct RedeemInviteView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var code = ""
    @State private var result: String?
    @State private var succeeded = false
    @FocusState private var focused: Bool

    var body: some View {
        List {
            if model.account.isLoggedIn {
                inputSection
            } else {
                signedOutSection
            }
        }
        .navigationTitle("Redeem invite code")
        .navigationBarTitleDisplayMode(.inline)
        // A keystroke-level swipe puts the keyboard away instead of scrolling
        // the form under it. That matters after redeeming: the keyboard shifts
        // the whole popover up, and the back button goes off the top edge.
        .scrollDismissesKeyboard(.immediately)
        .accessibilityIdentifier("account.redeem.screen")
        .onAppear { focused = model.account.isLoggedIn }
    }

    // MARK: - Signed in

    private var inputSection: some View {
        Group {
            Section {
                TextField("Invite code", text: $code)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .focused($focused)
                    .submitLabel(.go)
                    .onSubmit { redeem() }
                    .accessibilityIdentifier("account.redeem.field")

                Button {
                    redeem()
                } label: {
                    HStack {
                        Spacer()
                        if model.account.working {
                            ProgressView().controlSize(.small)
                        }
                        Text("Redeem")
                            .fontWeight(.semibold)
                        Spacer()
                    }
                }
                .disabled(trimmedCode.isEmpty || model.account.working)
                .accessibilityIdentifier("account.redeem.submit")
            } footer: {
                Text("Enter the code exactly as you received it. Capital letters and dashes matter.")
            }

            if let result {
                Section {
                    Label(result, systemImage: succeeded ? "checkmark.seal" : "exclamationmark.triangle")
                        .foregroundStyle(succeeded ? Theme.accentText : Theme.failed)
                        .accessibilityIdentifier("account.redeem.result")
                }
            }

            if let user = model.account.user, user.isPaid, let paidUntil = user.paidUntil {
                Section {
                    LabeledContent {
                        Text(paidUntil.formatted(date: .abbreviated, time: .omitted))
                    } label: {
                        Label("Paid until", systemImage: "calendar")
                    }
                } footer: {
                    Text("Invite time adds to whatever you already have, so redeeming two codes in a row stacks them.")
                }
            }
        }
    }

    /// The code as typed, without the whitespace a keyboard adds.
    private var trimmedCode: String {
        code.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Submit the code.
    private func redeem() {
        guard !trimmedCode.isEmpty, !model.account.working else { return }
        focused = false
        Task {
            let wasPaid = model.account.isPaid
            let accepted = await model.account.redeem(code: trimmedCode)
            succeeded = accepted
            if accepted {
                let until = model.account.user?.paidUntil
                    .map { $0.formatted(date: .abbreviated, time: .omitted) } ?? ""
                result = until.isEmpty
                    ? String(localized: "The invite code was accepted.")
                    : String(format: String(localized: "The invite code was accepted. Paid until %@."), until)
                code = ""
                if !wasPaid {
                    // Nothing else on this screen changes; playing the success
                    // feedback is the whole confirmation.
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                }
            } else {
                result = model.account.lastError ?? String(localized: "That invite code was not accepted.")
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }

    // MARK: - Signed out

    private var signedOutSection: some View {
        Section {
            ContentUnavailableView {
                Label("Sign in first", systemImage: "person.crop.circle.badge.exclamationmark")
            } description: {
                Text("Invite codes are added to an account, so there has to be one to add this to.")
            }
            NavigationLink {
                AccountScreen()
            } label: {
                Label("Sign in or create an account", systemImage: "person.crop.circle")
            }
            .accessibilityIdentifier("account.redeem.signin")
        }
    }
}

#Preview {
    NavigationStack {
        RedeemInviteView().environment(AppModel())
    }
}
