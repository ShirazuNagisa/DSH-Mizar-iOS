//
//  ConversationImageDecoder.swift
//  DSH-Mizar
//
//  Bytes to a bitmap, at a size a phone can hold.
//
//  The same discipline as the preview page: ImageIO reads the header first, the
//  pixel budget is checked before a single row is decoded, and only then is a
//  downsampled bitmap produced -- with the EXIF orientation applied, so a photo
//  from a phone is not drawn on its side. `UIImage(data:)` would decode the full
//  bitmap first and ask questions later, which for a 20000 × 20000 PNG is the
//  jetsam kill the budget exists to prevent.
//
//  The budget itself lives in `MizarKit.ImagePreviewPolicy`, where the cheap
//  suite can test it; this file is the CoreGraphics part, which stays in the app.
//

import ImageIO
import MizarKit
import UIKit

enum ConversationImageDecoder {
    /// Decode one picture payload.
    ///
    /// - Parameters:
    ///   - payload: the bytes, and what the host said about the file.
    ///   - alt: the caption the message gave, carried onto the decoded picture.
    /// - Returns: the bitmap and the file's own pixel size.
    /// - Throws: ``ConversationImageFailure/tooLarge`` when the pixels do not
    ///   fit the budget, ``ConversationImageFailure/unreadable`` when the bytes
    ///   are not an image this device can decode.
    static func decode(
        _ payload: ConversationImagePayload,
        alt: String?,
    ) throws -> ConversationImageStore.Picture {
        guard let source = CGImageSourceCreateWithData(payload.data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        else {
            throw ConversationImageFailure.unreadable
        }
        guard ConversationImagePolicy.accepts(width: width, height: height) else {
            throw ConversationImageFailure.tooLarge
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: ImagePreviewPolicy.maxThumbnailPixels,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let bitmap = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ConversationImageFailure.unreadable
        }
        return ConversationImageStore.Picture(
            image: UIImage(cgImage: bitmap),
            pixelSize: CGSize(width: width, height: height),
            byteSize: payload.byteSize,
            name: payload.name,
            alt: alt,
        )
    }
}
