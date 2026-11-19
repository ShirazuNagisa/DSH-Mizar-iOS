//
//  ComposerView.swift
//  DSH-Mizar
//
//  Sending a prompt, and stopping one.
//
//  One slab of glass: the field on top, growing with the text; the attachments,
//  when there are any; and along the bottom edge the controls -- commands, the
//  model, the context dial -- with the one round button at the end. The button
//  carries both actions, and which one it carries is the whole state machine:
//
//    the session is running, nothing typed, nothing attached     -> stop
//    anything else                                               -> send
//
//  That is DSH's own rule, and it is right for the same reason it is right
//  there: mid-turn the thing an operator most often wants is to interrupt, and
//  the second most common is to queue something up. One button that changes
//  meaning keeps both one tap away; it changes shape as it changes meaning, so
//  the meaning is never a surprise.
//
//  What "queue something up" means is the operator's choice, and it is the
//  guided-send switch in Settings. On, a send into a running turn travels at
//  once with `mode: "steer"`: the host feeds it to the model inside the turn and
//  nothing is interrupted. Off -- the default -- the phone keeps the text in a
//  bar above this field until the turn ends, because a message the host has
//  already queued cannot be called back, and calling it back is what the bar is
//  for. See ``PendingPromptBar``.
//
//  Attachments are part of the paid feature set, which a direct link on the
//  operator's own network also unlocks: nothing there is carried by the relay,
//  which is the commercial reason the two go together. The buttons live in the
//  command popover and draw their own lock when the set is not available;
//  tapping a locked one opens the account screen, because a refusal that
//  explains itself is a refusal the operator can act on.
//

