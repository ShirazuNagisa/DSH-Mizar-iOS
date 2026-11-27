//
//  ComposerBar.swift
//  DSH-Mizar
//
//  The strip between the conversation and the field: which model is answering,
//  how full the context window is, and the host's own commands.
//
//  It lives inside the composer's glass, along its bottom edge, and it replaced
//  a segmented control
//  that swapped the conversation for a usage screen. The swap was the problem:
//  "what is it doing" and "what has it cost" are asked at the same time, and a
//  control that shows one by hiding the other makes the second question cost a
//  tap and a scroll back. Three figures in a row cost neither.
//
//  Every element is a control, not a label. The model pill opens the model
//  picker, the context pill opens the breakdown, and the command button opens
//  the list -- which is how DSH's own bar behaves.
//

import SwiftUI
import MizarKit

/// The controls along the bottom of the composer: the host's commands, which
/// model is answering, and how full the context window is.
struct ComposerBar: View {
    let sessionId: String
    /// The session's usage frame, when it has been read.
    let stats: SessionStatsFrame?
    /// Whether the field holds the keyboard, so a command can focus it -- and so
    /// the row can make room for the text while it is being typed.
    @Binding var focused: Bool
    @Environment(AppModel.self) private var model
    /// Which panel is open, owned by the screen rather than by this view.
    ///
    /// These were `@State` here, and the bar sits inside an overlay whose
    /// content SwiftUI rebuilds as the conversation scrolls. A panel whose
    /// openness is stored in a view that gets rebuilt closes itself the moment
    /// it opens.
    @Binding var showingModel: Bool
    @Binding var showingContext: Bool
    @Binding var showingCommands: Bool
    /// Whether the permission picker is out, owned by the screen like the other
    /// panels.
    @Binding var showingPermission: Bool
    /// Open the photo picker. `ComposerView` owns the picker modifier; this is
    /// just the flag, because a `PhotosPicker` presented from inside a popover
    /// closes with the popover.
    @Binding var showingPhotoPicker: Bool
    /// Open the file importer.
    @Binding var showingFileImporter: Bool
    /// Called when the advanced feature set is locked and an attachment button
    /// is tapped: the account screen, where the plan can be bought. Not a silent
    /// no-op -- a locked button that does nothing is a bug report.
    var onLockedAttachment: () -> Void = {}
    /// Called after a compaction, so the screen that owns `stats` can re-read
    /// the frame behind the figure above the composer.
    var onContextChanged: () async -> Void = {}
    /// Called once the host has taken a permission switch, so the screen can
    /// re-read the frame the shield is drawn from.
    var onPermissionApplied: () async -> Void = {}
    /// Open the command and skill palette. The `+` window closes first; the
    /// screen owns both flags because a popover's content is rebuilt while it
    /// is up, and a panel whose openness lives inside it closes itself.
    var onBrowseCommands: () -> Void = {}

    var body: some View {
        HStack(spacing: 6) {
            commandButton
            ComposerPermissionButton(
                sessionId: sessionId,
                stats: stats,
                isPresented: $showingPermission,
                onApplied: onPermissionApplied,
            )
            modelPill
                .layoutPriority(1)
            contextPill
        }
        .animation(.mizarSmooth, value: focused)
    }

    /// `deepseek-v4 · High`, for the route this session will actually use.
    ///
    /// The same resolution the picker's "in force" line uses, because the two
    /// used to disagree: after a switch this bar read only the host's stats
    /// frame, which is refreshed on the next read -- and on an idle session
    /// nothing asks -- so it went on naming the model the session was on before
    /// the switch while the picker named the new one.
    private var modelLabel: String {
        guard let selection = agreedModelSelection(
            chosen: model.chosenModelSelection(for: sessionId),
            reported: stats?.model,
            // The button naming nothing but "Model" is the one thing it must
            // never do, so a session with no stats frame falls back to the
            // route a new turn would take.
            fallback: model.modelCatalog?.defaultSelection,
        ) else {
            return String(localized: "Model")
        }
        return modelPillLabel(model: selection.model, effort: selection.reasoningEffort)
    }

    private var modelPill: some View {
        // The capsule opens the thinking strip, which is an overlay inside the
        // composer rather than a window out of it: one surface, blurred and
        // dimmed where the field was.
        ModelPill(label: modelLabel, compact: focused) {
            withMizarAnimation(.mizarMorphIn) { showingModel = true }
        }
        .layoutPriority(1)
        .accessibilityLabel("Model, \(modelLabel)")
        .accessibilityIdentifier("composer.model")
    }

    // MARK: - Context

    private var contextPercent: Int? { stats?.context?.percent }

