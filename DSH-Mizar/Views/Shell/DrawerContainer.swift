//
//  DrawerContainer.swift
//  DSH-Mizar
//
//  The shell's three layers -- the workspace sidebar, the turn plane, and the
//  conversation card over them -- as UIKit views, each hosting its SwiftUI
//  content in a hosting controller of its own.
//
//  The drawers move here, in Core Animation, and nowhere in SwiftUI. Moving
//  the card with SwiftUI modifiers re-rendered the whole hosted tree on every
//  frame -- measured on an iPhone 16 Pro at eight milliseconds and more a frame,
//  which is the whole of a 120 Hz frame and held the drawers to 60 Hz. Here a
//  frame of a drag is a handful of layer properties, and a settle is one set of
//  keyframe animations the render server plays at the display's rate on its
//  own, whatever the main thread is doing.
//
//  Every value is the one the SwiftUI shell drew, from the same progress: the
//  sidebar's 44-point travel and its fade, the card's shrink across the
//  travel, its corner, shade, rim and shadow, and the dismiss surface over the
//  part of the card still on screen. On a regular width the drawers are
//  columns and the card is laid out beside them, as before.
//

import SwiftUI
import UIKit

struct DrawerContainer: UIViewControllerRepresentable {
    let shell: ShellState
    let compact: Bool
    /// Whether the window is a spread, and the safe area the *shell* measured.
    ///
    /// A spread's columns are interior to the window, so UIKit's own insets --
    /// worked out from the display the app is drawing into -- are not the ones
    /// to inset them by. The debug geometry injection makes that concrete: a
    /// 951-point container inside a 466-point window is reported as 84 points
    /// unsafe on the trailing edge, which drew a phantom strip down the right
    /// of the conversation. The shell already knows the truth.
    let spread: Bool
    let spreadInsets: EdgeInsets
    let leadingWidth: CGFloat
    let trailingWidth: CGFloat
    /// The iPad's columns.
    let pinnedVisible: Bool
    let indexColumnShown: Bool
    /// Made once; never set again (see `MizarShell`).
    let roots: ShellLayerRoots
    let layers: ShellLayerContext

    func makeUIViewController(context: Context) -> DrawerContainerController {
        let controller = DrawerContainerController(
            shell: shell,
            context: layers,
            sidebar: roots.sidebar,
            plane: roots.plane,
            card: roots.card,
        )
        controller.configure(
            compact: compact,
            spread: spread,
            spreadInsets: spreadInsets,
            leadingWidth: leadingWidth,
            trailingWidth: trailingWidth,
            pinnedVisible: pinnedVisible,
            indexColumnShown: indexColumnShown,
            reduceMotion: context.environment.accessibilityReduceMotion,
            animated: false,
        )
        return controller
    }

    func updateUIViewController(_ controller: DrawerContainerController, context: Context) {
        controller.configure(
            compact: compact,
            spread: spread,
            spreadInsets: spreadInsets,
            leadingWidth: leadingWidth,
            trailingWidth: trailingWidth,
            pinnedVisible: pinnedVisible,
            indexColumnShown: indexColumnShown,
            reduceMotion: context.environment.accessibilityReduceMotion,
            animated: true,
        )
    }
}

/// Everything the phone's layers draw at one progress.
///
/// A pure function of the progress and the geometry, so the frame a finger
/// draws and every keyframe of a settle are the same computation.
///
/// Internal rather than private so the narrowing can be pinned by a test
/// (see ``cardScale(reveal:)``).
struct DrawerLook {
    /// The card's corner once pushed aside: the smallest corner of any Face ID
    /// iPhone, so at rest it hides inside the display's mask on every device,
    /// and pushed aside it reads as the screen itself.
    static let cardCorner: CGFloat = 39
    /// How far the card shrinks once pushed aside, over the drawer's travel.
    static let cardShrink: CGFloat = 0.06
    /// How far the drawer under the card travels as it comes forward.
    static let drawerTravel: CGFloat = 44