import MizarKit
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ComposerView: View {
    let sessionId: String
    let stats: SessionStatsFrame?
    /// What has been typed. Owned by the screen, because the command list puts
    /// text in here -- a command is something the operator finishes typing.
    @Binding var text: String
    /// Whether the field holds the keyboard. Owned by the screen so a tap on the
    /// conversation can put it away.
    @Binding var focused: Bool
    /// Whether the composer is opened out into its tall, focused-input form.
    /// Owned by the screen: the room the conversation reserves and the dock's
    /// presence both answer to it.
    @Binding var expanded: Bool
    @Binding var showingModel: Bool
    @Binding var showingContext: Bool
    @Binding var showingCommands: Bool
    /// Whether the rewrite's intent window is out. Owned by the screen, like
    /// the other panels: a popover's content is rebuilt while it is up.
    @Binding var showingEnhance: Bool
    /// The two on-device entries' state, owned by the screen so a task survives
    /// the rebuids a scrolling conversation causes.
    let onDevice: ComposerOnDeviceInput
    /// Called the moment a send is tapped, with what is being sent: the screen
    /// puts it in flight towards the conversation before the host has answered.
    var onWillSend: (String) -> Void = { _ in }
    /// Called with the text the host accepted, so the conversation can pick it up.
    let onSent: (String) async -> Void
    /// Called when the host refused it; the text is back in the field.
    var onSendFailed: (String) -> Void = { _ in }
    /// The measured resting shell height, even while the editor is expanded.
    /// The screen reserves this space without waiting for collapse to finish.
    var onCollapsedHeightChanged: ((CGFloat) -> Void)? = nil
    /// Re-read the usage frame after the context page compacts it.
    var onContextChanged: () async -> Void = {}
    /// The token names the field may draw as pills: the two commands plus the
    /// connected computer's skills. Owned by the screen, which reads the synced
    /// list, because a view that fetched here would fetch once per rebuild.
    var knownTokenNames: [String] = []
    /// A token the palette asked the field to put down, consumed once.
    var insertion: ComposerInsertion?
    /// Called after the field placed ``insertion``, so the screen clears it.
    var onInsertionApplied: () -> Void = {}
    /// Whether the field is sitting on a lone `/`, which shows the palette's
    /// hint above the composer.
    var onSlashTokenChanged: (Bool) -> Void = { _ in }
    /// Open the command and skill palette from the `+` window.
    var onBrowseCommands: () -> Void = {}

    @Environment(AppModel.self) private var model
    @State private var sending = false
    @State private var stopping = false
    /// Bumped on every send, to bounce the arrow.
    @State private var sends = 0
    // MARK: On-device input

    /// Where the caret or selection last was, in plain-text offsets.
    ///
    /// Reported by the editor because only it knows: a hold-to-talk recording
    /// has to put its words where the caret stood when the finger went down,
    /// and neither the rewriter nor the microphone can ask a `UITextView` from
    /// here.
    @State private var composerSelection = NSRange(location: 0, length: 0)
    /// Bumped whenever the draft changes, so work that started against an
    /// earlier draft can tell it no longer speaks for what is on screen.
    @State private var draftRevision = 0
    /// A replacement waiting for the editor to place it, once.
    @State private var pendingEdit: ComposerEdit?
    /// Whether the current press has crossed the cancel line, so the strip can
    /// say what letting go will do.
    @State private var dictationCancelling = false
    /// The scene's phase, for stopping a rewrite and a recording that nobody is
    /// waiting for any more.
    @Environment(\.scenePhase) private var scenePhase
    /// Whether an input method is mid-composition. A rewrite started now would
    /// be a rewrite of a draft that is still being chosen between.
    @State private var isComposing = false

    /// The field's resting height, measured by the editor and clamped to eight lines.
    ///
    /// The resting composer is laid out from this rather than from the
    /// editor's own ambition: a `UIViewRepresentable` fills whatever it is
    /// proposed, and the field used to wrap its content only because a
    /// SwiftUI `TextField` has an intrinsic height. One line of body text is
    /// the starting estimate, so the first layout is a line tall and the
    /// first measurement corrects it before it is drawn.
    @State private var fieldHeight: CGFloat = UIFont.preferredFont(forTextStyle: .body).lineHeight
    @State private var restingInsets: CGFloat?

    // MARK: Attachments

    /// What is attached to the next send.
    @State private var attachments: [AttachmentDraft] = []
    /// Where the upload writes its progress, out of the socket's executor.
    @State private var uploadProgress = AttachmentProgress()
    /// The items picked from the photo library, before they are normalised.
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showingPhotoPicker = false
    @State private var showingFileImporter = false
    /// The account screen, when a free account taps a locked attachment button.
    @State private var showingPaywall = false
    /// Why the last attachment attempt failed, or why the send did.
    @State private var attachmentError: String?
    /// Whether an upload is in flight, so the price of a second tap is clear.
    @State private var uploading = false

    private static let buttonSize: CGFloat = 34
    private static let corner: CGFloat = Theme.Radius.xl

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The key, not the Chinese: this string is already in the catalogue.
            //
            // Expanded, the field is the composer: it takes every point between
            // the top edge and the controls, so a long prompt is read whole
            // instead of through an eight-line letterbox. It is one editor with
            // two heights, never two editors: a second branch would be a second
            // view, and focus does not survive the swap -- the keyboard dropped
            // on every expand and collapse until this was one view. See
            // ``ComposerTextInput``.
            ComposerTextInput(
                text: $text,
                expanded: expanded,
                wantsFocus: focused,
                knownTokenNames: knownTokenNames,
                insertion: insertion,
                onInsertionApplied: onInsertionApplied,
                edit: pendingEdit,
                onEditFinished: { outcome in
                    pendingEdit = nil
                    _ = outcome
                },
                onSelectionChanged: { range in composerSelection = range },
                onCompositionChanged: { composing in
                    isComposing = composing
                    // A composition starting mid-rewrite means the operator is
                    // editing: the answer is already stale and nobody is
                    // waiting for it.
                    if composing, onDevice.isEnhancing { onDevice.cancelEnhancement() }
                },
                onDictationPress: beginDictation,
                onDictationRelease: {
                    dictationCancelling = false
                    onDevice.endHold()
                },
                onDictationCancel: {
                    dictationCancelling = true
                    onDevice.cancelHold()
                },
                onSlashTokenChanged: onSlashTokenChanged,
                onFocusChanged: { value in focused = value },
                onMeasuredHeight: { height in fieldHeight = height },
            )
            .frame(maxWidth: .infinity, maxHeight: expanded ? .infinity : nil, alignment: .topLeading)
            // Resting, the field is as tall as its own text -- one line to
            // eight, measured at the width it actually has -- and scrolls
            // inside itself past eight. Expanded, it fills the room the screen
            // gives it and the text scrolls inside it. Neither height is
            // estimated from a character count.
            .frame(height: expanded ? nil : fieldHeight, alignment: .topLeading)
            .anchorPreference(key: ComposerRestingBoundsKey.self, value: .bounds) {
                ComposerRestingBounds(editor: $0)
            }
            .padding(.horizontal, 16)
            .padding(.top, 13)
            .padding(.bottom, 6)
            .accessibilityIdentifier("composer.field")
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(SessionDetailView.space)) } action: { frame in
                ComposerGeometry.shared.field = frame
            }

            // The microphone's own region, above the controls and inside the
            // glass: the operator's attention is on the finger, so the answer
            // to "what is it hearing" belongs where the thumb already is.
            if onDevice.dictation.phase != .idle {
                ComposerDictationStrip(
                    phase: onDevice.dictation.phase,
                    liveText: onDevice.dictation.liveText,
                    level: onDevice.dictation.level,
                    elapsed: onDevice.dictation.elapsed,
                    cancelling: dictationCancelling,
                    onOpenSettings: openSettings,
                    onDismiss: { onDevice.resetDictation() },
                )
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            VStack(alignment: .leading, spacing: 0) {
                if !attachments.isEmpty {
                    AttachmentStrip(drafts: attachments, progress: uploadProgress) { id in
                        remove(id)
                    }
                }

                if let attachmentError {
                    Label(attachmentError, systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(Theme.failed)
                        .lineLimit(2)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 4)
                        .accessibilityIdentifier("composer.attachment.error")
                }

                HStack(spacing: 6) {
                    ComposerBar(
                        sessionId: sessionId,
                        stats: stats,
                        focused: $focused,
                        showingModel: $showingModel,
                        showingContext: $showingContext,
                        showingCommands: $showingCommands,
                        showingPhotoPicker: $showingPhotoPicker,
                        showingFileImporter: $showingFileImporter,
                        onLockedAttachment: { showingPaywall = true },
                        onContextChanged: onContextChanged,
                        onBrowseCommands: onBrowseCommands,
                    )
                    Spacer(minLength: 4)
                    // The rewriter sits immediately left of the keyboard
                    // chevron, and appears and leaves with it: it is about what
                    // is being typed. The microphone is deliberately not here:
                    // talking belongs to the resting field, and it is a hold on
                    // the field itself rather than a button to aim at.
                    if focused {
                        enhanceButton
                            .transition(.pop)
                    }
                    // Put the keyboard away. Only there while the keyboard is up:
                    // with it down the button has nothing to do, and a control
                    // that does nothing reads as a broken one.
                    if focused {
                        dismissKeyboardButton
                            .transition(.pop)
                    }
                    expandButton
                    primaryButton
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            .anchorPreference(key: ComposerRestingBoundsKey.self, value: .bounds) {
                ComposerRestingBounds(chrome: $0)
            }
            .anchorPreference(key: ComposerShellBoundsKey.self, value: .bounds) {
                ComposerShellMeasurement(chrome: $0)
            }
        }
        .contentShape(.rect)
        .onTapGesture { focused = true }
        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
        .animation(.mizarSmooth, value: text.isEmpty)
        .animation(.mizarSmooth, value: attachments.count)
        // Drives the keyboard button's arrival when the field is tapped into.
        // `expanded` is deliberately not animated here: the expand button
        // already wraps its change in a transaction, and a second implicit
        // animation over the same change double-drove the layout.
        .animation(.mizarSmooth, value: focused)
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
        .transformAnchorPreference(key: ComposerShellBoundsKey.self, value: .bounds) { measurement, shell in
            measurement.shell = shell
            measurement.fieldHeight = fieldHeight
            measurement.insets = restingInsets
        }
        .overlayPreferenceValue(ComposerRestingBoundsKey.self) { bounds in
            GeometryReader { shell in
                Color.clear
                    .onGeometryChange(for: ComposerRestingMeasurement?.self) { _ in
                        guard let editor = bounds.editor, let chrome = bounds.chrome else { return nil }
                        let editorHeight = shell[editor].height
                        let chromeHeight = shell[chrome].height
                        guard editorHeight.isFinite, editorHeight > 0,
                              chromeHeight.isFinite, chromeHeight >= 0 else { return nil }
                        // Never subtract an animated expanded editor to infer a target.
                        // Refresh padding only when the actual editor is resting.
                        var insets = restingInsets
                        if !expanded, abs(editorHeight - fieldHeight) <= 0.5 {
                            let measured = shell.size.height - editorHeight - chromeHeight
                            if measured.isFinite, measured >= 0 { insets = measured }
                        }
                        guard let insets else { return nil }
                        let target = fieldHeight + chromeHeight + insets
                        guard target.isFinite, target > 0 else { return nil }
                        return ComposerRestingMeasurement(insets: insets, height: target)
                    } action: { measurement in
                        guard let measurement else { return }
                        restingInsets = measurement.insets
                        onCollapsedHeightChanged?(measurement.height)
                    }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .mizarFeedback(.impact(weight: .light), trigger: sends)
        // A picker bound to this view rather than to a button: it has to survive
        // the popover closing.
        .photosPicker(
            isPresented: $showingPhotoPicker,
            selection: $photoItems,
            maxSelectionCount: max(1, AttachmentLimits.maxImages - imageCount),
            matching: .images,
        )
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            Task { await addPhotos(items) }
        }
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true,
        ) { result in
            switch result {
            case .success(let urls): addFiles(urls)
            case .failure(let error): attachmentError = Self.describeAttachmentFailure(error)
            }
        }
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
        // Every change of the draft, from a keystroke, a command's insert or an
        // on-device edit, moves the revision. Work that was asked for against an
        // earlier draft compares this before it writes.
        .onChange(of: text) { _, _ in
            draftRevision &+= 1
            // Editing is the operator changing their mind: a rewrite of the
            // draft they are leaving is work nobody will read, and a recording
            // is listening to words that are no longer the draft.
            if onDevice.isEnhancing { onDevice.cancelEnhancement() }
            if onDevice.isRecording { onDevice.cancelHold() }
        }
        .onAppear { onDevice.refreshAvailability() }
        .onChange(of: scenePhase) { _, phase in
            // A rewrite nobody is waiting for and a microphone left running are
            // both stopped when the scene leaves: the operator has looked away.
            if phase == .active {
                onDevice.refreshAvailability()
            } else {
                onDevice.cancelAll()
            }
        }
        // A result is handed to the field only while the draft it was computed
        // from is still the draft on screen; a stale one is dropped, not written.
        .onChange(of: onDevice.pendingEdit) { _, request in
            guard let request else { return }
            onDevice.pendingEdit = nil
            guard request.revision == draftRevision else { return }
            pendingEdit = request.edit
        }
        // One panel at a time. Opening another closes the rewrite's window,
        // exactly as each panel already closes the others.
        .onChange(of: showingModel) { _, open in if open { showingEnhance = false } }
        .onChange(of: showingContext) { _, open in if open { showingEnhance = false } }
        .onChange(of: showingCommands) { _, open in if open { showingEnhance = false } }
        .animation(.mizarSnappy, value: onDevice.dictation.phase != .idle)
    }

    private enum Mode: Equatable { case idle, send, stop }

    private var mode: Mode {
        if showsStop { return .stop }
        return sendEnabled ? .send : .idle
    }

    private var primaryButton: some View {
        Button {
            Task { await primary() }
        } label: {
            ZStack {
                Image(systemName: mode == .stop ? "stop.fill" : "arrow.up")
                    .font(.system(size: mode == .stop ? 13 : 15, weight: .bold))
                    .foregroundStyle(foreground)
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.bounce.up, value: sends)
                    .opacity(sending || uploading ? 0 : 1)
                if sending || uploading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(foreground)
                }
            }
            .frame(width: Self.buttonSize, height: Self.buttonSize)
            .background {
                Circle()
                    .fill(fill)
                    .shadow(color: mode == .idle ? .clear : fill.opacity(0.4), radius: 8, y: 3)
            }
            .scaleEffect(mode == .idle ? 0.92 : 1)
            .contentShape(.circle)
        }
        .buttonStyle(.pressable(scale: 0.88))
        .disabled(mode == .idle)
        .animation(.mizarBouncy, value: mode)
        .accessibilityLabel(showsStop ? "Stop" : "Send")
        .accessibilityIdentifier(showsStop ? "composer.stop" : "composer.send")
    }

    /// Put the keyboard away, one tap -- and with it the expanded composer:
    /// the tall field exists for typing, and with no keyboard up it is a
    /// screenful of nothing to type into. Sits at the left of the expand
    /// button, and only exists while the keyboard is up -- see the call site.
    private var dismissKeyboardButton: some View {
        Button {
            withMizarAnimation(.mizarSmooth) {
                focused = false
                expanded = false
            }
        } label: {
            // A chevron, not an arrow: next to the send button's arrow.up the
            // two stems read as the same glyph, and these keys are not send.
            //
            // A solid circle, like the send button it sits beside -- not glass.
            // A glass circle nested inside the composer's own glass is morphed
            // by the glass engine whenever the slab changes shape, so the
            // button wandered with the expansion and snapped back after;
            // opaque fills are not morphable, which is why the other keys on
            // this row never moved.
            Image(systemName: "chevron.down")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: Self.buttonSize, height: Self.buttonSize)
                .background {
                    Circle()
                        .fill(Color(.tertiarySystemFill))
                }
                .contentShape(.circle)
        }
        .buttonStyle(.pressable(scale: 0.88))
        .accessibilityLabel(Text("Hide keyboard"))
        .accessibilityIdentifier("composer.dismissKeyboard")
    }

    /// Ask the on-device model to rewrite the draft, or explain why it cannot.
    ///
    /// In the same grey circle as the keyboard chevron: this is a small action
    /// about what is being typed, not a mode of the screen. The draft says
    /// whether it can be tapped, but the button stays in place -- a control
    /// that moves in as the first character arrives makes the row jump under
    /// the thumb, and one that vanishes when the model is off is a feature the
    /// operator cannot find again.
    private var enhanceButton: some View {
        Button { showEnhancePanel() } label: {
            ZStack {
                Circle()
                    .fill(Color(.tertiarySystemFill))
                if onDevice.isEnhancing {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: "sparkles")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: Self.buttonSize, height: Self.buttonSize)
            .contentShape(.circle)
        }
        .buttonStyle(.pressable(scale: 0.88))
        .disabled(blankDraft || onDevice.isRecording || isComposing)
        .mizarPopover(isPresented: $showingEnhance, arrowEdge: .bottom) {
            ComposerEnhancePanel(
                availability: onDevice.enhancementAvailability,
                onPick: { intent in
                    // Closed first, then the rewrite starts: writing a draft
                    // underneath a window that is still animating away is a
                    // write the operator cannot see the result of.
                    showingEnhance = false
                    onDevice.enhance(draft: text, intent: intent, revision: draftRevision)
                },
                onOpenSettings: openSettings,
            )
        }
        .accessibilityLabel(Text("Improve prompt"))
        .accessibilityValue(onDevice.isEnhancing ? Text("Rewriting") : Text(""))
        .accessibilityIdentifier("composer.enhance")
    }

    /// A blank draft answers nothing: the button is drawn, disabled, with the
    /// accessibility state to match.
    private var blankDraft: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Open the intent window, closing the other panels first.
    private func showEnhancePanel() {
        guard !blankDraft, !isComposing else { return }
        onDevice.refreshAvailability()
        withMizarAnimation(.mizarSnappy) {
            showingModel = false
            showingContext = false
            showingCommands = false
            showingEnhance = true
        }
    }

    /// Start listening with every panel out of the way.
    ///
    /// The words land where the operator pointed: the keyboard's caret when it
    /// is up, and the end of the draft when it is not -- a resting field has no
    /// caret the operator can see, and guessing a position inside their text
    /// would be worse than appending.
    private func beginDictation() {
        guard !onDevice.isEnhancing else { return }
        dictationCancelling = false
        withMizarAnimation(.mizarSnappy) {
            showingModel = false
            showingContext = false
            showingCommands = false
            showingEnhance = false
        }
        let range = focused
            ? composerSelection
            : NSRange(location: (text as NSString).length, length: 0)
        onDevice.beginHold(revision: draftRevision, selection: range)
    }

    /// iOS's own page for this app, where a switched-off permission is turned
    /// back on. The only thing the app can do about a refusal.
    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    /// Open the composer out to the height of the screen, and back.
    ///
    /// At rest a grey circle with an up chevron -- the field will grow
    /// upwards; open, it takes on the send button's blue, and the same tap
    /// puts the composer back to rest. The expansion itself is laid out by
    /// the screen, which owns the space above; this button only decides.
    private var expandButton: some View {
        Button {
            // One transaction for both: the expansion animates the shape, and
            // the keyboard rises with it, so the first character can follow
            // the tap immediately. Animated separately they drove the layout
            // twice, and the row shuddered.
            withMizarAnimation(.mizarSmooth) {
                expanded.toggle()
                if expanded {
                    focused = true
                }
            }
        } label: {
            Image(systemName: "chevron.up")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(expanded ? Theme.onAccent : .secondary)
                .frame(width: Self.buttonSize, height: Self.buttonSize)
                .background {
                    Circle()
                        .fill(expanded ? Color.accentColor : Color(.tertiarySystemFill))
                        .shadow(
                            color: expanded ? Color.accentColor.opacity(0.4) : .clear,
                            radius: 8, y: 3,
                        )
                }
                .contentShape(.circle)
        }
        .buttonStyle(.pressable(scale: 0.88))
        .accessibilityLabel(Text(expanded ? "Collapse the composer" : "Expand the composer"))
        .accessibilityIdentifier("composer.expand")
    }

    private var fill: Color {
        switch mode {
        case .stop: Theme.failed
        case .send: .accentColor
        case .idle: Color(.tertiarySystemFill)
        }
    }

    private var foreground: Color {
        switch mode {
        case .stop: .white
        case .send: Theme.onAccent
        case .idle: .secondary
        }
    }

    /// Whether the session this composer belongs to has a turn in flight.
    private var running: Bool {
        model.sessions.first { $0.sessionId == sessionId }?.running ?? false
    }

    /// Whether the one button is a stop button right now.
    private var showsStop: Bool {
        running && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && attachments.isEmpty && !stopping
    }

    private var sendEnabled: Bool {
        guard !sending, !uploading else { return false }
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        return !attachments.isEmpty
    }

    /// How many of the attached drafts are images.
    private var imageCount: Int {
        attachments.count(where: \.isImage)
    }

    /// Do whichever job the button is currently carrying.
    private func primary() async {
        if showsStop {
            stopping = true
            await model.cancelTurn(sessionId: sessionId)
            stopping = false
        } else {
            await send()
        }
    }

    // MARK: - Sending

    private func send() async {
        // A rewrite or a recording in flight is about the draft being sent.
        // Sending cancels it and sends what the operator wrote.
        onDevice.cancelEnhancement()
        onDevice.cancelHold()
        let outgoing = text
        let drafts = attachments
        let display = AttachmentDraft.promptText(outgoing, drafts: drafts)
        guard !display.isEmpty else { return }
        // Read once, before any suspension: a turn can end while a request is in
        // flight, and the answer to "was this a send into a running turn?" has
        // to be the one the operator pressed the button on.
        let runningWhenSent = running
        let guided = model.settings.values.guidedSendByDefault
        // The server's plan is the authority, but the phone can avoid a useless
        // upload: without the advanced feature set nothing can be attached, and
        // the account screen is where that changes. A LAN link unlocks the set
        // as well, so this guard is only reachable off the operator's own
        // network; the sentence still names the plan, because the screen it
        // opens is where a plan is bought.
        if !drafts.isEmpty, model.isLocalAgentMode {
            // Said here as well as hidden in the menu: a draft can outlive a
            // mode switch, and "nothing happened" is the worst answer.
            attachmentError = String(localized: "The on-device agent cannot take attachments yet.")
            return
        }
        if !drafts.isEmpty, !model.advancedFeaturesUnlocked {
            attachmentError = String(localized: "Attachments need a paid account.")
            showingPaywall = true
            return
        }

        // A text-only send into a running turn with guided send off stays on
        // the phone. The bar above the field takes it, and it goes when the turn
        // ends -- or sooner, by the operator's own hand, still as guidance.
        // Attachments are the exception: their files are already on the host by
        // the time the prompt is, and the bar only speaks for text.
        if drafts.isEmpty, runningWhenSent, !guided {
            sending = true
            sends += 1
            attachmentError = nil
            withMizarAnimation(.mizarSmooth) { text = "" }
            model.holdPrompt(outgoing, for: sessionId)
            sending = false
            focused = true
            return
        }

        sending = true
        sends += 1
        attachmentError = nil
        onWillSend(display)
        // Clear optimistically so the field is ready for the next thought; put
        // everything back if the host refused it, so nothing is silently lost.
        // The attachments stay on screen while they upload, which is the one
        // place the progress is drawn.
        withMizarAnimation(.mizarSmooth) { text = "" }

        // Guidance is only a mode for a turn that is running; a send that is
        // about to start one is ordinary either way.
        let mode: PromptMode = runningWhenSent && guided ? .steer : .queue
        let accepted: Bool
        if drafts.isEmpty {
            accepted = await model.sendPrompt(outgoing, to: sessionId, mode: mode)
        } else {
            accepted = await uploadAndSend(drafts: drafts, text: outgoing, mode: mode)
        }

        if accepted {
            withMizarAnimation(.mizarSmooth) { attachments = [] }
            uploadProgress.clear()
            await onSent(display)
        } else {
            text = outgoing
            attachments = drafts
            uploadProgress.clear()
            onSendFailed(display)
        }
        sending = false
        focused = true
    }

    /// Upload every attachment, then send the prompt that names them.
    ///
    /// - Parameters:
    ///   - drafts: the attachments.
    ///   - text: the prompt text, possibly empty.
    ///   - mode: how to hand it over when a turn is running. Attachments are
    ///     handed over immediately either way; `.queue` is the old behaviour
    ///     and the safe answer when the operator has not asked for guidance.
    /// - Returns: whether the host accepted the prompt.
    private func uploadAndSend(drafts: [AttachmentDraft], text: String, mode: PromptMode) async -> Bool {
        uploading = true
        defer { uploading = false }
        var ids: [String] = []
        do {
            for draft in drafts {
                let draftId = draft.id
                let progress = uploadProgress
                let ref = try await model.uploadAttachment(
                    data: draft.data,
                    kind: draft.kind,
                    name: draft.name,
                    mediaType: draft.mediaType,
                    sessionId: sessionId,
                    progress: { value in
                        Task { @MainActor in
                            progress.set(value, for: draftId)
                        }
                    },
                )
                ids.append(ref.attachmentId)
            }
            let accepted = await model.sendPrompt(text, attachmentIds: ids, to: sessionId, mode: mode)
            if accepted {
                // The record the computer writes is the words alone, so the
                // phone keeps what went with them -- see ``DeliveredAttachments``.
                DeliveredAttachments.record(
                    drafts.map { DeliveredAttachment(isImage: $0.isImage, name: $0.name) },
                    for: text,
                )
            }
            return accepted
        } catch {
            attachmentError = Self.describeAttachmentFailure(error)
            return false
        }
    }

    /// A failed upload as a sentence.
    ///
    /// `NOT_IMPLEMENTED` is the old-host-plugin case: the computer's DSH predates
    /// the upload methods, and the fix is an update on the computer, not a
    /// retry on the phone. Saying so is the difference between a bug report and
    /// a support answer.
    private static func describeAttachmentFailure(_ error: any Error) -> String {
        if let mizar = error as? MizarError {
            switch mizar.code {
            case "NOT_IMPLEMENTED", "MALFORMED_FRAME", "UPLOAD_UNKNOWN":
                return String(localized: "This computer's DSH plugin is too old to receive attachments. Update DSH on the computer, then try again.")
            default:
                return AppModel.displayMessage(for: mizar)
            }
        }
        return error.localizedDescription
    }

    // MARK: - Attaching

    /// Read picked photos into drafts.
    ///
    /// - Parameter items: the picked items; the picker binding is reset whatever
    ///   happens so picking the same photo twice fires again.
    private func addPhotos(_ items: [PhotosPickerItem]) async {
        defer { photoItems = [] }
        for item in items {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw AttachmentProblem.unreadableImage
                }
                add(try AttachmentDraft.image(from: data))
            } catch {
                attachmentError = Self.describe(error)
            }
        }
    }

    /// Read imported files into drafts.
    ///
    /// - Parameter urls: the URLs from `fileImporter`.
    private func addFiles(_ urls: [URL]) {
        for url in urls {
            do {
                add(try AttachmentDraft.file(from: url))
            } catch {
                attachmentError = Self.describe(error)
            }
        }
    }

    /// Add one draft, subject to the limits.
    ///
    /// - Parameter draft: the draft to add.
    private func add(_ draft: AttachmentDraft) {
        var candidate = attachments
        candidate.append(draft)
        do {
            try AttachmentDraft.validate(candidate)
            withMizarAnimation(.mizarSmooth) { attachments = candidate }
            attachmentError = nil
        } catch {
            attachmentError = Self.describe(error)
        }
    }

    /// Remove one draft.
    /// - Parameter id: the draft's identity.
    private func remove(_ id: UUID) {
        withMizarAnimation(.mizarSmooth) {
            attachments.removeAll { $0.id == id }
        }
        uploadProgress.clear()
        attachmentError = nil
    }

    /// A local validation failure as a sentence.
    private static func describe(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

/// Propagates the actual shell bounds so its parent can measure dock overhead
/// in the same layout pass, independently of editor-height callbacks.
struct ComposerShellMeasurement {
    var shell: Anchor<CGRect>?
    var chrome: Anchor<CGRect>?
    var fieldHeight: CGFloat?
    var insets: CGFloat?
}

struct ComposerShellBoundsKey: PreferenceKey {
    static var defaultValue: ComposerShellMeasurement { ComposerShellMeasurement() }

    static func reduce(value: inout ComposerShellMeasurement, nextValue: () -> ComposerShellMeasurement) {
        let next = nextValue()
        value.shell = next.shell ?? value.shell
        value.chrome = next.chrome ?? value.chrome
        value.fieldHeight = next.fieldHeight ?? value.fieldHeight
        value.insets = next.insets ?? value.insets
    }
}

private struct ComposerRestingBounds {
    var editor: Anchor<CGRect>?
    var chrome: Anchor<CGRect>?
}

private struct ComposerRestingBoundsKey: PreferenceKey {
    static var defaultValue: ComposerRestingBounds { ComposerRestingBounds() }

    static func reduce(value: inout ComposerRestingBounds, nextValue: () -> ComposerRestingBounds) {
        let next = nextValue()
        value.editor = next.editor ?? value.editor
        value.chrome = next.chrome ?? value.chrome
    }
}

private struct ComposerRestingMeasurement: Equatable {
    var insets: CGFloat
    var height: CGFloat
}

/// Where the field is, for the send's flight to start from.
///
/// A plain object rather than state: the frame changes on every keystroke that
/// wraps a line, and nothing needs to redraw when it does -- it is read once, at
/// the moment of a send.
@MainActor
final class ComposerGeometry {
    static let shared = ComposerGeometry()
    var field: CGRect = .zero
}

// MARK: - The field

/// The composer's editor: one `UITextView` behind a `UIViewRepresentable`,
/// carrying both the resting and the expanded size.
///
/// Why not the SwiftUI `TextField` it replaces: an unlimited-line `TextField`
/// inside a frame that grows without limit promises neither a constrained
/// editing viewport, nor caret following, nor a scroll range -- a long draft
/// was cut off with no way to reach its middle or its end. A `UITextView`
/// states all three explicitly: the resting height is the text's own measured
/// height clamped to eight lines, the expanded height is the room the screen
/// gives it, and anything past either scrolls inside the editor.
///
/// One instance for both sizes, never two: a second branch would be a second
/// view, and focus does not survive the swap -- the keyboard dropped on every
/// expand and collapse until the field was one view. Expanding changes the
/// height and the scrolling, not the editor.
struct ComposerTextInput: UIViewRepresentable {
    /// What has been typed. Owned by the screen, because the command list
    /// writes into it too -- a command is something the operator finishes
    /// typing.
    @Binding var text: String
    /// Whether the composer is opened out: the editor then fills the room it
    /// is given rather than using its measured resting height.
    var expanded: Bool
    /// Whether the field should hold the keyboard.
    var wantsFocus: Bool
    /// The token names the field may draw as pills. See ``ComposerView``.
    var knownTokenNames: [String] = []
    /// A token the palette asked for, placed once and reported back.
    var insertion: ComposerInsertion?
    /// Reported after ``insertion`` landed, so the screen clears it.
    var onInsertionApplied: () -> Void = {}
    /// A replacement the on-device features asked for, placed once.
    var edit: ComposerEdit?
    /// Reported after ``edit`` was consumed, applied or discarded, so the
    /// screen clears it and can say what happened.
    var onEditFinished: (ComposerEditOutcome) -> Void = { _ in }
    /// Reported whenever the caret or selection moves, in plain offsets.
    var onSelectionChanged: (NSRange) -> Void = { _ in }
    /// Reported when an input method starts or finishes a composition.
    var onCompositionChanged: (Bool) -> Void = { _ in }
    /// Held on the resting field: start listening, stop, or slide up to cancel.
    var onDictationPress: () -> Void = {}
    var onDictationRelease: () -> Void = {}
    var onDictationCancel: () -> Void = {}
    /// Reported when the field starts or stops sitting on a lone `/`.
    var onSlashTokenChanged: (Bool) -> Void = { _ in }
    /// Called when the editor takes or gives up the keyboard on its own -- a
    /// tap into the field, a tap out of it.
    var onFocusChanged: (Bool) -> Void
    /// Called with the resting height at the current width, clamped to one
    /// through eight lines even while expanded. Expansion ignores this height
    /// for layout but keeps it ready for the next collapse.
    var onMeasuredHeight: (CGFloat) -> Void

    func makeCoordinator() -> ComposerTextInputCoordinator {
        ComposerTextInputCoordinator(text: $text, onFocusChanged: onFocusChanged, onMeasuredHeight: onMeasuredHeight)
    }

    func makeUIView(context: Context) -> ComposerEditorView {
        let editor = ComposerEditorView()
        editor.delegate = context.coordinator
        context.coordinator.editor = editor
        editor.knownTokenNames = knownTokenNames
        editor.onSlashTokenChanged = onSlashTokenChanged
        // A hold on the resting field is the microphone. It is a UIKit
        // recogniser rather than a SwiftUI gesture because cancelling needs
        // the finger's *location* -- a long press has no translation, that
        // method belongs to a pan -- and because it has to stay out of the
        // field's own editing gestures: its delegate only lets it begin when
        // no keyboard is up.
        let hold = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(ComposerTextInputCoordinator.handleDictationHold(_:)),
        )
        hold.minimumPressDuration = 0.4
        hold.allowableMovement = 10_000
        hold.cancelsTouchesInView = true
        hold.delegate = context.coordinator
        editor.dictationPressRecognizer = hold
        editor.addGestureRecognizer(hold)
        editor.onDictationPress = { [weak coordinator = context.coordinator] in
            coordinator?.onDictationPress()
        }
        editor.onDictationRelease = { [weak coordinator = context.coordinator] in
            coordinator?.onDictationRelease()
        }
        editor.onDictationCancel = { [weak coordinator = context.coordinator] in
            coordinator?.onDictationCancel()
        }
        // A long press is not something VoiceOver can perform, so the same
        // three states are exposed as actions.
        editor.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: String(localized: "Start dictation")) { [weak coordinator = context.coordinator] _ in
                coordinator?.onDictationPress()
                return true
            },
            UIAccessibilityCustomAction(name: String(localized: "Stop dictation")) { [weak coordinator = context.coordinator] _ in
                coordinator?.onDictationRelease()
                return true
            },
            UIAccessibilityCustomAction(name: String(localized: "Cancel dictation")) { [weak coordinator = context.coordinator] _ in
                coordinator?.onDictationCancel()
                return true
            },
        ]
        // The pill's bitmap is drawn for one appearance and one type size.
        // Both can change while the field is alive -- a system appearance
        // switch, a Dynamic Type slider -- and neither is a text change.
        editor.registerForTraitChanges([
            UITraitUserInterfaceStyle.self,
            UITraitPreferredContentSizeCategory.self,
            UITraitDisplayScale.self,
        ]) { (view: ComposerEditorView, _) in
            view.refreshTokenRendering(force: true)
        }
        editor.onNaturalHeight = { [weak coordinator = context.coordinator] height in
            coordinator?.reportMeasuredHeight(height)
        }
        // The composer's own padding does the spacing; the editor's insets
        // would double it. Zeroed, so a line of text starts exactly where the
        // SwiftUI padding says it does -- the layout the field had before.
        editor.textContainerInset = .zero
        editor.textContainer.lineFragmentPadding = 0
        // Body text, following the operator's Dynamic Type setting -- the
        // same font the SwiftUI field used.
        editor.font = UIFont.preferredFont(forTextStyle: .body)
        editor.adjustsFontForContentSizeCategory = true
        editor.textColor = UIColor.label
        editor.backgroundColor = .clear
        // The resting composer scrolls internally once the draft is past
        // eight lines; the expanded one always does. No scroll indicator:
        // the field is a small surface, and a bar down its edge read as a
        // second scroll view fighting the conversation's.
        editor.isScrollEnabled = true
        editor.showsVerticalScrollIndicator = false
        editor.showsHorizontalScrollIndicator = false
        // Return inserts a newline, as the vertical field it replaces did.
        editor.returnKeyType = .default
        // The identifier the UI suite queries. A `UITextView` is a *textView*
        // to XCUITest, not a textField -- the query type changed with the
        // component (see `docs/ios-three-issues-diagnosis-2026-10-22.md`).
        editor.accessibilityIdentifier = "composer.field"
        editor.accessibilityLabel = String(localized: "Ask your agent…")
        // The hold is the microphone on the resting field; VoiceOver cannot
        // perform a hold, so the hint names it and the custom actions below
        // offer start, stop and cancel.
        editor.accessibilityHint = String(localized: "Hold to dictate")
        // The placeholder is a label, not attributed text: it has to vanish
        // the moment the first character arrives and come back when the last
        // one goes, and it must not scroll with the text.
        //
        // This manually created subview uses explicit Auto Layout constraints.
        let placeholder = UILabel()
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        placeholder.font = editor.font
        placeholder.text = String(localized: "Ask your agent…")
        placeholder.textColor = UIColor.placeholderText
        placeholder.numberOfLines = 0
        placeholder.isUserInteractionEnabled = false
        placeholder.accessibilityElementsHidden = true
        editor.addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.leadingAnchor.constraint(equalTo: editor.frameLayoutGuide.leadingAnchor),
            placeholder.trailingAnchor.constraint(equalTo: editor.frameLayoutGuide.trailingAnchor),
            placeholder.topAnchor.constraint(equalTo: editor.frameLayoutGuide.topAnchor),
        ])
        editor.placeholderLabel = placeholder
        // The draft the screen already holds -- a restored one, or one a
        // command just wrote -- is in the field from the first layout.
        editor.text = text
        editor.refreshTokenRendering(force: true)
        return editor
    }

    func updateUIView(_ editor: ComposerEditorView, context: Context) {
        // The callbacks are refreshed rather than captured once: the screen
        // rebuilds this struct on every update, and a closure captured at
        // `makeUIView` would be the first one the screen ever built.
        context.coordinator.text = $text
        context.coordinator.onFocusChanged = onFocusChanged
        context.coordinator.onMeasuredHeight = onMeasuredHeight
        context.coordinator.onInsertionApplied = onInsertionApplied
        context.coordinator.onSlashTokenChanged = onSlashTokenChanged
        context.coordinator.knownTokenNames = knownTokenNames
        context.coordinator.insertion = insertion
        context.coordinator.edit = edit
        context.coordinator.onEditFinished = onEditFinished
        context.coordinator.onSelectionChanged = onSelectionChanged
        context.coordinator.onCompositionChanged = onCompositionChanged
        context.coordinator.onDictationPress = onDictationPress
        context.coordinator.onDictationRelease = onDictationRelease
        context.coordinator.onDictationCancel = onDictationCancel
        editor.knownTokenNames = knownTokenNames
        editor.onSlashTokenChanged = onSlashTokenChanged

        // A pick from the palette lands before an external write is considered:
        // it replaces a slash or a selection, writes the binding itself, and the
        // binding is still the old value for the rest of this update. Treating
        // that as an external write would undo the insert immediately.
        let inserted = context.coordinator.applyPendingInsertion()
        // The same for an on-device replacement: placed first, then the binding
        // is written, so the still-old value is not read as an external write.
        let placed = context.coordinator.applyPendingEdit()

        // The text, only when it has actually changed from outside. Assigning
        // on every SwiftUI update resets the selection, empties the undo
        // stack and interrupts a Chinese input method's composition -- the
        // field would fight the operator mid-word.
        // The placeholder is a UILabel, not the text view's own text, so
        // XCUITest (and VoiceOver) see an empty value for an empty field. Say
        // the placeholder as the value while it is empty; once there is text,
        // the plain draft is the value -- `textView.text` would expose the
        // attachment characters the pills are drawn with, and every assertion
        // that reads the field would see `\u{FFFC}` instead of `/goal`.
        let draft = editor.plainText
        editor.accessibilityValue = draft.isEmpty
            ? String(localized: "Ask your agent…")
            : draft
        if !inserted, !placed, draft != text, editor.markedTextRange == nil {
            // A composition in progress is the operator's: the marked text is
            // a candidate being chosen between, and a replacement now takes
            // it away. The write waits for the commit, which comes through
            // `textViewDidChange`.
            editor.setPlainText(text, caret: nil)
            // The caret follows the write -- a command's insert lands where
            // the command put it -- and is scrolled to visible if the write
            // left it below the fold. Reading a long draft by scrolling up is
            // not disturbed: nothing here runs without a real text change.
            if let caret = editor.selectedTextRange?.start {
                editor.scrollRectToVisible(editor.caretRect(for: caret), animated: false)
            }
        }

        // A synced skill list that arrived while the field was open is new
        // tokens to draw. The call is a no-op when nothing a pill depends on
        // changed, so it can run on every update.
        editor.refreshTokenRendering()

        // The keyboard follows the binding, and only on a change: calling
        // `becomeFirstResponder` on every update re-opens a keyboard the
        // operator had just put away with the chevron.
        if wantsFocus != context.coordinator.focused {
            if wantsFocus {
                editor.becomeFirstResponder()
            } else {
                editor.resignFirstResponder()
            }
        }

        // One editor, two heights: expanded fills the room it is given and
        // scrolls its content; resting is the text's own measured height, and
        // scrolls only once the draft is past eight lines.
        editor.isExpanded = expanded
        // The placeholder goes when the first character arrives, exactly as
        // the SwiftUI field's did.
        editor.placeholderLabel?.isHidden = !text.isEmpty
    }
}

