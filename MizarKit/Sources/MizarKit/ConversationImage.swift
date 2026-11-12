//
//  ConversationImage.swift
//  MizarKit
//
//  The bytes behind a picture a model pointed at.
//
//  A message never carries pixels: an answer that shows a screenshot carries a
//  line like `![实时活动](docs/evidence/shot.png)` and nothing else. The desktop
//  resolves that path against the session's workspace and draws the file; this
//  is the phone's half of the same idea -- ask the computer what the path is
//  (`file.stat`), refuse what a thumbnail has no business decoding, then read it
//  in the same 256 KiB slices the preview page uses.
//
//  The split is deliberate: the policy and the wire sequence live here, where
//  the cheap host suite can hold them, and every CoreGraphics call stays in the
//  app. A picture that cannot be had is an ordinary outcome, not an error the
//  stream has to explain -- the row keeps its caption and says one sentence.
//

import Foundation

/// A picture a message asked for.
public struct ConversationImageTarget: Sendable, Equatable, Hashable {
    /// The path exactly as the model wrote it: usually relative to the
    /// session's workspace, sometimes absolute. The host resolves it; the phone
    /// never guesses.
    public let path: String
    /// What the model meant the picture to say, kept for the caption a reader
    /// gets when it cannot be loaded, and for VoiceOver.
    public let alt: String?

    public init(path: String, alt: String? = nil) {
        self.path = path
        self.alt = alt
    }

    /// The target a block names, or `nil` when the block is not a picture.
    ///
    /// - Parameter block: one parsed block.
    public init?(block: MarkdownBlock) {
        guard case .image(let alt, let path) = block else { return nil }
        self.init(path: path, alt: alt)
    }

    /// The path without a Markdown anchor or fragment.
    ///
    /// A model occasionally writes `shot.png#L3` because every *other* file it
    /// references is a source file that takes one. A picture does not.
    public var lookupPath: String {
        guard let hash = path.firstIndex(of: "#"), hash != path.startIndex else { return path }
        return String(path[..<hash])
    }

    /// Whether the path names a place on the computer rather than the network.
    ///
    /// Only local files are read over the bridge: `file.read` is scoped to a
    /// session's workspace, and an `https:` picture belongs to a different
    /// mechanism this build does not have.
    public var isLocal: Bool {
        let lower = lookupPath.lowercased()
        guard let colon = lookupPath.firstIndex(of: ":") else { return true }
        let scheme = lower[..<colon]
        // A Windows drive letter is a path, not a scheme.
        if scheme.count == 1 { return true }
        return scheme == "file"
    }
}

/// What an inline picture will agree to load.
///
/// Numbers, not opinions: the same ceiling on both sides of the wire would be a
/// second chance to disagree, so the client asks for less than the host would
/// give and says why when a picture is past it.
public enum ConversationImagePolicy {
    /// The most bytes one inline picture may be.
    ///
    /// The host's own ceiling is 32 MiB (a document); a transcript is not a
    /// document viewer. Twelve covers a 6-shot contact sheet and an unedited
    /// phone screenshot, and stops a page of 30 MiB TIFFs from being read six
    /// times while somebody scrolls past.
    public static let maximumBytes = 12 * 1_048_576

    /// The extensions this client draws.
    ///
    /// What ImageIO reads on the oldest iOS this app targets, plus the formats
    /// DSH itself normalises to (PNG, JPEG, WebP, GIF).
    public static let extensions: Set<String> = [
        "png", "jpg", "jpeg", "jpe", "webp", "gif", "heic", "heif", "bmp", "tiff", "tif",
    ]

    /// Whether a path's extension is one this client draws.
    ///
    /// - Parameter path: a path as written, with or without a fragment.
    public static func accepts(path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension.lowercased()
        return extensions.contains(ext)
    }

    /// Whether a host-reported media type is one this client draws.
    ///
    /// - Parameter mediaType: the `file.stat` answer, e.g. `image/png`.
    public static func accepts(mediaType: String) -> Bool {
        mediaType.lowercased().hasPrefix("image/")
    }

    /// Whether a size may be read.
    ///
    /// - Parameter bytes: the file's size, as `file.stat` reported it.
    public static func accepts(bytes: Int) -> Bool {
        bytes > 0 && bytes <= maximumBytes
    }

    /// Whether the pixel budget allows the bitmap.
    ///
    /// - Parameters:
    ///   - width: the image's pixel width.
    ///   - height: the image's pixel height.
    public static func accepts(width: Int, height: Int) -> Bool {
        ImagePreviewPolicy.accepts(width: width, height: height)
    }
}

