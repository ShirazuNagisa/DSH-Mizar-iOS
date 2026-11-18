//
//  ComposerOnDeviceControls.swift
//  DSH-Mizar
//
//  The three pieces of chrome the on-device features add: the intent window
//  the sparkles opens, the strip the microphone draws while the finger is
//  down, and the one-line note a slow rewrite or a refusal leaves behind.
//
//  They are separate leaves rather than part of the composer for the same
//  reason the command palette is: a popover's content is rebuilt while it is
//  up, and a view that owns its own state there closes itself. Everything
//  these draw is handed in; everything they decide is a callback.
//

import SwiftUI
import UIKit

// MARK: - The intent window

/// What "improve" can mean, in a window out of the sparkles button.
///
/// Three rows, one per intent, laid out from the enum rather than by hand: a
/// fourth intent then costs one case and no layout work. When the model is not
/// available the same window explains why instead of offering rows -- a tap
/// that did nothing would be the failure this is avoiding.
struct ComposerEnhancePanel: View {
    let availability: ComposerEnhanceAvailability
    let onPick: (ComposerEnhanceIntent) -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PopoverHeader(title: "Improve prompt", systemImage: "sparkles")
            if availability.isAvailable {
                VStack(spacing: 0) {
                    ForEach(ComposerEnhanceIntent.allCases) { intent in
                        if intent != ComposerEnhanceIntent.allCases.first {
                            Divider().padding(.leading, 50)
                        }
                        Button { onPick(intent) } label: {
                            row(intent)
                        }
                        .buttonStyle(.pressable(scale: 0.98, dims: true))
                        .accessibilityIdentifier("composer.enhance.\(intent.rawValue)")
                    }
                }
                .padding(.bottom, 6)
            } else {
                explanation
            }
        }
        .frame(width: 320)
        .accessibilityIdentifier("composer.enhance.panel")
    }

    private func row(_ intent: ComposerEnhanceIntent) -> some View {
        HStack(spacing: 12) {
            Image(systemName: intent.systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.accentText)
                .frame(width: 22)
            Text(intent.title)
                .font(.body)
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 18)
        .frame(height: 44)
        .contentShape(.rect)
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(availability.explanation ?? "The rewrite is not available right now.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if availability.isActionable {
                Button(action: onOpenSettings) {
                    Text("Open Settings")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.pressable(scale: 0.97))
                .accessibilityIdentifier("composer.enhance.settings")
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 18)
        .accessibilityIdentifier("composer.enhance.explanation")
    }
}

// MARK: - Hold to talk

/// The long-press surface under the microphone.
///
/// UIKit rather than a SwiftUI gesture combination, because the two gestures
/// the feature needs are a long press and a *location* -- and a long press has
/// no translation: that method belongs to a pan, which is why a finger that
/// slid up has to be measured against where it went down. The recogniser also
/// keeps the field's own selection and magnifier out of the way: the press is
/// never installed on the text view.
struct ComposerMicControl: UIViewRepresentable {
    /// Whether a press may start anything.
    var isEnabled: Bool
    /// Whether the microphone is already recording, for the accessibility
    /// value a VoiceOver operator hears.
    var isRecording: Bool
    var onPress: () -> Void
    var onRelease: () -> Void
    var onCancel: () -> Void

