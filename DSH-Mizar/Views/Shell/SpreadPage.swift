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

/// How much of the conversation is behind the reader.
///
/// The spine's one number, as a pure function of the scroll view's own
/// geometry, so it can be pinned without a running conversation.
///
/// The first attempt asked `TurnIndex.visible`, which turned out not to answer
/// the question at all: `onScrollVisibilityChange` only fires when visibility
/// *changes*, and the rows' first `setVisible` can land before `publish` has
/// given the index its session -- the fence then drops it. Measured on the Duo
/// spread, ten seconds after launch: `turns=4 visible=0 realized=4`. The scroll
/// offset is always there, so it is the one that is used.
enum ReadingProgress {
    /// - Parameters:
    ///   - contentHeight: the scroll content, insets included.
    ///   - viewportHeight: the part of it on screen.
    ///   - visibleMinY: the top of the viewport, in content coordinates.
    ///   - topInset: the content's own top inset, so 0 means the first line.
    static func fraction(
        contentHeight: CGFloat,
        viewportHeight: CGFloat,
        visibleMinY: CGFloat,
        topInset: CGFloat,
    ) -> Double {
        let scrollable = contentHeight - viewportHeight
        guard scrollable > 1 else { return 1 }
        let travelled = visibleMinY + topInset
        return min(1, max(0, Double(travelled / scrollable)))
    }
}

/// The valley: a hairline, a handle, and the tap that turns the page.
///
/// `available` is false on the home screen, where there is no conversation for
/// a second page to keep company: the valley is then simply empty, and the
/// handle does not invite a page that has nothing to show.
///
/// `progress` is how far through the conversation the operator has read, as a
/// fraction of the turns. It is the one number the spine carries: a book's
/// spine tells you how thick the book is as you hold it, and this one tells you
/// how much of it is behind you. It moves only when a turn scrolls past -- the
/// truth is turn-granular -- and it *travels* to the new fraction rather than
/// jumping, so the seam never flicks.
struct SpreadSpine: View {
    let available: Bool
    let open: Bool
    let progress: Double
    let toggle: () -> Void

    /// The track's own span, as fractions of the page height: the hinge runs
    /// from just under the bar to just above the home indicator.
    private static let top: CGFloat = 0.07
    private static let bottom: CGFloat = 0.07
    /// How long the bookmark is: long enough to find, short enough to be a mark.
    private static let bookmark: CGFloat = 34

    var body: some View {
        Button(action: toggle) {
            GeometryReader { geometry in
                let height = geometry.size.height
                let track = height * (1 - Self.top - Self.bottom)
                ZStack(alignment: .top) {
                    Rectangle()
                        .fill(Color.primary.opacity(available ? 0.05 : 0))
                        .frame(width: 1, height: track)
                        .offset(y: height * Self.top)
                    // The handle: the only thing here that says "press me".
                    // Shorter when the page is out, because then it is a seam
                    // and not an invitation.
                    Capsule()
                        .fill(Color.primary.opacity(open ? 0.14 : 0.22))
                        .frame(width: 3.5, height: open ? 22 : 30)
                        .offset(y: (height - (open ? 22 : 30)) / 2)
                    // Where the page is open: a bookmark, not a gauge.
                    //
                    // A fill that grew to the whole spine was the first
                    // attempt, and at the end of a conversation it read as
                    // "100% complete" -- a progress bar wearing a book's
                    // clothes, and a lie about a conversation that was just
                    // opened. A mark that *moves* says the one true thing: you
                    // are here. It is also the quieter of the two.
                    Capsule()
                        .fill(Color.accentColor.opacity(available ? 0.45 : 0))
                        .frame(width: 2, height: Self.bookmark)
                        // Just beside the seam rather than on it: the handle
                        // lives at the middle, and a ribbon that stuck out of
                        // the fold would not sit on top of the grip that opens
                        // the page.
                        .offset(
                            x: 5,
                            y: height * Self.top + (track - Self.bookmark) * min(1, max(0, progress)),
                        )
                }
                .frame(width: geometry.size.width, height: height, alignment: .top)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .animation(Motion.pick(.mizarSmooth), value: open)
        .animation(Motion.pick(.mizarGentle), value: progress)
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