/// Why a picture is not on the page.
///
/// Semantics, not sentences: the app owns the wording, and every case here is
/// something a reader can act on. `unreadable` is the only one that means "the
/// picture was there and this build could not draw it".
public enum ConversationImageFailure: Sendable, Equatable, Error {
    /// The file is gone, or the path names nothing.
    case missing
    /// Inside the workspace but not readable: outside it, a directory, or a
    /// name the host refuses.
    case forbidden
    /// Larger than ``ConversationImagePolicy/maximumBytes``.
    case tooLarge
    /// The computer's plugin predates `file.stat`.
    case oldPlugin
    /// Reading files needs a local network link or a paid account.
    case locked
    /// The computer is not reachable.
    case offline
    /// Not a picture this client draws.
    case notAnImage
    /// A picture whose bytes or header could not be used.
    case unreadable

    /// The case a host error code maps to.
    ///
    /// - Parameter code: the `MizarError.code` the host sent.
    public init(code: String) {
        switch code {
        case "FILE_UNKNOWN", "NOT_FOUND":
            self = .missing
        case "FILE_FORBIDDEN", "PATH_ESCAPES_SANDBOX":
            self = .forbidden
        case "FILE_TOO_LARGE", "RESPONSE_TOO_LARGE":
            self = .tooLarge
        case "NOT_IMPLEMENTED":
            self = .oldPlugin
        case "PREVIEW_LOCKED", "PERMISSION_DENIED", "UNAUTHENTICATED", "PAIRING_REQUIRED":
            self = .locked
        case "NO_CONNECTION", "SOCKET_CLOSED", "CONNECTION_LOST", "HOST_OFFLINE":
            self = .offline
        case "FILE_SLICE_INVALID", "FILE_SLICE_STALLED", "MALFORMED_FRAME":
            self = .unreadable
        default:
            self = .unreadable
        }
    }
}

/// A picture's bytes, and what the host said about them.
public struct ConversationImagePayload: Sendable, Equatable {
    /// The file's bytes, as read.
    public let data: Data
    /// The size the host reported before the read.
    public let byteSize: Int
    /// `image/png`, or whatever the host associated with the extension.
    public let mediaType: String
    /// When the file was last written, epoch milliseconds. Part of the cache
    /// key, so a regenerated picture is a different picture.
    public let modifiedAt: Double
    /// The file's own name, for the lightbox title.
    public let name: String

    public init(data: Data, byteSize: Int, mediaType: String, modifiedAt: Double, name: String) {
        self.data = data
        self.byteSize = byteSize
        self.mediaType = mediaType
        self.modifiedAt = modifiedAt
        self.name = name
    }
}

/// Reading one message's picture off the computer.
public struct ConversationImageFetcher: Sendable {
    private let reader: FileReader

    /// - Parameter reader: the bridge reader, injected so tests need no socket.
    public init(reader: FileReader) {
        self.reader = reader
    }

    /// Read a picture, or say why it cannot be drawn.
    ///
    /// The order matters: the extension is refused before a frame is spent, the
    /// size is refused before the bytes are read, and the media type the host
    /// reports is checked as well because an extension is a claim.
    ///
    /// - Parameters:
    ///   - sessionId: the session whose workspace the path is resolved in.
    ///   - target: the picture the message asked for.
    ///   - progress: fraction read, for the placeholder.
    /// - Returns: the bytes and the host's facts.
    /// - Throws: ``ConversationImageFailure``, or `CancellationError`.
    public func fetch(
        sessionId: String,
        target: ConversationImageTarget,
        progress: (@Sendable (Double) -> Void)? = nil,
    ) async throws -> ConversationImagePayload {
        guard target.isLocal else { throw ConversationImageFailure.notAnImage }
        let path = target.lookupPath
        let facts: FileFacts
        do {
            facts = try await reader.stat(sessionId: sessionId, path: path)
        } catch let error as MizarError {
            throw ConversationImageFailure(code: error.code)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ConversationImageFailure.offline
        }
        guard ConversationImagePolicy.accepts(path: path)
            || ConversationImagePolicy.accepts(mediaType: facts.mediaType)
        else {
            throw ConversationImageFailure.notAnImage
        }
        guard ConversationImagePolicy.accepts(bytes: facts.byteSize) else {
            throw ConversationImageFailure.tooLarge
        }
        let data: Data
        do {
            data = try await reader.read(
                sessionId: sessionId,
                path: path,
                expectedSize: facts.byteSize,
                progress: progress,
            )
        } catch let error as MizarError {
            throw ConversationImageFailure(code: error.code)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ConversationImageFailure.offline
        }
        guard data.count == facts.byteSize, !data.isEmpty else {
            throw ConversationImageFailure.unreadable
        }
        return ConversationImagePayload(
            data: data,
            byteSize: facts.byteSize,
            mediaType: facts.mediaType,
            modifiedAt: facts.modifiedAt,
            name: facts.name,
        )
    }
}