    /// How far up the finger has to travel before letting go cancels.
    static let cancelTravel: CGFloat = 60

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIView {
        let view = MicPressView()
        view.backgroundColor = .clear
        view.isAccessibilityElement = true
        view.accessibilityTraits = .button
        view.accessibilityIdentifier = "composer.mic"
        let press = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handle(_:)),
        )
        // Long enough that a tap is a tap and not a recording, and allowed to
        // travel: the slide up *is* part of the gesture, not a failure of it.
        press.minimumPressDuration = 0.28
        press.allowableMovement = 10_000
        press.cancelsTouchesInView = true
        view.addGestureRecognizer(press)
        context.coordinator.press = press
        context.coordinator.installCustomActions()
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.parent = self
        view.accessibilityLabel = String(localized: "Hold to dictate")
        view.accessibilityHint = String(localized: "Hold to talk; slide up to cancel")
        view.accessibilityValue = isRecording ? String(localized: "Recording") : nil
        view.isUserInteractionEnabled = isEnabled
        context.coordinator.press?.isEnabled = isEnabled
        context.coordinator.refreshCustomActions()
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: ComposerMicControl
        weak var press: UILongPressGestureRecognizer?
        private var startPoint: CGPoint?
        private var isDown = false
        private var isCancelling = false

        init(_ parent: ComposerMicControl) {
            self.parent = parent
        }

        @objc func handle(_ gesture: UILongPressGestureRecognizer) {
            let point = gesture.location(in: gesture.view)
            switch gesture.state {
            case .began:
                guard parent.isEnabled else { return }
                startPoint = point
                isDown = true
                isCancelling = false
                if Haptics.enabled {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                }
                parent.onPress()
            case .changed:
                guard isDown, !isCancelling, let startPoint else { return }
                // Up, not distance: sliding sideways along the row is a thumb
                // adjusting, sliding up is the operator changing their mind.
                if startPoint.y - point.y > ComposerMicControl.cancelTravel {
                    isCancelling = true
                    if Haptics.enabled {
                        UINotificationFeedbackGenerator().notificationOccurred(.warning)
                    }
                    parent.onCancel()
                }
            case .ended:
                guard isDown else { return }
                isDown = false
                startPoint = nil
                if !isCancelling {
                    parent.onRelease()
                }
                isCancelling = false
            case .cancelled, .failed:
                guard isDown else { return }
                isDown = false
                startPoint = nil
                isCancelling = false
                parent.onCancel()
            default:
                break
            }
        }

        /// VoiceOver's three actions, because a long press is not something it
        /// can perform: start, stop and cancel are the same states, exposed as
        /// actions instead of a gesture.
        func installCustomActions() {
            // Rebuilt on every update; labels follow the recording state.
            refreshCustomActions()
        }

        func refreshCustomActions() {
            guard let view = press?.view else { return }
            view.accessibilityCustomActions = [
                UIAccessibilityCustomAction(
                    name: String(localized: "Start dictation"),
                ) { [weak self] _ in
                    guard let self, self.parent.isEnabled else { return false }
                    self.parent.onPress()
                    return true
                },
                UIAccessibilityCustomAction(
                    name: String(localized: "Stop dictation"),
                ) { [weak self] _ in
                    guard let self else { return false }
                    self.parent.onRelease()
                    return true
                },
                UIAccessibilityCustomAction(
                    name: String(localized: "Cancel dictation"),
                ) { [weak self] _ in
                    guard let self else { return false }
                    self.parent.onCancel()
                    return true
                },
            ]
        }
    }
}

/// A view that exists to be pressed: no drawing, one gesture, one hit test.
private final class MicPressView: UIView {
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        // The drawn circle is 34 points; the thumb that presses it is wider.
        bounds.insetBy(dx: -5, dy: -5).contains(point)
    }
}

// MARK: - The recording strip

/// The strip above the controls while the microphone is doing something.
///
/// One fixed-height region carries all of it -- level, preview, clock and the
/// cancel line -- because the operator's attention is on the finger, not on a
/// second surface appearing elsewhere. The preview is a preview: the draft is
/// not touched until the finger lifts.
struct ComposerDictationStrip: View {
    let phase: ComposerDictator.Phase
    let liveText: String
    let level: Double
    let elapsed: TimeInterval
    let cancelling: Bool
    var onOpenSettings: (() -> Void)?
    var onDismiss: (() -> Void)?

    @ScaledMetric(relativeTo: .subheadline) private var height: CGFloat = 44

