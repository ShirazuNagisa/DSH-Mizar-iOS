//
//  ComposerPill.swift
//  DSH-Mizar
//
//  The capsule the composer draws around a command or a skill.
//
//  A pill is an `NSTextAttachment`, not a styled run: only an attachment is
//  atomic to TextKit, which is what makes it wrap to the next line as a whole
//  instead of breaking between two letters, and what makes one backspace delete
//  all of it. The image is drawn here rather than by the system because the
//  pill is a filled capsule with inverted text, and `NSAttributedString` has no
//  rounded background to give it.
//
//  Two consequences worth knowing:
//
//  - The image is a bitmap for one appearance and one width. It is regenerated
//    when the field changes width, appearance or Dynamic Type, which the editor
//    does in `refreshTokenRendering`.
//  - Nothing in this file decides what a token is. ``ComposerTokens`` owns that;
//    this file only turns a literal it was handed into a picture.
//

import SwiftUI
import UIKit

/// One token the palette asked the field to put down.
///
/// A value rather than a binding: the screen hands it over, the editor consumes
/// it once and calls back, and a second delivery cannot happen because the
/// identity changes on every request.
struct ComposerInsertion: Identifiable, Equatable {
    let id = UUID()
    /// What to insert, without the trailing space the editor adds.
    let literal: String
    /// Whether a lone `/` before the caret is the trigger and must be replaced.
    let replacesSlashToken: Bool

    init(literal: String, replacesSlashToken: Bool = false) {
        self.literal = literal
        self.replacesSlashToken = replacesSlashToken
    }
}

/// How a pill is measured and drawn.
enum ComposerPill {
    /// The attribute that carries a token's literal through an attachment run.
    ///
    /// `U+FFFC` is all the attributed string holds for the token; without this
    /// the draft could not be reconstructed from the field.
    static let literalKey = NSAttributedString.Key("mizar.composerLiteral")

    /// The pill's type: one step below the body the draft is written in, so a
    /// capsule fits inside the line the text already needs.
    static func font(for traits: UITraitCollection) -> UIFont {
        UIFontMetrics(forTextStyle: .body).scaledFont(
            for: .systemFont(ofSize: 15, weight: .semibold),
            maximumPointSize: 20,
            compatibleWith: traits,
        )
    }

    /// Horizontal room inside the capsule.
    private static let padding: CGFloat = 9

    /// The smallest capsule worth drawing, for a one-letter name.
    private static let minimumWidth: CGFloat = 34

    /// One attachment for one literal.
    ///
    /// - Parameters:
    ///   - literal: `/goal`, `/grilling`.
    ///   - maxWidth: the field's content width; a wider pill is truncated.
    ///   - traits: the appearance and display scale to draw for.
    /// - Returns: an attachment whose image is the capsule.
    static func attachment(
        literal: String,
        maxWidth: CGFloat,
        traits: UITraitCollection,
    ) -> NSTextAttachment {
        let font = font(for: traits)
        let picture = image(literal: literal, maxWidth: maxWidth, traits: traits)
        let attachment = NSTextAttachment()
        attachment.image = picture
        // The bounds are relative to the baseline: centre the capsule on the
        // line rather than sitting it on the baseline like a glyph.
        let height = picture.size.height
        let y = (font.ascender + font.descender) / 2 - height / 2
        attachment.bounds = CGRect(x: 0, y: y, width: picture.size.width, height: height)
        return attachment
    }

    /// The capsule, drawn.
    ///
    /// Exposed rather than private so a snapshot can pin the two appearances
    /// without a text view: the field itself is a `UIViewRepresentable`, which
    /// `ImageRenderer` does not render.
    static func image(
        literal: String,
        maxWidth: CGFloat,
        traits: UITraitCollection,
    ) -> UIImage {
        let font = font(for: traits)
        let height = ceil(font.lineHeight) + 4
        let limit = max(minimumWidth, maxWidth)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let natural = (literal as NSString).size(withAttributes: attributes).width
        let labelLimit = max(8, limit - padding * 2)
        let label: String
        let labelWidth: CGFloat
        if natural > labelLimit {
            label = truncated(literal, font: font, maxWidth: labelLimit)
            labelWidth = (label as NSString).size(withAttributes: attributes).width
        } else {
            label = literal
            labelWidth = natural
        }
        let size = CGSize(
            width: min(limit, max(minimumWidth, ceil(labelWidth) + padding * 2)),
            height: height,
        )

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = traits.displayScale
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            let background = Theme.accentUI.resolvedColor(with: traits)
            let ink = Theme.onAccentUI.resolvedColor(with: traits)
            let rect = CGRect(origin: .zero, size: size)
            background.setFill()
            UIBezierPath(roundedRect: rect, cornerRadius: height / 2).fill()

            let textAttributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink]
            let textSize = (label as NSString).size(withAttributes: textAttributes)
            (label as NSString).draw(
                at: CGPoint(x: padding, y: (height - textSize.height) / 2),
                withAttributes: textAttributes,
            )
        }
    }

    /// The longest prefix of `literal` whose capsule text fits, plus `…`.
    ///
    /// A binary search over prefixes rather than a loop: a long skill name is
    /// truncated on every width change, and a hundred measurements per pill on a
    /// rotation is not a cost worth paying for a picture.
    private static func truncated(_ literal: String, font: UIFont, maxWidth: CGFloat) -> String {
        let ellipsis = "…"
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        var low = 0
        var high = literal.count
        var best = 0
        while low <= high {
            let middle = (low + high) / 2
            let candidate = String(literal.prefix(middle)) + ellipsis
            if (candidate as NSString).size(withAttributes: attributes).width <= maxWidth {
                best = middle
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        return String(literal.prefix(best)) + ellipsis
    }
}

/// A pill, for the snapshot suite.
///
/// Renders the same bitmap the editor puts in the field, without a text view.
struct ComposerPillPreview: View {
    let literal: String
    var style: UIUserInterfaceStyle = .light
    var maxWidth: CGFloat = 260

    var body: some View {
        Image(uiImage: image)
            .resizable(resizingMode: .stretch)
            .frame(width: image.size.width, height: image.size.height)
            .accessibilityLabel(Text(verbatim: literal))
    }

    private var image: UIImage {
        let traits = UITraitCollection(traitsFrom: [
            UITraitCollection(displayScale: 2),
            UITraitCollection(userInterfaceStyle: style),
        ])
        return ComposerPill.image(literal: literal, maxWidth: maxWidth, traits: traits)
    }
}
