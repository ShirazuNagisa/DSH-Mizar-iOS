//
//  CommunitySettingsView.swift
//  DSH-Mizar
//
//  Where to find the project and the people using it.
//
//  Two doors, both of which leave the app rather than opening a page of their
//  own: the website is the operator's own browser (their choice of one, and its
//  history), and the QQ group is QQ. Nothing is imitated here -- an in-app web
//  view of a page the app does not own is a second browser with none of the
//  first one's affordances.
//

import SwiftUI
import UIKit

struct CommunitySettingsView: View {
    /// Closes the settings sheet this page was pushed in.
    var onDone: (() -> Void)?
    /// The system's browser opener.
    @Environment(\.openURL) private var openURL

    /// Whether a tap on the QQ row had to fall back to copying the group
    /// number, because this phone has no QQ to open.
    @State private var qqNumberCopied = false

    var body: some View {
        SettingsPage(title: "Community", onDone: onDone) {
            List {
                Section {
                    Button {
                        openWebsite()
                    } label: {
                        LabeledContent {
                            Image(systemName: "arrow.up.right")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } label: {
                            SettingsRowLabel("Website", systemImage: "globe")
                        }
                    }
                    .accessibilityIdentifier("settings.community.website")

                    Button {
                        openQQGroup()
                    } label: {
                        LabeledContent {
                            Image(systemName: "arrow.up.right")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } label: {
                            SettingsRowLabel("QQ group", systemImage: "bubble.left.and.bubble.right")
                        }
                    }
                    .accessibilityIdentifier("settings.community.qq")

                    // Said only when it happened: a permanent footnote about an
                    // app the operator may well have installed would be noise on
                    // every visit.
                    if qqNumberCopied {
                        Text("QQ is not installed. The group number has been copied to the clipboard.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .transition(.rise)
                            .accessibilityIdentifier("settings.community.qq.copied")
                    }
                } header: {
                    SettingsSectionHeader("Community")
                }
            }
        }
    }

    /// The project's own page, in the operator's browser.
    private func openWebsite() {
        guard let url = URL(string: "https://dsh-mizar.shirazu-nagisa.com") else { return }
        openURL(url)
    }

    /// The feedback group, in QQ.
    ///
    /// QQ answers a group card at `mqqapi://card/show_pslcard`, which opens the
    /// group's own page inside QQ -- one tap from joining, rather than a number
    /// the operator has to copy out and search for. A phone without QQ has no
    /// handler for that scheme at all, so the number goes to the clipboard and
    /// the row says so: a tap that appears to do nothing is the one outcome
    /// worth ruling out.
    private func openQQGroup() {
        let group = "1130443236"
        let card = URL(string: "mqqapi://card/show_pslcard?src_type=internal&version=1&uin=\(group)&card_type=group&source=qrcode")
        if let card, UIApplication.shared.canOpenURL(card) {
            UIApplication.shared.open(card)
            return
        }
        UIPasteboard.general.string = group
        withMizarAnimation(.mizarSmooth) { qqNumberCopied = true }
    }
}
