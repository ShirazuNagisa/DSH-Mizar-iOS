//
//  ComposerLanguageSnapshotTests.swift
//  DSH-MizarTests
//
//  The composer's language in Chinese and in English: the command list, and
//  the failure card -- the copy assertions
//  `AppFlowNavigationTests.testInterfaceFollowsTheLanguageAndContentDoesNot`
//  makes across two full app launches, pushed down to snapshots
//  (docs/phase2-triage.md).
//
//  The field itself is no longer snapshotted: it became a `UITextView` behind
//  `UIViewRepresentable` (`ComposerTextInput`), which `ImageRenderer` cannot
//  draw, so its pilot is the identifier/copy contract below -- see the note on
//  `composerFieldIdentifiersAndPlaceholderAreAddressable`.
//
//  Two renders:
//  - `CommandList`, the app's own view -- it takes the gate as a `Bool` and
//    owns no environment (`AttachmentGateSnapshotTests` already renders it),
//    and since `ComposerBar.commands`' titles are catalogue keys its rows
//    follow the locale too;
//  - `FailureCard`, the app's own view, internal for exactly this
//    (`ConversationView`). Its message is hard-coded English on purpose: the
//    turn's content never translates with the interface, and the pixels prove
//    it -- the same sentence sits under a Chinese and an English heading.
//
//  The locale follows the environment, not the simulator: the harness pins
//  `en_US` by default and each argument overrides it, so one record run on the
//  canonical English-locale simulator produces both goldens.
//

import MizarKit
import SwiftUI
import UIKit
import Testing
@testable import DSH_Mizar

@MainActor
struct ComposerLanguageSnapshotTests {
    enum Language: String, CaseIterable, Sendable {
        /// 简体中文 -- the app's other language.
        case zhHans = "zh-Hans"
        /// English, what the harness pins by default.
        case english = "en"

        var locale: Locale { Locale(identifier: rawValue) }
    }

    // MARK: - The field

