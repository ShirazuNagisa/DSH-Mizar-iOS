//
//  ConversationImageSnapshotTests.swift
//  DSH-MizarTests
//
//  The two deterministic drawings this feature added.
//
//  The load itself is deliberately absent: it goes through `file.stat` /
//  `file.read` on a socket, and a snapshot that races a socket is the definition
//  of flaky. What is left is everything that decides how a picture *looks* --
//  the lightbox's fit, its chrome and its caption, and what a message does when
//  there is no bridge to read the file through (a Markdown document preview),
//  which must be its caption rather than a failure sentence about a computer
//  nobody asked.
//

import MizarKit
import SwiftUI
import Testing
@testable import DSH_Mizar

@MainActor
struct ConversationImageSnapshotTests {
    /// A picture with known pixels, so the reference is stable.
    private static func fixture(size: CGSize = CGSize(width: 240, height: 160)) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { context in
            UIColor(red: 0.10, green: 0.16, blue: 0.28, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor(red: 0.24, green: 0.72, blue: 0.90, alpha: 1).setFill()
            context.fill(CGRect(x: 16, y: 16, width: size.width - 32, height: 40))
            UIColor.white.withAlphaComponent(0.85).setFill()
            context.fill(CGRect(x: 16, y: 76, width: size.width - 96, height: 12))
            context.fill(CGRect(x: 16, y: 100, width: size.width - 64, height: 12))
        }
    }

    @Test("the lightbox draws a picture fit, with its caption and size")
    func lightbox() throws {
        let picture = ConversationImageStore.Picture(
            image: Self.fixture(),
            pixelSize: CGSize(width: 240, height: 160),
            byteSize: 4096,
            name: "survey.png",
            alt: "A survey of the island",
        )
        let snapshot = try SnapshotHarness.assertSnapshot(
            of: ConversationImageLightbox(picture: picture),
            named: "ConversationImageLightbox",
            size: CGSize(width: 390, height: 844),
        )
        #expect(snapshot.pixelWidth == 780)
        #expect(snapshot.pixelHeight == 1688)
    }

    @Test("a link that may not have the bytes draws one line, and no room for a picture")
    func subscriptionLine() throws {
        let view = ConversationImageView(target: ConversationImageTarget(
            path: "shots/survey.png",
            alt: "A survey of the island",
        ))
        .environment(\.conversationImagesEntitled, false)
        .padding(16)
        let snapshot = try SnapshotHarness.assertSnapshot(
            of: view,
            named: "ConversationImageSubscription",
            size: CGSize(width: 390, height: 150),
        )
        #expect(snapshot.pixelWidth == 780)
    }

    @Test("a message with a picture and no bridge draws its caption, not a failure")
    func captionWithoutABridge() throws {
        let message = MarkdownMessage("![A survey of the island](shots/survey.png)")
            .font(.body)
            .padding(16)
        let snapshot = try SnapshotHarness.assertSnapshot(
            of: message,
            named: "ConversationImageCaptionOnly",
            size: CGSize(width: 390, height: 120),
        )
        #expect(snapshot.pixelWidth == 780)
    }
}
