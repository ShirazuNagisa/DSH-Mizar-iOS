//
//  Popover.swift
//  DSH-Mizar
//
//  Windows that grow out of what was tapped.
//
//  The rule for the whole app: a control opens a small window that comes out of
//  the control itself -- anchored to it, pointing back at it, sized to what it
//  holds -- the way the system's own menus and pickers do. Not a sheet that
//  takes the screen. A sheet says "you are somewhere else now"; a window out of
//  the button says "this is about the thing you just touched", and it can be
//  put away with a tap anywhere else.
//
//  On a phone SwiftUI turns a popover into a sheet unless told not to, which is
//  the one thing this file exists to say. Everything that opens from a tap goes
//  through here, so the rule is stated once and nobody can forget it.
//
//  The exceptions are the system's own surfaces -- the share sheet, a
//  confirmation the system draws -- and the one screen that is not opened by a
//  tap at all: the full-screen first download.
//

import SwiftUI

extension View {
    /// A small window out of this view, on every size class.
    ///
    /// - Parameters:
    ///   - isPresented: whether it is out.
    ///   - arrowEdge: the side of the window that points at this view, when it
    ///     matters; left to the system otherwise, which keeps it on screen.
    ///   - content: what it holds. Size it to its contents, or give it a
    ///     frame: a list in a popover has no height of its own.
    func mizarPopover<Content: View>(
        isPresented: Binding<Bool>,
        arrowEdge: Edge? = nil,
        @ViewBuilder content: @escaping () -> Content,
    ) -> some View {
        popover(isPresented: isPresented, arrowEdge: arrowEdge) {
            content()
                .presentationCompactAdaptation(.popover)
        }
    }

    /// The same, for a window about one item.
    func mizarPopover<Item: Identifiable, Content: View>(
        item: Binding<Item?>,
        arrowEdge: Edge? = nil,
        @ViewBuilder content: @escaping (Item) -> Content,
    ) -> some View {
        popover(item: item, arrowEdge: arrowEdge) { value in
            content(value)
                .presentationCompactAdaptation(.popover)
        }
    }
}

/// The sizes the app's windows come in, so a list in one is the same width as
/// a list in another.
enum PopoverSize {
    /// A short list or a form: a few rows.
    static let compact = CGSize(width: 320, height: 380)
    /// A list worth scrolling: the model picker, the computers.
    static let list = CGSize(width: 340, height: 480)
}

/// A small window's own header: a title and, when the window has something
/// worth confirming, the button that closes it.
///
/// For windows that have no navigation stack of their own -- most of them.
/// A popover is closed by tapping outside it, so the button is offered only
/// where leaving is a decision rather than a dismissal.
struct PopoverHeader<Trailing: View>: View {
    let title: LocalizedStringKey
    var systemImage: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.accentText)
            }
            Text(title)
                .font(.headline)
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 10)
    }
}

extension PopoverHeader where Trailing == EmptyView {
    init(title: LocalizedStringKey, systemImage: String? = nil) {
        self.title = title
        self.systemImage = systemImage
        trailing = EmptyView()
    }
}
