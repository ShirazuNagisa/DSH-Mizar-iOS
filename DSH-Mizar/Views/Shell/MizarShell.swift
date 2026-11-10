//
//  MizarShell.swift
//  DSH-Mizar
//
//  The app, once a computer is paired: the workspaces on the left, the
//  conversation, and the conversation's plane of pages on the right -- its
//  turns, the subagents it has delegated to, and a preview page still to come.
//
//  On a phone the conversation is the screen and the two drawers are under it.
//  Drag the conversation to the right, or tap the button at the top left, and
//  the workspace sidebar comes out while the conversation steps aside as a card:
//  it follows the finger, shrinks a little, takes on the display's rounded
//  corners and dims, and a tap on it brings it back. Drag it to the left, or tap
//  its title, and the same thing happens in the mirror: the turn index comes out
//  on the right. On an iPad both are columns -- the sidebar beside the
//  conversation, the index beside it on the other side -- each slid away and
//  back with its own button.
//
//  Both drawers and the conversation stay mounted the whole time, each in a
//  hosting controller of its own inside a UIKit container
//  (`DrawerContainer.swift`), and only Core Animation moves them. Nothing here
//  follows the drag: a SwiftUI value that changed on every frame re-rendered the
//  whole tree under it, and held the drawers to 60 Hz.
//

import SwiftUI
import UIKit
import MizarKit

