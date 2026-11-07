//
//  SnapshotHarness.swift
//  DSH-MizarTests
//
//  The smallest thing that lets layout and copy be checked without launching the
//  app: render a SwiftUI view with `ImageRenderer` at a fixed size and scale,
//  and compare the pixels with a reference PNG in `Snapshots/__Snapshots__/`.
//
//  Why not swift-snapshot-testing: this project has zero package dependencies on
//  purpose (`scripts/ios.sh` explains why a package reference cannot resolve
//  under the restricted file policy the build runs under), and the library
//  would bring a second rendering/comparison pipeline, a second recording
//  workflow and its own tolerance rules for one thing that takes a couple of
//  hundred lines. The tradeoff is deliberate: no automatic image-diff service,
//  no perceptual/structural matching, no per-device reference sets. What we get
//  is a dependency-free harness whose reference bytes are reviewable in the same
//  `git diff` as the code that changed them.
//
//  Rules this file enforces, because a snapshot suite is only useful if it
//  cannot silently bless a regression:
//
//    * A mismatch never updates the reference. Recording is a separate, explicit
//      run with `MIZAR_SNAPSHOT_RECORD=1`.
//    * A missing reference is a failure, never a quiet "record and pass".
//    * Comparison is exact on dimensions and near-exact on pixels (a tolerance
//      for antialiasing, not for layout or colour changes).
//    * Failure artifacts (the actual render and a diff) are written next to the
//      references but under `__Failures__/`, which is git-ignored.
//
//  Determinism: a reference PNG belongs to a simulator runtime and a scale. The
//  harness pins colour scheme, display scale, locale and dynamic type, because
//  otherwise the same view renders differently depending on the machine. The
//  locale is a parameter rather than a law: `assertSnapshot(locale:)` overrides
//  it for a view rendered in a second language, and `nil` keeps the pinned
//  `en_US`, so existing references stay comparable byte for byte. It
//  cannot pin Reduce Motion (the SwiftUI environment key is get-only), so a
//  pilot must render a view whose static state does not depend on it. It cannot
//  pin the OS's text rasteriser either: an iOS upgrade may require a deliberate
//  re-record, which is what `docs/snapshots.md` says to do.
//

import SwiftUI
import UIKit

/// Renders SwiftUI views into reference PNGs and compares them pixel by pixel.
@MainActor
enum SnapshotHarness {
    /// 2x rather than the simulator's native 3x: half the bytes in the repo, and
    /// still enough resolution that a 1-pt layout shift moves real pixels.
    static let scale: CGFloat = 2

    /// How much pixel drift is treated as rendering noise rather than a change.
    ///
    /// `maxChannelDelta` absorbs antialiasing at text and shape edges (a 2/255
    /// difference in one channel is invisible). `maxDifferingFraction` allows a
    /// tenth of a per cent of the pixels to exceed it — a hairline edge, not a
    /// moved row and not a changed colour. Text size, spacing, colour and
    /// geometry changes all blow past this.
    struct Tolerance: Sendable {
        var maxChannelDelta: UInt8
        var maxDifferingFraction: Double

        static let `default` = Tolerance(maxChannelDelta: 2, maxDifferingFraction: 0.001)
    }

    /// What a test can assert about the render that just happened.
    struct Rendered: Sendable {
        /// The reference name, without the `@2x` suffix.
        let name: String
        let pixelWidth: Int
        let pixelHeight: Int
        /// True when this run wrote the reference instead of comparing with it.
        let recorded: Bool
    }

    struct SnapshotFailure: Error, CustomStringConvertible {
        let description: String
    }

    /// `MIZAR_SNAPSHOT_RECORD=1` is the only way to record: a failing comparison
    /// must never reach this. The scheme passes the build setting of the same
    /// name through to the test process; see `docs/snapshots.md`.
    static var isRecording: Bool {
        ProcessInfo.processInfo.environment["MIZAR_SNAPSHOT_RECORD"] == "1"
    }

