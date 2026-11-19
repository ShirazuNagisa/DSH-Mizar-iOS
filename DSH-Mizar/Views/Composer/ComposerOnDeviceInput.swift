//
//  ComposerOnDeviceInput.swift
//  DSH-Mizar
//
//  The screen's side of the two on-device entries: what is running, what to
//  say about it, and the one edit the field is about to be handed.
//
//  A single owner rather than state scattered through the composer, for the
//  same reason the composer's panels are owned by the screen: this view is
//  rebuilt while the operator types and the conversation scrolls, and a task
//  whose state lives in a struct is a task that can be lost mid-flight. One
//  object survives the rebuilds, cancels both features on the screen's own
//  life-cycle events, and keeps the rewriter and the microphone independent
//  of each other -- one being unavailable never disables the other.
//
//  The edit handoff is deliberately one slot: the field consumes it once, the
//  composer clears it, and a result that arrives against a draft the operator
//  has since changed is dropped instead of written.
//

import Foundation
import Observation

@Observable
@MainActor
final class ComposerOnDeviceInput {
    /// A replacement, and the draft revision it was computed against.
    struct PendingEdit: Equatable {
        let edit: ComposerEdit
        let revision: Int
    }

    /// What the rewriter is doing.
    enum EnhancementPhase: Equatable {
        case idle
        case running(ComposerEnhanceIntent)
        /// Past the point where waiting needs an explanation.
        case slow(ComposerEnhanceIntent)
    }

    // MARK: State

    private(set) var enhancementPhase: EnhancementPhase = .idle
    private(set) var enhancementAvailability: ComposerEnhanceAvailability = .unknown
    /// Whether the interface is being asked right now.
    private(set) var isProbingAvailability = false
    /// One line about something the operator should know. Cleared on its own.
    private(set) var notice: String?
    /// The edit waiting for the field, if any.
    var pendingEdit: PendingEdit?

    /// The microphone's own state machine.
    let dictation = ComposerDictator()

    // MARK: Private

    private var enhanceTask: Task<Void, Never>?
    private var probeTask: Task<Void, Never>?
    /// Identity of the request in flight; a result carrying an older token is
    /// a result for a draft the operator has already moved past.
    private var enhanceToken = UUID()
    private var noticeTask: Task<Void, Never>?
    private var holdStarted = false
    private var holdRange: NSRange?
    private var holdRevision: Int?

    /// How long a request may take before waiting needs a note.
    private static let slowThreshold: Duration = .milliseconds(1200)

    // MARK: - Enhancement

    var isEnhancing: Bool {
        if case .idle = enhancementPhase { return false }
        return true
    }

    var isEnhancingSlow: Bool {
        if case .slow = enhancementPhase { return true }
        return false
    }

    /// The entry is usable when the model is available and the draft is not
    /// blank. A blank draft keeps the button in place, disabled, so the row
    /// does not shift when the first character arrives.
    var canEnhance: Bool {
        enhancementAvailability.isAvailable && enhancementPhase == .idle
    }

    /// Ask the interface, not the claim.
    ///
    /// The claim is instant and is used for the cases it is certainly right
    /// about (`available`). When it says no, the panel asks the model itself:
    /// 27.3 in mainland China can say "not eligible" while the model answers,
    /// and only a real call can tell the difference.
    func refreshAvailability() {
        let claimed = ComposerEnhancement.availability()
        guard claimed.isWorthProbing else {
            enhancementAvailability = claimed
            return
        }
        guard probeTask == nil else { return }
        enhancementAvailability = .checking
        isProbingAvailability = true
        probeTask = Task { [weak self] in
            let result = await ComposerEnhancement.probe()
            guard let self else { return }
            self.enhancementAvailability = result
            self.isProbingAvailability = false
            self.probeTask = nil
        }
    }

    /// Rewrite the draft, once.
    ///
    /// - Parameters:
    ///   - draft: the whole draft. The rewrite replaces all of it.
    ///   - intent: what "improve" means this time.
    ///   - revision: the draft revision the operator saw; the result is only
    ///     handed to the field while the draft still carries it.
    func enhance(draft: String, intent: ComposerEnhanceIntent, revision: Int) {
        guard canEnhance,
              !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }

        let token = UUID()
        enhanceToken = token
        enhancementPhase = .running(intent)
        notice = nil