    let lead: CGFloat
    let trail: CGFloat
    let reveal: CGFloat
    let towardsTrailing: Bool
    let sidebarShift: CGFloat
    let planeShift: CGFloat
    /// Which drawer, if any, is the one being revealed. Decided by the sign of
    /// the progress, so it changes once per gesture: the other drawer sits
    /// behind an opaque card and is simply not drawn.
    let leadingShown: Bool
    let trailingShown: Bool
    let corner: CGFloat
    let cardTransform: CATransform3D
    /// The dismiss surface: the part of the screen the pushed card still covers.
    let dismissFrame: CGRect

    /// The card's scale at a reveal.
    ///
    /// The narrowing runs with the travel: one at rest, `1 - cardShrink` with
    /// the drawer out, and linear in between -- so the card is exactly as
    /// narrow as it will be, at the moment the drawer arrives. The card used
    /// to arrive at its narrowest over the first third of the travel and then
    /// only translated for the rest of it, which read as a card that had
    /// finished shrinking while the drawer was still coming.
    static func cardScale(reveal: CGFloat) -> CGFloat {
        1 - cardShrink * min(1, max(0, reveal))
    }

    init(progress p: CGFloat, leadingWidth: CGFloat, trailingWidth: CGFloat, size: CGSize) {
        lead = max(0, min(1, p))
        trail = max(0, min(1, -p))
        reveal = max(lead, trail)
        towardsTrailing = trail > lead
        leadingShown = trail < lead
        trailingShown = lead < trail
        sidebarShift = -(1 - lead) * Self.drawerTravel
        planeShift = (1 - trail) * Self.drawerTravel
        // The corner is the screen's own or it is nothing: two values, so the
        // mask changes at most once per gesture.
        corner = reveal > 0.001 ? Self.cardCorner : 0
        // The shrink runs with the travel: the card narrows as it is pushed
        // aside, and is fully narrow when the drawer arrives, so the two
        // finish together. Scaled about its leading or trailing edge, then
        // moved.
        let scale = Self.cardScale(reveal: reveal)
        let anchor = (towardsTrailing ? 1 : -1) * size.width / 2
        let offset = towardsTrailing ? -trailingWidth * trail : leadingWidth * p
        var transform = CATransform3DMakeTranslation(-anchor, 0, 0)
        transform = CATransform3DConcat(transform, CATransform3DMakeScale(scale, scale, 1))
        transform = CATransform3DConcat(transform, CATransform3DMakeTranslation(anchor + offset, 0, 0))
        cardTransform = transform
        let shift = lead > 0.02 ? leadingWidth * p : trailingWidth * p
        dismissFrame = CGRect(x: max(0, shift), y: 0, width: max(0, size.width - abs(shift)), height: size.height)
    }
}

@MainActor
final class DrawerContainerController: UIViewController, DrawerSurface {
    let shell: ShellState
    let context: ShellLayerContext
    let sidebarHost: UIHostingController<AnyView>
    let planeHost: UIHostingController<AnyView>
    let cardHost: UIHostingController<AnyView>

    private let cardShadow = UIView()
    private let cardView = UIView()
    private let shadeView = UIView()
    private let rimView = RimView()
    private let dismissView = DismissView()
    private let pan = DrawerPanRecognizer(target: nil, action: nil)
    private let panCoordinator: DrawerPanCoordinator

    private var compact = true
    private var spread = false
    private var spreadInsets = EdgeInsets()
    /// The card's corner as last drawn, and the rim's direction: each of them
    /// switches at most once per gesture, so they are written only when they
    /// change and not on every frame of a drag.
    private var drawnCorner: CGFloat = -1
    private var drawnRimTowardsTrailing: Bool?
    /// The interaction and accessibility flags as last written: each of them
    /// changes at most once per gesture.
    private var drawnSidebarOpen = false
    private var drawnPlaneOpen = false
    private var drawnCardHidden = false
    private var drawnDismissOpen = false
    private var drawnDismissLabel: String?
    /// Whether the card's content is being held as a still picture, and the
    /// task that lets it live again (see ``holdContentWhileMoving()``).
    private var contentFrozen = false
    private var thawTask: Task<Void, Never>?
    /// When the drawer is due to be at rest: the end of the settle being
    /// played. Zero while a finger is on the card.
    private var motionEndsAt: CFTimeInterval = 0
    private var leadingWidth: CGFloat = 320
    private var trailingWidth: CGFloat = 300
    private var reduceMotion = false
    private var laidOutSize: CGSize = .zero
    /// The layout changed without the size changing: a width class or a drawer
    /// width. The next layout pass lays the layers out again regardless.
    private var needsRelayout = false
    /// The phone's drawers, as last drawn.
    private var progress: CGFloat = 0
    private var shownSides: (leading: Bool, trailing: Bool) = (false, false)
    /// The iPad's columns: how far each is out, moved by their own spring.
    private let columns = ColumnMotion()
    private var playingKeys: [(CALayer, String)] = []

