//
//  ComposerOnDeviceSnapshotTests.swift
//  DSH-MizarTests
//
//  The two pieces of chrome the on-device features added, as pixels.
//
//  The rewrite's window and the microphone's strip are leaves -- they take
//  their state as values and own no environment -- which is exactly what the
//  snapshot harness can judge honestly. What the references pin is the part a
//  unit test cannot: the three rows are the same shape and the same height,
//  the explanation window is not a page, and the strip's clock, meter, preview
//  and cancel line share one 44-point line instead of pushing the composer
//  taller.
//
//  The strip's preview text is deliberately Chinese in both languages: a
//  transcript is the operator's words, not the interface's copy, and the
//  reference proves the field's font renders it without falling back.
//

import SwiftUI
import Testing
import UIKit
@testable import DSH_Mizar

@MainActor
struct ComposerOnDeviceSnapshotTests {
    enum Appearance: String, CaseIterable, Sendable {
        case light
        case dark

        var scheme: ColorScheme { self == .dark ? .dark : .light }
    }

    @Test(arguments: Appearance.allCases)
    func rewriteWindowOffersTheThreeIntents(_ appearance: Appearance) throws {
        let snapshot = try SnapshotHarness.assertSnapshot(
            of: ComposerEnhancePanel(
                availability: .available,
                onPick: { _ in },
                onOpenSettings: {},
            )
            .background(Color(uiColor: .systemBackground))
            .environment(\.colorScheme, appearance.scheme),
            named: "ComposerEnhancePanel-\(appearance.rawValue)",
            size: CGSize(width: 320, height: 200),
        )
        #expect(snapshot.pixelWidth == 640)
        #expect(snapshot.pixelHeight == 400)
    }

    @Test
    func rewriteWindowExplainsAModelThatIsNotReady() throws {
        let snapshot = try SnapshotHarness.assertSnapshot(
            of: ComposerEnhancePanel(
                availability: .modelNotReady,
                onPick: { _ in },
                onOpenSettings: {},
            )
            .background(Color(uiColor: .systemBackground)),
            named: "ComposerEnhancePanel-modelNotReady",
            size: CGSize(width: 320, height: 150),
        )
        #expect(snapshot.pixelWidth == 640)
    }

    @Test
    func recordingStripSharesOneLine() throws {
        let snapshot = try SnapshotHarness.assertSnapshot(
            of: ComposerDictationStrip(
                phase: .recording,
                liveText: "帮我给这个函数补一个单元测试",
                level: 0.6,
                elapsed: 7,
                cancelling: false,
            )
            .padding(.horizontal, 16)
            .background(Color(uiColor: .systemBackground)),
            named: "ComposerDictationStrip-recording",
            size: CGSize(width: 390, height: 60),
        )
        #expect(snapshot.pixelWidth == 780)
    }

    @Test
    func recordingStripSaysWhenSpeechIsUnavailable() throws {
        let snapshot = try SnapshotHarness.assertSnapshot(
            of: ComposerDictationStrip(
                phase: .unsupported,
                liveText: "",
                level: 0,
                elapsed: 0,
                cancelling: false,
                onDismiss: {},
            )
            .padding(.horizontal, 16)
            .background(Color(uiColor: .systemBackground)),
            named: "ComposerDictationStrip-unsupported",
            size: CGSize(width: 390, height: 60),
        )
        #expect(snapshot.pixelWidth == 780)
    }
}