        let slow = Task { [weak self] in
            try? await Task.sleep(for: Self.slowThreshold)
            guard let self, !Task.isCancelled, self.enhanceToken == token,
                  self.enhancementPhase == .running(intent)
            else { return }
            self.enhancementPhase = .slow(intent)
        }
        enhanceTask = Task { [weak self] in
            defer { slow.cancel() }
            guard let self else { return }
            do {
                let rewritten = try await ComposerEnhancement.rewrite(draft, intent: intent)
                guard !Task.isCancelled, self.enhanceToken == token else { return }
                try ComposerEnhancement.validate(original: draft, rewritten: rewritten)
                guard self.enhanceToken == token, !Task.isCancelled else { return }
                self.enhancementPhase = .idle
                self.pendingEdit = PendingEdit(
                    edit: ComposerEdit(
                        range: NSRange(location: 0, length: (draft as NSString).length),
                        text: rewritten,
                        source: .enhancement,
                    ),
                    revision: revision,
                )
            } catch {
                guard self.enhanceToken == token else { return }
                self.enhancementPhase = .idle
                if let failure = error as? ComposerEnhanceFailure {
                    // "Unchanged" is silence: there was nothing left to do.
                    if failure == .unchanged { return }
                    self.showNotice(failure.message)
                } else {
                    self.showNotice(String(localized: "The rewrite is not available right now."))
                }
            }
        }
    }

    /// Drop the rewrite in flight. Its answer is ignored when it arrives.
    func cancelEnhancement() {
        enhanceToken = UUID()
        enhanceTask?.cancel()
        enhanceTask = nil
        enhancementPhase = .idle
    }

    // MARK: - Dictation

    var isRecording: Bool { dictation.isRecording }

    /// Whether a press would show the permission explanation instead of
    /// listening.
    var dictationNeedsPermission: Bool { dictation.phase == .permissionDenied }

    var dictationNeedsSettings: Bool { dictation.phase == .permissionDenied }

    /// Start listening where the caret was at the moment of the press.
    ///
    /// The range and the revision are captured before anything is awaited: a
    /// recording must land where the operator pointed, not where the field
    /// happens to be when the transcript arrives.
    func beginHold(revision: Int, selection: NSRange) {
        guard !holdStarted else { return }
        cancelEnhancement()
        holdStarted = true
        holdRange = selection
        holdRevision = revision
        Task { [weak self] in
            guard let self else { return }
            let started = await self.dictation.begin()
            guard self.holdStarted else {
                // The finger lifted while the microphone was coming up.
                if started { _ = await self.dictation.finish() }
                return
            }
            if !started {
                // The first hold on a phone that has never asked shows the
                // system alert and answers `false`; the permission may be
                // granted by now, so the same hold tries once more. Every other
                // no -- a refusal, an asset download, an unsupported model --
                // leaves the entry at rest with its own explanation.
                if self.dictation.phase == .idle {
                    let retried = await self.dictation.begin()
                    guard self.holdStarted else {
                        if retried { _ = await self.dictation.finish() }
                        return
                    }
                    if retried { return }
                    self.showNotice(String(localized: "Microphone allowed. Hold the field again to dictate."))
                }
                self.holdStarted = false
                self.holdRange = nil
                self.holdRevision = nil
            }
        }
    }

    /// The finger lifted: land the transcript once, or discard it.
    func endHold() {
        guard holdStarted else { return }
        holdStarted = false
        let range = holdRange ?? NSRange(location: 0, length: 0)
        let expected = holdRevision
        holdRange = nil
        holdRevision = nil
        Task { [weak self] in
            guard let self else { return }
            let transcript = await self.dictation.finish()
            guard let transcript,
                  !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let expected
            else {
                // The microphone was open and nothing came back. Silence is
                // the one answer the operator cannot tell apart from a broken
                // button, so say it -- but only when the capture really ran:
                // a refused permission or a download has its own explanation.
                if self.dictation.phase == .idle {
                    self.showNotice(
                        String(localized: "Nothing was heard. Your draft is unchanged."),
                    )
                }
                return
            }
            self.pendingEdit = PendingEdit(
                edit: ComposerEdit(range: range, text: transcript, source: .dictation),
                revision: expected,
            )
        }
    }

    /// The operator dragged up past the cancel line, or the screen is going
    /// away. Nothing is inserted.
    func cancelHold() {
        guard holdStarted || dictation.phase != .idle else { return }
        holdStarted = false
        holdRange = nil
        holdRevision = nil
        dictation.cancel()
    }

    /// Put the entry back to rest after the operator has read its explanation.
    func resetDictation() {
        dictation.reset()
    }

    // MARK: - Both

    /// Both features stop, and nothing they held is inserted.
    ///
    /// Called when the screen leaves and when the scene stops being active: a
    /// rewrite started in the background is a rewrite nobody is waiting for,
    /// and a microphone left running is a microphone the operator did not
    /// agree to.
    func cancelAll() {
        cancelEnhancement()
        cancelHold()
        probeTask?.cancel()
        probeTask = nil
        isProbingAvailability = false
        noticeTask?.cancel()
        notice = nil
    }

    /// What to do after the field consumed (or refused) the pending edit.
    func noteEditFinished(_ outcome: ComposerEditOutcome) {
        switch outcome {
        case .applied, .rejected:
            break
        case .discardedComposition:
            showNotice(String(localized: "The text was not inserted. Finish choosing characters first."))
        }
    }

    // MARK: - Notice

    private func showNotice(_ message: String?) {
        guard let message else { return }
        noticeTask?.cancel()
        notice = message
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, !Task.isCancelled else { return }
            if self.notice == message { self.notice = nil }
        }
    }

    /// Clear the note by hand (a tap on it).
    func dismissNotice() {
        noticeTask?.cancel()
        notice = nil
    }
}