    private var contextPill: some View {
        Button { showingContext = true } label: {
            HStack(spacing: 5) {
                ContextRing(percent: contextPercent)
                if let contextPercent {
                    Text("\(contextPercent)%")
                        .font(.caption.monospacedDigit().weight(.medium))
                        .contentTransition(.numericText())
                        .animation(.mizarSmooth, value: contextPercent)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 32)
            .background(.fill.tertiary, in: Capsule())
            .contentShape(.capsule)
        }
        .buttonStyle(.pressable)
        .fixedSize()
        .disabled(stats?.context == nil)
        .mizarPopover(isPresented: $showingContext, arrowEdge: .bottom) {
            ContextDetail(
                stats: stats,
                sessionId: sessionId,
                onChanged: onContextChanged,
            )
        }
        .accessibilityLabel("Context, \(contextLabel)")
        .accessibilityIdentifier("composer.context")
    }

    private var contextLabel: String {
        // "Context" is the catalogue key on its own and the figure is appended
        // to it: `String(localized: "Context \(percent)%")` builds a key that
        // did not resolve, and the Chinese interface showed the English word.
        guard let percent = contextPercent else { return String(localized: "Context") }
        return "\(String(localized: "Context")) \(percent)%"
    }

    // MARK: - Commands

    private var commandButton: some View {
        Button { showingCommands = true } label: {
            Image(systemName: "plus")
                .font(.system(size: 15, weight: .semibold))
                .rotationEffect(.degrees(showingCommands ? 45 : 0))
                .animation(.mizarBouncy, value: showingCommands)
                .frame(width: 32, height: 32)
                .background(.fill.tertiary, in: Circle())
                .contentShape(.circle)
        }
        .buttonStyle(.pressable)
        .mizarPopover(isPresented: $showingCommands, arrowEdge: .bottom) {
            CommandList(
                // The kernel has no upload: `upload.*` answers NOT_IMPLEMENTED
                // and a prompt carrying `attachmentIds` is refused outright.
                // Offering the buttons would be offering a guaranteed failure.
                canAttach: model.advancedFeaturesUnlocked && !model.isLocalAgentMode,
                onAttachment: { kind in
                    // Closed first: the picker is presented by the composer, and
                    // a popover that stays up over the photo sheet hides it.
                    showingCommands = false
                    // The server's plan is the authority, but the phone avoids a
                    // useless picker: without the advanced feature set there is
                    // nothing to attach to, and the account screen is where that
                    // changes. On a LAN link the set is open, so this guard is
                    // reached only off the operator's own network.
                    guard model.advancedFeaturesUnlocked else {
                        onLockedAttachment()
                        return
                    }
                    switch kind {
                    case .photo: showingPhotoPicker = true
                    case .file: showingFileImporter = true
                    }
                },
                onBrowse: {
                    // Closed first, then the palette opens. The other order
                    // left a popover behind the sheet, over the field the
                    // palette is about to write into.
                    showingCommands = false
                    onBrowseCommands()
                },
            )
        }
        .accessibilityLabel(Text("Commands and attachments"))
        .accessibilityIdentifier("composer.commands")
    }
}

/// Which attachment picker a button wants.
enum AttachmentPickerKind {
    case photo
    case file
}

/// The attachment buttons, and the door to the command palette.
///
/// Internal rather than private so the snapshot suite can render both gate
/// states from fixtures (`AttachmentGateSnapshotTests`); it takes the gate as
/// a `Bool` and owns no environment, so the render is the app's own view.
///
/// The attachments row is deliberately above the palette door rather than beside
/// the field: the field's leading edge is where the operator's thumb already is
/// for text, and a row of two labelled buttons is discoverable in a way that two
/// unlabelled glyphs are not. The gate is drawn, not just enforced: a lock and a
/// footer that says why, so the refusal explains itself. The footer's wording is
/// the paid plan's, because that is the plan this feature is sold with, and the
/// same buttons are open on a LAN link as well.
///
/// The commands used to be `/goal` and `/plan` inline. They moved to the
/// palette (`CommandSkillPalette`) when skills joined them: this popover is
/// about what to put in the message, and the palette is a page where two
/// commands and a machine's whole skill list can be searched in one field.
struct CommandList: View {
    /// Whether the advanced feature set is available, so attachments may be
    /// added. True for a paid account and on a LAN link.
    let canAttach: Bool
    /// Pick a photo or a file, or ask for the account screen when locked.
    let onAttachment: (AttachmentPickerKind) -> Void
    /// Open the command and skill palette.
    let onBrowse: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PopoverHeader(title: "Commands and attachments", systemImage: "plus.circle")

            HStack(spacing: 8) {
                attachmentButton(
                    title: "Add photo",
                    symbol: "photo.on.rectangle",
                    identifier: "composer.attach.photo",
                ) { onAttachment(.photo) }
                attachmentButton(
                    title: "Add file",
                    symbol: "doc.badge.plus",
                    identifier: "composer.attach.file",
                ) { onAttachment(.file) }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, canAttach ? 10 : 4)

