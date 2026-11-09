//
//  AnnouncementBanner.swift
//  DSH-Mizar
//
//  The banner the operator's message arrives on.
//
//  It is drawn in the app's own materials rather than as an alert: a rounded
//  glass card that sits under the status bar, the accent-coloured symbol the
//  message chose, the sentence, and -- only when the server asked for one -- a
//  single button that opens a settings page. A banner is not a decision the
//  operator has to answer before using the app, so nothing about it blocks the
//  screen behind it.
//
//  Motion follows the rest of the app: it drops in with the bouncy token and
//  fades out; with Reduce Motion it only fades. The card holds the two
//  accessibility identifiers the tests look for (`announcement.banner` and
//  `announcement.action`), and the close button is labelled so VoiceOver does
//  not read "x".
//

import MizarKit
import SwiftUI

struct AnnouncementBanner: View {
    let announcement: Announcement
    /// Called when the button is tapped, with the settings page it names.
    var onAction: (AnnouncementTarget) -> Void
    /// Called when the banner is closed or has done its job.
    var onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The accent, or the waiting colour when the server asked for attention.
    private var toneColor: Color {
        announcement.tone == "notice" ? Theme.waiting : Theme.accentText
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: announcement.resolvedSymbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.onAccent)
                .frame(width: 32, height: 32)
                .background(Circle().fill(toneColor))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(announcement.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("announcement.title")
                Text(announcement.body)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("announcement.body")
                if let button = announcement.actionableButton {
                    Button {
                        if let destination = button.destination {
                            onAction(destination)
                        }
                        onDismiss()
                    } label: {
                        Text(button.label)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Theme.onAccent)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(Color.accentColor))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                    .accessibilityIdentifier("announcement.action")
                }
            }
            .layoutPriority(1)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(.fill.quaternary))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Dismiss"))
            .accessibilityIdentifier("announcement.close")
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.white.opacity(0.14), lineWidth: 1),
        )
        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("announcement.banner")
    }
}

#Preview {
    VStack {
        AnnouncementBanner(
            announcement: Announcement.preview(
                title: "0.9.9 is on TestFlight",
                body: "The new settings directory and turn cycle are ready to try.",
                button: AnnouncementButton(label: "Open settings", target: "notifications"),
            ),
            onAction: { _ in },
            onDismiss: {},
        )
        .padding()
        Spacer()
    }
}