    /// The field is a `UITextView` behind `UIViewRepresentable`
    /// (`ComposerTextInput`), and `ImageRenderer` does not draw UIKit-backed
    /// views -- the field would render as an empty rectangle, the same
    /// finding `AttachmentStripSnapshotTests` records for a `ScrollView`.
    /// The old pilot rebuilt an approximate modifier chain around a SwiftUI
    /// `TextField`, which verified a copy of the field rather than the field:
    /// its `.lineLimit(1...8)` had already drifted from the production
    /// expanded branch. This pilot therefore stops at the identifier and
    /// copy contract, which is the half a unit test can make honestly today
    /// -- the placeholder is resolved through the catalogue, so the field
    /// asks in the interface's language, and the identifier the UI suite
    /// queries is still declared in the view's source.
    ///
    /// The long-text behaviour itself is UI-test territory (a real window,
    /// a real keyboard, a real scroll range); the diagnosis that sent this
    /// component here is `docs/ios-three-issues-diagnosis-2026-10-22.md`.
    @Test
    func composerFieldIdentifiersAndPlaceholderAreAddressable() throws {
        try AppSourceContract.expectIdentifiers(
            ["composer.field"],
            in: "DSH-Mizar/Views/ComposerView.swift",
        )
        try AppSourceContract.expectFragments(
            [#"String(localized: "Ask your agent…")"#],
            in: "DSH-Mizar/Views/ComposerView.swift",
            describing: "the placeholder's catalogue key",
        )
    }

    @Test
    func editorMeasuresMultilineDraftAndClampsRestingHeight() {
        let editor = ComposerEditorView(frame: CGRect(x: 0, y: 0, width: 320, height: 24))
        editor.font = .preferredFont(forTextStyle: .body)
        editor.textContainerInset = .zero
        editor.textContainer.lineFragmentPadding = 0
        var measured: CGFloat = 0
        editor.onNaturalHeight = { measured = $0 }
        editor.text = "first"
        editor.measureAndReportNaturalHeight()
        let oneLine = measured
        editor.text = "first\nsecond\nthird"
        editor.measureAndReportNaturalHeight()
        #expect(measured > oneLine * 2)
        editor.text = (1...80).map { "line \($0)" }.joined(separator: "\n")
        editor.measureAndReportNaturalHeight()
        let lineHeight = editor.font!.lineHeight
        #expect(abs(measured - lineHeight * 8) < 1)
        editor.isExpanded = true
        editor.measureAndReportNaturalHeight()
        #expect(abs(measured - lineHeight * 8) < 1, "expanded viewport must not poison the resting height")
    }

    @Test
    func heightReportsAreDeferredAndCoalesced() async {
        var reports: [CGFloat] = []
        let coordinator = ComposerTextInputCoordinator(
            text: .constant(""), onFocusChanged: { _ in },
            onMeasuredHeight: { reports.append($0) }
        )
        coordinator.reportMeasuredHeight(24)
        coordinator.reportMeasuredHeight(72)
        #expect(reports.isEmpty)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(reports == [72])
    }

    @Test
    func initialPlacementRequiresValidBottomGeometry() {
        func atBottom(_ content: CGFloat, _ viewport: CGFloat, _ minY: CGFloat, _ maxY: CGFloat) -> Bool {
            ConversationPlacementGeometry(
                contentHeight: content, viewportHeight: viewport,
                visibleMinY: minY, visibleMaxY: maxY
            ).isAtBottom(tolerance: 2)
        }
        #expect(atBottom(2000, 600, 1400, 2000))
        #expect(!atBottom(2000, 600, 0, 600))
        #expect(!atBottom(2000, 600, 2001, 2601))
        #expect(atBottom(200, 600, 0, 600))
        // A short page pushed down a few points is still entirely on screen;
        // the composer reserve used to make exactly this shape fail.
        #expect(atBottom(200, 600, 10, 610))
        #expect(!atBottom(200, 600, 300, 900))
        #expect(!atBottom(0, 600, 0, 600))
        #expect(!atBottom(200, 0, 0, 200))
        #expect(!atBottom(.nan, 600, 0, 600))

        func withInsets(_ content: CGFloat, _ minY: CGFloat, _ maxY: CGFloat,
                        top: CGFloat = 116, bottom: CGFloat = 76) -> Bool {
            ConversationPlacementGeometry(
                contentHeight: content, viewportHeight: 652,
                visibleMinY: minY, visibleMaxY: maxY,
                topInset: top, bottomInset: bottom
            ).isAtBottom(tolerance: 2)
        }
        // Values observed from the real hosted ScrollView red test, plus
        // positions above and below that same physical bottom.
        #expect(withInsets(6134, 5366, 6210))
        #expect(!withInsets(6134, 5266, 6110))
        #expect(!withInsets(6134, 5466, 6310))
        #expect(withInsets(200, -116, 728))
        #expect(!withInsets(200, 250, 1094))
        #expect(!withInsets(6134, 5366, 6210, bottom: .nan))
    }

    @Test
    func failedPlacementCanRestartAndAcceptLateGeometryWithoutStealingNavigation() {
        let bottom = ConversationPlacementGeometry(
            contentHeight: 6134, viewportHeight: 652,
            visibleMinY: 5366, visibleMaxY: 6210, topInset: 116, bottomInset: 76
        )
        let top = ConversationPlacementGeometry(
            contentHeight: 6134, viewportHeight: 652,
            visibleMinY: -116, visibleMaxY: 728, topInset: 116, bottomInset: 76
        )
        var state = InitialPlacement.positioningFailed
        let restarted = state.beginIfNeeded(generation: 9)
        #expect(restarted)
        #expect(state == .placing(generation: 9))
        let acceptedTop = state.finishIfPositioned(top, tolerance: 4)
        #expect(!acceptedTop)
        // A failed placement no longer gates the page: the conversation is
        // revealed at the best position and corrected underneath.
        #expect(state.isRevealed)
        let acceptedBottom = state.finishIfPositioned(bottom, tolerance: 4)
        #expect(acceptedBottom)
        #expect(state == .ready)
        let restartedReady = state.beginIfNeeded(generation: 10)
        #expect(!restartedReady)

        state = .positioningFailed
        let acceptedMissing = state.finishIfPositioned(nil, tolerance: 4)
        #expect(!acceptedMissing)
        let acceptedLate = state.finishIfPositioned(bottom, tolerance: 4)
        #expect(acceptedLate)
        #expect(state.isRevealed)
        state = .navigating
        let acceptedNavigation = state.finishIfPositioned(bottom, tolerance: 4)
        let restartedNavigation = state.beginIfNeeded(generation: 11)
        #expect(!acceptedNavigation)
        #expect(!restartedNavigation)
        #expect(state == .navigating)
    }

    /// Exercise the acceptance function with ScrollGeometry measured by a real
    /// SwiftUI ScrollView, not hand-authored rectangles. The navigation bar and
    /// bottom safe-area inset model the environment of SessionDetailView.
    /// UIKit's scrollable bottom is an independent oracle for physical position.
    @Test
    func longConversationAtPhysicalBottomPassesPlacementWithSafeAreaInsets() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let observations = HostedPlacementObservations()
        let controller = UIHostingController(rootView: HostedPlacementScrollView(observations: observations))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }

