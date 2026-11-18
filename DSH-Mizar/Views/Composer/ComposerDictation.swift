//
//  ComposerDictation.swift
//  DSH-Mizar
//
//  Hold-to-talk, on this iPhone.
//
//  The microphone is a second entry into the same draft, and everything about
//  it is gated on its own: the speech model, the language assets and the
//  microphone permission are three separate questions, and a "no" to any of
//  them must not take the rewriter down with it.
//
//  What the operator sees while the finger is down is a *preview*: the draft
//  binding is untouched until the finger lifts. That is the whole safety
//  property -- a cancelled recording, a dropped audio route or a call must
//  leave the draft exactly as it was, with its selection and its undo stack
//  intact.
//
//  Audio never reaches the file system: the engine's tap feeds the analyzer
//  in memory, and a cancel drops the buffer.
//

import Foundation
import Observation

/// Everything that can stand between a long press and a transcript.
@Observable
@MainActor
final class ComposerDictator {
    /// Where a recording is, as far as the operator is concerned.
    enum Phase: Equatable {
        /// Nothing has been asked for.
        case idle
        /// No speech model for this device or language.
        case unsupported
        /// The microphone was refused. The entry explains and offers Settings.
        case permissionDenied
        /// The language's speech assets are not installed. The associated
        /// value is the download's progress, or `nil` before it starts.
        case assets(progress: Double?)
        /// Microphones and the analyzer are being brought up.
        case preparing
        /// Listening.
        case recording
        /// Something failed while listening; the draft is untouched.
        case failed
    }

    private(set) var phase: Phase = .idle
    /// What has been heard so far. A preview: never the draft.
    private(set) var liveText = ""
    /// The input level, 0...1, for the strip's meter.
    private(set) var level: Double = 0
    /// How long the finger has been down.
    private(set) var elapsed: TimeInterval = 0

    var isRecording: Bool { phase == .recording }

    /// Bring the microphone and the analyzer up.
    ///
    /// - Returns: whether audio is now being captured. `false` is a normal
    ///   answer: a permission that was just granted starts on the *next*
    ///   press, so the system alert is never answered into a half-started
    ///   recording.
    func begin() async -> Bool {
        phase = .unsupported
        return false
    }

    /// Stop capturing and answer with the transcript, or `nil` when there is
    /// nothing worth inserting.
    func finish() async -> String? {
        phase = .idle
        return nil
    }

    /// Stop and throw the capture away.
    func cancel() {
        phase = .idle
        liveText = ""
        level = 0
        elapsed = 0
    }

    /// Put the entry back to its resting state after the operator has read
    /// whatever it had to say.
    func reset() {
        phase = .idle
    }
}