struct MizarShell: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase
    @State private var shell = ShellState()
    @State private var turnIndex = TurnIndex()
    /// Which of the drawer's three pages is in front, shared with the
    /// conversation so a tap on a delivered file can turn the plane.
    @State private var sidePlane = SidePlaneState()
    /// What the preview page is showing, and the cache behind it.
    @State private var preview = PreviewCenter()
    /// What the three layers read that changes after they are made.
    @State private var layers = ShellLayerContext()
    /// The layers' roots, made once. Setting a hosting controller's root view
    /// re-renders its whole tree, so they are never set again: everything that
    /// changes reaches them through observation.
    @State private var roots: ShellLayerRoots?
    @State private var placed = false
    /// Whether a conversation has been on screen since launch.
    ///
    /// The drawer opens when a selection goes away, but a launch has no
    /// selection to lose: the first `nil` is the app starting, not somebody
    /// leaving a conversation.
    @State private var hasOpenedASession = false
    #if DEBUG
    /// A debug launch asked for the right drawer; it is opened once a session
    /// has arrived to show in it, since the drawer's own close rides the same
    /// selection change.
    @State private var debugOpenTrailingWanted = false
    #endif

    var body: some View {
        GeometryReader { geometry in
            let insets = geometry.safeAreaInsets
            let size = CGSize(
                width: geometry.size.width + insets.leading + insets.trailing,
                height: geometry.size.height + insets.top + insets.bottom,
            )
            // The window as pages (see `FoldLayout`). A spread is the cover
            // display's width twice with the hinge's valley between them, so
            // unfolding adds a page rather than reflowing the one being read:
            // the same fact that makes "no black bars" and "the fold means
            // something" the same design instead of two.
            let fold = FoldLayout(
                size: size,
                widthClass: sizeClass,
                idiom: UIDevice.current.userInterfaceIdiom,
            )
            let compact = fold.shape != .columns
            let leading = sidebarWidth(in: size, compact: compact)
            let trailing = indexWidth(in: size, compact: compact)
            // The second page: out only when there is a conversation for it to
            // keep company, and only while the operator has not folded it away.
            let secondPage = fold.isSpread
                && shell.spreadPlaneOpen
                && model.selectedSessionId != nil
            // The card is the whole screen, under the status bar and the home
            // indicator. The reader itself stays inside the safe area so it can
            // say how big the screen is; each layer's hosting controller takes
            // its own safe area, and the keyboard's, from the window.
            ZStack(alignment: .top) {
                // One surface under both pages. The valley is this showing
                // through, not a bar drawn where the hinge is -- a book's
                // gutter is the absence of a page, not a line on one.
                Theme.paneBackground
                    .ignoresSafeArea()
                DrawerContainer(
                    shell: shell,
                    compact: compact,
                    leadingWidth: leading,
                    // A spread has no drawer on the right: the plane lives on
                    // the second page, pinned, and the spine is what opens it.
                    trailingWidth: fold.isSpread ? 0 : trailing,
                    pinnedVisible: shell.pinnedVisible,
                    indexColumnShown: indexColumnShown,
                    roots: roots ?? makeRoots(),
                    layers: layers,
                )
                .frame(width: fold.leftPage.width, height: size.height)
                .frame(maxWidth: .infinity, alignment: fold.isSpread ? .leading : .center)
                .ignoresSafeArea()
                .onChange(of: leading, initial: true) { _, width in shell.leadingWidth = width }
                .onChange(of: trailing, initial: true) { _, width in shell.trailingWidth = width }
                .onChange(of: size.width, initial: true) { _, width in shell.containerWidth = width }
                .onChange(of: compact, initial: true) { _, compact in layers.compact = compact }
                .onChange(of: fold.shape, initial: true) { _, shape in
                    shell.fold = shape
                    layers.spread = shape == .spread
                    // The plane only exists where it can be shown. A left-over
                    // "open" would put the second page out the moment the
                    // phone unfolds again, without anyone asking for it.
                    if shape != .spread { shell.spreadPlaneOpen = false }
                }
                .onChange(of: fold.isSpread, initial: true) { _, spread in
                    // Unfolding over an open conversation is the gesture this
                    // whole adaptation exists for: the second page comes out
                    // already carrying the turns, rather than making the
                    // operator ask for the thing they just made room for.
                    shell.trailingAvailable = model.selectedSessionId != nil && !spread
                    if spread, model.selectedSessionId != nil { shell.spreadPlaneOpen = true }
                }
                if secondPage {
                    SpreadPage(content: roots?.spreadPlane ?? AnyView(EmptyView()))
                        .frame(width: fold.rightPage.width, height: size.height)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .ignoresSafeArea()
                    // In from the spine and back into it: the motion names the
                    // hinge, so the page reads as the other half of the book
                    // rather than a sheet that happens to sit on the right.
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: .leading).combined(with: .opacity),
                            removal: .move(edge: .leading).combined(with: .opacity),
                        ),
                    )
                }
                if fold.isSpread {
                    SpreadSpine(
                        available: model.selectedSessionId != nil,
                        open: secondPage,
                        progress: readingProgress,
                        toggle: { shell.toggleTrailing(compact: true) },
                    )
                    // The valley's own width, the full height: no content may
                    // be under it, so the whole strip is a safe tap target.
                    .frame(width: FoldLayout.gutter, height: size.height)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .ignoresSafeArea()
                }

                // The banner is above the card, the sidebar and the composer:
                // it is the app talking, not a screen. It is placed inside the
                // safe area's top so it clears the island and the status bar,
                // and it never takes a tap meant for the screen underneath --
                // only the card itself is interactive.
                if let announcement = model.announcements.banner {
                    AnnouncementBanner(
                        announcement: announcement,
                        onAction: { destination in
                            model.openSettings(destination.settingsTopic)
                        },
                        onDismiss: { model.announcements.dismiss() },
                    )
                    .padding(.horizontal, 12)
                    .padding(.top, insets.top + 8)
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: .top).combined(with: .opacity),
                            removal: .opacity,
                        ),
                    )
                    .zIndex(1)
                }
            }
            .animation(Motion.pick(.mizarBouncy), value: model.announcements.banner?.id)
            // The page arrives and leaves on the same spring the columns use,
            // and the window's own change of shape eases too, so unfolding
            // settles instead of snapping.
            .animation(Motion.pick(.mizarSmooth), value: secondPage)
            .animation(Motion.pick(.mizarSmooth), value: fold.isSpread)
                // No second launch animation. The root's `LaunchingView`
                // already covers the wait; once the phase is an answer the
                // shell is the page, directly. The old turning mark here was a
                // second, unrelated animation after "connecting", which read
                // as the app loading twice.
        }
        .environment(shell)
        .environment(turnIndex)
        .environment(sidePlane)
        .environment(preview)
        // The reader captures the socket, so it is rebuilt whenever the computer
        // changes and on the first frame. A stale closure would answer
        // `SOCKET_CLOSED` for every preview until the app restarted.
        .onAppear { attachPreviewReader() }
        .onChange(of: model.host?.hostId) { _, _ in attachPreviewReader() }
        .onChange(of: scenePhase, initial: true) { _, phase in layers.scenePhase = phase }
        .onAppear { if roots == nil { roots = makeRoots() } }
        // Whether the drawers are moving, published to the motion that
        // yields to it: the shimmer, the turning mark, the typewriter --
        // anything that redraws every frame it runs -- holds for the
        // duration of a drag and its settle, so the frames that move the
        // card are not spent redrawing the card's content.
        .environment(\.drawersStill, !shell.isDragging && !shell.isSettling)
        .onAppear {
            guard !placed else { return }
            placed = true
            // A launch opens on the app's own page, not on the folder list.
            // The sidebar is one tap away; opening it for somebody who has not
            // asked for it hides the page the app is about. Placed without
            // animating; the first frame is a state, not a change.
            shell.pinnedVisible = false
            shell.place(open: false)
            shell.trailingAvailable = model.selectedSessionId != nil
            #if DEBUG
            // A debug way into the right drawer, for screenshots and future
            // drawer tests: the drawer otherwise belongs to a gesture, which
            // `simctl` can launch but cannot make. On a regular width the
            // drawer is a pinned column, so the same argument pins it instead
            // of settling the phone's drawer spring.
            if ProcessInfo.processInfo.arguments.contains("-mizarOpenTurnIndex") {
                debugOpenTrailingWanted = true
                if model.selectedSessionId != nil {
                    shell.trailingAvailable = true
                    if sizeClass == .regular {
                        shell.indexPinnedVisible = true
                    } else {
                        shell.openTrailing()
                    }
                }
            }
            #endif
        }
        .onChange(of: model.selectedSessionId) { _, selected in
            shell.trailingAvailable = selected != nil
            // A session chosen from anywhere -- a row, a notification, a launch
            // argument, a session just created -- is a session the operator
            // wants to see, so the card comes back. A selection that goes away
            // (a disconnect, a switch of computer) puts the list back in front.
            if selected != nil {
                hasOpenedASession = true
                shell.close()
            } else if hasOpenedASession, !shell.settledOpen {
                // Backing out of a conversation puts the list back in front,
                // because that is where the operator came from. A launch is not
                // that: nothing was left, and the page behind the drawer is the
                // home page -- the month, the composer, the way back in -- which
                // is a better answer to "open the app" than a folder list.
                shell.open()
            }
            #if DEBUG
            // The debug open arrives after the close that rides the same
            // selection, so the drawer ends the launch open rather than
            // losing the race to it. Same regular-width branch as above.
            if debugOpenTrailingWanted, selected != nil {
                shell.trailingAvailable = true
                if sizeClass == .regular {
                    shell.indexPinnedVisible = true
                } else {
                    shell.openTrailing()
                }
            }
            #endif
        }
        .onChange(of: turnIndex.jumpCount) { _, _ in
            // A turn chosen in the drawer: the card comes back to show it.
            if shell.trailingOpen { shell.close() }
        }
        .mizarFeedback(.selection, trigger: shell.settled)
    }

    // MARK: - Layout

    /// The three layers' SwiftUI content, each with what it reads from above
    /// the container.
    private func makeRoots() -> ShellLayerRoots {
        let model = model
        let shell = shell
        let turnIndex = turnIndex
        let layers = layers
        func root(_ edges: Edge.Set, _ content: @escaping (Bool) -> some View) -> AnyView {
            AnyView(ShellLayer(
                model: model,
                shell: shell,
                turnIndex: turnIndex,
                sidePlane: sidePlane,
                preview: preview,
                context: layers,
                edges: edges,
                content: content,
            ))
        }
        return ShellLayerRoots(
            sidebar: root([.top, .leading, .bottom]) { _ in SidebarView() },
            // The container's plane is the drawer on a phone and the column on
            // an iPad; on a spread it is the second page instead, and two live
            // copies of the plane would be two lists of the same turns.
            plane: root([.top, .trailing, .bottom]) { _ in ContainerPlane() },
            spreadPlane: root([.top, .trailing, .bottom]) { _ in
                SessionSidePlane(onPick: {})
            },
            card: root(.all) { compact in ShellPane(compact: compact) },
        )
    }

    /// Point the preview at this computer's socket.
    private func attachPreviewReader() {
        guard let host = model.host else { return }
        let model = model
        preview.attach(hostId: host.hostId) { method, payload in
            try await model.previewCall(method, payload)
        }
        Task { await preview.refreshCacheUsage() }
    }

    /// Whether the iPad's index column is out: only beside a conversation.
    private var indexColumnShown: Bool {
        shell.indexPinnedVisible && model.selectedSessionId != nil
    }

    /// How far through the conversation the operator has read, from the turns on
    /// screen: 0 at the first turn, 1 at the last.
    ///
    /// Turn-granular on purpose. The precise answer is a scroll offset, and a
    /// spine that tracked every pixel would be a scroll bar wearing a metaphor;
    /// a book's thickness moves when you turn a page. The view eases between the
    /// values, so the seam still never flickers -- it just knows about turns,
    /// which is the unit this app already reads in.
    private var readingProgress: Double { turnIndex.readingFraction }

    private func sidebarWidth(in size: CGSize, compact: Bool) -> CGFloat {
        compact ? min(330, size.width * 0.84) : min(340, max(280, size.width * 0.3))
    }

    private func indexWidth(in size: CGSize, compact: Bool) -> CGFloat {
        compact ? min(320, size.width * 0.82) : min(320, max(260, size.width * 0.26))
    }
}