    init(shell: ShellState, context: ShellLayerContext, sidebar: AnyView, plane: AnyView, card: AnyView) {
        self.shell = shell
        self.context = context
        sidebarHost = UIHostingController(rootView: sidebar)
        planeHost = UIHostingController(rootView: plane)
        cardHost = UIHostingController(rootView: card)
        panCoordinator = DrawerPanCoordinator(shell: shell)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Self.sidebarBackground

        for host in [sidebarHost, planeHost] {
            addChild(host)
            host.view.backgroundColor = .clear
            view.addSubview(host.view)
            host.didMove(toParent: self)
        }

        // The shadow is a shape of its own behind the card, not an effect on
        // it: a shadow path is drawn by the render server from the path alone,
        // whatever the card's content does.
        cardShadow.isUserInteractionEnabled = false
        cardShadow.layer.shadowColor = UIColor.black.cgColor
        cardShadow.layer.shadowRadius = 30
        // The shadow is drawn at full strength and faded with the view's
        // alpha, so a drag does not ask for the shadow to be drawn again for
        // every frame: only the reveal changes, and that is a compositing.
        cardShadow.layer.shadowOpacity = shadowStrength
        cardShadow.alpha = 0
        view.addSubview(cardShadow)

        cardView.layer.cornerCurve = .continuous
        cardView.layer.masksToBounds = true
        cardView.backgroundColor = .systemBackground
        view.addSubview(cardView)
        addChild(cardHost)
        cardHost.view.backgroundColor = .systemBackground
        cardView.addSubview(cardHost.view)
        cardHost.didMove(toParent: self)

        // A shade, and a faint rim of the accent on the edge that faces the
        // open drawer: the card catching the light of the list behind it. Both
        // fade with the reveal; neither is ever redrawn.
        shadeView.isUserInteractionEnabled = false
        shadeView.alpha = 0
        cardView.addSubview(shadeView)
        rimView.isUserInteractionEnabled = false
        rimView.alpha = 0
        cardView.addSubview(rimView)

        dismissView.onClose = { [weak self] in self?.shell.close() }
        view.addSubview(dismissView)

        pan.coordinator = panCoordinator
        pan.delegate = panCoordinator
        view.addGestureRecognizer(pan)

        columns.onFrame = { [weak self] in self?.layoutColumns() }

        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in
            self.applyColours()
        }
        applyColours()
        distributeSafeArea()
        shell.attach(self)
    }

    /// Take the values the SwiftUI shell decides.
    func configure(
        compact: Bool,
        spread: Bool,
        spreadInsets: EdgeInsets,
        leadingWidth: CGFloat,
        trailingWidth: CGFloat,
        pinnedVisible: Bool,
        indexColumnShown: Bool,
        reduceMotion: Bool,
        animated: Bool,
    ) {
        let layoutChanged = compact != self.compact
            || spread != self.spread
            || spreadInsets != self.spreadInsets
            || leadingWidth != self.leadingWidth
            || trailingWidth != self.trailingWidth
        self.compact = compact
        self.spread = spread
        self.spreadInsets = spreadInsets
        self.leadingWidth = leadingWidth
        self.trailingWidth = trailingWidth
        self.reduceMotion = reduceMotion
        pan.isEnabled = compact
        columns.retarget(
            lead: pinnedVisible ? 1 : 0,
            trail: indexColumnShown ? 1 : 0,
            animated: animated && !compact && isViewLoaded && view.window != nil,
            reduced: reduceMotion,
        )
        if layoutChanged, isViewLoaded {
            distributeSafeArea()
            needsRelayout = true
            view.setNeedsLayout()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let size = view.bounds.size
        guard size != laidOutSize || needsRelayout else { return }
        laidOutSize = size
        needsRelayout = false
        // A new size mid-settle would leave the keyframes drawing the old
        // geometry: the drawers are drawn where they are going instead.
        stopPlaying()
        layoutLayers()
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        distributeSafeArea()
    }

    /// Hand each layer the screen's safe area as a value of its own.
    ///
    /// UIKit works a view's safe area out from its frame in the window,
    /// transform included, and only when it next lays the view out: a card
    /// shrunk to 94 % was given the screen's insets less the 26 points the
    /// shrink pulls its edges in by -- a navigation bar under the status bar, a
    /// composer down by the home indicator -- and kept whichever value its last
    /// layout had happened to see. On a phone the layers' hosting controllers
    /// therefore take only the keyboard from UIKit, and the screen's insets
    /// come from this untransformed container, through the layers' context, as
    /// the SwiftUI shell handed them to its drawers. On a regular width nothing
    /// moves by transform, and the columns take UIKit's own safe area.
    private func distributeSafeArea() {
        // A spread's pans are interior: their insets come from the shell, the
        // same way a phone's do, and UIKit is asked for the keyboard only.
        let regions: SafeAreaRegions = (compact || spread) ? .keyboard : .all
        for host in [cardHost, sidebarHost, planeHost] where host.safeAreaRegions != regions {
            host.safeAreaRegions = regions
        }
        let insets = view.safeAreaInsets
        let screen = EdgeInsets(top: insets.top, leading: insets.left, bottom: insets.bottom, trailing: insets.right)
        let wanted: EdgeInsets? = compact ? screen : (spread ? spreadInsets : nil)
        if context.screenInsets != wanted { context.screenInsets = wanted }
    }

    override func accessibilityPerformEscape() -> Bool {
        guard compact else { return false }
        shell.close()
        return true
    }

    // MARK: Layout

    private func layoutLayers() {
        let bounds = view.bounds
        guard bounds.width > 0 else { return }
        if compact {
            placeCentered(sidebarHost.view, CGRect(x: 0, y: 0, width: leadingWidth, height: bounds.height))
            placeCentered(planeHost.view, CGRect(x: bounds.width - trailingWidth, y: 0, width: trailingWidth, height: bounds.height))
            placeCentered(cardShadow, bounds)
            placeCentered(cardView, bounds)
            cardHost.view.frame = cardView.bounds
            shadeView.frame = cardView.bounds
            rimView.frame = cardView.bounds
            dismissView.isHidden = false
            show(progress: progress)
        } else {
            dismissView.isHidden = true
            layoutColumns()
        }
    }

    /// The iPad: the sidebar beside the conversation, the index beside it on
    /// the other side, each slid away and back by its own spring, and the
    /// conversation laid out in what is left.
    private func layoutColumns() {
        guard !compact, isViewLoaded else { return }
        thawContent()
        let bounds = view.bounds
        let lead = columns.lead
        let trail = columns.trail
        withoutActions {
            sidebarHost.view.transform = .identity
            planeHost.view.transform = .identity
            cardView.transform = .identity
            cardShadow.transform = .identity
            sidebarHost.view.frame = CGRect(x: -(1 - lead) * leadingWidth, y: 0, width: leadingWidth, height: bounds.height)
            planeHost.view.frame = CGRect(
                x: bounds.width - trailingWidth + (1 - trail) * trailingWidth,
                y: 0,
                width: trailingWidth,
                height: bounds.height,
            )
            let cardFrame = CGRect(
                x: leadingWidth * lead,
                y: 0,
                width: max(0, bounds.width - leadingWidth * lead - trailingWidth * trail),
                height: bounds.height,
            )
            cardView.frame = cardFrame
            cardShadow.frame = cardFrame
            cardHost.view.frame = cardView.bounds
            shadeView.frame = cardView.bounds
            rimView.frame = cardView.bounds
            cardView.layer.cornerRadius = 0
            cardShadow.alpha = 0
            shadeView.alpha = 0
            rimView.alpha = 0
            sidebarHost.view.alpha = 1
            planeHost.view.alpha = 1
            sidebarHost.view.isUserInteractionEnabled = true
            planeHost.view.isUserInteractionEnabled = true
            sidebarHost.view.accessibilityElementsHidden = false
            planeHost.view.accessibilityElementsHidden = false
            cardView.accessibilityElementsHidden = false
        }
    }

    /// Size a view that may carry a transform: by bounds and centre, which a
    /// transform leaves alone, never by frame.
    private func placeCentered(_ view: UIView, _ frame: CGRect) {
        view.bounds = CGRect(origin: .zero, size: frame.size)
        view.center = CGPoint(x: frame.midX, y: frame.midY)
    }

    // MARK: DrawerSurface

    func show(progress: CGFloat) {
        self.progress = progress
        guard compact, isViewLoaded, view.bounds.width > 0 else { return }
        let look = look(at: progress)
        withoutActions {
            apply(look)
        }
        applyState(look)
        fadeSides(to: look)
        holdContentWhileMoving()
    }

    func play(_ path: DrawerPath) {
        progress = path.target
        // The settle is over when the path is: the content is held until then.
        motionEndsAt = path.endTime
        guard compact, isViewLoaded, view.bounds.width > 0 else { return }
        let looks = path.samples.map { look(at: $0) }
        guard let last = looks.last else { return }
        withoutActions {
            apply(last)
        }
        applyState(last)
        holdContentWhileMoving()
        // The fade between drawers is part of the path: it can only change at
        // the very end, when the card is home and covers both.
        sidebarHost.view.alpha = last.leadingShown ? 1 : 0
        planeHost.view.alpha = last.trailingShown ? 1 : 0
        shownSides = (last.leadingShown, last.trailingShown)

        let bounds = cardView.bounds
        func add(_ layer: CALayer, _ keyPath: String, _ values: [Any], discrete: Bool = false) {
            let animation = CAKeyframeAnimation(keyPath: keyPath)
            animation.values = values
            animation.duration = path.duration
            animation.beginTime = path.beginTime
            animation.calculationMode = discrete ? .discrete : .linear
            animation.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
            let key = "drawer.\(keyPath)"
            layer.add(animation, forKey: key)
            playingKeys.append((layer, key))
        }
        let transforms = looks.map { NSValue(caTransform3D: $0.cardTransform) }
        add(cardView.layer, "transform", transforms)
        add(cardShadow.layer, "transform", transforms)
        add(cardView.layer, "cornerRadius", looks.map { $0.corner }, discrete: true)
        add(rimView.borderLayer, "cornerRadius", looks.map { $0.corner }, discrete: true)
        add(cardShadow.layer, "shadowPath", looks.map { shadowPath(bounds, corner: $0.corner) }, discrete: true)
        add(cardShadow.layer, "shadowOffset", looks.map { NSValue(cgSize: shadowOffset($0)) }, discrete: true)
        add(cardShadow.layer, "opacity", looks.map { Float($0.reveal) })
        add(shadeView.layer, "opacity", looks.map { Float($0.reveal) })
        add(rimView.layer, "opacity", looks.map { Float($0.reveal) })
        add(rimView.gradient, "startPoint", looks.map { NSValue(cgPoint: rimStart($0)) }, discrete: true)
        add(rimView.gradient, "endPoint", looks.map { NSValue(cgPoint: rimEnd($0)) }, discrete: true)
        add(sidebarHost.view.layer, "transform.translation.x", looks.map { $0.sidebarShift })
        add(planeHost.view.layer, "transform.translation.x", looks.map { $0.planeShift })
        add(sidebarHost.view.layer, "opacity", looks.map { Float($0.leadingShown ? 1 : 0) }, discrete: true)
        add(planeHost.view.layer, "opacity", looks.map { Float($0.trailingShown ? 1 : 0) }, discrete: true)
    }

    func stopPlaying() {
        for (layer, key) in playingKeys { layer.removeAnimation(forKey: key) }
        playingKeys.removeAll()
    }

    // MARK: Drawing

    private func look(at progress: CGFloat) -> DrawerLook {
        DrawerLook(
            progress: progress,
            leadingWidth: leadingWidth,
            trailingWidth: trailingWidth,
            size: view.bounds.size,
        )
    }

    /// The layer properties of one look, set directly.
    ///
    /// Only what changed is written. The corner switches once per gesture and
    /// the rim's direction switches when the drag crosses over, but writing
    /// either of them every frame marks the layer as needing to be drawn
    /// again, and the rim's gradient is the size of the whole card. The
    /// shadow's fade is the view's alpha, not the shadow's opacity, so the
    /// shadow itself is drawn once and then composited.
    private func apply(_ look: DrawerLook) {
        let bounds = cardView.bounds
        // Through UIView, not the layer: UIKit is told the card's geometry has
        // changed and works its safe area out again, which the card's hosting
        // controller then puts back to the screen's.
        cardView.transform = CATransform3DGetAffineTransform(look.cardTransform)
        cardShadow.transform = cardView.transform
        if look.corner != drawnCorner {
            drawnCorner = look.corner
            cardView.layer.cornerRadius = look.corner
            rimView.borderLayer.cornerRadius = look.corner
            cardShadow.layer.shadowPath = shadowPath(bounds, corner: look.corner)
        }
        if look.towardsTrailing != drawnRimTowardsTrailing {
            drawnRimTowardsTrailing = look.towardsTrailing
            cardShadow.layer.shadowOffset = shadowOffset(look)
            rimView.gradient.startPoint = rimStart(look)
            rimView.gradient.endPoint = rimEnd(look)
        }
        // The shadow's own opacity is fixed: the reveal fades the whole view,
        // which is a compositing the render server does, rather than a shadow
        // drawn again for every frame.
        cardShadow.alpha = look.reveal
        shadeView.alpha = look.reveal
        rimView.alpha = look.reveal
        // Through UIView, as the card's transform is: a transform set on the
        // layer moves the picture and the touches but not what UIKit tells
        // accessibility, which went on reading the drawer 44 points off.
        sidebarHost.view.transform = CGAffineTransform(translationX: look.sidebarShift, y: 0)
        planeHost.view.transform = CGAffineTransform(translationX: look.planeShift, y: 0)
    }

    /// The card's content is a still image while the drawer moves.
    ///
    /// The conversation page is a live SwiftUI tree under a full-screen mask, a
    /// shadow and glass. While the card is scaled and slid, that tree has to
    /// be drawn again for every frame, and a tree under a scale is drawn at
    /// the scale it is scaled to: the picture is redrawn, at a new size, as
    /// the card narrows, and the elements inside it move by a hair each time.
    /// The tree itself holds while a drawer moves (see `drawersStill`), so it
    /// is the same picture every frame -- so it is drawn once into a texture,
    /// and the render server moves that texture. The elements inside the card
    /// then travel as one body, at the display's own rate, and a main thread
    /// that is busy cannot make them jump.
    ///
    /// It is thawed when the drawer is at rest, so the page is live again for
    /// reading, for a new message and for the typewriter.
    private func freezeContent() {
        guard !contentFrozen else { return }
        contentFrozen = true
        let scale = view.window?.screen.scale ?? UIScreen.main.scale
        cardHost.view.layer.shouldRasterize = true
        cardHost.view.layer.rasterizationScale = scale
    }

    private func thawContent() {
        thawTask?.cancel()
        thawTask = nil
        guard contentFrozen else { return }
        contentFrozen = false
        cardHost.view.layer.shouldRasterize = false
    }

    /// Hold the card's content for as long as the drawer is moving, and let it
    /// live again once the drawer is at rest.
    private func holdContentWhileMoving() {
        let moving = shell.isDragging || shell.isSettling || CACurrentMediaTime() < motionEndsAt
        guard moving else {
            thawContent()
            return
        }
        freezeContent()
        guard thawTask == nil else { return }
        thawTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(80))
                guard let self else { return }
                if !self.shell.isDragging, !self.shell.isSettling, CACurrentMediaTime() >= self.motionEndsAt {
                    self.thawContent()
                    return
                }
            }
        }
    }

    /// Who may be touched and who is read out: decided by where the drawers
    /// are going, as it was when these were SwiftUI modifiers.
    ///
    /// The flags are the same on every frame of a gesture, so they are written
    /// when they change: each one asks UIKit to redo the work of the
    /// accessibility tree, and a drag does not need that work sixty times a
    /// second.
    private func applyState(_ look: DrawerLook) {
        let sidebarOpen = look.lead > 0.5
        let planeOpen = look.trail > 0.5
        if sidebarOpen != drawnSidebarOpen {
            drawnSidebarOpen = sidebarOpen
            sidebarHost.view.isUserInteractionEnabled = sidebarOpen
            sidebarHost.view.accessibilityElementsHidden = !sidebarOpen
        }
        if planeOpen != drawnPlaneOpen {
            drawnPlaneOpen = planeOpen
            planeHost.view.isUserInteractionEnabled = planeOpen
            planeHost.view.accessibilityElementsHidden = !planeOpen
        }
        let cardHidden = look.reveal > 0.5
        if cardHidden != drawnCardHidden {
            drawnCardHidden = cardHidden
            cardView.accessibilityElementsHidden = cardHidden
        }
        dismissView.frame = look.dismissFrame
        let dismissOpen = sidebarOpen || planeOpen
        if dismissOpen != drawnDismissOpen {
            drawnDismissOpen = dismissOpen
            dismissView.isUserInteractionEnabled = dismissOpen
            dismissView.isAccessibilityElement = dismissOpen
        }
        let label = look.lead > 0.02
            ? String(localized: "Close sidebar")
            : String(localized: "Close turns")
        if label != drawnDismissLabel {
            drawnDismissLabel = label
            dismissView.accessibilityLabel = label
        }
    }

    /// The edge of a gesture is a fade rather than a cut: the drawer under the
    /// card changes only when the drag crosses from one side to the other,
    /// never while the finger moves, and it fades with the smooth spring.
    private func fadeSides(to look: DrawerLook) {
        let sides = (look.leadingShown, look.trailingShown)
        guard sides != shownSides else { return }
        shownSides = sides
        let change = {
            self.sidebarHost.view.alpha = look.leadingShown ? 1 : 0
            self.planeHost.view.alpha = look.trailingShown ? 1 : 0
        }
        if reduceMotion {
            UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseInOut, .beginFromCurrentState], animations: change)
        } else {
            UIView.animate(
                springDuration: 0.5,
                bounce: 0,
                initialSpringVelocity: 0,
                delay: 0,
                options: [.beginFromCurrentState, .allowUserInteraction],
                animations: change,
            )
        }
    }

    private var shadowStrength: Float {
        traitCollection.userInterfaceStyle == .dark ? 0.5 : 0.16
    }

    private func shadowOffset(_ look: DrawerLook) -> CGSize {
        CGSize(width: look.towardsTrailing ? 8 : -8, height: 0)
    }

    private func shadowPath(_ bounds: CGRect, corner: CGFloat) -> CGPath {
        UIBezierPath(roundedRect: bounds, cornerRadius: corner).cgPath
    }

    private func rimStart(_ look: DrawerLook) -> CGPoint {
        CGPoint(x: look.towardsTrailing ? 1 : 0, y: 0.5)
    }

    private func rimEnd(_ look: DrawerLook) -> CGPoint {
        CGPoint(x: look.towardsTrailing ? 0 : 1, y: 0.5)
    }

    private func applyColours() {
        let traits = traitCollection
        shadeView.backgroundColor = UIColor.black.withAlphaComponent(traits.userInterfaceStyle == .dark ? 0.32 : 0.05)
        let accent = (UIColor(named: "AccentColor") ?? .tintColor).resolvedColor(with: traits)
        rimView.gradient.colors = [
            accent.withAlphaComponent(0.45).cgColor,
            UIColor.white.withAlphaComponent(0.06).cgColor,
            // Transparent white rather than clear, which is transparent black:
            // the layer interpolates colours as they are, and a black end
            // would grey the fade on its way out.
            UIColor.white.withAlphaComponent(0).cgColor,
        ]
        cardShadow.layer.shadowOpacity = shadowStrength
        if compact, isViewLoaded {
            withoutActions {
                cardShadow.alpha = look(at: progress).reveal
            }
        }
    }

    private func withoutActions(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    /// The sidebar's ground, under both drawers.
    private static let sidebarBackground = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.075, green: 0.082, blue: 0.098, alpha: 1)
            : UIColor(red: 0.953, green: 0.957, blue: 0.969, alpha: 1)
    }
}

