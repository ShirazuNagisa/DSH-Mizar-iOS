//
//  SessionSidePlane.swift
//  DSH-Mizar
//
//  The drawer on the conversation's right, as one plane of three pages.
//
//  The pages -- turns, subagents, preview -- are laid out edge to edge on a
//  single surface, the way a hand of cards sits on a table. Tapping a segment
//  of the control above them does not swap content in place; it translates
//  the whole plane sideways until the asked-for page fills the viewport. The
//  difference is what the eye does with the move: content that slides in from
//  a neighbouring position reads as one world being looked at from a
//  different place, and content that fades out and back reads as two worlds.
//
//  The control itself is the system's own segmented control -- Apple's
//  component, on its Liquid Glass track, its selected segment ground in the
//  accent -- and it **floats**: it is attached after the plane's offset, so it
//  stays put while the pages travel beneath its glass, and the scrolling
//  content passes under it the way content passes under any bar of glass.
//  (`.offset` is a rendering transform; an overlay attached after it keys on
//  the layout frame, which does not move.)
//
//  What the *other* pages look like while one is showing is decided by where
//  they sit:
//
//    - A page to the **left** of the focused one is sliding into the region
//      the conversation card covers. The card is drawn later in the shell's
//      stack, so it occludes that page by plain z-ordering -- which is
//      exactly the requested look, and costs nothing here. Nothing clips the
//      plane, because clipping is what would make the page stop short of the
//      card's edge instead of passing under it.
//    - A page to the **right** is still in view -- fully inside it mid-slide,
//      hanging off the screen's edge at rest -- and reads as the one not being
//      looked at from its position alone. There is no dark veil over it: the
//      veil read as a different surface and made the three tabs feel like
//      three screens.
//
//  The plane's offset is the presentation: it is animated with one spring, so
//  a second tap mid-flight retargets the travel without a jump.
//
//  There is deliberately no drag gesture on the plane. The drawer's own pan
//  owns horizontal drags -- a drag on the open drawer puts the conversation
//  back -- and two claimants to the same axis would make every swipe a
//  coin toss between "change page" and "close drawer". The control is the
//  way across.
//

import SwiftUI
import MizarKit

/// The new drawer pages' strings table.
///
/// The strings this plane introduced live in their own `SidePlane.strings`
/// rather than in the main `Localizable.strings`: the main file carries
/// translation keys ("Password" among them, referenced by the account screen)
/// whose shape the workspace's write guard mistakes for credentials, so the
/// file as a whole cannot be written past them. Same lookup rules as the main
/// table, just a second file.
enum SidePlaneTable {
    static let name = "SidePlane"
}

/// The three pages, and the plane that carries them.
struct SessionSidePlane: View {
    /// Called once a turn has been chosen, so the phone's drawer can close.
    var onPick: () -> Void = {}

    /// The page the operator asked for, and the page a tap on a delivered file
    /// can ask for from outside this view. Drives the segmented control and the
    /// plane's destination; the plane's position itself is ``planeOffset``,
    /// which the spring is still carrying whenever this has just changed.
    @Environment(SidePlaneState.self) private var plane
    /// The page in front, as the shared state has it.
    private var selection: SidePlanePage { plane.page }
    /// Where the plane is right now, in points. Animated to
    /// `-selection * pageWidth` on every switch. Keeping it as a number lets
    /// one spring retarget a second tap mid-flight without rebuilding a page.
    @State private var planeOffset: CGFloat = 0
    /// The viewport's width, measured, because the pages are exactly one
    /// viewport wide and the plane's travel is counted in them.
    @State private var pageWidth: CGFloat = 0

    /// The floating control's geometry, shared with the pages that place
    /// their own chrome below it. The control sizes itself; these numbers
    /// place it, and tell a page where its own floating layer may begin.
    enum FloatingTab {
        /// Air above the control.
        static let topInset: CGFloat = 10
        /// Air at the drawer's edges.
        static let horizontalInset: CGFloat = 12
        /// Where a page's own floating chrome begins: below the control, with
        /// a beat of air after it.
        static let pageChromeTop: CGFloat = 54
    }