    var body: some View {
        Group {
            if phase == .recording {
                recording
            } else {
                explanation
            }
        }
        .padding(.horizontal, 12)
        .frame(height: height)
        .background(Color(.quaternarySystemFill), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityIdentifier("composer.dictation.strip")
    }

    private var recording: some View {
        HStack(spacing: 8) {
            Text(Self.clock(elapsed))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            LevelMeter(level: level)
            Text(liveText.isEmpty ? String(localized: "Listening…") : liveText)
                .font(.subheadline)
                .lineLimit(1)
                // The end of a sentence is what is being heard; the start is
                // what has already scrolled away.
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(cancelling ? "Release to cancel" : "Slide up to cancel")
                .font(.caption2)
                .foregroundStyle(cancelling ? Theme.failed : .secondary)
                .lineLimit(1)
                .fixedSize()
                .accessibilityHidden(true)
        }
        .animation(.mizarSnappy, value: cancelling)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Recording"))
        .accessibilityValue(liveText)
    }

    private var explanation: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(phase == .failed ? Theme.failed : .secondary)
            Text(message)
                .font(.subheadline)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if case .assets(let progress) = phase {
                if let progress {
                    Text(progress, format: .percent.precision(.fractionLength(0)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.mini)
                }
            }
            if phase == .permissionDenied, let onOpenSettings {
                Button(action: onOpenSettings) {
                    Text("Open Settings")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.pressable(scale: 0.95))
                .accessibilityIdentifier("composer.dictation.settings")
            }
            if phase == .failed || phase == .unsupported, let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Dismiss"))
            }
        }
    }

    private var symbol: String {
        switch phase {
        case .permissionDenied: "mic.slash"
        case .unsupported: "waveform.slash"
        case .assets: "arrow.down.circle"
        case .preparing: "waveform"
        case .failed: "exclamationmark.triangle"
        case .recording, .idle: "waveform"
        }
    }

    private var message: String {
        switch phase {
        case .permissionDenied:
            String(localized: "Allow microphone access to dictate.")
        case .unsupported:
            String(localized: "Dictation is not available on this device.")
        case .assets(nil):
            String(localized: "Downloading the speech model…")
        case .assets(.some):
            String(localized: "Downloading the speech model…")
        case .preparing:
            String(localized: "Getting the microphone ready…")
        case .failed:
            String(localized: "Dictation stopped. Your draft is unchanged.")
        case .recording, .idle:
            String(localized: "Listening…")
        }
    }

    /// `0:07` -- a recording is seconds long, and a clock that reads `00:00:07`
    /// is wider than the numbers are worth.
    static func clock(_ elapsed: TimeInterval) -> String {
        let seconds = max(0, Int(elapsed.rounded(.down)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// Four bars that answer the input level. Decoration: the preview text is the
/// information, and a VoiceOver operator should not hear a meter.
private struct LevelMeter: View {
    let level: Double

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<4, id: \.self) { index in
                Capsule()
                    .fill(Theme.accentText.opacity(0.85))
                    .frame(width: 3, height: barHeight(index))
            }
        }
        .frame(width: 20, height: 22)
        .accessibilityHidden(true)
    }

    private func barHeight(_ index: Int) -> CGFloat {
        let weights = [0.55, 1.0, 0.75, 0.45]
        let amplitude = min(max(level, 0), 1)
        let baseline: CGFloat = 4
        return baseline + CGFloat(weights[index] * amplitude) * 16
    }
}

// MARK: - The note

/// One quiet line about on-device work: a rewrite that is taking a moment, or
/// a refusal that left the draft alone.
///
/// A capsule above the composer rather than an alert: the operator asked for
/// the draft to change and it did not, which is information, not an
/// interruption. It goes away on its own; the two buttons are for the two
/// cases where staying is not enough.
struct ComposerOnDeviceNote: View {
    let text: String
    var isBusy = false
    var onCancel: (() -> Void)?
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            if isBusy {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Image(systemName: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Text(text)
                .font(.subheadline)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if let onCancel {
                Button(action: onCancel) {
                    Text("Cancel")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.pressable(scale: 0.95))
            }
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Dismiss"))
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 38)
        .liquidCapsule()
        .accessibilityIdentifier("composer.onDevice.note")
    }
}