/// The editor itself: a plain `UITextView` that reports the height its text
/// needs at whatever width it has been given, and draws the tokens it is told
/// about as capsules.
///
/// Measured in `layoutSubviews` rather than on the text delegate alone: the
/// natural height depends on the width, and the width changes with a
/// rotation, an iPad split and a Dynamic Type change -- none of which is a
/// text change. `measureAndReportNaturalHeight()` covers the text changes.
///
/// The draft is still a plain string. The attributed text this view holds is a
/// *rendering* of that string: every token is one `U+FFFC` carrying an image,
/// and ``plainText`` turns the field back into exactly what was typed. That is
/// what keeps the send path, the draft store and the host's parser unchanged.
@MainActor
final class ComposerEditorView: UITextView {
    /// The placeholder label, shown while the field is empty.
    var placeholderLabel: UILabel?

    /// Whether the composer is expanded. Its viewport fills the available
    /// room, but height reports always describe the resting viewport.
    var isExpanded = false

    /// The undo manager programmatic edits register into.
    ///
    /// `nil` in the app, where the view's own manager -- the window's, the one
    /// typing lands on -- is used, so one ⌘Z or one shake takes a rewrite back
    /// to the draft it replaced. Tests inject one because a view outside a
    /// window has no responder chain to ask.
    var editUndoManager: UndoManager?