        var measuredScroll: UIScrollView?
        for _ in 0..<100 {
            controller.view.layoutIfNeeded()
            measuredScroll = placementScrollView(in: controller.view)
            if let scroll = measuredScroll,
               scroll.contentSize.height > scroll.bounds.height * 2,
               scroll.adjustedContentInset.bottom >= 72,
               observations.latest != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let scroll = try #require(measuredScroll, "hosted SwiftUI scroll view was not created")
        #expect(scroll.contentSize.height > scroll.bounds.height * 2, "fixture must contain genuinely long content")
        #expect(scroll.adjustedContentInset.bottom >= 72, "fixture must establish a real adjusted bottom inset")

        // UIScrollView's maximum resting offset includes adjusted insets. No
        // application geometry fields are fabricated or changed for this test.
        let physicalBottom = max(
            -scroll.adjustedContentInset.top,
            scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom
        )
        scroll.setContentOffset(CGPoint(x: 0, y: physicalBottom), animated: false)
        for _ in 0..<50 {
            controller.view.layoutIfNeeded()
            if let latest = observations.latest,
               abs(latest.offsetY - scroll.contentOffset.y) < 1,
               abs(scroll.contentOffset.y - physicalBottom) < 1 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let sample = try #require(observations.latest, "SwiftUI did not report scroll geometry")
        #expect(abs(scroll.contentOffset.y - physicalBottom) < 1, "fixture did not actually reach UIKit's physical bottom")
        #expect(sample.bottomInset >= 72, "SwiftUI must also observe the safe-area content inset")
        #expect(
            sample.placement.isAtBottom(tolerance: 2),
            "A physically bottomed real ScrollView must be accepted: content=\(sample.placement.contentHeight), viewport=\(sample.placement.viewportHeight), visible=\(sample.placement.visibleMinY)...\(sample.placement.visibleMaxY), insets=\(sample.topInset)/\(sample.bottomInset), UIKitOffset=\(scroll.contentOffset.y), SwiftUIOffset=\(sample.offsetY)"
        )
    }