    /// The folder the test sources live in, via the compile-time path of this
    /// file. References live in the repository rather than the test bundle so
    /// they are reviewable and versioned with the view they cover.
    static var testsDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    }

    static var referenceDirectory: URL {
        testsDirectory.appendingPathComponent("Snapshots/__Snapshots__", isDirectory: true)
    }

    /// Mismatch artifacts, ignored by git. References are never overwritten.
    static var failureDirectory: URL {
        referenceDirectory.appendingPathComponent("__Failures__", isDirectory: true)
    }

    // MARK: - Assert

    /// Render `view` at `size` and compare it with `name`'s reference.
    ///
    /// - Parameters:
    ///   - view: the view to render. Build it from fixture data, not from the
    ///     live app model: a snapshot has to be reproducible from the test.
    ///   - name: the reference's name. Use one per case; put the case's input in
    ///     the name (`MizarRing-openingHalf`) so a failure says what changed.
    ///   - size: the exact layout size in points. A reference is invalid at any
    ///     other size.
    ///   - scale: pixels per point. Changes only with a deliberate re-record.
    ///   - tolerance: see ``Tolerance``.
    ///   - locale: the locale the view's localisable text resolves in. `nil`
    ///     keeps the harness's pinned `en_US`; a test rendering a second
    ///     language passes the locale it names, which is how one record run on
    ///     the canonical English-locale simulator produces both goldens.
    /// - Returns: the render's pixel dimensions, for an explicit size assertion.
    static func assertSnapshot(
        of view: some View,
        named name: String,
        size: CGSize,
        scale: CGFloat = SnapshotHarness.scale,
        tolerance: Tolerance = .default,
        locale: Locale? = nil,
    ) throws -> Rendered {
        guard size.width > 0, size.height > 0 else {
            throw SnapshotFailure(description: "Snapshot \"\(name)\" was given a zero or negative size \(size).")
        }
        let image = try render(view, size: size, scale: scale, locale: locale)
        let actual = try pixels(of: image)
        let referenceURL = referenceDirectory.appendingPathComponent("\(name)@\(formatted(scale))x.png")

        if isRecording {
            guard let png = image.pngData() else {
                throw SnapshotFailure(description: "Could not encode snapshot \"\(name)\" as PNG.")
            }
            do {
                try FileManager.default.createDirectory(at: referenceDirectory, withIntermediateDirectories: true)
                try png.write(to: referenceURL, options: .atomic)
            } catch {
                throw SnapshotFailure(description: "Could not write reference \"\(referenceURL.path)\": \(error)")
            }
            print("[snapshots] recorded \(referenceURL.lastPathComponent) (\(actual.width)x\(actual.height) px)")
            return Rendered(
                name: name,
                pixelWidth: actual.width,
                pixelHeight: actual.height,
                recorded: true,
            )
        }

        guard FileManager.default.fileExists(atPath: referenceURL.path) else {
            throw SnapshotFailure(description: """
            Missing snapshot reference at \(referenceURL.path).
            Record it deliberately with MIZAR_SNAPSHOT_RECORD=1, then review the new PNG before committing it.
            """)
        }
        guard let referenceImage = UIImage(contentsOfFile: referenceURL.path) else {
            throw SnapshotFailure(description: "Snapshot reference at \(referenceURL.path) is not a readable image.")
        }
        let reference = try pixels(of: referenceImage)

        guard reference.width == actual.width, reference.height == actual.height else {
            let actualURL = try writeFailureArtifacts(name: name, actual: image, diff: nil)
            throw SnapshotFailure(description: """
            Snapshot "\(name)" is \(actual.width)x\(actual.height) px but its reference is \
            \(reference.width)x\(reference.height) px. Either the view's fixed size changed (re-record \
            deliberately if that is intended) or the reference belongs to another scale.
            Actual render: \(actualURL.path)
            """)
        }

        let difference = compare(actual: actual, reference: reference, tolerance: tolerance)
        guard difference.isWithin(tolerance: tolerance, totalPixels: actual.width * actual.height) else {
            let diff = diffImage(actual: actual, reference: reference, tolerance: tolerance)
            let actualURL = try writeFailureArtifacts(name: name, actual: image, diff: diff)
            throw SnapshotFailure(description: """
            Snapshot "\(name)" changed: \(difference.differingPixels) of \(actual.width * actual.height) \
            pixels differ by more than \(tolerance.maxChannelDelta)/255 \
            (allowed fraction: \(tolerance.maxDifferingFraction)), largest channel delta \
            \(difference.largestDelta)/255, first difference at \(difference.firstDifferenceDescription).
            Actual render and diff: \(actualURL.deletingLastPathComponent().path)
            If the change is intended, re-record with MIZAR_SNAPSHOT_RECORD=1 and review the PNG diff.
            """)
        }

        return Rendered(
            name: name,
            pixelWidth: actual.width,
            pixelHeight: actual.height,
            recorded: false,
        )
    }

    // MARK: - Render

    /// Render one view through the deterministic environment every reference is
    /// recorded with. Keeping the pins here (rather than in each test) is what
    /// makes two snapshots of the same view comparable.
    ///
    /// - Parameter locale: the locale override, or `nil` for the pinned `en_US`.
    static func render(_ view: some View, size: CGSize, scale: CGFloat, locale: Locale? = nil) throws -> UIImage {
        let renderer = ImageRenderer(content: pinned(view, size: size, scale: scale, locale: locale))
        renderer.scale = scale
        renderer.proposedSize = ProposedViewSize(width: size.width, height: size.height)
        // White underlay and an opaque render: no half-transparent PNGs whose
        // alpha channel differs by encoder, and references that read on GitHub.
        renderer.isOpaque = true
        guard let image = renderer.uiImage else {
            throw SnapshotFailure(description: "ImageRenderer produced no image for a \(size.width)x\(size.height) view.")
        }
        return image
    }

    /// Everything that can move a pixel pinned to one value.
    private static func pinned(_ view: some View, size: CGSize, scale: CGFloat, locale: Locale? = nil) -> some View {
        view
            .frame(width: size.width, height: size.height)
            .background(Color.white)
            // No animation may be in flight when the renderer draws. Without
            // this, a view that carries a transition (the model pill's
            // `.blurReplace`, for example) is rasterised at whatever progress
            // its insertion happened to reach, which differs between runs and
            // makes the reference depend on scheduling rather than layout.
            .transaction { transaction in
                transaction.disablesAnimations = true
                transaction.animation = nil
            }
            .environment(\.colorScheme, .light)
            .environment(\.dynamicTypeSize, .large)
            .environment(\.locale, locale ?? Locale(identifier: "en_US"))
            .environment(\.displayScale, scale)
    }

    // MARK: - Pixels

    private struct Pixels {
        let width: Int
        let height: Int
        /// Premultiplied RGBA, 8 bits per component.
        let bytes: [UInt8]
    }

    /// One `UIImage` as premultiplied RGBA bytes in device RGB, so two renders
    /// are compared in one colour space regardless of how each was produced.
    private static func pixels(of image: UIImage) throws -> Pixels {
        guard let cgImage = image.cgImage else {
            throw SnapshotFailure(description: "A rendered snapshot has no CGImage to compare.")
        }
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else {
            throw SnapshotFailure(description: "A rendered snapshot has empty pixel dimensions.")
        }
        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
            ) else {
                return false
            }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else {
            throw SnapshotFailure(description: "Could not decode a rendered snapshot into RGBA pixels.")
        }
        return Pixels(width: width, height: height, bytes: bytes)
    }

    private struct Difference {
        let differingPixels: Int
        let largestDelta: UInt8
        let firstDifference: (x: Int, y: Int)?

        var firstDifferenceDescription: String {
            guard let first = firstDifference else { return "none" }
            return "(\(first.x), \(first.y))"
        }

        /// The comparison passes while only a fraction of the pixels may exceed
        /// the channel tolerance. The allowed count floors, so a small image is
        /// not rounded up into a free-whole-pixel allowance.
        func isWithin(tolerance: Tolerance, totalPixels: Int) -> Bool {
            let allowed = Int(Double(totalPixels) * tolerance.maxDifferingFraction)
            return differingPixels <= allowed
        }
    }

    private static func compare(actual: Pixels, reference: Pixels, tolerance: Tolerance) -> Difference {
        var differingPixels = 0
        var largestDelta: UInt8 = 0
        var firstDifference: (x: Int, y: Int)?
        for index in stride(from: 0, to: actual.bytes.count, by: 4) {
            var pixelDelta: UInt8 = 0
            for channel in 0..<4 {
                let a = actual.bytes[index + channel]
                let b = reference.bytes[index + channel]
                let delta = a > b ? a - b : b - a
                pixelDelta = max(pixelDelta, delta)
            }
            largestDelta = max(largestDelta, pixelDelta)
            if pixelDelta > tolerance.maxChannelDelta {
                differingPixels += 1
                if firstDifference == nil {
                    let pixel = index / 4
                    firstDifference = (pixel % actual.width, pixel / actual.width)
                }
            }
        }
        return Difference(
            differingPixels: differingPixels,
            largestDelta: largestDelta,
            firstDifference: firstDifference,
        )
    }

    // MARK: - Failure artifacts

    /// Write the actual render (and a diff, when available) under
    /// `__Failures__/` and return the actual PNG's URL. Never touches references.
    @discardableResult
    private static func writeFailureArtifacts(name: String, actual: UIImage, diff: UIImage?) throws -> URL {
        do {
            try FileManager.default.createDirectory(at: failureDirectory, withIntermediateDirectories: true)
        } catch {
            throw SnapshotFailure(description: "Snapshot \"\(name)\" failed and \(failureDirectory.path) could not be created: \(error)")
        }
        let actualURL = failureDirectory.appendingPathComponent("\(name)-actual@\(formatted(scale))x.png")
        guard let png = actual.pngData() else {
            throw SnapshotFailure(description: "Snapshot \"\(name)\" failed and the actual render could not be encoded as PNG.")
        }
        do {
            try png.write(to: actualURL, options: .atomic)
            if let diff, let diffPNG = diff.pngData() {
                try diffPNG.write(
                    to: failureDirectory.appendingPathComponent("\(name)-diff@\(formatted(scale))x.png"),
                    options: .atomic,
                )
            }
        } catch {
            throw SnapshotFailure(description: "Snapshot \"\(name)\" failed and its artifacts could not be written: \(error)")
        }
        return actualURL
    }

    /// A magenta-on-dimmed-reference image: the pixels that differ, visible at a
    /// glance next to the actual render.
    private static func diffImage(actual: Pixels, reference: Pixels, tolerance: Tolerance) -> UIImage? {
        var bytes = [UInt8](repeating: 0, count: actual.bytes.count)
        for index in stride(from: 0, to: actual.bytes.count, by: 4) {
            var pixelDelta: UInt8 = 0
            for channel in 0..<4 {
                let a = actual.bytes[index + channel]
                let b = reference.bytes[index + channel]
                pixelDelta = max(pixelDelta, a > b ? a - b : b - a)
            }
            if pixelDelta > tolerance.maxChannelDelta {
                bytes[index] = 255
                bytes[index + 1] = 0
                bytes[index + 2] = 255
                bytes[index + 3] = 255
            } else {
                // The reference dimmed to grey, so unchanged pixels cannot be
                // confused with the ones that did change.
                let grey = reference.bytes[index + 3] / 3
                bytes[index] = grey
                bytes[index + 1] = grey
                bytes[index + 2] = grey
                bytes[index + 3] = 255
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let cgImage = CGImage(
                  width: actual.width,
                  height: actual.height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: actual.width * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent,
              )
        else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    /// Scale as it appears in a file name: `2`, `2.5`.
    private static func formatted(_ scale: CGFloat) -> String {
        scale == scale.rounded() ? String(Int(scale)) : String(format: "%g", scale)
    }
}
