//
//  AboutSettingsView.swift
//  DSH-Mizar
//
//  What this build is, where its community is, who wrote it, and -- behind the
//  same shelf -- the tools that only exist for testing.
//
//  The order is the order of the questions: where it comes from, what it is,
//  who made it. The developer section is the "and more" of 关于与更多: pairing
//  with a code is the old way in, kept for a developer machine, a relay that has
//  not been flipped to accounts, and a UI test.
//

import MizarKit
import SwiftUI
import UIKit

struct AboutSettingsView: View {
    @Environment(AppModel.self) private var model
    /// Closes the settings sheet this page was pushed in.
    var onDone: (() -> Void)?
    /// The system's browser opener, for the source link.
    @Environment(\.openURL) private var openURL

    @AppStorage(OnboardingKeys.done) private var onboardingDone = false
    @AppStorage(OnboardingKeys.started) private var onboardingStarted = false
    /// The pairing sheet, kept here as a developer tool while accounts replace it.
    @State private var showingPairing = false

    var body: some View {
        SettingsPage(title: "About & More", onDone: onDone) {
            List {
                aboutSection
                surveysSection
                creditsSection
                if AppModel.showsManualPairing {
                    developerSection
                }
            }
            .refreshable { await model.credits.refresh() }
            .task { await model.credits.start() }
        }
    }

    // MARK: - 关于

    private var aboutSection: some View {
        Section {
            Button {
                openSource()
            } label: {
                LabeledContent {
                    Image(systemName: "arrow.up.right")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } label: {
                    SettingsRowLabel("Source code", systemImage: "chevron.left.forwardslash.chevron.right")
                }
            }
            .accessibilityIdentifier("settings.about.source")

            Button {
                onboardingStarted = true
                onboardingDone = false
                onDone?()
            } label: {
                SettingsRowLabel("Replay welcome", systemImage: "sparkles")
            }
            .accessibilityIdentifier("settings.about.replayOnboarding")

            // 兑换邀请码 lives on the account screen, next to the plan it pays
            // for: an invite is an account thing, and About is about the build.
            LabeledContent {
                Text(AppModel.versionLine)
                    .monospacedDigit()
            } label: {
                SettingsRowLabel("Version", systemImage: "number")
            }
            .accessibilityIdentifier("settings.about.version")
        } header: {
            SettingsSectionHeader("About")
        }
    }

    // MARK: - 问卷

    /// The operator's questionnaires, one row in and one shelf further.
    ///
    /// It lives on this page because a questionnaire is about the product the
    /// way "about" is: the operator asks, the operator pays in paid days, and
    /// nothing about using the app changes while one is open.
    private var surveysSection: some View {
        Section {
            NavigationLink {
                SurveysView()
            } label: {
                SettingsRowLabel("Questionnaires", systemImage: "checklist")
            }
            .accessibilityIdentifier("settings.about.surveys")
        } header: {
            SettingsSectionHeader("Questionnaires")
        } footer: {
            Text("Fill one in and the reward it carries is added to your account. Each account can answer each questionnaire once.")
        }
    }

    // MARK: - 鸣谢

    /// The contributors, one row each, tappable to their GitHub profile.
    private var creditsSection: some View {
        Section {
            if model.credits.contributors.isEmpty {
                HStack(spacing: 10) {
                    if case .loading = model.credits.state {
                        ProgressView().controlSize(.small)
                    }
                    Text(creditsEmptyText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("settings.credits.empty")
                }
                .padding(.vertical, 4)
            } else {
                ForEach(model.credits.contributors) { contributor in
                    Link(destination: contributor.profileURL) {
                        ContributorRow(
                            contributor: contributor,
                            avatar: model.credits.avatar(for: contributor.login),
                        )
                    }
                    .accessibilityIdentifier("settings.credits.row.\(contributor.login)")
                }
            }
        } header: {
            SettingsSectionHeader("Credits")
        }
    }

    /// What an empty list says, by state.
    private var creditsEmptyText: String {
        switch model.credits.state {
        case .failed:
            // The technical detail is for the log, not for a settings row: it
            // is raw GitHub English and says nothing the operator can act on.
            String(localized: "The contributor list is unavailable right now.")
        case .loading: String(localized: "Loading contributors…")
        default: String(localized: "No contributors to show yet.")
        }
    }

    /// Open the project in the default browser.
    private func openSource() {
        // The system's own opener, so the operator's browser choice is honoured
        // and nothing here pretends to be a browser view.
        guard let url = URL(string: "https://github.com/ShirazuNagisa/DSH-Mizar") else { return }
        openURL(url)
    }

    // MARK: - 开发者

    /// The tools that only exist for testing or for a host without an account.
    ///
    /// Pairing is the old way in. Accounts replaced it for everyday use, but a
    /// developer machine, a relay that has not been flipped to accounts, and a
    /// UI test all still need the code path.
    private var developerSection: some View {
        Section {
            Button("Pair a computer") {
                showingPairing = true
            }
            .tint(Theme.accentText)
            .accessibilityIdentifier("settings.pair")
        } header: {
            SettingsSectionHeader("Developer")
        } footer: {
            Text("Pairing with a code is kept for development; sign in above to find your computers by account.")
        }
        .sheet(isPresented: $showingPairing) {
            PairingSheet()
        }
    }
}

/// One contributor: avatar, name, what they did, and the way to their profile.
struct ContributorRow: View {
    let contributor: Contributor
    let avatar: UIImage?

    /// Built as `Text`, not `String`: the row has to follow the environment's
    /// language (the snapshot suite renders both), while `String(localized:)`
    /// follows the process locale and returned Chinese inside an English view.
    private var detailText: Text {
        var parts: [Text] = []
        if contributor.commits > 0 {
            parts.append(
                contributor.commits == 1
                    ? Text("1 commit")
                    : Text("\(contributor.commits) commits"),
            )
        }
        if contributor.coAuthored > 0 {
            parts.append(
                contributor.coAuthored == 1
                    ? Text("1 co-authored")
                    : Text("\(contributor.coAuthored) co-authored"),
            )
        }
        guard let first = parts.first else { return Text("Contributor") }
        return parts.dropFirst().reduce(first) { $0 + Text(" · ") + $1 }
    }

    var body: some View {
        HStack(spacing: 12) {
            avatarView
                .frame(width: 32, height: 32)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(contributor.name ?? contributor.login)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                (contributor.name == nil
                    ? detailText
                    : Text(verbatim: "@\(contributor.login) · ") + detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: "arrow.up.right")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var avatarView: some View {
        if let avatar {
            Image(uiImage: avatar).resizable().scaledToFill()
        } else {
            ZStack {
                Circle().fill(.fill.tertiary)
                Image(systemName: "person.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