    /// Called with the clamped resting height at the current width, whenever
    /// the layout produces a different one.
    var onNaturalHeight: ((CGFloat) -> Void)?

    /// The token names the field may draw as pills.
    var knownTokenNames: [String] = []

    /// Reported when the field starts or stops sitting on a lone `/`.
    var onSlashTokenChanged: ((Bool) -> Void)?

    /// Told when a hold on the resting field begins, ends, or slides up.
    var onDictationPress: (() -> Void)?
    var onDictationRelease: (() -> Void)?
    var onDictationCancel: (() -> Void)?

    /// The recogniser installed for that hold, so the delegate can tell it
    /// apart from the field's own editing gestures.
    var dictationPressRecognizer: UILongPressGestureRecognizer?

    private var lastReportedHeight: CGFloat = 0
    /// The literals last rendered, in order. Positions are deliberately absent:
    /// typing in front of a pill shifts every range and must not force a
    /// rebuild, while adding, removing or renaming a token must.
    private var lastTokenLiterals = ""
    private var lastKnownTokenNames: [String] = []
    private var lastBuildWidth: CGFloat = 0
    private var lastBuildStyle: UIUserInterfaceStyle = .unspecified
    /// Guards the one recursion this class could create: assigning
    /// `attributedText` moves the selection, and a selection change reports the
    /// slash state.
    private var isRendering = false