    /// Real production ComposerView in a window; samples its rendered UIKit
    /// background and text viewport on CADisplayLink, not just final layout.
    @Test
    func composerCollapseKeepsPresentationBottomFixedForEmptyAndLongDraft() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let state = ComposerMotionState()
        let samples = ComposerMotionRecorder()
        let controller = UIHostingController(rootView: ComposerMotionHost(state: state, recorder: samples))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            samples.stop()
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }
        try await Task.sleep(for: .milliseconds(600))
        samples.root = controller.view
        samples.start()
        for focused in [false, true] {
        for draftMode in 0...2 {
            let longDraft = draftMode != 0
            let storedDraft = (1...80).map { "Long draft line \($0): actual editor input" }.joined(separator: "\n")
            state.text = draftMode == 2 ? storedDraft : ""
            state.focused = focused
            state.expanded = false
            try await Task.sleep(for: .milliseconds(500))
            try await samples.waitUntilStable()
            samples.frames = []
            samples.label = "focus-\(focused)-mode-\(draftMode)-expand"
            samples.capture()
            withMizarAnimation(.mizarSmooth) { state.expanded = true }
            try await Task.sleep(for: .milliseconds(1200))
            let expansion = samples.frames
            let expansionBase = try #require(expansion.first)
            let expansionDrift = expansion.map { abs($0.shell.maxY - expansionBase.shell.maxY) }.max() ?? 0
            print("[composer-motion] \(samples.label) frames=\(expansion.count) bottomDrift=\(expansionDrift)")
            #expect(expansion.count >= 15)
            #expect(expansionDrift <= 1, "expansion must keep bottom fixed")
            #expect(window.isKeyWindow && !window.isHidden)
            #expect(motionEditor(in: controller.view)?.isFirstResponder == focused)
            if draftMode == 1 {
                let editor = try #require(motionEditor(in: controller.view))
                editor.text = storedDraft
                editor.delegate?.textViewDidChange?(editor)
                try await Task.sleep(for: .milliseconds(400))
            }
            try await samples.waitUntilStable()
            let expandedEditor = try #require(motionEditor(in: controller.view))
            #expect(expandedEditor.bounds.height > UIFont.preferredFont(forTextStyle: .body).lineHeight * 8 + 20)
            samples.frames = []
            samples.label = "focus-\(focused)-mode-\(draftMode)-collapse"
            samples.capture()
            withMizarAnimation(.mizarSmooth) { state.expanded = false }
            try await Task.sleep(for: .milliseconds(800))
            samples.capture()
            let frames = samples.frames
            #expect(frames.count >= 15, "must sample the animation, not only endpoints")
            let baseline = try #require(frames.first)
            let drift = frames.map { abs($0.shell.maxY - baseline.shell.maxY) }.max() ?? 0
            let topTravel = (frames.map { $0.shell.minY }.max() ?? 0) - (frames.map { $0.shell.minY }.min() ?? 0)
            print("[composer-motion] \(samples.label) frames=\(frames.count) bottomDrift=\(drift) topTravel=\(topTravel)")
            for frame in frames {
                print("[composer-motion] \(samples.label) t=\(frame.time - baseline.time) shell=\(frame.shell) editor=\(frame.editor) focused=\(frame.focused) keyboard=\(frame.keyboard)")
            }
            #expect(topTravel > 30, "fixture must actually collapse the production composer")
            let focusStayed = frames.allSatisfy { $0.focused == focused }
            let minimumEditor = frames.map { $0.editor.height }.min() ?? 0
            let reverseTravel = zip(frames, frames.dropFirst()).map { max(0, $0.shell.minY - $1.shell.minY) }.max() ?? 0
            print("[composer-motion] \(samples.label) minEditor=\(minimumEditor) reverseTopStep=\(reverseTravel)")
            #expect(focusStayed, "focus must remain stable during collapse")
            #expect(minimumEditor > 1, "viewport must never collapse to zero and redraw")
            #expect(reverseTravel <= 1, "top must not reverse direction during collapse")
            #expect(drift <= 1, "\(samples.label): presentation bottom moved \(drift)pt; only top edge may move")
            try await samples.waitUntilStable()
            let collapsedTarget = try #require(state.collapsedTarget, "collapsed-target measurement must initialize, not silently use old fallback")
            let realShell = try #require(samples.shell)
            print("[composer-target] label=\(samples.label) target=\(collapsedTarget) realCollapsedShell=\(realShell.bounds.height)")
            #expect(abs(collapsedTarget - realShell.bounds.height) <= 1, "collapsed target must agree with actual compact shell")
            if longDraft {
                let restingEditor = try #require(motionEditor(in: controller.view))
                #expect(abs(restingEditor.bounds.height - UIFont.preferredFont(forTextStyle: .body).lineHeight * 8) < 1)
            }
        }
        }
    }

    @Test(arguments: ["long-unchanged", "empty-to-long", "long-to-empty", "repeat-rapid"])
    func realSessionDetailCollapseDoesNotTeleportConversation(_ mode: String) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let cache = InMemoryConversationCache()
        let id = "scroll-motion-offline"
        let items: [ConversationItem] = (1...40).map { number in
            .message(id: "seq-\(number)", role: number.isMultiple(of: 2) ? .assistant : .user,
                     text: "Message \(number). " + String(repeating: "Actual conversation body. ", count: 8),
                     at: Date(timeIntervalSince1970: Double(number)))
        }
        await cache.save(CachedConversation(sessionId: id, items: items, throughSeq: nil))
        let model = AppModel(conversations: cache)
        let state = SessionScrollMotionState()
        let recorder = SessionScrollMotionRecorder()
        let controller = UIHostingController(rootView:
            NavigationStack { SessionDetailView(sessionId: id, onComposerBindingAvailable: { state.expanded = $0 }, onPlacementChanged: { state.placement = $0 }, onConversationContentBottomChanged: { state.contentBottom = $0 }, onComposerFrameChanged: { state.composerFrame = $0 }) }
                .environment(model).environment(TurnIndex()).environment(ShellState())
        )
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(for: .seconds(2))
        let editor = try #require(motionEditor(in: controller.view))
        let binding = try #require(state.expanded)
        print("[session-scroll] placementBeforeTrigger=\(String(describing: state.placement))")
        try #require(state.placement == .ready, "fixture must reveal the real conversation before measuring motion")
        let scroll = try #require(sessionMotionScroll(in: controller.view))
        recorder.scroll = scroll
        recorder.editor = editor
        editor.becomeFirstResponder()
        try await Task.sleep(for: .seconds(1))
        try #require(editor.isFirstResponder, "focused real-session path must actually show the editor keyboard")
        recorder.start()
        defer { recorder.stop() }
        let longDraft = (1...80).map { "Draft line \($0)" }.joined(separator: "\n")
        editor.text = mode == "empty-to-long" ? "" : longDraft
        editor.delegate?.textViewDidChange?(editor)
        try await Task.sleep(for: .seconds(1))
        for _ in 0..<30 {
            scroll.setContentOffset(CGPoint(x: 0, y: max(-scroll.adjustedContentInset.top, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)), animated: false)
            try await Task.sleep(for: .milliseconds(100))
        }
        let initialBottomDistance = scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom - scroll.contentOffset.y
        print("[session-scroll] initialBottomDistance=\(initialBottomDistance) size=\(scroll.contentSize.height) offset=\(scroll.contentOffset.y)")
        #expect(abs(initialBottomDistance) <= 1, "fixture must start at the actual bottom, not an estimated LazyVStack extent")
        withMizarAnimation(.mizarSmooth) { binding.wrappedValue = true }
        try await Task.sleep(for: .milliseconds(1200))
        for _ in 0..<30 {
            scroll.setContentOffset(CGPoint(x: 0, y: max(-scroll.adjustedContentInset.top, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)), animated: false)
            try await Task.sleep(for: .milliseconds(100))
        }
        if mode == "empty-to-long" || mode == "long-to-empty" {
            let currentEditor = try #require(motionEditor(in: controller.view))
            currentEditor.text = mode == "empty-to-long" ? longDraft : ""
            currentEditor.delegate?.textViewDidChange?(currentEditor)
            try await Task.sleep(for: .seconds(1))
        }
        if mode == "repeat-rapid" {
            for text in ["", longDraft, "short", longDraft] {
                let currentEditor = try #require(motionEditor(in: controller.view))
                currentEditor.text = text
                currentEditor.delegate?.textViewDidChange?(currentEditor)
                try await Task.sleep(for: .milliseconds(150))
            }
            withMizarAnimation(.mizarSmooth) { binding.wrappedValue = false }
            try await Task.sleep(for: .milliseconds(100))
            withMizarAnimation(.mizarSmooth) { binding.wrappedValue = true }
            try await Task.sleep(for: .seconds(1))
        }
        let expandedBottomDistance = scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom - scroll.contentOffset.y
        print("[session-scroll] expandedBottomDistance=\(expandedBottomDistance)")
        #expect(abs(expandedBottomDistance) <= 1)
        recorder.frames = []
        recorder.capture()
        withMizarAnimation(.mizarSmooth) { binding.wrappedValue = false }
        try await Task.sleep(for: .milliseconds(1800))
        let frames = recorder.frames
        let first = try #require(frames.first)
        for frame in frames {
            print("[session-scroll] t=\(frame.time-first.time) offset=\(frame.offset) presentation=\(frame.presentationOffset) size=\(frame.contentHeight) viewport=\(frame.viewport) insets=\(frame.topInset),\(frame.bottomInset) editorHeight=\(frame.editorHeight)")
        }
        let late = frames.filter { $0.time-first.time >= 0.55 }
        let jumps = zip(late, late.dropFirst()).map { abs($1.presentationOffset - $0.presentationOffset) }
        let maximum = jumps.max() ?? 0
        let finalDistance = scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom - scroll.contentOffset.y
        print("[session-scroll] mode=\(mode) frames=\(frames.count) maxLateFrameJump=\(maximum) finalBottomDistance=\(finalDistance)")
        let compactEditor = try #require(motionEditor(in: controller.view))
        let editorScreen = compactEditor.convert(compactEditor.bounds, to: window)
        let contentBottomScreen = scroll.convert(CGPoint(x: 0, y: scroll.contentSize.height), to: window).y
        print("[session-scroll] overlay mode=\(mode) compactEditorTop=\(editorScreen.minY) editorHeight=\(editorScreen.height) actualContentEnd=\(contentBottomScreen)")
        let messageBottom = try #require(state.contentBottom)
        let composerFrame = try #require(state.composerFrame)
        let visibleGap = composerFrame.minY - messageBottom
        print("[session-scroll] overlap mode=\(mode) messageBottom=\(messageBottom) compactShell=\(composerFrame) gap=\(visibleGap)")
        #expect(visibleGap >= 0, "actual latest message must not be hidden behind compact composer")
        #expect(visibleGap <= 32, "stale long reservation must not leave an excessive gap after draft deletion")
        #expect(abs(finalDistance) <= 1, "must preserve actual bottom, not merely suppress correction")
        #expect(frames.count > 60)
        #expect(maximum <= 2, "conversation must not teleport after composer collapse settles")
    }

    // MARK: - The commands

    @Test(arguments: Language.allCases)
    func composerCommandTitlesFollowTheLanguage(_ language: Language) throws {
        try AppSourceContract.expectIdentifiers(
            ["composer.commands"],
            in: "DSH-Mizar/Views/ComposerBar.swift",
        )
        try AppSourceContract.expectFragments(
            [
                #""/goal", "Goal", "target""#,
                #""command.\(command.slash.dropFirst())""#,
            ],
            in: "DSH-Mizar/Views/ComposerBar.swift",
            describing: "the goal command's title key and wire identifier",
        )

        let snapshot = try SnapshotHarness.assertSnapshot(
            of: CommandList(
                canAttach: true,
                onAttachment: { _ in },
                onPick: { _ in },
            ),
            named: "ComposerCommands-\(language.rawValue)",
            size: CGSize(width: 300, height: 380),
            locale: language.locale,
        )
        #expect(snapshot.pixelWidth == 600)
        #expect(snapshot.pixelHeight == 760)
    }

    // MARK: - The failure card

    @Test(arguments: Language.allCases)
    func failureCardFollowsTheLanguageButNotTheContent(_ language: Language) throws {
        try AppSourceContract.expectFragments(
            [#"Label("The turn ended without a response", systemImage: "exclamationmark.triangle.fill")"#],
            in: "DSH-Mizar/Views/ConversationView.swift",
            describing: "the failure card's copy key",
        )

        // The message is the UI test's own fixture sentence, hard-coded in
        // English: the turn's content is host output and never translates with
        // the interface. The pixels are the proof -- the same sentence under
        // 本轮没有产生回复 and under "The turn ended without a response". An
        // hour-old failure never arms the shake (the onAppear guard is twenty
        // seconds), so the render is the resting card.
        let snapshot = try SnapshotHarness.assertSnapshot(
            of: FailureCard(
                message: "Refactor the parser and run the tests.",
                at: Date(timeIntervalSinceNow: -3600),
            )
            .padding(.horizontal, 16),
            named: "FailureCardLanguage-\(language.rawValue)",
            size: CGSize(width: 390, height: 80),
            locale: language.locale,
        )
        #expect(snapshot.pixelWidth == 780)
        #expect(snapshot.pixelHeight == 160)
    }
}

