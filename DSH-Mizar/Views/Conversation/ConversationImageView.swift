//
//  ConversationImageView.swift
//  DSH-Mizar
//
//  A picture inside an answer.
//
//  The desktop draws a standalone Markdown image as an inline preview and opens
//  a lightbox when it is tapped; this is the same promise on a phone. What the
//  message carries is a path (see `MizarKit.ConversationImage`), so the row asks
//  the store for the bytes, keeps the answer in its own state, and says one
//  sentence when the picture cannot be had -- a failure here is a fact about the
//  computer, not an error in the conversation, and it must not take the answer
//  down with it.
//
//  Two things are deliberately *not* done. The picture is not height-capped: the
//  desktop draws it at the column's width whatever its height, and a transcript
//  that silently cropped a screenshot would be lying about what the model showed.
//  And the alt text is not printed under a picture that loaded: it is what the
//  model wrote the picture *for*, so it is the caption when the picture fails
//  and the VoiceOver label when it does not.
//

import MizarKit
import SwiftUI
import UIKit

// MARK: - Environment

/// The store a conversation's pictures are read through.
private struct ConversationImagesKey: EnvironmentKey {
    static let defaultValue: ConversationImageStore? = nil
}

/// The session a turn belongs to, so a relative path can be resolved.
private struct ConversationSessionKey: EnvironmentKey {
    static let defaultValue: String = ""
}

extension EnvironmentValues {
    /// The picture store, when this screen has one.
    var conversationImages: ConversationImageStore? {
        get { self[ConversationImagesKey.self] }
        set { self[ConversationImagesKey.self] = newValue }
    }

    /// The session whose workspace this turn's paths are relative to.
    var conversationSessionId: String {
        get { self[ConversationSessionKey.self] }
        set { self[ConversationSessionKey.self] = newValue }
    }
}

// MARK: - The row

/// One picture, drawn where the model put it.
struct ConversationImageView: View {
    /// The path and the caption the message wrote.
    let target: ConversationImageTarget

    @Environment(\.conversationImages) private var store
    @Environment(\.conversationSessionId) private var sessionId
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: ConversationImagePhase = .idle
    @State private var showingLightbox = false

    var body: some View {
        Group {
            switch phase {
            case .loaded(let picture):
                pictureButton(picture)
            case .failed(let failure):
                failureCard(failure)
            case .idle, .loading:
                placeholder
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: target) { await load() }
        .fullScreenCover(isPresented: $showingLightbox) {
            if case .loaded(let picture) = phase {
                ConversationImageLightbox(picture: picture)
            }
        }
    }

    /// The tallest a picture is drawn inline.
    ///
    /// About one and a third screens of an ordinary phone; anything past it is
    /// centred and smaller, and one tap puts it full screen.
    private static let maximumHeight: CGFloat = 460

    // MARK: States

    private func pictureButton(_ picture: ConversationImageStore.Picture) -> some View {
        Button {
            showingLightbox = true
        } label: {
            Image(uiImage: picture.image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(maxWidth: .infinity)
                // A picture taller than this is drawn whole but smaller, and
                // centred: a portrait screenshot at the column's width is two
                // phone screens of one answer, which stops the conversation dead.
                // The desktop has the same picture at a column twice as wide and
                // twice as tall, so this is the phone's version of the same rule
                // -- never a crop, because a cropped screenshot lies about what
                // the model showed.
                .frame(maxHeight: Self.maximumHeight)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                        .strokeBorder(.quaternary, lineWidth: 0.5)
                }
                .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("conversation.image")
        .accessibilityLabel(Text(picture.alt ?? picture.name))
        .accessibilityHint(Text("Opens it full screen"))
        .transition(.opacity)
    }

    /// The box that holds the place of a picture still arriving.
    ///
    /// A fixed height, not the picture's: the height is a fact about the bytes,
    /// and the bytes are what is missing. One hundred and sixty points is about
    /// what a screenshot in a phone column comes out at, so the row settles
    /// rather than jumping when the real one lands.
    private var placeholder: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
            .fill(Color.primary.opacity(0.06))
            .frame(maxWidth: .infinity)
            .frame(height: 160)
            .overlay {
                Image(systemName: "photo")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(.tertiary)
            }
            .shimmering(active: !reduceMotion)
            .accessibilityIdentifier("conversation.image.loading")
            .accessibilityLabel(Text("Loading the picture…"))
    }

    private func failureCard(_ failure: ConversationImageFailure) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.sm) {
            Image(systemName: "photo.badge.exclamationmark")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.sentence(for: failure))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let alt = target.alt {
                    Text(alt)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        }
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 0.5)
        }
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .onTapGesture { retry() }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("conversation.image.failed")
        .accessibilityLabel(Text(Self.sentence(for: failure)))
        .accessibilityHint(Text("Tapping tries again"))
    }

    // MARK: Loading

    private func load() async {
        guard let store else {
            phase = .failed(.offline)
            return
        }
        if case .loaded = phase { return }
        if case .idle = phase { phase = .loading }
        let result = await store.picture(sessionId: sessionId, target: target)
        // Written even when this task was cancelled: a cancellation here means
        // the row was rebuilt, and the rebuild's own load reads the same answer
        // from the store. Returning early is what left the placeholder on
        // screen for ever.
        switch result {
        case .success(let picture):
            withMizarAnimation(.mizarSmooth) { phase = .loaded(picture) }
            openLightboxIfTheTourAsked()
        case .failure(let failure):
            phase = .failed(failure)
        }
    }

    /// Open the lightbox on launch, for the screenshot tour.
    ///
    /// The drawer has the same kind of hook (`-mizarOpenTurnIndex`,
    /// `-mizarSidePagePreview`): a gesture is not something `simctl` can make, and
    /// a state nobody can photograph is a state nobody reviews. Debug-only, and
    /// it does nothing unless the tour passes the flag.
    private func openLightboxIfTheTourAsked() {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("-mizarOpenImageLightbox") else { return }
        guard !showingLightbox else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            showingLightbox = true
        }
        #endif
    }

    private func retry() {
        guard let store else { return }
        store.forget(sessionId: sessionId, target: target)
        phase = .loading
        Task { await load() }
    }

    // MARK: Wording

    /// One sentence about why there is no picture.
    ///
    /// - Parameter failure: what went wrong.
    /// - Returns: the sentence to draw.
    static func sentence(for failure: ConversationImageFailure) -> String {
        switch failure {
        case .missing:
            String(localized: "The picture is no longer on the computer.")
        case .forbidden:
            String(localized: "The picture is outside the session's working folder.")
        case .tooLarge:
            String(localized: "The picture is larger than 12 MB, so it is not shown here.")
        case .oldPlugin:
            String(localized: "This computer's Mizar plugin is too old to send pictures.")
        case .locked:
            String(localized: "Showing pictures needs a local network link or the paid plan.")
        case .offline:
            String(localized: "The computer is not connected.")
        case .notAnImage:
            String(localized: "This file is not a picture this app can show.")
        case .unreadable:
            String(localized: "This picture could not be read.")
        }
    }
}