    /// Eight lines at the current font: the resting composer's ceiling. Past
    /// it the editor scrolls instead of growing, which is the whole point --
    /// an unlimited `TextField` grew without limit and cut the text off.
    private var restingHeightLimit: CGFloat {
        (font?.lineHeight ?? 20) * 8
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        measureAndReportNaturalHeight()
        // The pill's truncation is a question about the width. A rotation or a
        // split changes it without a text change; the refresh is deferred one
        // turn because replacing `attributedText` inside layout would ask for
        // another layout from inside this one.
        if bounds.width > 0, abs(bounds.width - lastBuildWidth) > 0.5 {
            scheduleRenderRefresh()
        }
    }

    /// Measure the text at its actual width, clamp to the resting viewport,
    /// and report when that resting height differs from the last one.
    ///
    /// Measured, never counted in characters: how many lines a paragraph
    /// wraps to is a question about the width, and only the layout engine can
    /// answer it. The guard on the last reported value is what stops the
    /// report from re-driving the layout that produced it.
    func measureAndReportNaturalHeight() {
        guard bounds.width > 0 else { return }
        let natural = sizeThatFits(CGSize(width: bounds.width, height: .infinity)).height
        // Keep the collapse target ready while expanded. Reporting the full
        // document height here made collapse first use that oversized target,
        // then relayout again when the deferred resting measurement arrived.
        let reported = min(max(natural, font?.lineHeight ?? 20), restingHeightLimit)
        guard reported != lastReportedHeight else { return }
        lastReportedHeight = reported
        onNaturalHeight?(reported)
    }