@MainActor
private final class SessionScrollMotionState {
    var expanded: Binding<Bool>?
    var placement: InitialPlacement?
    var contentBottom: CGFloat?
    var composerFrame: CGRect?
}

@MainActor
private func sessionMotionScroll(in view: UIView) -> UIScrollView? {
    if let scroll = view as? UIScrollView, !(scroll is UITextView), scroll.contentSize.height > scroll.bounds.height * 2 { return scroll }
    for child in view.subviews { if let found = sessionMotionScroll(in: child) { return found } }
    return nil
}

@MainActor
private final class SessionScrollMotionRecorder: NSObject {
    struct Frame {
        var time: CFTimeInterval
        var offset: CGFloat
        var presentationOffset: CGFloat
        var contentHeight: CGFloat
        var viewport: CGFloat
        var topInset: CGFloat
        var bottomInset: CGFloat
        var editorHeight: CGFloat
    }
    weak var scroll: UIScrollView?
    weak var editor: ComposerEditorView?
    var frames: [Frame] = []
    private var link: CADisplayLink?
    func start() {
        let link = CADisplayLink(target: self, selector: #selector(capture))
        link.add(to: .main, forMode: .common)
        self.link = link
    }
    func stop() { link?.invalidate(); link = nil }
    @objc func capture() {
        guard let scroll, let editor else { return }
        frames.append(Frame(time: CACurrentMediaTime(), offset: scroll.contentOffset.y,
                            presentationOffset: (scroll.layer.presentation() ?? scroll.layer).bounds.origin.y,
                            contentHeight: scroll.contentSize.height, viewport: scroll.bounds.height,
                            topInset: scroll.adjustedContentInset.top, bottomInset: scroll.adjustedContentInset.bottom,
                            editorHeight: (editor.layer.presentation() ?? editor.layer).bounds.height))
    }
}

@MainActor
@Observable
private final class ComposerMotionState {
    var text = ""
    var expanded = false
    var focused = false
    var collapsedTarget: CGFloat?
}

private struct ComposerMotionHost: View {
    @Bindable var state: ComposerMotionState
    let recorder: ComposerMotionRecorder
    @State private var model = AppModel()