/// What the layers read that changes after they are made.
@MainActor
@Observable
final class ShellLayerContext {
    var compact = true
    /// Whether the window is a spread. The pages' own content reads it to know
    /// that a column is a page, not a drawer that happens to be pinned open.
    var spread = false
    var scenePhase: ScenePhase = .active
    /// The screen's safe area, from the untransformed container, on a phone;
    /// `nil` where the layers take UIKit's own (see `DrawerContainer`).
    var screenInsets: EdgeInsets?
}

/// The roots of the three hosting controllers.
struct ShellLayerRoots {
    let sidebar: AnyView
    let plane: AnyView
    /// The plane as the *second page* of a spread. A root of its own rather
    /// than the same view again: a spread must mount one plane, not two.
    let spreadPlane: AnyView
    let card: AnyView
}

/// A layer's root: its content, with the environment the shell sets up.
///
/// Each layer is the root of a hosting controller of its own, so the
/// environment above the container does not reach it by itself: the model,
/// the shell, the turn index and whether the drawers are moving are handed
/// down here. The scene phase too, which a hosting controller that is not
/// the scene's own does not otherwise follow.
private struct ShellLayer<Content: View>: View {
    let model: AppModel
    let shell: ShellState
    let turnIndex: TurnIndex
    let sidePlane: SidePlaneState
    let preview: PreviewCenter
    let context: ShellLayerContext
    /// Which of the screen's insets this layer is given: the card all of them,
    /// each drawer all but the edge the card covers.
    let edges: Edge.Set
    let content: (Bool) -> Content

