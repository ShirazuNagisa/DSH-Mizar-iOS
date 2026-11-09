//
//  SettingsTopic.swift
//  DSH-Mizar
//
//  The settings directory: one case per shelf, in the order the shelves are
//  read on screen.
//
//  The order is deliberate and is the whole design of this screen. It runs from
//  the things that are about the person (the account and the plan it pays for),
//  through what the app will say to them (notifications, the Live Activity, and
//  how a half-sent message is handled), to how the message travels (transfer,
//  the agent on this phone), to what this phone keeps (files, the session data),
//  and finally outwards: the community, the log to send when something breaks,
//  and what the build is.
//
//  Every case owns its title, its one-line summary and its symbol, so the
//  directory row and the page it opens cannot disagree about what the shelf is
//  called.
//

import MizarKit
import SwiftUI

/// One shelf of the settings screen.
enum SettingsTopic: String, CaseIterable, Identifiable {
    case notifications
    case sending
    case transfer
    case localAgent
    case files
    case community
    case logs
    case about

    var id: String { rawValue }

    /// What the directory row and the page's title bar both say.
    var title: LocalizedStringKey {
        switch self {
        case .notifications: "Notifications & Live Activity"
        case .sending: "Sending Preferences"
        case .transfer: "Transfer"
        case .localAgent: "On-Device Agent (Experimental)"
        case .files: "Files & Cache"
        case .community: "Community"
        case .logs: "Logs"
        case .about: "About & More"
        }
    }

    /// What is on the shelf, in one line, for a directory that is scanned
    /// rather than read.
    var summary: LocalizedStringKey {
        switch self {
        case .notifications: "Notification kinds, the Live Activity and haptics."
        case .sending: "What happens to a message sent while a turn is running."
        case .transfer: "Local network first, and the P2P direct connection."
        case .localAgent: "Model configuration, and the sessions it keeps on this phone."
        case .files: "Previewed files, the file cache, and the local session data."
        case .community: "The project's website and the feedback group."
        case .logs: "Export a diagnostic log for one problem."
        case .about: "Version, source code, credits and the developer tools."
        }
    }

    /// Its symbol in the directory.
    var symbol: String {
        switch self {
        case .notifications: "bell.badge"
        case .sending: "paperplane"
        case .transfer: "network"
        case .localAgent: "cpu"
        case .files: "externaldrive"
        case .community: "person.2"
        case .logs: "text.alignleft"
        case .about: "info.circle"
        }
    }

    /// The page behind the row.
    ///
    /// `@MainActor` because the page it builds is a view, and every view's
    /// initializer is main-actor-isolated: the directory is drawn on the main
    /// actor, and this is called from that draw.
    ///
    /// - Parameter onDone: closes the settings sheet, handed down so every page
    ///   can offer the same way out.
    /// - Returns: the topic's screen.
    @MainActor
    @ViewBuilder
    func page(onDone: (() -> Void)?) -> some View {
        pageBody(onDone: onDone)
            // The shelf's identity, for the tests (and for a banner that opens
            // one): the title is localized, the id is not.
            .accessibilityIdentifier("settings.page.\(rawValue)")
    }

    /// The page itself, without the wrapper the identifier needs.
    @MainActor
    @ViewBuilder
    private func pageBody(onDone: (() -> Void)?) -> some View {
        switch self {
        case .notifications: NotificationsSettingsView(onDone: onDone)
        case .sending: SendingSettingsView(onDone: onDone)
        case .transfer: TransferSettingsView(onDone: onDone)
        case .localAgent: LocalAgentSettingsView(onDone: onDone)
        case .files: FilesSettingsView(onDone: onDone)
        case .community: CommunitySettingsView(onDone: onDone)
        case .logs: LogsSettingsView(onDone: onDone)
        case .about: AboutSettingsView(onDone: onDone)
        }
    }
}

/// One directory row: the shelf's symbol, its name, and one line about it.
///
/// Two lines rather than one because eight bare titles do not say what is
/// behind them, and the operator should not have to open each shelf to find
/// out whether their setting is inside.
struct SettingsTopicRow: View {
    let topic: SettingsTopic

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: topic.symbol)
                .font(.body)
                .foregroundStyle(Theme.accentText)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(topic.title)
                    .foregroundStyle(Theme.accentText)
                Text(topic.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}


/// Where a server-sent banner's button goes.
///
/// The relay names a settings page by the shelf's own id. `account` is the one
/// that is not a shelf -- it is the row above the directory -- so it opens the
/// directory and stops there. A name this build does not know never reaches
/// here: the banner hides a button it cannot place.
extension AnnouncementTarget {
    /// The shelf to push, or `nil` for the directory itself.
    var settingsTopic: SettingsTopic? {
        switch self {
        case .account: nil
        case .notifications: .notifications
        case .sending: .sending
        case .transfer: .transfer
        case .localAgent: .localAgent
        case .files: .files
        case .community: .community
        case .logs: .logs
        case .about: .about
        }
    }
}
