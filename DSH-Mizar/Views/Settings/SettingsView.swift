//
//  SettingsView.swift
//  DSH-Mizar
//
//  The settings sheet: a directory of shelves, one page behind each of them.
//
//  The screen is split in two on purpose. The account row stays on the front
//  page, because "who is signed in, and what plan is that" is the first thing
//  somebody looks for in settings and it is not a preference -- it is a fact
//  about the person, and it has to be reachable without knowing which shelf it
//  would be filed under. Everything else is a shelf: a title, a symbol, one
//  line about what is inside, and a page behind it.
//
//  The order of the shelves is the order somebody needs them: what this phone
//  will tell you, how a message you send while the agent works is handled, how
//  the message travels, what runs on this phone, what it keeps, where its
//  community is, what to send when something is wrong, and what it is. Each
//  shelf keeps the sections it always had, unchanged, on its own page
//  (``SettingsTopic``); this file only draws the front page.
//
//  Native throughout -- `List`, `Section`, `NavigationLink`, the system's own
//  disclosure -- because every one of these has an accessibility shape the
//  operator already knows and a look that follows the OS forward. Nothing is
//  imitated, and no row is drawn by hand.
//

import MizarKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    /// Closes the sheet this screen is presented in.
    var onDone: (() -> Void)?
    /// Changes on every sheet presentation; the header's icon uses it as its
    /// identity so one load starts when the sheet opens, not when its view was
    /// first built.
    var animationToken: Int = 0
    /// The shelf to push as the sheet opens, when something outside asked for
    /// one (the announcement banner's button, today).
    var initialTopic: SettingsTopic?
    /// What is pushed above the directory. Empty is the front page.
    @State private var path: [SettingsTopic] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                header
                accountSection
                topicsSection
            }
            .navigationDestination(for: SettingsTopic.self) { topic in
                topic.page(onDone: onDone)
            }
            .navigationTitle("")
            // A small window keeps its title small.
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                // An entry that named a page lands on it; the gear names none
                // and lands on the directory, as it always has.
                if let initialTopic, path.isEmpty {
                    path = [initialTopic]
                }
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Settings")
                        .font(.headline)
                        .foregroundStyle(Theme.accentText)
                }
                if let onDone {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", action: onDone)
                            .tint(Theme.accentText)
                            .accessibilityIdentifier("settings.done")
                    }
                }
            }
        }
    }

    // MARK: - Header

    /// What the app is talking to, under its name.
    ///
    /// "No computer paired yet" is true and unhelpful while the on-device agent
    /// is the host: nothing is paired, and the thing answering is this phone.
    private var headerSubtitle: String {
        if model.isLocalAgentMode { return String(localized: "On-Device Agent") }
        if let host = model.host {
            return String(format: String(localized: "Paired with %@"), host.displayName)
        }
        return String(localized: "No computer paired yet")
    }

    /// What this is, before what it does: the icon, the name, the version.
    private var header: some View {
        Section {
            HStack(spacing: 16) {
                // The app's own icon, drawn rather than pasted. It runs one
                // chain load (five dots → arcs → icon) and stops on the icon;
                // the looping motion is for status rows, not this header.
                MizarIconTile(size: 64, motion: .assembling, animationToken: animationToken)
                    .shadow(color: Theme.navy.opacity(0.22), radius: 8, y: 3)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: "DSH-Mizar")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(Theme.accentText)
                    Text(headerSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.vertical, 6)
            .listRowBackground(Color.clear)
        }
    }

    // MARK: - 账户

    /// The account row: who is signed in, or that nobody is.
    ///
    /// It stays on the front page rather than moving into a shelf because it is
    /// the second thing a person looks for in settings, and because it has to be
    /// reachable without signing in — the row is how anybody discovers an
    /// account exists. The plan lives one tap further in, on the account screen's
    /// subscription section: "what am I on" and "what would paying change" are
    /// the same question asked twice.
    ///
    /// A blank avatar and 未登录 is not an error state; it is the truth about an
    /// app that works without one.
    private var accountSection: some View {
        Section {
            NavigationLink {
                AccountScreen(onDone: onDone)
            } label: {
                HStack(spacing: 14) {
                    AccountAvatarView(user: model.account.user, image: model.account.customAvatar, size: 44)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.account.isLoggedIn ? model.account.displayName : String(localized: "Not signed in"))
                            .font(.body.weight(.medium))
                            .foregroundStyle(Theme.accentText)
                            .accessibilityIdentifier("settings.account.name")
                        Text(model.account.isPaid ? String(localized: "Paid account") : String(localized: "Free account"))
                            .font(.caption)
                            .foregroundStyle(model.account.isPaid ? Theme.accentText : Color.secondary)
                            .accessibilityIdentifier("settings.account.plan")
                    }
                }
                .padding(.vertical, 2)
            }
            .accessibilityIdentifier("settings.account")
        } header: {
            SettingsSectionHeader("Account")
        } footer: {
            if !model.account.isLoggedIn {
                Text("A Mizar account is required to use the app. It keeps every relay session attributable to one person.")
            } else if let notice = model.account.noticeMessage {
                Text(notice)
            }
        }
    }

    // MARK: - 主题目录

    /// The shelves, top to bottom, in the order ``SettingsTopic`` declares.
    ///
    /// One section rather than eight: these are peers, and eight cards would
    /// draw eight boundaries that mean nothing.
    private var topicsSection: some View {
        Section {
            ForEach(SettingsTopic.allCases) { topic in
                NavigationLink(value: topic) {
                    SettingsTopicRow(topic: topic)
                }
                .accessibilityIdentifier("settings.topic.\(topic.rawValue)")
            }
        }
    }
}

#Preview {
    SettingsView().environment(AppModel())
}
