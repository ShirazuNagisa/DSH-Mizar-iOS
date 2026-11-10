//
//  SpreadPage.swift
//  DSH-Mizar
//
//  The second page of a spread, and the spine that opens it.
//
//  A spread is the app's own two-pane structure laid on the hardware's: the
//  conversation on the left page, the plane of turns, subagents and preview on
//  the right. The gutter between them is not a divider the app draws -- it is
//  the valley the hinge leaves, with one hairline in it that carries the
//  conversation's progress, and a handle at its middle that opens and closes
//  the page beside it.
//
//  Why the valley is also the control: the hinge is the one strip on the
//  display that no content may occupy, so it is the one strip where a gesture
//  can never be mistaken for a tap on something else. Making it the handle
//  costs nothing and needs no chrome: the fold already told the operator where
//  the middle of the book is.
//

import SwiftUI

/// The right-hand page: the plane, and its quiet surface.
struct SpreadPage: View {
    let content: AnyView

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            // The plane's own drawer surface, so a page of the book is the same
            // material it is when it slides in from the edge on a phone.
            .background(Theme.sidebarBackground)
    }
}

/// The plane as the container mounts it.
///
/// On a phone it is the drawer that slides out from the right; on an iPad it is
/// the pinned column. On a spread it is neither -- the second page mounts it --
/// and mounting it twice would be two lists of the same turns, two preview
/// readers, two of everything. This view is the one that knows to step aside.
struct ContainerPlane: View {
    @Environment(ShellState.self) private var shell

    var body: some View {
        if shell.fold == .spread {
            EmptyView()
        } else {
            SessionSidePlane(onPick: {})
        }
    }
}

/// The valley: a hairline, a handle, and the tap that turns the page.
///
/// `available` is false on the home screen, where there is no conversation for
/// a second page to keep company: the valley is then simply empty, and the
/// handle does not invite a page that has nothing to show.
struct SpreadSpine: View {
    let available: Bool
    let open: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            ZStack {
                // The one element allowed to touch the seam. Low enough in
                // contrast to read as the hinge's own shadow rather than as a
                // line the interface drew to divide itself.
                Rectangle()
                    .fill(Color.primary.opacity(available ? 0.05 : 0))
                    .frame(width: 1)
                    .frame(maxHeight: .infinity)
                    .padding(.vertical, 64)
                // The handle: the only thing here that says "press me". Shorter
                // when the page is out, because then it is a seam and not an
                // invitation.
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    Capsule()
                        .fill(Color.primary.opacity(open ? 0.14 : 0.22))
                        .frame(width: 3.5, height: open ? 22 : 30)
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .animation(Motion.pick(.mizarSmooth), value: open)
        .opacity(available ? 1 : 0)
        .allowsHitTesting(available)
        .accessibilityLabel(Text(open ? "Hide turns" : "Show turns"))
        .accessibilityIdentifier("shell.spreadSpine")
    }
}

/// The toolbar's way to the second page, for the operator who has not yet
/// noticed that the gutter is a handle.
struct SpreadPageToggle: View {
    @Environment(ShellState.self) private var shell

    var body: some View {
        Button {
            shell.toggleTrailing(compact: true)
        } label: {
            Image(systemName: shell.spreadPlaneOpen ? "sidebar.right" : "rectangle.split.2x1")
                .font(.system(size: 16, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 28, height: 24)
                .contentShape(.rect)
        }
        .accessibilityLabel(Text(shell.spreadPlaneOpen ? "Hide turns" : "Show turns"))
        .accessibilityIdentifier("shell.spreadPageToggle")
    }
}