/// The card's rim: an accent gradient seen only through a one-point border
/// drawn inside the card's edge.
private final class RimView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }
    var gradient: CAGradientLayer { unsafeDowncast(layer, to: CAGradientLayer.self) }
    let borderLayer = CALayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        borderLayer.borderWidth = 1
        borderLayer.borderColor = UIColor.white.cgColor
        borderLayer.cornerCurve = .continuous
        layer.mask = borderLayer
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        borderLayer.frame = bounds
        CATransaction.commit()
    }
}

/// The card, while it is pushed aside, is one big button back.
///
/// Always in the hierarchy on a phone, sized to the part of the card still on
/// screen; at rest it takes no touches and is hidden from accessibility.
private final class DismissView: UIView {
    var onClose: () -> Void = {}

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityTraits = .button
        accessibilityIdentifier = "shell.dismissSidebar"
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func tapped() { onClose() }

    override func accessibilityActivate() -> Bool {
        onClose()
        return true
    }
}

/// The iPad's columns: how far the sidebar and the index columns are out,
/// carried by the smooth spring -- `mizarSmooth`, critically damped over half a
/// second -- or under Reduce Motion by `mizarFade`'s 0.22 s ease.
///
/// Stepped once per frame on purpose: the conversation between the columns is
/// laid out again at each width, the way SwiftUI's animation of the width did.
@MainActor
private final class ColumnMotion: NSObject {
    private struct Track {
        var start: Double = 0
        var velocity: Double = 0
        var target: Double = 0
        var beginTime: CFTimeInterval = 0
        var reduced = false