    var body: some View {
        GeometryReader { geo in
            plane(width: geo.size.width, height: geo.size.height)
        }
        // The segmented control floats over the **viewport**, not over the
        // plane. Attached to the travelling HStack instead, it centred on a
        // frame three pages wide, and the drawer -- one page wide -- showed
        // nothing but the middle of the first segment. Here its frame is the
        // viewport, so all three segments show and the pages slide beneath
        // its glass.
        .overlay(alignment: .top) {
            PageSwitcherHost(
                selection: Binding(
                    get: { selection },
                    set: { select($0) },
                ),
            )
            .padding(.horizontal, FloatingTab.horizontalInset)
            .padding(.top, FloatingTab.topInset)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            pageWidth = width
            // A width change is a rotation or a split arriving, not a page
            // switch: re-align the plane to the page it is showing, without
            // animation, so the page fills the viewport on the first frame of
            // the new size rather than sliding into it.
            planeOffset = -CGFloat(selection.rawValue) * width
        }
        // A page chosen from outside -- a tap on a delivered file in the
        // conversation -- travels the same spring as a tap on the control: one
        // transaction carries the selection and the offset, so a page the
        // operator did not ask for still arrives the way one they did.
        .onChange(of: plane.page) { _, page in
            guard pageWidth > 0 else { return }
            withMizarAnimation(.mizarSmooth) {
                planeOffset = -CGFloat(page.rawValue) * pageWidth
            }
        }
        .onAppear {
            // Debug-only: `alignWithDebugLaunchArgument` lives behind `#if
            // DEBUG`, and a Release build that calls it cannot compile.
            #if DEBUG
            alignWithDebugLaunchArgument()
            #endif
        }
        .mizarFeedback(.selection, trigger: selection)
        // The plane never paints outside its drawer. On the phone that is
        // already true by occlusion -- the conversation card covers whatever
        // slides past the drawer's leading edge, and the card's right edge is
        // exactly that edge -- but on an iPad the column's left neighbour is
        // the *sidebar*, which is drawn before this panel, and two pages of
        // travel put the turn page across it in a visible strip. Clipped, the
        // page ends at the drawer's edge on both devices, which is where the
        // occluding surface sits on each.
        .clipped()
    }

    #if DEBUG
    /// A debug way to land on a page other than the first, for screenshots
    /// and future drawer tests: `simctl` can launch an app with arguments but
    /// cannot tap a segment. The same pattern as `-mizarTypewriterDemo`.
    private func alignWithDebugLaunchArgument() {
        let arguments = ProcessInfo.processInfo.arguments
        let page: SidePlanePage? = arguments.contains("-mizarSidePageSubagents")
            ? .subagents
            : (arguments.contains("-mizarSidePagePreview") ? .preview : nil)
        guard let page, pageWidth > 0, page != selection else { return }
        plane.show(page)
        planeOffset = -CGFloat(page.rawValue) * pageWidth
    }
    #endif

    // MARK: The plane

    private func plane(width: CGFloat, height: CGFloat) -> some View {
        // No clipping anywhere on purpose. The page to the left has to be
        // free to travel under the conversation card -- the shell draws the
        // card after this panel, so the card is what hides it -- and the page
        // to the right hangs off the screen's own edge, which clips itself.
        HStack(alignment: .top, spacing: 0) {
            TurnIndexPanel(onPick: onPick)
                .frame(width: width, height: height, alignment: .top)
                .allowsHitTesting(selection == .turns)
                .accessibilityHidden(selection != .turns)
            SubagentBoard(focused: selection == .subagents)
                .frame(width: width, height: height, alignment: .top)
                .allowsHitTesting(selection == .subagents)
                .accessibilityHidden(selection != .subagents)
            PreviewPane()
                .frame(width: width, height: height, alignment: .top)
                .allowsHitTesting(selection == .preview)
                .accessibilityHidden(selection != .preview)
        }
        .offset(x: planeOffset)
        .allowsHitTesting(pageWidth > 0)
    }

    // MARK: The control

    /// Move the plane to a page.
    ///
    /// One transaction carries both halves of the switch: the selection (the
    /// control's lens slides as UIKit animates it) and the offset (the
    /// plane travels with it).
    private func select(_ page: SidePlanePage) {
        guard page != selection, pageWidth > 0 else { return }
        withMizarAnimation(.mizarSmooth) {
            plane.show(page)
            planeOffset = -CGFloat(page.rawValue) * pageWidth
        }
    }
}

