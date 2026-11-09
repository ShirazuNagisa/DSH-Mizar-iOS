//
//  AppSourceContract.swift
//  DSH-MizarTests
//
//  Pins the accessibility identifiers and user-facing copy that the UI suite
//  queries, without launching the app.
//
//  Why a source-level check instead of the accessibility tree: SwiftUI does not
//  expose its accessibility tree to a unit-test process (it is materialised by
//  the accessibility server, which is exactly what XCUITest talks to), and
//  rendering a view with `ImageRenderer` discards accessibility information
//  entirely. A snapshot therefore proves the pixels, and this file proves that
//  the identifiers the migrated XCUITests looked for are still declared in the
//  view's source. Together they cover what the XCUITest asserted — "this row is
//  on screen, says this, and is addressable" — without a 20-second app launch.
//
//  The check reads the app's source from the repository (the simulator can read
//  the checkout path, and `#filePath` gives the test the same root the build
//  used). That is a stronger contract than a fixture string in a test, because
//  deleting `.accessibilityIdentifier("settings.account.name")` from the app
//  fails the suite even though the fixture still renders.
//

import Foundation

enum AppSourceContract {
    /// The iOS checkout root, derived from this file's compile-time path.
    static var iosRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // DSH-MizarTests
            .deletingLastPathComponent() // iOS
    }

    struct ContractFailure: Error, CustomStringConvertible {
        let description: String
    }

    /// Fail unless every identifier is applied in the given app source file.
    ///
    /// - Parameters:
    ///   - identifiers: the literal identifiers, without the `.` prefix.
    ///   - relativePath: the app source file, relative to the iOS root.
    static func expectIdentifiers(_ identifiers: [String], in relativePath: String) throws {
        try expectFragments(
            identifiers.map { ".accessibilityIdentifier(\"\($0)\")" },
            in: relativePath,
            describing: "accessibility identifier",
        )
    }

    /// Fail unless every fragment appears verbatim in the given app source file.
    ///
    /// Use this for copy (`String(localized: "…")`) and for identifiers that are
    /// applied to the exact view the snapshot covers.
    /// Read one app source file, for a contract that is about what a file does
    /// *not* say.
    ///
    /// - Parameter relativePath: the file, relative to the iOS root.
    /// - Returns: its text.
    static func text(at relativePath: String) throws -> String {
        let url = iosRoot.appendingPathComponent(relativePath)
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw ContractFailure(description: """
            Could not read \(url.path). \
            Unit tests run in the simulator and read the checkout through the path the \
            compiler used; if the checkout moved since the build, rebuild before running.
            """)
        }
    }

    static func expectFragments(
        _ fragments: [String],
        in relativePath: String,
        describing kind: String = "source fragment",
    ) throws {
        let source = try text(at: relativePath)
        let missing = fragments.filter { !source.contains($0) }
        guard missing.isEmpty else {
            throw ContractFailure(description: """
            \(relativePath) no longer declares:
            \(missing.map { "  \($0)" }.joined(separator: "\n"))
            Those are what the UI suite queries, so removing or renaming one removes coverage \
            that the snapshot alone cannot provide.
            """)
        }
    }
}