        func state(at time: CFTimeInterval) -> (position: Double, velocity: Double) {
            let t = max(0, time - beginTime)
            if reduced {
                let u = min(1, t / 0.22)
                let eased = u < 0.5 ? 2 * u * u : 1 - pow(-2 * u + 2, 2) / 2
                return (start + (target - start) * eased, 0)
            }
            let omega = 2 * Double.pi / 0.5
            let a = start - target
            let b = velocity + omega * a
            let decay = exp(-omega * t)
            return (target + (a + b * t) * decay, (b - omega * (a + b * t)) * decay)
        }

        func done(at time: CFTimeInterval) -> Bool {
            let (x, v) = state(at: time)
            return reduced ? time - beginTime >= 0.22 : abs(x - target) < 0.0005 && abs(v) < 0.02
        }
    }

    var onFrame: () -> Void = {}
    private var leadTrack = Track(start: 1, target: 1)
    private var trailTrack = Track()
    private var link: CADisplayLink?
    private var placed = false

    var lead: CGFloat { CGFloat(link == nil ? leadTrack.target : leadTrack.state(at: CACurrentMediaTime()).position) }
    var trail: CGFloat { CGFloat(link == nil ? trailTrack.target : trailTrack.state(at: CACurrentMediaTime()).position) }

    func retarget(lead: CGFloat, trail: CGFloat, animated: Bool, reduced: Bool) {
        let now = CACurrentMediaTime()
        func update(_ track: inout Track, to target: CGFloat) {
            guard Double(target) != track.target || !placed else { return }
            if animated, placed {
                let state = link == nil ? (track.target, 0) : track.state(at: now)
                track = Track(start: state.0, velocity: state.1, target: Double(target), beginTime: now, reduced: reduced)
            } else {
                track = Track(start: Double(target), target: Double(target), beginTime: now)
            }
        }
        let before = (leadTrack.target, trailTrack.target)
        update(&leadTrack, to: lead)
        update(&trailTrack, to: trail)
        let changed = before != (leadTrack.target, trailTrack.target) || !placed
        let wasPlaced = placed
        placed = true
        guard changed else { return }
        if animated, wasPlaced {
            start()
        } else {
            onFrame()
        }
    }

    private func start() {
        guard link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(step(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func step(_ link: CADisplayLink) {
        let now = link.targetTimestamp
        if leadTrack.done(at: now), trailTrack.done(at: now) {
            link.invalidate()
            self.link = nil
        }
        onFrame()
    }
}
