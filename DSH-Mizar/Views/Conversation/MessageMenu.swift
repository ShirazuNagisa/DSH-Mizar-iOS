//
//  MessageMenu.swift
//  DSH-Mizar
//
//  The menu a held message opens: the bubble lifts, the screen dims behind it,
//  and two things can be done with the words -- copy them, or select them in
//  place.
//
//  The lift is arithmetic, not animation: where the bubble goes and how far it
//  shrinks is worked out once from its frame and the room the screen has, so the
//  menu and the copy land inside the container whatever the message's height.
//  That is why ``MessageMenuLayout`` is pure and tested without a screen.
//

import SwiftUI
import UIKit

// MARK: - What the menu is about

/// One held message, and where it was when it was held.
struct MessageMenuRequest: Equatable, Identifiable {
    let id: String
    let text: String
    let frame: CGRect
}

/// What a bubble may ask of the screen that hosts the menu.
///
/// A value in the environment rather than a callback threaded through the rows:
/// every user bubble reads it, and the rows are rebuilt while the page settles.
/// The closures are main-actor on purpose: they write the screen's own state,
/// and an environment default has to be safe to share.
struct MessageMenuPresenter {
    var open: (@MainActor (MessageMenuRequest) -> Void) = { _ in }
    var select: (@MainActor (String) -> Void) = { _ in }
}

// MARK: - Environment

/// How a bubble opens the menu, injected by the screen.
private struct MessageMenuPresenterKey: EnvironmentKey {
    static let defaultValue = MessageMenuPresenter()
}

/// The message whose menu is open, so its bubble can hide under the copy.
private struct MessageMenuActiveIdKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

/// The message being selected in place, if one is.
private struct SelectingMessageIdKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

/// Called when the operator is finished selecting.
private struct EndMessageSelectionKey: EnvironmentKey {
    static let defaultValue: @MainActor () -> Void = {}
}

extension EnvironmentValues {
    /// How a bubble opens the menu, injected by the screen.
    var messageMenuPresenter: MessageMenuPresenter {
        get { self[MessageMenuPresenterKey.self] }
        set { self[MessageMenuPresenterKey.self] = newValue }
    }

    /// The message whose menu is open, so its bubble can hide under the copy.
    var messageMenuActiveId: String? {
        get { self[MessageMenuActiveIdKey.self] }
        set { self[MessageMenuActiveIdKey.self] = newValue }
    }

    /// The message being selected in place, if one is.
    var selectingMessageId: String? {
        get { self[SelectingMessageIdKey.self] }
        set { self[SelectingMessageIdKey.self] = newValue }
    }

    /// Called when the operator is finished selecting.
    var endMessageSelection: @MainActor () -> Void {
        get { self[EndMessageSelectionKey.self] }
        set { self[EndMessageSelectionKey.self] = newValue }
    }
}

/// Where a bubble was last laid out, read once when it is held.
///
/// Not `@Observable` on purpose: a frame is written on every layout pass, and
/// nothing needs to redraw when it changes -- the same reasoning as
/// ``FlightFrames``.
final class MessageFrameBox {
    var frame: CGRect = .zero
}

// MARK: - Where everything goes

/// Which side of the bubble the menu sits on.
enum MessageMenuPlacement: Equatable {
    case above
    case below
}

/// Where the lifted bubble and its menu go, worked out once from the bubble's
/// frame and the room the screen has. Pure, so the arithmetic is tested
/// without a screen.
struct MessageMenuLayout: Equatable {
    var bubbleOrigin: CGPoint
    var scale: CGFloat
    var menuOrigin: CGPoint
    var placement: MessageMenuPlacement

    static let menuSize = CGSize(width: 248, height: 104)
    static let gap: CGFloat = 8
    static let margin: CGFloat = 12
    static let sideMargin: CGFloat = 16
    static let minimumScale: CGFloat = 0.2

    /// - Parameters:
    ///   - source: the bubble's frame, in the container's coordinates.
    ///   - container: the area the menu may use.
    ///   - menu: the menu's size.
    static func place(
        source: CGRect,
        container: CGRect,
        menu: CGSize = menuSize,
    ) -> MessageMenuLayout {
        let room = container.height - 2 * margin - menu.height - gap
        let scale = min(1, max(minimumScale, room / max(source.height, 1)))
        let height = source.height * scale
        let width = source.width * scale
        // The trailing edge stays where it was: the bubble shrinks towards
        // the side it is anchored to, the way it was laid out.
        let x = source.maxX - width
        let desired = source.midY - height / 2

        func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
            min(max(value, low), max(low, high))
        }

