//
//  WelcomeGateView.swift
//  DSH-Mizar
//
//  The screen before the app: who you are.
//
//  A hard gate, not a suggestion. Every byte this app moves crosses a relay the
//  project pays for, and an account is what makes those bytes attributable --
//  which is what lets abnormal traffic be recognised instead of the server
//  quietly disappearing one day. The copy says that plainly rather than dressing
//  a login wall as a feature.
//
//  It is also the screen an existing install lands on after updating: the gate
//  asks anybody who is not signed in, regardless of how long they have used the
//  app.
//

import MizarKit
import SwiftUI

struct WelcomeGateView: View {
    @Environment(AppModel.self) private var model
    /// Which form to present. Held as an item rather than a Bool plus a mode:
    /// setting both in one tap raced the sheet's first build, and the sheet
    /// opened on the login half every time.
    @State private var presentedMode: AccountScreen.Mode?

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Theme.navy, Theme.navyDeep],
                startPoint: .top,
                endPoint: .bottom,
            )
            .ignoresSafeArea()
            RadialGradient(
                colors: [Color.accentColor.opacity(0.24), .clear],
                center: .init(x: 0.5, y: 0.34),
                startRadius: 10,
                endRadius: 340,
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: 40)
                    MizarRing(motion: .once, size: 92, palette: .ink(.white))
                        .padding(.bottom, 30)

                    Text("Sign in to get started")
                        .font(.largeTitle.weight(.bold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)

                    Text(
                        String(
                            localized: "DSH-Mizar's conversations travel through a relay. Once you sign in, every byte belongs to an account, so abnormal traffic can be recognised and stopped — that is what keeps the free server running.",
                        ),
                    )
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.72))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 14)
                    .padding(.horizontal, 30)

                    Spacer(minLength: 34)

                    VStack(spacing: 12) {
                        Button {
                            presentedMode = .login
                        } label: {
                            Text("Sign in")
                                .font(.headline)
                                .foregroundStyle(Theme.onAccent)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.glassProminent)
                        .controlSize(.extraLarge)
                        .accessibilityIdentifier("welcome.gate.signIn")

                        Button {
                            presentedMode = .register
                        } label: {
                            Text("Create account")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.glass)
                        .controlSize(.extraLarge)
                        .accessibilityIdentifier("welcome.gate.register")

                        AppleSignInView { _ in }
                            .padding(.top, 2)
                            .accessibilityIdentifier("welcome.gate.apple")
                    }
                    .padding(.horizontal, 28)

                    Text("Signing in is only for the account and traffic safety; conversations never pass through the account server.")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.5))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 18)
                        .padding(.horizontal, 34)
                        .padding(.bottom, 24)
                }
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .environment(\.colorScheme, .dark)
        .accessibilityIdentifier("welcome.gate")
        .sheet(item: $presentedMode) { mode in
            NavigationStack {
                AccountScreen(onDone: { presentedMode = nil }, initialMode: mode)
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .interactiveDismissDisabled(!model.account.isLoggedIn)
        }
        .onChange(of: model.account.isLoggedIn) { _, signedIn in
            if signedIn { presentedMode = nil }
        }
    }
}