            if !canAttach {
                HStack(spacing: 5) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9, weight: .semibold))
                    Text("Paid accounts only")
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 18)
                .padding(.bottom, 10)
                .accessibilityIdentifier("composer.attach.locked")
            }

            Divider()
                .padding(.bottom, 4)
            // A VStack, not a List.
            //
            // As List rows with `.buttonStyle(.plain)` the taps never reached
            // the buttons at all: the list stayed open, the action never ran,
            // and the field stayed empty. Measured by the test -- the row was
            // on screen, the tap was delivered somewhere, and `onPick` was not
            // called. Plain rows have no such opinion, and every one of them is
            // a button whose whole width is tappable.
            VStack(spacing: 0) {
                // The palette's door.
                //
                // A whole row, not a chevron on the header: the popover now
                // holds a page, and a page needs an entry that reads as one.
                Button(action: onBrowse) {
                    HStack(spacing: 14) {
                        Image(systemName: "text.magnifyingglass")
                            .font(.body.weight(.medium))
                            .frame(width: 30, height: 30)
                            .foregroundStyle(Theme.accentText)
                            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        Text("Open commands and skills")
                            // One line, scaled down if the popover is narrow:
                            // this row is the popover's door, and a door that
                            // wraps to two lines at 300 pt reads as a paragraph.
                            .font(.subheadline)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                        Spacer(minLength: 12)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 20)
                    .frame(height: 50)
                    .contentShape(.rect)
                }
                .buttonStyle(.pressable(scale: 0.98, dims: true))
                .accessibilityIdentifier("composer.browseCommands")
            }
            .padding(.bottom, 8)
        }
        .frame(width: 300)
    }

    /// One of the two attachment buttons.
    ///
    /// - Parameters:
    ///   - title: the label.
    ///   - symbol: the SF Symbol.
    ///   - identifier: the accessibility identifier a UI test asks for.
    ///   - action: what a tap does. A locked button still runs this: the
    ///     composer opens the account screen rather than swallowing the tap.
    private func attachmentButton(
        title: LocalizedStringKey,
        symbol: String,
        identifier: String,
        action: @escaping () -> Void,
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(canAttach ? Theme.accentText : Color.secondary)
                HStack(spacing: 3) {
                    if !canAttach {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    Text(title)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(canAttach ? Color.primary : Color.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.pressable(scale: 0.97, dims: true))
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(Text(title))
    }
}

/// The little occupancy dial.
///
/// Its colour slides rather than switches: the accent while there is room,
/// warming to amber past three quarters and to red past nine tenths -- a window
/// that is nearly full is the thing that makes a session start summarising
/// itself, and it should be visible before it happens rather than after. Past
/// nine tenths it also breathes, once every few seconds.
struct ContextRing: View {
    let percent: Int?
    var size: CGFloat = 15
    var lineWidth: CGFloat = 2.4
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle()
                .stroke(.secondary.opacity(0.22), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
        .animation(.mizarGentle, value: percent)
        .modifier(Breathing(active: (percent ?? 0) >= 90 && !reduceMotion))
    }

    private var fraction: CGFloat { min(1, max(0, CGFloat(percent ?? 0) / 100)) }

    private var tint: Color {
        guard let percent else { return .secondary }
        if percent >= 90 { return Theme.failed }
        if percent >= 75 { return Theme.waiting }
        return Theme.accentText
    }
}

/// A slow pulse, for a figure that wants to be looked at.
private struct Breathing: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        if active {
            // Rest, then one quick swell and settle -- a breath, not a throb.
            content.phaseAnimator([1.0, 1.2]) { view, scale in
                view.scaleEffect(scale)
            } animation: { scale in
                scale > 1 ? .easeOut(duration: 0.3).delay(2.6) : .spring(duration: 0.5, bounce: 0.3)
            }
        } else {
            content
        }
    }
}

/// The context dial, and the one action that belongs to it.
private struct ContextDetail: View {
    let stats: SessionStatsFrame?
    let sessionId: String
    let onChanged: () async -> Void

    @Environment(AppModel.self) private var model
    @State private var current: SessionStatsFrame?
    @State private var completed = false
    @State private var failure: String?

    private var context: ContextPressure? { (current ?? stats)?.context }
    private var compacting: Bool { model.isCompacting(sessionId) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let context {
                HStack(spacing: 14) {
                    ContextRing(percent: context.percent, size: 52, lineWidth: 6)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.percent.map { "\($0)%" } ?? "—")
                            .font(.title2.monospacedDigit().weight(.bold))
                        Text("of the context window in use")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Button {
                    Task { await compact() }
                } label: {
                    HStack(spacing: 7) {
                        if compacting {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }
                        Text(compacting ? "Compacting…" : "Compact context")
                            .font(.subheadline.weight(.medium))
                    }
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(Theme.onAccent)
                }
                .buttonStyle(.borderedProminent)
                .disabled(compacting)
                .accessibilityIdentifier("context.compact")

                if let failure {
                    Text(failure)
                        .font(.caption)
                        .foregroundStyle(Theme.failed)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("context.compact.error")
                } else if completed {
                    Text("Context compacted.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("context.compact.done")
                }
            } else {
                Text("No context figure yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(width: 280)
        .onAppear { current = stats }
        .onChange(of: stats) { _, next in current = next }
    }

    private func compact() async {
        guard !compacting else { return }
        completed = false
        failure = nil
        do {
            try await model.compactSession(sessionId)
            await onChanged()
            current = await model.stats(for: sessionId) ?? current
            completed = true
        } catch {
            failure = (error as? MizarError).map(AppModel.displayMessage(for:))
                ?? error.localizedDescription
        }
    }
}
