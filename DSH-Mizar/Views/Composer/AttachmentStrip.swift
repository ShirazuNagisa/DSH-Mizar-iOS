//
//  AttachmentStrip.swift
//  DSH-Mizar
//
//  The row of things about to be sent, above the composer's controls.
//
//  Shown only when there is something attached, so the composer is the same size
//  it has always been for the overwhelming majority of messages. Each chip is a
//  thumbnail (for images) or a labelled document (for files), a removal button,
//  and a thin progress bar while the host is receiving it — the upload happens
//  before the prompt is sent, and an operator watching three photos go up over a
//  mobile connection deserves to see which one is in flight.
//

import MizarKit
import SwiftUI

struct AttachmentStrip: View {
    /// What is attached.
    let drafts: [AttachmentDraft]
    /// Where upload progress is recorded, when an upload is running.
    var progress: AttachmentProgress?
    /// Remove one draft. The chip's button writes through this.
    var onRemove: (UUID) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(drafts) { draft in
                    chip(draft)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .scrollIndicators(.hidden)
        .accessibilityIdentifier("composer.attachment.strip")
    }

    /// One attachment.
    private func chip(_ draft: AttachmentDraft) -> some View {
        ZStack(alignment: .topTrailing) {
            content(draft)
                .frame(width: draft.isImage ? 58 : 148, height: 58)
                .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
                .overlay(alignment: .bottom) {
                    progressBar(draft)
                }

            Button {
                onRemove(draft.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.black.opacity(0.55))
            }
            .buttonStyle(.plain)
            .offset(x: 5, y: -5)
            .accessibilityLabel(String(format: String(localized: "Remove %@"), draft.shortLabel))
            .accessibilityIdentifier("composer.attachment.remove")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("composer.attachment")
    }

    /// The thumbnail or the document label.
    @ViewBuilder
    private func content(_ draft: AttachmentDraft) -> some View {
        if draft.isImage, let thumbnail = draft.thumbnail {
            Image(uiImage: thumbnail)
                .resizable()
                .scaledToFill()
                .accessibilityLabel(draft.shortLabel)
        } else {
            VStack(spacing: 4) {
                Image(systemName: draft.isImage ? "photo" : "doc")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Theme.accentText)
                Text(draft.shortLabel)
                    .font(.caption2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 6)
            }
            .frame(width: 148)
        }
    }

    /// A hairline of progress under a chip while it uploads.
    @ViewBuilder
    private func progressBar(_ draft: AttachmentDraft) -> some View {
        if let value = progress?.value(for: draft.id), value > 0, value < 1 {
            GeometryReader { geometry in
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: max(2, geometry.size.width * value))
            }
            .frame(height: 3)
            .padding(.horizontal, 4)
            .padding(.bottom, 4)
            .accessibilityHidden(true)
        }
    }
}