    // MARK: - The plain draft

    /// Exactly what was typed, with every token spelled back out.
    ///
    /// The field's own `text` is not this: it contains one `U+FFFC` per pill.
    /// This is the value the binding, the draft store and the send path see.
    var plainText: String {
        let source = renderedText
        guard source.length > 0 else { return "" }
        let text = source.string as NSString
        var plain = ""
        plain.reserveCapacity(source.length)
        source.enumerateAttributes(
            in: NSRange(location: 0, length: source.length),
            options: [],
        ) { attributes, range, _ in
            if let literal = attributes[ComposerPill.literalKey] as? String {
                plain += literal
            } else {
                plain += text.substring(with: range)
            }
        }
        return plain
    }

    /// The selection, in plain-text offsets.
    var plainSelectionRange: NSRange {
        let selection = selectedRange
        let rendered = renderedText
        let start = plainOffset(for: selection.location, in: rendered)
        let end = plainOffset(for: NSMaxRange(selection), in: rendered)
        return NSRange(location: start, length: max(0, end - start))
    }

    /// The attributed text, never nil: `UITextView.attributedText` is optional
    /// only because it predates attributed strings being its normal state.
    private var renderedText: NSAttributedString {
        attributedText ?? NSAttributedString()
    }

    /// Put a plain draft in the field and rebuild its pills.
    ///
    /// - Parameters:
    ///   - plain: the whole draft, as typed.
    ///   - caret: where the insertion point goes, in plain offsets. `nil` puts
    ///     it at the end, which is where an external write such as restoring a
    ///     draft or a command's insert lands.
    func setPlainText(_ plain: String, caret: Int?) {
        text = plain
        // `text` replaced the attributed string, so whatever was on screen is
        // gone; the next render must rebuild even if the literals happen to
        // compare equal.
        lastTokenLiterals = "\u{0}"
        refreshTokenRendering(force: true)
        let target = caret ?? (plain as NSString).length
        let rendered = renderedText
        let location = attributedOffset(forPlain: target, in: rendered)
        selectedRange = NSRange(location: min(location, rendered.length), length: 0)
        reportSlashState()
    }

    // MARK: - The on-device edit

    /// The manager a programmatic edit registers into.
    private var registrationUndoManager: UndoManager? { editUndoManager ?? undoManager }

    /// Apply one replacement as a single undoable edit.
    ///
    /// The whole draft is rebuilt with the same pill pass typing uses, and the
    /// replacement is one `textStorage` change: one edit, one undo, a caret
    /// after what was placed. A composition in progress is never written into
    /// -- the operator is choosing between candidates and a replacement now
    /// takes the candidate away.
    ///
    /// - Parameter edit: the replacement, with its range in plain offsets.
    /// - Returns: whether the draft changed, and why not when it did not.
    func apply(_ edit: ComposerEdit) -> ComposerEditOutcome {
        guard markedTextRange == nil else { return .discardedComposition }
        let plain = plainText
        guard edit.isInBounds(of: plain) else { return .rejected }

        let before = renderedText
        let beforeSelection = selectedRange
        let updated = (plain as NSString).replacingCharacters(in: edit.range, with: edit.text)
        let tokens = ComposerTokens.scan(updated, names: knownTokenNames)
        let built = makeAttributedText(updated, tokens: tokens, width: bounds.width)
        let caret = edit.range.location + (edit.text as NSString).length
        replaceAll(
            with: built,
            caret: attributedOffset(forPlain: caret, in: built),
            tokens: tokens,
        )
        if let manager = registrationUndoManager {
            manager.registerUndo(withTarget: self) { editor in
                editor.restore(before, selection: beforeSelection)
            }
        }
        if let start = selectedTextRange?.start {
            scrollRectToVisible(caretRect(for: start), animated: false)
        }
        return .applied
    }