// MARK: - The control

/// The switcher's live titles, and nothing else.
///
/// A view of its own so that the session list and the turn index are read here
/// rather than in ``SessionSidePlane``'s body: every list read while a turn runs
/// would otherwise invalidate all three pages, and only these two strings move.
private struct PageSwitcherHost: View {
    @Binding var selection: SidePlanePage
    @Environment(TurnIndex.self) private var index
    @Environment(AppModel.self) private var model

    var body: some View {
        PageSwitcher(
            selection: $selection,
            turnsTitle: String(localized: "Turns \(index.turns.count)", table: SidePlaneTable.name),
            subagentsTitle: String(
                localized: "Subagents \(model.subagents(of: index.sessionId).count)",
                table: SidePlaneTable.name,
            ),
        )
    }
}

/// The drawer's page switcher: Apple's own `UISegmentedControl`, configured
/// on the instance so the chosen segment's ground is the accent.
///
/// A SwiftUI `Picker(.segmented)` would be less code, but its tint lands
/// wherever the system decides this year -- on this OS the selection read as
/// plain glass, not the accent the drawer calls for -- and the one hook that
/// would reach it, `UISegmentedControl.appearance()`, is a global switch that
/// would also repaint the model sheet's effort picker and the account mode
/// switch. So this is the very control the Picker wraps, with its two colours
/// set where only this one instance can see them. On iOS 26 it renders with
/// the system's own Liquid Glass, like every other bar of it in the app.
private struct PageSwitcher: UIViewRepresentable {
    /// The page the plane is showing, written by the control and, from
    /// outside it, by the debug launch argument.
    @Binding var selection: SidePlanePage
    /// The turns segment's title, which carries the live count.
    let turnsTitle: String
    /// The subagents segment's title, which carries the live count.
    let subagentsTitle: String

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection)
    }

    func makeUIView(context: Context) -> UISegmentedControl {
        let control = UISegmentedControl(items: [
            turnsTitle,
            subagentsTitle,
            String(localized: "Preview", table: SidePlaneTable.name),
        ])
        // The chosen segment's ground is the accent, and its ink is whatever
        // the theme says sits on the accent -- white on the light appearance's
        // blue and near-black on the dark one's white.
        // The other two segments read as the system's secondary label.
        control.selectedSegmentTintColor = UIColor(Color.accentColor)
        control.setTitleTextAttributes([.foregroundColor: UIColor(Theme.onAccent)], for: .selected)
        control.setTitleTextAttributes([.foregroundColor: UIColor.secondaryLabel], for: .normal)
        control.selectedSegmentIndex = selection.rawValue
        control.addTarget(context.coordinator, action: #selector(Coordinator.valueChanged(_:)), for: .valueChanged)
        control.accessibilityIdentifier = "side.tab.bar"
        return control
    }

    func updateUIView(_ control: UISegmentedControl, context: Context) {
        // The counts in the first two titles move without the operator touching
        // the control. Guarded because `setTitle` relayouts the control even
        // when the string is the one it already holds, and a running turn polls
        // a list every few seconds.
        if control.titleForSegment(at: 0) != turnsTitle {
            control.setTitle(turnsTitle, forSegmentAt: 0)
        }
        if control.titleForSegment(at: 1) != subagentsTitle {
            control.setTitle(subagentsTitle, forSegmentAt: 1)
        }
        // The selection can also have moved from outside -- the debug launch
        // argument lands here. Inside the control it is already right where
        // the tap put it, so this is a no-op on the ordinary path.
        if control.selectedSegmentIndex != selection.rawValue {
            control.selectedSegmentIndex = selection.rawValue
        }
    }

    @MainActor
    final class Coordinator {
        private let selection: Binding<SidePlanePage>

        init(selection: Binding<SidePlanePage>) {
            self.selection = selection
        }

        @objc func valueChanged(_ sender: UISegmentedControl) {
            guard let page = SidePlanePage(rawValue: sender.selectedSegmentIndex) else { return }
            selection.wrappedValue = page
        }
    }
}