    var body: some View {
        Group {
            // A spread's page is a phone's page, and the app has to believe it.
            // Every `sizeClass == .regular` branch in the conversation was
            // written for the iPad's columns; a 461.5-point page is not one of
            // those. The trait is set here, inside the hosting controller,
            // because that is the only place the window's real trait does not
            // win -- see the note above `ShellLayer`.
            if context.compact {
                content(context.compact)
                    .environment(\.horizontalSizeClass, .compact)
            } else {
                content(context.compact)
            }
        }
        .safeAreaPadding(padding)
            .environment(model)
            .environment(shell)
            .environment(context)
            .environment(turnIndex)
            .environment(sidePlane)
            .environment(preview)
            .environment(\.drawersStill, !shell.isDragging && !shell.isSettling)
            .environment(\.drawerGate, shell.gate)
            .environment(\.scenePhase, context.scenePhase)
    }

    private var padding: EdgeInsets {
        guard let insets = context.screenInsets else { return EdgeInsets() }
        return EdgeInsets(
            top: edges.contains(.top) ? insets.top : 0,
            leading: edges.contains(.leading) ? insets.leading : 0,
            bottom: edges.contains(.bottom) ? insets.bottom : 0,
            trailing: edges.contains(.trailing) ? insets.trailing : 0,
        )
    }
}

