//
//  PreviewPane.swift
//  DSH-Mizar
//
//  The drawer's third page: the file the model delivered, drawn.
//
//  It is a page of the plane rather than a window of its own, so everything here
//  is inside a column a few hundred points wide and one screen tall. The header
//  says which file this is; below it the body is one of five states — nothing
//  yet, reading, a viewer, "no viewer for this", or a sentence about what went
//  wrong.
//
//  The page remembers per conversation, and the remembering lives in
//  ``PreviewCenter``: the drawer outlives the conversation in front of it, so the
//  question "what was I looking at here" cannot be answered by view state.
//

import MizarKit
import SwiftUI

struct PreviewPane: View {
    @Environment(PreviewCenter.self) private var preview
    @Environment(AppModel.self) private var model
    /// The account screen, offered by the locked state to a free account.
    @State private var showingPaywall = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Below the floating segmented control, in the space the eye reads as
        // this page's own.
        .padding(.top, SessionSidePlane.FloatingTab.pageChromeTop)
        // The file belongs to the conversation, so a change of conversation is
        // what changes the page. Idempotent: a page already showing this
        // session's file does nothing.
        .task(id: model.selectedSessionId) {
            await preview.restore(sessionId: model.selectedSessionId)
        }
        // No identifier on this container: SwiftUI propagates a container's
        // accessibility identifier to every element below it, which would
        // replace the viewers' own `preview.code` / `preview.image` /
        // `preview.markdown` identifiers with one name for the whole page.
    }

    // MARK: - Header

    /// Which file this is, when there is one.
    @ViewBuilder
    private var header: some View {
        if let target = preview.current {
            HStack(alignment: .center, spacing: 10) {
                DeliveredFileIcon(kind: target.kind, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(target.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let detail = target.detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("preview.header")
        }
    }

    // MARK: - Body

    @ViewBuilder
    private var content: some View {
        // The policy is drawn rather than hidden behind a dead tap: whatever
        // route the phone is on, the page itself says why the preview is not
        // running and what changes it. Same instinct as the composer's locked
        // attachments -- a refusal that only no-ops is a bug report.
        if !model.previewUnlocked {
            locked
        } else {
            switch preview.state {
            case .empty:
                message(
                    symbol: "eye",
                    title: String(localized: "No preview yet"),
                    detail: String(localized: "Nothing yet. Files the model delivers will be previewed here."),
                    identifier: "preview.empty",
                )

            case .loading(let progress):
                loading(progress)

            case .ready(let url, let unconfirmed):
                viewer(url: url, kind: preview.current?.kind ?? .other)
                    .overlay(alignment: .bottom) {
                        // Only when the copy is old: a preview read from the computer
                        // just now has nothing to explain.
                        if unconfirmed {
                            Text("Saved copy — shown without asking the computer")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .liquidCapsule(interactive: false)
                                .padding(.bottom, 10)
                                .accessibilityIdentifier("preview.cachedNote")
                        }
                    }

            case .unsupported:
                message(
                    symbol: "doc.questionmark",
                    title: preview.current?.name ?? String(localized: "This file"),
                    detail: String(localized: "This kind of file cannot be previewed yet. It can still be opened on the computer."),
                    identifier: "preview.unsupported",
                )

            case .failed(let reason):
                failure(reason)
            }
        }
    }

    @ViewBuilder
    private func viewer(url: URL, kind: PreviewKind) -> some View {
        switch kind {
        case .markdown:
            MarkdownPreview(url: url)
        case .pdf:
            PDFPreview(url: url)
        case .word:
            DocumentPreview(url: url)
        case .source:
            SourcePreview(url: url)
        case .image:
            ImagePreview(url: url)
        case .other:
            // Unreachable: a file with no viewer never reaches `ready`. Kept
            // exhaustive so a new kind is a compile error here rather than a
            // blank page.
            message(
                symbol: "doc",
                title: preview.current?.name ?? "",
                detail: String(localized: "This kind of file cannot be previewed yet."),
                identifier: "preview.unsupported",
            )
        }
    }

    // MARK: - States

    private func loading(_ progress: Double?) -> some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.regular)
            Text("Reading from the computer…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let progress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 180)
                Text(progress, format: .percent.precision(.fractionLength(0)))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .accessibilityIdentifier("preview.loading")
    }

    private func failure(_ reason: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title3)
                .foregroundStyle(Theme.waiting)
            Text(reason)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)
            Button("Try again") { preview.retry() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(Theme.accentText)
                .accessibilityIdentifier("preview.retry")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .accessibilityIdentifier("preview.failed")
    }

    /// The locked-out state: which door is closed, and how to open it.
    ///
    /// Two different closures for two different reasons. A plan is a purchase,
    /// so that one offers the account screen the composer's locked attachments
    /// offer. The punched path is not a purchase at all -- the operator already
    /// chose it in Settings -- so its sentence names the switch that changes it
    /// instead of a shop that cannot.
    @ViewBuilder
    private var locked: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock")
                .font(.title3)
                .foregroundStyle(.tertiary)
            if !model.advancedFeaturesUnlocked {
                Text("This preview needs a paid account")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text("Files are read off the computer and through the relay, which is part of the paid plan. On a local network link, preview is free for every account.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 24)
                Button {
                    showingPaywall = true
                } label: {
                    Text("See the account")
                        .foregroundStyle(Theme.onAccent)
                }
                .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .accessibilityIdentifier("preview.locked.account")
            } else {
                Text("Preview is not available over P2P direct")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text("P2P direct connections do not carry file previews yet. Turn P2P direct off in Settings → Transfer, or connect over the local network or the relay.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .accessibilityIdentifier("preview.locked")
        .sheet(isPresented: $showingPaywall) {
            NavigationStack {
                AccountScreen()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showingPaywall = false }
                        }
                    }
            }
        }
    }

    private func message(
        symbol: String,
        title: String,
        detail: String,
        identifier: String,
    ) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .accessibilityIdentifier(identifier)
    }
}

// MARK: - The icon

/// The file's badge: a document with its kind on it.
///
/// The same shape the composer's attachment chip uses, so a file looks like a
/// file wherever it appears in the app.
struct DeliveredFileIcon: View {
    let kind: PreviewKind
    var size: CGFloat = 30

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(Color.accentColor.opacity(0.14))
            Image(systemName: symbol)
                .font(.system(size: size * 0.52, weight: .regular))
                .foregroundStyle(Theme.accentText)
            Text(kind.badge)
                .font(.system(size: size * 0.24, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.onAccent)
                .padding(.horizontal, size * 0.1)
                .padding(.vertical, size * 0.03)
                .background(Color.accentColor, in: Capsule())
                .offset(y: size * 0.26)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    /// An image gets the photo glyph; everything else keeps the page.
    private var symbol: String {
        switch kind {
        case .image: "photo.fill"
        default: "doc.fill"
        }
    }
}