    var body: some View {
        Color.white.overlay(alignment: .bottom) {
            GeometryReader { _ in
                VStack(spacing: 8) {
                    Spacer(minLength: 0)
                    ComposerView(
                        sessionId: "motion-offline", stats: nil,
                        text: $state.text, focused: $state.focused,
                        expanded: $state.expanded,
                        showingModel: .constant(false), showingContext: .constant(false),
                        showingCommands: .constant(false), onSent: { _ in },
                        onCollapsedHeightChanged: { state.collapsedTarget = $0 }
                    )
                    .background(ComposerMotionProbe(recorder: recorder))
                    .frame(maxHeight: state.expanded ? .infinity : nil)
                }
            }
        }
        .coordinateSpace(.named(SessionDetailView.space))
        .environment(model)
    }
}

private struct ComposerMotionProbe: UIViewRepresentable {
    let recorder: ComposerMotionRecorder
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        recorder.shell = view
        return view
    }
    func updateUIView(_ view: UIView, context: Context) {}
}

@MainActor
private final class ComposerMotionRecorder: NSObject {
    struct Frame {
        var time: CFTimeInterval
        var shell: CGRect
        var editor: CGRect
        var focused: Bool
        var keyboard: CGRect
    }
    var keyboardFrame: CGRect = .zero
    private var keyboardObserver: NSObjectProtocol?
    weak var root: UIView?
    weak var shell: UIView?
    var frames: [Frame] = []
    var label = ""
    private var link: CADisplayLink?
    func start() {
        keyboardObserver = NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { [weak self] notification in
            let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect ?? .zero
            MainActor.assumeIsolated { self?.keyboardFrame = frame }
        }
        let link = CADisplayLink(target: self, selector: #selector(capture))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }
    func waitUntilStable() async throws {
        // Real presentation geometry, not a timer-only claim of stability.
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(50))
            let recent = Array(frames.suffix(8))
            guard recent.count == 8, let first = recent.first else { continue }
            let stable = recent.allSatisfy {
                abs($0.shell.maxY - first.shell.maxY) < 0.05 &&
                abs($0.shell.minY - first.shell.minY) < 0.05 &&
                abs($0.editor.height - first.editor.height) < 0.05 &&
                $0.focused == first.focused && $0.keyboard == first.keyboard
            }
            if stable { return }
        }
        Issue.record("presentation geometry did not settle within 5 seconds")
    }
    func stop() {
        link?.invalidate(); link = nil
        if let keyboardObserver { NotificationCenter.default.removeObserver(keyboardObserver) }
        keyboardObserver = nil
    }
    @objc func capture() {
        guard let root, let shell, let editor = motionEditor(in: root) else { return }
        let destination = root.layer.presentation() ?? root.layer
        let shellLayer = shell.layer.presentation() ?? shell.layer
        let editorLayer = editor.layer.presentation() ?? editor.layer
        frames.append(Frame(
            time: CACurrentMediaTime(),
            shell: shellLayer.convert(shellLayer.bounds, to: destination),
            editor: editorLayer.convert(editorLayer.bounds, to: destination),
            focused: editor.isFirstResponder,
            keyboard: keyboardFrame
        ))
    }
}