// MARK: - The lightbox

/// The picture, whole, over the page.
///
/// A photo viewer's gestures, and nothing else: pinch or double-tap to zoom, drag
/// to move when zoomed, drag down to close when not, and a close button for
/// anybody who does not want to discover a gesture. It opens at fit, never at
/// the crop the row might have implied, because "full screen" is where a picture
/// stops being a preview of itself.
struct ConversationImageLightbox: View {
    let picture: ConversationImageStore.Picture

    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @State private var committedScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var committedOffset: CGSize = .zero
    @State private var dragDismiss: CGFloat = 0

    private var isZoomed: Bool { scale > 1.01 }

    var body: some View {
        ZStack {
            Color.black.opacity(0.97 - dragDismiss / 2400)
                .ignoresSafeArea()

            Image(uiImage: picture.image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .scaleEffect(scale)
                .offset(x: offset.width, y: offset.height + dragDismiss)
                .gesture(zoom)
                .simultaneousGesture(pan)
                .onTapGesture(count: 2) { toggleZoom() }
                .accessibilityIdentifier("conversation.image.lightbox")
                .accessibilityLabel(Text(picture.alt ?? picture.name))

            VStack {
                HStack {
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                            .background(.white.opacity(0.14), in: Circle())
                    }
                    .accessibilityIdentifier("conversation.image.close")
                    .accessibilityLabel(Text("Close"))
                }
                .padding(Theme.Space.lg)
                Spacer()
                VStack(spacing: 2) {
                    if let alt = picture.alt {
                        Text(alt)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.white.opacity(0.92))
                    }
                    Text(verbatim: "\(Int(picture.pixelSize.width)) × \(Int(picture.pixelSize.height))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.55))
                }
                .multilineTextAlignment(.center)
                .padding(.horizontal, Theme.Space.xl)
                .padding(.bottom, Theme.Space.xl)
            }
        }
        .statusBarHidden()
    }

    // MARK: Gestures

    private var zoom: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                scale = min(4, max(1, committedScale * value.magnification))
            }
            .onEnded { _ in
                committedScale = scale
                if !isZoomed { resetPan() }
            }
    }

    private var pan: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                if isZoomed {
                    offset = CGSize(
                        width: committedOffset.width + value.translation.width,
                        height: committedOffset.height + value.translation.height,
                    )
                } else {
                    // Dragging a picture that fits means "put it away", and the
                    // downward distance is what says so. Upward is ignored: it
                    // would fight the scroll the page no longer has.
                    dragDismiss = max(0, value.translation.height)
                }
            }
            .onEnded { value in
                if isZoomed {
                    committedOffset = offset
                } else if value.translation.height > 120 || value.predictedEndTranslation.height > 260 {
                    dismiss()
                } else {
                    withMizarAnimation(.mizarSmooth) { dragDismiss = 0 }
                }
            }
    }

    private func toggleZoom() {
        withMizarAnimation(.mizarSmooth) {
            if isZoomed {
                scale = 1
                committedScale = 1
                resetPan()
            } else {
                scale = 2.5
                committedScale = 2.5
            }
        }
    }

    private func resetPan() {
        offset = .zero
        committedOffset = .zero
    }
}
