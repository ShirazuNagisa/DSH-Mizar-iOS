//
//  SnapshotFixtures.swift
//  DSH-MizarTests
//
//  Data the snapshot tests render, never data they fetch.
//
//  A snapshot that reads the live model is not reproducible: the reference would
//  encode whatever the pairing store, the keychain or the network happened to
//  say. Everything here is a literal or built from one, so the same test renders
//  the same pixels on any machine that has the same simulator runtime.
//

import Foundation
import MizarKit
import SwiftUI
@testable import DSH_Mizar

@MainActor
enum SnapshotFixtures {
    /// The app's English strings, resolved through the app bundle's `en.lproj`.
    ///
    /// `String(localized:locale:)` cannot be used for this: its `locale:`
    /// argument only affects formatting, not which translation is loaded — the
    /// bundle picks that from the process's preferred languages. This loads the
    /// English catalog explicitly, so a reference recorded on a Chinese-language
    /// simulator says exactly what a reference recorded on an English one says.
    static var englishBundle: Bundle {
        guard let path = Bundle.main.path(forResource: "en", ofType: "lproj"),
              let bundle = Bundle(path: path)
        else {
            return .main
        }
        return bundle
    }

    /// The app's light accent, for a fixture that has to draw it.
    ///
    /// The asset catalogue's `AccentColor` is invisible to the snapshot bundle
    /// (its `Bundle.main` has no app assets), so a view that needs the real
    /// light accent takes this literal. Keep it equal to the asset's light
    /// entry, `#0A78AE`.
    static var brandAccent: Color { Color(red: 0.039, green: 0.471, blue: 0.682) }

    /// The icon's own navy, from `Theme`.
    static var navy: Color { Color(red: 19 / 255, green: 31 / 255, blue: 61 / 255) }

    /// A signed-in paid account linked to Apple: the avatar is Apple's monogram,
    /// which is the generated-gradient path's counterpart.
    static let paidAppleLinkedUser = AccountUser(
        id: "00000000-0000-4000-8000-000000000042",
        username: "shirazu",
        email: "shirazu@example.com",
        emailVerified: true,
        plan: .paid,
        paidSources: ["appstore"],
        avatar: AccountAvatar(kind: .generated, colors: [], initials: "SN"),
        appleLinked: true,
    )

    /// A signed-in free account without Apple: the server palette and initials
    /// are what the account row would draw.
    static let signedInFreeUser = AccountUser(
        id: "00000000-0000-4000-8000-000000000043",
        username: "arowey",
        email: "arowey@example.com",
        plan: .free,
        avatar: AccountAvatar(
            kind: .generated,
            colors: ["#1F6FEB", "#58A6FF"],
            initials: "AR",
        ),
    )

    /// Two file drafts, deliberately not images: an image chip draws its
    /// thumbnail through `UIImage`, and the test wants the document chip's
    /// text-and-symbol layout, which is the one that regresses unnoticed.
    static var fileDrafts: [AttachmentDraft] {
        [
            AttachmentDraft(
                kind: .file,
                name: "mizar-notes.txt",
                mediaType: "text/plain",
                data: Data("notes".utf8),
                thumbnail: nil,
            ),
            AttachmentDraft(
                kind: .file,
                name: "budget-2026.pdf",
                mediaType: "application/pdf",
                data: Data("%PDF-1.7".utf8),
                thumbnail: nil,
            ),
        ]
    }
}