@MainActor
private func motionEditor(in view: UIView) -> ComposerEditorView? {
    if let editor = view as? ComposerEditorView { return editor }
    for child in view.subviews {
        if let editor = motionEditor(in: child) { return editor }
    }
    return nil
}

@MainActor
private final class HostedPlacementObservations {
    var latest: HostedPlacementSample?
}

private struct HostedPlacementSample: Equatable {
    var placement: ConversationPlacementGeometry
    var offsetY: CGFloat
    var topInset: CGFloat
    var bottomInset: CGFloat
}

private struct HostedPlacementScrollView: View {
    let observations: HostedPlacementObservations

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(0..<100) { index in
                            Text("Turn \(index): a long conversation fixture")
                                .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
                        }
                        Color.clear.frame(height: 126).id("hosted.conversation.end")
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 8)
                }
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .defaultScrollAnchor(.bottom, for: .sizeChanges)
                .onScrollGeometryChange(for: HostedPlacementSample.self) { geometry in
                    HostedPlacementSample(
                        placement: ConversationPlacementGeometry(
                            contentHeight: geometry.contentSize.height,
                            viewportHeight: geometry.containerSize.height,
                            visibleMinY: geometry.visibleRect.minY,
                            visibleMaxY: geometry.visibleRect.maxY,
                            topInset: geometry.contentInsets.top,
                            bottomInset: geometry.contentInsets.bottom
                        ),
                        offsetY: geometry.contentOffset.y,
                        topInset: geometry.contentInsets.top,
                        bottomInset: geometry.contentInsets.bottom
                    )
                } action: { _, sample in
                    observations.latest = sample
                }
                .task {
                    await Task.yield()
                    proxy.scrollTo("hosted.conversation.end", anchor: .bottom)
                }
            }
            .navigationTitle("Hosted conversation")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear.frame(height: 72)
            }
        }
    }
}

@MainActor
private func placementScrollView(in view: UIView) -> UIScrollView? {
    if let scroll = view as? UIScrollView { return scroll }
    for child in view.subviews {
        if let scroll = placementScrollView(in: child) { return scroll }
    }
    return nil
}