        let aboveY = clamp(
            desired,
            container.minY + margin + menu.height + gap,
            container.maxY - margin - height,
        )
        let belowY = clamp(
            desired,
            container.minY + margin,
            container.maxY - margin - menu.height - gap - height,
        )
        // Whichever side moves the bubble less; above wins a tie.
        let placement: MessageMenuPlacement =
            abs(aboveY - desired) <= abs(belowY - desired) ? .above : .below
        let y = placement == .above ? aboveY : belowY

        let menuX = clamp(
            source.maxX - menu.width,
            container.minX + sideMargin,
            container.maxX - sideMargin - menu.width,
        )
        let menuY = placement == .above ? y - gap - menu.height : y + height + gap

        return MessageMenuLayout(
            bubbleOrigin: CGPoint(x: x, y: y),
            scale: scale,
            menuOrigin: CGPoint(x: menuX, y: menuY),
            placement: placement,
        )
    }
}

// MARK: - The menu

/// The menu itself: two rows of glass. No environment, so a snapshot can own it.
struct MessageMenuCard: View {
    let onCopy: () -> Void
    let onSelect: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            row(
                symbol: "doc.on.doc",
                title: Text("Copy"),
                identifier: "message.menu.copy",
                action: onCopy,
            )
            row(
                symbol: "text.cursor",
                title: Text("Select Text"),
                identifier: "message.menu.select",
                action: onSelect,
            )
        }
        .padding(.vertical, 8)
        .frame(width: 248)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Theme.Radius.xl, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Message actions"))
        .accessibilityIdentifier("message.menu")
    }

    private func row(
        symbol: String,
        title: Text,
        identifier: String,
        action: @escaping () -> Void,
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .regular))
                    .frame(width: 24, height: 24)
                title
                    .font(.body)
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .padding(.leading, 22)
            .padding(.trailing, 16)
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.pressable(scale: 0.98, dims: true))
        .accessibilityIdentifier(identifier)
    }
}

// MARK: - The overlay

/// The dim, the lifted copy of the bubble, and the menu.
struct MessageMenuOverlay: View {
    let request: MessageMenuRequest
    let onCopy: () -> Void
    let onSelect: () -> Void
    let onDismiss: () -> Void

    @State private var presented = false

    var body: some View {
        GeometryReader { geo in
            let layout = MessageMenuLayout.place(
                source: request.frame,
                container: CGRect(origin: .zero, size: geo.size),
            )
            ZStack(alignment: .topLeading) {
                Theme.scrim
                    .ignoresSafeArea()
                    .opacity(presented ? 1 : 0)
                    .contentShape(.rect)
                    .onTapGesture { dismiss(then: onDismiss) }

                // The bubble, lifted and shrunk to the room the menu leaves.
                // It is the same look the conversation draws, so the eye reads
                // one bubble moving rather than two bubbles.
                SentBubbleBody(text: request.text)
                    .frame(width: request.frame.width, height: request.frame.height)
                    .scaleEffect(presented ? layout.scale : 1, anchor: .topLeading)
                    .offset(
                        x: presented ? layout.bubbleOrigin.x : request.frame.minX,
                        y: presented ? layout.bubbleOrigin.y : request.frame.minY,
                    )
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)

                if presented {
                    MessageMenuCard(
                        onCopy: {
                            UIPasteboard.general.string = request.text
                            dismiss(then: onCopy)
                        },
                        onSelect: { dismiss(then: onSelect) },
                    )
                    .offset(x: layout.menuOrigin.x, y: layout.menuOrigin.y)
                    .transition(
                        .messageMenu(
                            anchor: layout.placement == .above ? .bottomTrailing : .topTrailing,
                        ),
                    )
                }
            }
        }
        .onAppear {
            withMizarAnimation(.mizarMorphIn) { presented = true }
        }
    }

    private func dismiss(then: @escaping () -> Void) {
        withAnimation(Motion.pick(.mizarMorphOut)) {
            presented = false
        } completion: {
            then()
        }
    }
}

// MARK: - Coming and going

/// The menu growing out of the bubble it belongs to.
struct MessageMenuTransition: Transition {
    var anchor: UnitPoint

    func body(content: Content, phase: TransitionPhase) -> some View {
        MessageMenuEffect(identity: phase.isIdentity, anchor: anchor) { content }
    }
}

private struct MessageMenuEffect<Wrapped: View>: View {
    let identity: Bool
    let anchor: UnitPoint
    @ViewBuilder var wrapped: Wrapped
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        wrapped
            .opacity(identity ? 1 : 0)
            .scaleEffect(identity || reduceMotion ? 1 : 0.6, anchor: anchor)
            .blur(radius: identity || reduceMotion ? 0 : 6)
    }
}

extension Transition where Self == MessageMenuTransition {
    static func messageMenu(anchor: UnitPoint) -> Self {
        MessageMenuTransition(anchor: anchor)
    }
}
