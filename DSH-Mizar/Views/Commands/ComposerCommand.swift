//
//  ComposerCommand.swift
//  DSH-Mizar
//
//  The commands the composer offers: two rows the phone owns, not something the
//  computer sends.
//
//  `/goal` and `/plan` are DSH's own slash commands. The phone has carried them
//  since the command popover existed, and they are the only entries under the
//  palette's "Commands" heading; skills are a separate list the computer syncs.
//  They live here rather than inside `ComposerBar` because two screens draw
//  them -- the palette and the command catalogue -- and a second hand-written
//  copy is how two lists of the same two things start disagreeing.
//
//  The catalogue keys are stored raw as well as as `LocalizedStringKey`s: the
//  palette searches what the operator can read, and a `LocalizedStringKey` has
//  no way back to its key or to the string it resolves to. `name` and `literal`
//  are what the host parses and must not change.
//

import Foundation
import SwiftUI

/// One of the composer's built-in slash commands.
struct ComposerCommand: Identifiable {
    /// The name without its slash: `goal`, `plan`.
    let name: String
    /// The catalogue key the row's title resolves from.
    let titleKey: String
    /// The catalogue key of the one line under it.
    let summaryKey: String
    /// Its symbol in the palette.
    let symbol: String

    var id: String { name }

    /// What the row says.
    var title: LocalizedStringKey { LocalizedStringKey(titleKey) }

    /// The one line under it, saying what it does.
    var summary: LocalizedStringKey { LocalizedStringKey(summaryKey) }

    /// The characters the field inserts and the host parses.
    var literal: String { "/" + name }

    /// Both the raw keys and the strings they resolve to, for the palette's
    /// case-insensitive search. The resolved values are read in the app
    /// bundle's language, which is the same language the interface is drawn
    /// in -- a Chinese operator can search 目标 as well as "goal".
    var searchText: String {
        [
            name,
            titleKey,
            summaryKey,
            String(localized: String.LocalizationValue(titleKey)),
            String(localized: String.LocalizationValue(summaryKey)),
        ]
        .joined(separator: " ")
    }

    /// Both commands, in the order the palette shows them.
    ///
    /// Computed rather than stored: `LocalizedStringKey` is not `Sendable`, and
    /// a global array of it would be shared mutable state under Swift 6. Two
    /// rows rebuilt per read are cheaper than an unsafe annotation.
    static var all: [ComposerCommand] {
        [
            ComposerCommand(
                name: "goal",
                titleKey: "Goal",
                summaryKey: "Agree what this session is for",
                symbol: "target",
            ),
            ComposerCommand(
                name: "plan",
                titleKey: "Plan",
                summaryKey: "Work out the steps before acting",
                symbol: "list.bullet.rectangle",
            ),
        ]
    }
}