    /// Put a whole attributed draft back, for undo and for redo.
    ///
    /// Undo is not "apply the inverse range": a replacement can change lengths
    /// and rebuild every pill, and restoring the snapshot bytes is the only
    /// thing that is guaranteed to be exact. Registering the inverse while
    /// undoing is also what gives the operator a redo.
    private func restore(_ attributed: NSAttributedString, selection: NSRange) {
        let current = renderedText
        let currentSelection = selectedRange
        replaceAll(
            with: attributed,
            caret: min(selection.location, attributed.length),
            tokens: nil,
        )
        registrationUndoManager?.registerUndo(withTarget: self) { editor in
            editor.restore(current, selection: currentSelection)
        }
    }

    /// Replace everything, and make the render bookkeeping agree.
    ///
    /// - Parameter tokens: the tokens the replacement was built from, or `nil`
    ///   when it was restored as bytes -- then the next render rescans.
    private func replaceAll(with attributed: NSAttributedString, caret: Int, tokens: [ComposerToken]?) {
        isRendering = true
        textStorage.beginEditing()
        textStorage.replaceCharacters(in: NSRange(location: 0, length: textStorage.length), with: attributed)
        textStorage.endEditing()
        selectedRange = NSRange(location: min(caret, textStorage.length), length: 0)
        typingAttributes = baseAttributes
        isRendering = false

        if let tokens {
            lastTokenLiterals = tokens.map(\.literal).joined(separator: "\u{1F}")
            lastKnownTokenNames = knownTokenNames
            lastBuildWidth = bounds.width
            lastBuildStyle = traitCollection.userInterfaceStyle
        } else {
            // A restore brings its own pills; the sentinel makes the next
            // render rescans rather than rebuild a bitmap over the snapshot.
            lastTokenLiterals = "\u{0}"
        }
    }

    // MARK: - Rendering

    /// Rebuild the attributed text when what a pill looks like has changed.
    ///
    /// Called on every keystroke and every SwiftUI update; it is a no-op unless
    /// the token list, the known names, the width or the appearance changed.
    /// A composition in progress is never interrupted.
    func refreshTokenRendering(force: Bool = false) {
        guard !isRendering, markedTextRange == nil else { return }
        let plain = plainText
        let tokens = ComposerTokens.scan(plain, names: knownTokenNames)
        let literals = tokens.map(\.literal).joined(separator: "\u{1F}")
        let width = bounds.width
        let style = traitCollection.userInterfaceStyle
        let hasAttachment = containsAttachments
        let drawn = hasAttachment || !tokens.isEmpty
        let needs = force
            || literals != lastTokenLiterals
            || knownTokenNames != lastKnownTokenNames
            || (drawn && (style != lastBuildStyle || abs(width - lastBuildWidth) > 0.5))
        guard needs else {
            // The bookkeeping still moves: a width that is irrelevant while the
            // field holds no pills is today's baseline for tomorrow's.
            lastBuildWidth = width
            lastBuildStyle = style
            return
        }

        let caret = plainOffset(for: selectedRange.location, in: renderedText)
        isRendering = true
        let built = makeAttributedText(plain, tokens: tokens, width: width)
        attributedText = built
        let restored = attributedOffset(forPlain: caret, in: built)
        selectedRange = NSRange(location: min(restored, built.length), length: 0)
        typingAttributes = baseAttributes
        isRendering = false

        lastTokenLiterals = literals
        lastKnownTokenNames = knownTokenNames
        lastBuildWidth = width
        lastBuildStyle = style
        reportSlashState()
    }

    /// Tell the screen whether the caret is on a lone `/`.
    func reportSlashState() {
        guard !isRendering else { return }
        let caret = plainOffset(for: selectedRange.location, in: renderedText)
        onSlashTokenChanged?(selectedRange.length == 0 && ComposerTokens.isLoneSlashToken(plainText, caret: caret))
    }

    /// The attributes every ordinary character is drawn with.
    private var baseAttributes: [NSAttributedString.Key: Any] {
        [
            .font: font ?? UIFont.preferredFont(forTextStyle: .body),
            .foregroundColor: textColor ?? UIColor.label,
        ]
    }

    /// The draft, with one attachment where each token is.
    private func makeAttributedText(
        _ plain: String,
        tokens: [ComposerToken],
        width: CGFloat,
    ) -> NSAttributedString {
        let built = NSMutableAttributedString()
        let source = plain as NSString
        var cursor = 0
        for token in tokens {
            if token.range.location > cursor {
                let run = NSRange(
                    location: cursor,
                    length: token.range.location - cursor,
                )
                built.append(NSAttributedString(string: source.substring(with: run), attributes: baseAttributes))
            }
            let attachment = ComposerPill.attachment(
                literal: token.literal,
                // A pill may take the whole line and no more; the image
                // truncates its own text when that is not enough.
                maxWidth: max(1, width),
                traits: traitCollection,
            )
            let run = NSMutableAttributedString(attachment: attachment)
            run.addAttribute(
                ComposerPill.literalKey,
                value: token.literal,
                range: NSRange(location: 0, length: run.length),
            )
            built.append(run)
            cursor = NSMaxRange(token.range)
        }
        if cursor < source.length {
            built.append(NSAttributedString(
                string: source.substring(from: cursor),
                attributes: baseAttributes,
            ))
        }
        return built
    }

    // MARK: - Offsets

    /// A position in the attributed text as a position in the plain draft.
    private func plainOffset(for attributedOffset: Int, in attributed: NSAttributedString) -> Int {
        guard attributedOffset > 0, attributed.length > 0 else { return 0 }
        let limit = min(attributedOffset, attributed.length)
        var plain = 0
        var index = 0
        while index < limit {
            let attributes = attributed.attributes(at: index, effectiveRange: nil)
            if let literal = attributes[ComposerPill.literalKey] as? String {
                plain += (literal as NSString).length
            } else {
                plain += 1
            }
            index += 1
        }
        // A caret past the last character (the normal end-of-text position)
        // keeps the characters it passed; there are none left to add.
        return plain
    }

    /// A position in the plain draft as a position in the attributed text.
    ///
    /// A plain position inside a token resolves to the token's own start: the
    /// caret can sit before or after a pill, never in the middle of one.
    private func attributedOffset(forPlain plain: Int, in attributed: NSAttributedString) -> Int {
        guard plain > 0 else { return 0 }
        var counted = 0
        var index = 0
        while index < attributed.length {
            let attributes = attributed.attributes(at: index, effectiveRange: nil)
            let span = (attributes[ComposerPill.literalKey] as? String)
                .map { ($0 as NSString).length } ?? 1
            if counted + span > plain { return index }
            counted += span
            index += 1
        }
        return attributed.length
    }