/// The conversation, or the home screen, in its navigation stack.
private struct ShellPane: View {
    let compact: Bool
    @Environment(AppModel.self) private var model
    @Environment(ShellLayerContext.self) private var layers

    var body: some View {
        NavigationStack {
            Group {
                if let sessionId = model.selectedSessionId {
                    // Keyed on the session, which is what makes every piece of
                    // state inside belong to the session it was filled from: the
                    // draft, the scroll anchor, the paging allowance, the
                    // in-flight-load gate. One identity per session is the tag
                    // that covers the ones nobody remembered to add, and it
                    // cancels a load the moment its subject goes away.
                    SessionDetailView(sessionId: sessionId)
                        .id(sessionId)
                } else {
                    HomeView()
                }
            }
            // The soft edge under the bar, as the window's own hosting view
            // gives it. In a hosting controller of its own the automatic style
            // turns hard, and a hard edge draws a line under the bar.
            .scrollEdgeEffectStyle(.soft, for: .top)
            // Declared here, outside the keyed view, so switching sessions does
            // not rebuild the bar and its glass.
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    SidebarToggle(compact: compact)
                }
                if !compact, model.selectedSessionId != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        TurnIndexToggle()
                    }
                }
                // A spread's second page is opened from the toolbar as well as
                // from the spine: the spine is the physical way, this is the
                // discoverable one. The spine keeps working when the toolbar is
                // scrolled out of the way, and the toolbar works when the
                // operator has not yet noticed that the gutter is a handle.
                if layers.spread, model.selectedSessionId != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        SpreadPageToggle()
                    }
                }
            }
        }
        .background(Theme.paneBackground)
    }
}

/// The button at the top left: two lines that fold into a chevron as the
/// sidebar opens, following the drag frame by frame.
struct SidebarToggle: View {
    let compact: Bool
    @Environment(ShellState.self) private var shell
    @Environment(AppModel.self) private var model

    /// Whether the one-time naming prompt should be out of this button.
    ///
    /// Read in the body, not only inside the binding: SwiftUI observes what a
    /// body reads, and a prompt held back while a drawer is moving has to be
    /// asked about again when the drawer stops. A value read only from inside a
    /// presentation binding is read once, at the wrong moment, and never again
    /// -- which is how a delayed prompt became a prompt that never appeared.
    private var wantsNaming: Bool {
        compact && model.pendingNameHostId != nil
            && !shell.settledOpen && !shell.isSettling && !shell.isDragging
    }

    var body: some View {
        let namingWanted = wantsNaming
        Button {
            shell.toggle(compact: compact)
        } label: {
            SidebarGlyphView(shell: shell, compact: compact, pinned: shell.pinnedVisible)
                .frame(width: 20, height: 16)
                .padding(4)
                .contentShape(.rect)
        }
        .accessibilityLabel(Text(isOpen ? "Hide sidebar" : "Show sidebar"))
        .accessibilityIdentifier("shell.sidebarToggle")
        .mizarPopover(
            isPresented: Binding(
                get: { namingWanted },
                set: { if !$0 { model.pendingNameHostId = nil } },
            ),
        ) {
            NamingWindow()
        }
    }

    private var isOpen: Bool { compact ? shell.settledOpen : shell.pinnedVisible }
}

/// The iPad's button for the index column: the sidebar's glyph, mirrored.
struct TurnIndexToggle: View {
    @Environment(ShellState.self) private var shell

