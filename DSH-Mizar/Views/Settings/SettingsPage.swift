//
//  SettingsPage.swift
//  DSH-Mizar
//
//  The furniture every settings topic page is drawn with.
//
//  The settings screen is a directory now: one row per shelf, and a page behind
//  each row. What those pages share is not their content but their edges -- the
//  title in the navigation bar, the sheet's Done button, the accent column, and
//  the two row idioms (`SettingsSectionHeader`, `SettingsRowLabel`) the screen
//  has always used. They live here so eight pages cannot drift into eight
//  slightly different versions of the same screen.
//
//  Native throughout -- `List`, `Section`, `Toggle`, `LabeledContent` -- because
//  every one of these has an accessibility shape the operator already knows.
//

import SwiftUI

// MARK: - Page

/// One topic page: the content, its title, and the way out of the sheet.
///
/// The Done button is repeated at every level rather than left on the root,
/// because a `NavigationStack` does not carry the root's toolbar items into a
/// pushed destination: without this, closing the settings from a topic page
/// costs a tap back first, and on the account page that omission was already
/// enough of a problem to give it its own copy.
struct SettingsPage<Content: View>: View {
    /// What the page is, in the navigation bar.
    let title: LocalizedStringKey
    /// Closes the sheet this page was pushed in. `nil` when the stack is
    /// presented by something that owns its own dismissal.
    var onDone: (() -> Void)?
    private let content: Content

    /// - Parameters:
    ///   - title: the navigation bar's title.
    ///   - onDone: closes the settings sheet.
    ///   - content: the page's list.
    init(
        title: LocalizedStringKey,
        onDone: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content,
    ) {
        self.title = title
        self.onDone = onDone
        self.content = content()
    }

    var body: some View {
        content
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
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

// MARK: - Rows

/// A settings section header: the readable cut of the icon's cyan.
///
/// The raw accent is a fill, not type; `accentText` is the colour that stays
/// legible on both the light settings page and its dark mode.
struct SettingsSectionHeader: View {
    private let title: LocalizedStringKey

    /// - Parameter title: the section's name.
    init(_ title: LocalizedStringKey) {
        self.title = title
    }

    var body: some View {
        Text(title).foregroundStyle(Theme.accentText)
    }
}

/// A settings row's label, in the same readable accent as its icon.
///
/// Destructive rows deliberately do not use this: their red is the signal.
struct SettingsRowLabel: View {
    private let title: LocalizedStringKey
    private let systemImage: String

    /// - Parameters:
    ///   - title: what the row is called.
    ///   - systemImage: its symbol.
    init(_ title: LocalizedStringKey, systemImage: String) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        Label(title, systemImage: systemImage)
            .foregroundStyle(Theme.accentText)
    }
}