    /// Whether any run is a pill.
    private var containsAttachments: Bool {
        let rendered = renderedText
        guard rendered.length > 0 else { return false }
        var found = false
        rendered.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: rendered.length),
            options: [],
        ) { value, _, stop in
            if value != nil {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    /// Re-render next turn, outside the layout that discovered the change.
    private func scheduleRenderRefresh() {
        DispatchQueue.main.async { [weak self] in
            self?.refreshTokenRendering()
        }
    }
}

/// The bridge between the editor and the screen's state.
///
/// Three jobs, and each one is a place a naive implementation corrupts the
/// field: the text follows the editor without feeding back, the keyboard
/// follows the binding without being re-opened on every update, and the
/// height follows the layout without a loop.
@MainActor
final class ComposerTextInputCoordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
    var text: Binding<String>
    var onFocusChanged: (Bool) -> Void
    var onMeasuredHeight: (CGFloat) -> Void
    var onInsertionApplied: () -> Void = {}
    var onSlashTokenChanged: (Bool) -> Void = { _ in }
    var knownTokenNames: [String] = []
    /// A token the palette asked for, waiting for the next update.
    var insertion: ComposerInsertion?
    /// A replacement the on-device features asked for, waiting for the next update.
    var edit: ComposerEdit?
    /// Told after an edit was consumed, applied or discarded.
    var onEditFinished: (ComposerEditOutcome) -> Void = { _ in }
    /// Told where the caret or selection went, in plain offsets.
    var onSelectionChanged: (NSRange) -> Void = { _ in }
    /// Told when a composition starts or finishes.
    var onCompositionChanged: (Bool) -> Void = { _ in }
    /// Told when a hold on the resting field starts, stops, or cancels.
    var onDictationPress: () -> Void = {}
    var onDictationRelease: () -> Void = {}
    var onDictationCancel: () -> Void = {}
    /// Where the hold began, and whether it has crossed the cancel line.
    private var dictationStart: CGPoint?
    private var dictationCancelled = false
    /// The last request this bridge placed. Identity, not equality: picking the
    /// same command twice is two inserts.
    private var lastInsertionId: UUID?
    /// The same, for a replacement: the same text at the same range twice is
    /// two edits.
    private var lastEditId: UUID?

    /// The editor this coordinator belongs to. Weak: the editor holds the
    /// coordinator as its delegate, and the measurement has to reach the
    /// view without a cycle.
    weak var editor: ComposerEditorView?

    /// Whether the editor last reported holding the keyboard. The bridge's
    /// own memory, so `becomeFirstResponder` is asked for once per change
    /// rather than once per update.
    var focused = false

    init(text: Binding<String>, onFocusChanged: @escaping (Bool) -> Void, onMeasuredHeight: @escaping (CGFloat) -> Void) {
        self.text = text
        self.onFocusChanged = onFocusChanged
        self.onMeasuredHeight = onMeasuredHeight
    }

    private var pendingHeight: CGFloat?
    private var heightReportScheduled = false

    func reportMeasuredHeight(_ height: CGFloat) {
        pendingHeight = height
        guard !heightReportScheduled else { return }
        heightReportScheduled = true
        // layoutSubviews may run inside a SwiftUI update. Deliver the latest
        // measurement next turn, avoiding state mutation during that update.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.heightReportScheduled = false
            guard let height = self.pendingHeight else { return }
            self.pendingHeight = nil
            self.onMeasuredHeight(height)
        }
    }

    func textViewDidChange(_ textView: UITextView) {
        // The binding follows the editor, not the other way round: this is
        // the only path that writes on an ordinary keystroke, and the
        // `updateUIView` guard above is what keeps that write from coming
        // straight back as a replacement.
        //
        // `plainText`, not `textView.text`: the field's own text holds one
        // replacement character per pill, and the draft is what was typed.
        guard let editor else { return }
        text.wrappedValue = editor.plainText
        // The text changed, so the height it needs may have: a paragraph
        // that just wrapped is a line taller. The render is a no-op unless a
        // token completed or disappeared; a composition in progress is left
        // alone until it commits.
        editor.refreshTokenRendering()
        editor.measureAndReportNaturalHeight()
        editor.reportSlashState()
        onCompositionChanged(editor.markedTextRange != nil)
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        // The hint follows the caret, not the text: typing `/`, walking the
        // caret off it and walking back are the same token and three states.
        editor?.reportSlashState()
        // The on-device features remember where the operator was: dictation
        // puts its words where the caret stood when the finger went down.
        if let editor {
            onSelectionChanged(editor.plainSelectionRange)
            onCompositionChanged(editor.markedTextRange != nil)
        }
    }

    func textViewDidBeginEditing(_ textView: UITextView) {
        setFocus(true)
        editor?.reportSlashState()
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        setFocus(false)
        // The retained selection still identifies the slash while the dock is open.
        editor?.reportSlashState()
    }

    // MARK: - The hold that talks

    /// The field's hold belongs to it only when it is resting.
    ///
    /// With the keyboard up, a long press on a text view is how text is
    /// selected; taking that gesture would take the field's editing away. The
    /// resting field has no caret to select around, and there the hold is the
    /// microphone. Expanded is a full-screen writing surface, not a resting
    /// composer.
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let editor, gestureRecognizer === editor.dictationPressRecognizer else { return true }
        return !editor.isFirstResponder && !editor.isExpanded && editor.markedTextRange == nil
    }

    /// One long press on the resting field: start, stop, or cancel.
    ///
    /// Only the resting field's own recogniser reaches here; the field decides
    /// that, so this handler is free to treat every event as a dictation one.
    /// Cancel is measured by where the finger went down, because a long press
    /// has no translation.
    @objc func handleDictationHold(_ gesture: UILongPressGestureRecognizer) {
        let point = gesture.location(in: gesture.view)
        switch gesture.state {
        case .began:
            dictationStart = point
            dictationCancelled = false
            if Haptics.enabled {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
            onDictationPress()
        case .changed:
            guard let start = dictationStart, !dictationCancelled else { return }
            // Up, not distance: sliding sideways along the row is a thumb
            // adjusting, sliding up is the operator changing their mind.
            if start.y - point.y > 60 {
                dictationCancelled = true
                if Haptics.enabled {
                    UINotificationFeedbackGenerator().notificationOccurred(.warning)
                }
                onDictationCancel()
            }
        case .ended:
            guard dictationStart != nil else { return }
            dictationStart = nil
            let cancelled = dictationCancelled
            dictationCancelled = false
            if !cancelled { onDictationRelease() }
        case .cancelled, .failed:
            guard dictationStart != nil else { return }
            dictationStart = nil
            dictationCancelled = false
            onDictationCancel()
        default:
            break
        }
    }

    // MARK: - The palette's pick

    /// Place a token the palette asked for, once.
    ///
    /// The editor's own selection decides where it lands. When the request came
    /// from the hint, the lone `/` before the caret is the trigger and is
    /// replaced; otherwise the pick replaces the selection, or inserts at the
    /// caret. A space follows every pill so the next word starts a word.
    ///
    /// - Returns: whether something was placed. The caller must not treat the
    ///   still-old binding as an external write in that same update.
    @discardableResult
    func applyPendingInsertion() -> Bool {
        guard let editor, let insertion,
              insertion.id != lastInsertionId,
              editor.markedTextRange == nil
        else { return false }
        lastInsertionId = insertion.id

        let plain = editor.plainText as NSString
        var range = editor.plainSelectionRange
        // With no keyboard there is no caret the operator can see. A pick made
        // from the `+` window then goes at the end of what is already there,
        // rather than in front of a draft the field was never opened on.
        if !editor.isFirstResponder,
           range.length == 0,
           range.location == 0,
           plain.length > 0,
           !insertion.replacesSlashToken
        {
            range = NSRange(location: plain.length, length: 0)
        }
        if insertion.replacesSlashToken, range.length == 0, range.location > 0 {
            let index = range.location - 1
            if plain.character(at: index) == 0x2F,
               index == 0 || ComposerTokens.isWhitespace(plain.character(at: index - 1))
            {
                range = NSRange(location: index, length: 1)
            }
        }
        let literal = insertion.literal + " "
        let updated = plain.replacingCharacters(in: range, with: literal)
        editor.setPlainText(updated, caret: range.location + (literal as NSString).length)
        // The binding and the screen's "consumed" state are written next turn:
        // this bridge is inside SwiftUI's own update, and mutating observable
        // state from there is how a view update turns into a cycle. The editor
        // already holds the new draft, so the delayed write lands on a field
        // that agrees with it.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.text.wrappedValue = updated
            self.onInsertionApplied()
        }
        return true
    }

    /// Place a replacement the on-device features asked for, once.
    ///
    /// The editor owns the write: it turns the plain range into a pill-aware
    /// attributed range, replaces exactly that run, and registers the whole
    /// thing as one undo. The binding follows afterwards, like an insertion's
    /// does, so this update cannot read the still-old binding as an external
    /// write and hand the field its previous draft back.
    ///
    /// - Returns: whether the draft changed. A discarded request (an input
    ///   method was mid-composition) still counts as consumed, and the screen
    ///   is told so it can clear the request and say what happened.
    @discardableResult
    func applyPendingEdit() -> Bool {
        guard let editor, let edit, edit.id != lastEditId else { return false }
        lastEditId = edit.id
        let outcome = editor.apply(edit)
        guard outcome.didApply else {
            DispatchQueue.main.async { [weak self] in
                self?.onEditFinished(outcome)
            }
            return false
        }
        editor.measureAndReportNaturalHeight()
        editor.reportSlashState()
        onSelectionChanged(editor.plainSelectionRange)
        DispatchQueue.main.async { [weak self, weak editor] in
            guard let self, let editor else { return }
            self.text.wrappedValue = editor.plainText
            self.onEditFinished(outcome)
        }
        return true
    }

    private func setFocus(_ value: Bool) {
        guard value != focused else { return }
        focused = value
        onFocusChanged(value)
    }
}