    var body: some View {
        Button {
            shell.toggleTrailing(compact: false)
        } label: {
            Image(systemName: shell.indexPinnedVisible ? "list.bullet.indent" : "list.bullet")
                .font(.system(size: 16, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 28, height: 24)
                .contentShape(.rect)
        }
        .accessibilityLabel(Text(shell.indexPinnedVisible ? "Hide turns" : "Show turns"))
        .accessibilityIdentifier("shell.turnIndexToggle")
    }
}

/// Two lines, the lower one shorter, that become a chevron pointing left.
struct SidebarGlyph: Shape {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        func point(_ closed: CGPoint, _ open: CGPoint) -> CGPoint {
            CGPoint(
                x: rect.minX + (closed.x + (open.x - closed.x) * progress) * rect.width,
                y: rect.minY + (closed.y + (open.y - closed.y) * progress) * rect.height,
            )
        }
        var path = Path()
        // Upper line -> upper stroke of the chevron.
        path.move(to: point(CGPoint(x: 0.05, y: 0.28), CGPoint(x: 0.62, y: 0.1)))
        path.addLine(to: point(CGPoint(x: 0.95, y: 0.28), CGPoint(x: 0.24, y: 0.5)))
        // Lower line -> lower stroke.
        path.move(to: point(CGPoint(x: 0.05, y: 0.72), CGPoint(x: 0.62, y: 0.9)))
        path.addLine(to: point(CGPoint(x: 0.6, y: 0.72), CGPoint(x: 0.24, y: 0.5)))
        return path
    }
}

/// The glyph, drawn by a shape layer that follows the drawers' progress
/// itself: frame by frame under a finger, and for a settle as the same
/// keyframes the shell's layers play. A SwiftUI shape that read the progress
/// re-rendered the toolbar -- and bridged its bar button items again -- on
/// every frame of a drag.
private struct SidebarGlyphView: UIViewRepresentable {
    let shell: ShellState
    let compact: Bool
    /// On a regular width the glyph shows whether the sidebar column is out.
    let pinned: Bool

    func makeUIView(context: Context) -> GlyphLayerView {
        let view = GlyphLayerView()
        view.configure(compact: compact, pinned: pinned, animated: false, reduced: false)
        shell.attach(view)
        return view
    }

    func updateUIView(_ view: GlyphLayerView, context: Context) {
        view.configure(
            compact: compact,
            pinned: pinned,
            animated: true,
            reduced: context.environment.accessibilityReduceMotion,
        )
    }
}

@MainActor
private final class GlyphLayerView: UIView, DrawerSurface {
    private let shape = CAShapeLayer()
    private var compact = true
    private var pinned = true
    private var progress: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        shape.fillColor = nil
        shape.lineWidth = 2
        shape.lineCap = .round
        shape.lineJoin = .round
        layer.addSublayer(shape)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in
            self.shape.strokeColor = UIColor.label.resolvedColor(with: self.traitCollection).cgColor
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(compact: Bool, pinned: Bool, animated: Bool, reduced: Bool) {
        let changed = compact != self.compact || pinned != self.pinned
        self.compact = compact
        self.pinned = pinned
        guard changed, !compact else {
            if changed { redraw() }
            return
        }
        // The iPad's toggle: the smooth spring, as the column it follows.
        let from = shape.presentation()?.path ?? shape.path
        redraw()
        guard animated, let from else { return }
        let animation: CABasicAnimation
        if reduced {
            animation = CABasicAnimation(keyPath: "path")
            animation.duration = 0.22
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        } else {
            let spring = CASpringAnimation(perceptualDuration: 0.5, bounce: 0)
            spring.keyPath = "path"
            spring.duration = spring.settlingDuration
            animation = spring
        }
        animation.fromValue = from
        animation.toValue = shape.path
        shape.add(animation, forKey: "glyph.toggle")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        shape.frame = bounds
        shape.strokeColor = UIColor.label.resolvedColor(with: traitCollection).cgColor
        redraw()
    }

    func show(progress: CGFloat) {
        self.progress = progress
        guard compact else { return }
        redraw()
    }

    func play(_ path: DrawerPath) {
        progress = path.target
        guard compact, bounds.width > 0 else { return }
        redraw()
        let animation = CAKeyframeAnimation(keyPath: "path")
        animation.values = path.samples.map { glyph(at: $0) }
        animation.duration = path.duration
        animation.beginTime = path.beginTime
        animation.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        shape.add(animation, forKey: "glyph.settle")
    }

    func stopPlaying() {
        shape.removeAnimation(forKey: "glyph.settle")
    }

    private func redraw() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.path = glyph(at: compact ? progress : (pinned ? 1 : 0))
        CATransaction.commit()
    }

    private func glyph(at progress: CGFloat) -> CGPath {
        SidebarGlyph(progress: max(0, min(1, progress))).path(in: bounds).cgPath
    }
}
