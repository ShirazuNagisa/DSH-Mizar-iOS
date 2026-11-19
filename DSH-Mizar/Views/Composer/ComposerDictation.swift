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
//  in memory, and a cancel drops the buffer. The speech model is Apple's own
//  and runs on device (``SpeechTranscriber``), which is why the only
//  permission the app asks for is the microphone.
//
//  The three gates are asked in a fixed order, because the order is what the
//  operator is *not* asked:
//
//   1. Can this device transcribe this language at all? A phone without the
//      model never raises a microphone alert for a feature that cannot work.
//   2. May the app use the microphone? Asked at the moment of use, never at
//      launch: a prompt for a button most sessions never press is a prompt
//      people learn to dismiss.
//   3. Are the language's assets on disk? A download is a system transfer,
//      not a permission, and it is started by a press rather than interrupting
//      one.
//

import AVFoundation
import Foundation
import Observation
import os
import Speech
import UIKit

/// Everything that can stand between a long press and a transcript.
@Observable
@MainActor
final class ComposerDictator {
    // MARK: - What the screen reads

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

    // MARK: - The two facts the system owns

    /// What the microphone's answer means to this feature.
    enum MicrophoneAnswer: Equatable {
        case granted
        /// iOS has not been asked. Asking is not starting: a recording that
        /// began behind the alert would be a recording whose first words were
        /// spoken to a dialog.
        case undetermined
        case denied
    }

    /// What a press can do, before anybody is asked anything.
    enum Capability: Equatable {
        /// The model, the language and its assets are all here.
        case ready
        /// The language can be transcribed once the system finishes downloading.
        case install
        /// No model, no language, or assets this device will never have.
        case unavailable
    }

    // MARK: - Test seam

    /// Asks iOS for the microphone.
    ///
    /// Injected at construction for one reason: a system permission alert
    /// cannot be answered from inside a test runner, and a test that waits on
    /// it hangs until the suite times out. Nothing else about this object is
    /// replaceable -- the audio, the analyzer and the assets are always the
    /// real ones, because a fake microphone would prove nothing about the code
    /// that matters.
    let requestMicrophonePermission: () async -> Bool

    // MARK: - Private

    /// Where the samples come from. Everything about it is off the main actor.
    private var capture: ComposerAudioCapture?
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var resultsTask: Task<Void, Never>?
    private var tickerTask: Task<Void, Never>?
    /// The system's download, if one is running. Outlives a cancel on purpose.
    private var installTask: Task<Void, Never>?
    private var assetProgress: Double?
    private var observers: [NSObjectProtocol] = []

    /// Segments the transcriber has finished with, joined as they arrive.
    private var settledText = ""
    /// The segment still being revised. It replaces itself, it does not append.
    private var volatileText = ""
    private var startedAt: Date?

    private var sessionConfigured = false
    private var previousCategory: AVAudioSession.Category?
    private var previousMode: AVAudioSession.Mode?

    /// Bumped by every path that stops listening.
    ///
    /// `begin()` is asynchronous and the finger that started it is not: a
    /// lift during `preparing` must not leave an engine running that nobody is
    /// left to stop. Every await in the bring-up path re-checks this, and the
    /// teardown paths bump it, so the losing side of the race releases what it
    /// built instead of finishing a recording nobody asked for.
    private var generation = 0

    init(
        requestMicrophonePermission: @escaping () async -> Bool = {
            await AVAudioApplication.requestRecordPermission()
        },
    ) {
        self.requestMicrophonePermission = requestMicrophonePermission
    }

    // MARK: - Press

    /// Bring the microphone and the analyzer up.
    ///
    /// - Returns: whether audio is now being captured. `false` is a normal
    ///   answer: a permission that was just granted starts on the *next*
    ///   press, so the system alert is never answered into a half-started
    ///   recording, and a language whose assets are still downloading answers
    ///   the same way.
    func begin() async -> Bool {
        guard phase != .recording, phase != .preparing else { return false }

        generation += 1
        let token = generation
        settle()

        // 1. Can this device do it at all?
        let available = SpeechTranscriber.isAvailable
        let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current)
        guard token == generation else { return false }
        guard available, let locale else {
            phase = .unsupported
            return false
        }

        // 2. May the app use the microphone?
        switch Self.answer(for: AVAudioApplication.shared.recordPermission) {
        case .undetermined:
            _ = await requestMicrophonePermission()
            guard token == generation else { return false }
            phase = .idle
            return false
        case .denied:
            phase = .permissionDenied
            return false
        case .granted:
            break
        }

        // 3. Are the language's assets on disk?
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        let assets = await AssetInventory.status(forModules: [transcriber])
        guard token == generation else { return false }
        switch Self.capability(for: assets) {
        case .unavailable:
            phase = .unsupported
            return false
        case .install:
            await startInstall(locale: locale, transcriber: transcriber)
            return false
        case .ready:
            break
        }

        phase = .preparing
        guard await startCapture(transcriber: transcriber, token: token) else {
            // A superseded bring-up cleans itself up and leaves the phase to
            // whoever superseded it.
            if phase == .preparing { phase = .idle }
            return false
        }
        return true
    }

    /// Stop capturing and answer with the transcript, or `nil` when there is
    /// nothing worth inserting.
    ///
    /// The analyzer is drained rather than cancelled: the words spoken in the
    /// last few hundred milliseconds are still inside it, and a transcript that
    /// stops at the previous sentence is the bug this ordering prevents.
    func finish() async -> String? {
        guard phase == .recording, let analyzer else {
            // Nothing was listening. A download in flight owns the phase and is
            // left alone; anything else goes back to rest.
            generation += 1
            settle()
            if installTask == nil { phase = .idle }
            return nil
        }

        generation += 1
        stopTicker()
        capture?.stop()
        capture = nil

        let results = resultsTask
        try? await analyzer.finalizeAndFinishThroughEndOfInput()
        await results?.value
        resultsTask = nil
        self.analyzer = nil
        // Observers first, session second: deactivating and restoring the
        // category posts exactly the route change this class listens for, and
        // reading back one's own teardown as an interruption is a way to end a
        // recording that has already ended.
        removeObservers()
        endSession()
        transcriber = nil

        let transcript = Self.normalizedTranscript(Self.joined(settledText, volatileText))
        settle()
        phase = .idle
        return transcript.isEmpty ? nil : transcript
    }

    /// Stop and throw the capture away.
    func cancel() {
        generation += 1
        stopTicker()
        settle()
        releaseAudio()
        // A language download is not this recording: it is a system transfer
        // the operator started with the same press, and dropping it here would
        // restart it from zero next time.
        if installTask == nil { phase = .idle }
    }

    /// Put the entry back to its resting state after the operator has read
    /// whatever it had to say.
    func reset() {
        switch phase {
        case .unsupported, .permissionDenied, .failed:
            phase = .idle
        case .assets, .idle, .preparing, .recording:
            break
        }
    }

    // MARK: - The pure decisions

    /// How the microphone's answer is read.
    static func answer(for permission: AVAudioApplication.recordPermission) -> MicrophoneAnswer {
        switch permission {
        case .granted: .granted
        case .undetermined: .undetermined
        default: .denied
        }
    }

    /// What a press can do with the assets the system reports.
    ///
    /// `supported` and `downloading` both mean "possible, not yet": the model
    /// exists for this language and the bytes are missing. `unsupported` is the
    /// only answer that ends the feature for this language, and it is kept
    /// distinct from the device having no model at all so the explanation can
    /// name the right reason.
    static func capability(for status: AssetInventory.Status) -> Capability {
        switch status {
        case .installed: .ready
        case .supported, .downloading: .install
        case .unsupported: .unavailable
        @unknown default: .unavailable
        }
    }

    /// The meter's scale: decibels, floored where speech stops being speech.
    ///
    /// Linear amplitude is the wrong scale for a meter -- ordinary speech sits
    /// between -30 and -10 dBFS, so a linear bar would move in the top tenth of
    /// its range and look broken for the whole sentence. -50 dBFS is silence and
    /// 0 dBFS is the loudest the meter can show.
    static func level(fromRMS rms: Double) -> Double {
        guard rms.isFinite, rms > 0 else { return 0 }
        let decibels = 20 * log10(rms)
        return min(1, max(0, (decibels + 50) / 50))
    }

    /// One line out of the transcriber's segments.
    ///
    /// The segments are separate results and their boundaries are the model's,
    /// not the sentence's: one can end without a trailing space and the next can
    /// begin with a newline. Joining them blindly gives "helloworld"; joining
    /// them with a space gives a Chinese draft a space after every clause. The
    /// separator is therefore decided per boundary, and the result is collapsed
    /// before it reaches the draft.
    static func joined(_ settled: String, _ addition: String) -> String {
        guard !addition.isEmpty else { return settled }
        guard !settled.isEmpty else { return addition }
        let separator = needsSeparator(after: settled, before: addition) ? " " : ""
        return settled + separator + addition
    }

    /// Whether a boundary between two pieces needs a space.
    ///
    /// Whitespace already present is respected; two pieces of CJK are joined
    /// directly, because a space between them is not how the language is
    /// written and the transcriber will not add one.
    static func needsSeparator(after left: String, before right: String) -> Bool {
        guard let last = left.last, let first = right.first else { return false }
        if last.isWhitespace || first.isWhitespace { return false }
        if last.isWhitespaceBoundaryFree, first.isWhitespaceBoundaryFree { return false }
        return true
    }

    /// A transcript shaped like a draft: one line, no stray runs of space.
    ///
    /// Trimming and collapsing in one pass is deliberate -- the draft field is
    /// measured and scrolled by its line count, and a leading newline from the
    /// model is an extra line of layout for no text.
    static func normalizedTranscript(_ raw: String) -> String {
        raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    // MARK: - Bringing audio up

    private func startCapture(transcriber: SpeechTranscriber, token: Int) async -> Bool {
        do {
            try beginSession()
        } catch {
            releaseAudio()
            phase = .failed
            return false
        }

        let formats = await transcriber.availableCompatibleAudioFormats
        guard token == generation else {
            endSession()
            return false
        }
        guard let capture = ComposerAudioCapture(analyzerFormats: formats) else {
            // No usable input on this route: a phone with no microphone that
            // can be opened, or a route that changed between the press and now.
            endSession()
            phase = .failed
            return false
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.capture = capture
        self.analyzer = analyzer
        self.transcriber = transcriber
        settledText = ""
        volatileText = ""

        do {
            try await analyzer.prepareToAnalyze(in: capture.analyzerFormat)
            guard token == generation else {
                releaseAudio()
                return false
            }
            startResults(transcriber)
            try await analyzer.start(inputSequence: capture.inputs)
            guard token == generation else {
                releaseAudio()
                return false
            }
            try capture.start()
        } catch {
            releaseAudio()
            phase = .failed
            return false
        }

        guard token == generation else {
            releaseAudio()
            return false
        }

        startedAt = Date()
        elapsed = 0
        level = 0
        startTicker()
        observeAudioSession()
        phase = .recording
        return true
    }

    /// Consume the transcriber's results for the life of one recording.
    ///
    /// Final results accumulate and volatile ones replace each other: a
    /// volatile result is the model revising the same sentence, so appending it
    /// would grow the preview with every correction.
    private func startResults(_ transcriber: SpeechTranscriber) {
        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self, !Task.isCancelled else { return }
                    self.absorb(result)
                }
            } catch {
                // The analyzer died mid-sentence. Say so once; the draft is
                // untouched and the next press starts over.
                guard let self, !Task.isCancelled, self.phase == .recording else { return }
                self.generation += 1
                self.releaseAudio()
                self.phase = .failed
            }
        }
    }

    private func absorb(_ result: SpeechTranscriber.Result) {
        let segment = String(result.text.characters)
        if result.isFinal {
            settledText = Self.joined(settledText, segment)
            volatileText = ""
        } else {
            volatileText = segment
        }
        liveText = Self.normalizedTranscript(Self.joined(settledText, volatileText))
    }

    /// The clock and the meter, sampled rather than pushed.
    ///
    /// The tap already runs on a thread the system owns; hopping to the main
    /// actor for every buffer would put the meter in front of the typing that is
    /// happening at the same time. The tap writes one number into a lock and
    /// this reads it twenty times a second, which is faster than the eye.
    private func startTicker() {
        tickerTask?.cancel()
        let started = Date()
        startedAt = started
        tickerTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(50))
                } catch {
                    return
                }
                guard let self, self.startedAt == started, self.phase == .recording else { return }
                self.elapsed = Date().timeIntervalSince(started)
                self.level = Self.level(fromRMS: self.capture?.currentLevel ?? 0)
            }
        }
    }

    private func stopTicker() {
        tickerTask?.cancel()
        tickerTask = nil
        startedAt = nil
    }

    // MARK: - The language's assets

    /// Start the system's language download, or attach to the one already
    /// running.
    ///
    /// Deliberately not awaited by ``begin()``: a first download is tens of
    /// megabytes and the finger that asked for it is already up. The press
    /// answers "not yet", the strip carries the progress, and the *next* press
    /// records -- the same contract as the permission alert.
    private func startInstall(locale: Locale, transcriber: SpeechTranscriber) async {
        guard installTask == nil else {
            phase = .assets(progress: assetProgress)
            return
        }
        phase = .assets(progress: assetProgress)

        installTask = Task { [weak self] in
            await self?.reserve(locale)
            guard let request = try? await AssetInventory.assetInstallationRequest(supporting: [transcriber])
            else {
                self?.installTask = nil
                self?.phase = .failed
                return
            }

            // Polled rather than observed: `Progress` supports key-value
            // observation, but an observation that is not invalidated on every
            // path outlives the transfer and keeps writing into a screen that
            // is gone. Four reads a second of a property the system already
            // updates cannot leak.
            let done = OSAllocatedUnfairLock(initialState: false)
            let download = Task.detached {
                defer { done.withLock { $0 = true } }
                try? await request.downloadAndInstall()
            }
            // `self` is re-bound inside the loop rather than held across it: a
            // download is minutes long in the worst case, and the screen that
            // started it is allowed to go away long before that.
            while !done.withLock({ $0 }) {
                guard let self else { return }
                self.assetProgress = request.progress.fractionCompleted
                self.phase = .assets(progress: self.assetProgress)
                do {
                    try await Task.sleep(for: .milliseconds(250))
                } catch {
                    // Cancelled: the transfer is the system's and outlives this
                    // watcher, so the next press re-reads the status instead of
                    // waiting on a loop that will never tick again.
                    self.assetProgress = nil
                    self.installTask = nil
                    return
                }
            }
            _ = await download.result
            let installed = await AssetInventory.status(forModules: [transcriber]) == .installed

            guard let self else { return }
            self.assetProgress = nil
            self.installTask = nil
            self.phase = installed ? .idle : .failed
        }
    }

    /// Reserve the *current* language, and only it.
    ///
    /// The reservation is what lets the system keep the assets for a language
    /// the app uses; the app uses one at a time, so anything else reserved under
    /// this bundle id is left over from an earlier build or from the system
    /// filling the list itself. `maximumReservedLocales` is small, and a full
    /// list is a download that quietly never starts.
    private func reserve(_ locale: Locale) async {
        let reserved = await AssetInventory.reservedLocales
        guard !reserved.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) else {
            return
        }
        for stale in Self.localesToRelease(
            reserved: reserved,
            maximum: AssetInventory.maximumReservedLocales,
            keeping: locale,
        ) {
            _ = await AssetInventory.release(reservedLocale: stale)
        }
        _ = try? await AssetInventory.reserve(locale: locale)
    }

    /// Which reservations to give up so the current language can have one.
    ///
    /// Nothing is released while there is room, and the current language is
    /// never released: the whole point of the reservation is that *this*
    /// language works next time.
    static func localesToRelease(
        reserved: [Locale],
        maximum: Int,
        keeping current: Locale,
    ) -> [Locale] {
        guard maximum > 0, reserved.count >= maximum else { return [] }
        let identifier = current.identifier(.bcp47)
        guard !reserved.contains(where: { $0.identifier(.bcp47) == identifier }) else { return [] }
        return reserved
    }

    // MARK: - Stopping

    /// The synchronous half of a teardown: nothing is left running or readable.
    ///
    /// One function for every path that abandons a recording -- the cancel
    /// gesture, an interruption, a phone call, leaving the screen -- because the
    /// failure it prevents is one path that forgets the tap and leaves the
    /// microphone open.
    private func releaseAudio() {
        capture?.stop()
        capture = nil
        if let analyzer {
            Task { await analyzer.cancelAndFinishNow() }
        }
        analyzer = nil
        transcriber = nil
        resultsTask?.cancel()
        resultsTask = nil
        removeObservers()
        endSession()
        stopTicker()
    }

    /// Clear everything the strip reads, except the phase.
    private func settle() {
        liveText = ""
        level = 0
        elapsed = 0
        settledText = ""
        volatileText = ""
    }

    // MARK: - The audio session

    private func beginSession() throws {
        let session = AVAudioSession.sharedInstance()
        previousCategory = session.category
        previousMode = session.mode
        // From here the category is the app's to restore, whether or not
        // activation succeeds: a failed activation that leaves the app in
        // `.record` is a phone that stops making sounds until it is restarted.
        sessionConfigured = true
        // `.record` rather than `.playAndRecord`: nothing is played, and a
        // record-only session does not take the speaker away from whatever the
        // operator was listening to. `.measurement` turns off the processing
        // the system applies for calls, which is the wrong gain for a
        // transcriber.
        try session.setCategory(.record, mode: .measurement, options: [])
        try session.setActive(true)
    }

    /// Hand the audio route back, then put the category back.
    ///
    /// `.notifyOthersOnDeactivation` is what tells the app that was paused for
    /// this recording that it may resume; deactivating without it leaves a
    /// podcast ducked until the phone is unlocked again.
    private func endSession() {
        guard sessionConfigured else { return }
        sessionConfigured = false
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        if let previousCategory, let previousMode {
            try? session.setCategory(previousCategory, mode: previousMode, options: [])
        }
        previousCategory = nil
        previousMode = nil
    }

    // MARK: - What takes the microphone away

    /// Watch for the three things that end a recording without the finger
    /// moving: a call, a route change, the app going to the background.
    ///
    /// Every one of them stops into `.idle` and keeps nothing: the draft, its
    /// selection and its undo stack are the operator's, and a recording cut off
    /// by a phone call is not a sentence they finished.
    private func observeAudioSession() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        // The recording these observers belong to. A notification that was
        // already on its way when the previous recording stopped would
        // otherwise arrive with a live phase and end the next one.
        let token = generation

        observers.append(
            center.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: nil,
                queue: .main,
            ) { [weak self] notification in
                let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                guard let raw, AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
                Task { @MainActor in self?.abandon(token) }
            },
        )

        observers.append(
            center.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: nil,
                queue: .main,
            ) { [weak self] _ in
                // Unplugged headphones, a Bluetooth headset joining, the route
                // rebuilding under an active engine: the tap's format belonged
                // to the route that is going away, and conversion into the
                // analyzer is no longer sound. Stop rather than guess.
                Task { @MainActor in self?.abandon(token) }
            },
        )

        observers.append(
            center.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main,
            ) { [weak self] _ in
                Task { @MainActor in self?.abandon(token) }
            },
        )
    }

    private func removeObservers() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
    }

    private func abandon(_ token: Int) {
        guard phase == .recording, token == generation else { return }
        generation += 1
        releaseAudio()
        settle()
        phase = .idle
    }
}

// MARK: - The microphone's plumbing

/// The engine, the converter and the stream the analyzer reads, off the main
/// actor.
///
/// The reasons it is a separate type: the tap runs on a real-time thread the
/// system owns, and everything it touches has to be either immutable, a lock,
/// or an `AsyncStream` continuation. None of those is true of a view model, so
/// the view model owns *this* and reads one number off it.
///
/// Nothing here writes a file: buffers are allocated per tap, converted in
/// place, handed to the analyzer and dropped.
final class ComposerAudioCapture {
    /// The format the analyzer was prepared with.
    let analyzerFormat: AVAudioFormat
    /// What the analyzer consumes. Finishing this stream is how a recording
    /// ends without being cancelled.
    let inputs: AsyncStream<AnalyzerInput>

    private let engine: AVAudioEngine
    private let inputFormat: AVAudioFormat
    private let converter: AVAudioConverter
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    /// Written by the tap, read by the UI's ticker. The only shared number.
    private let meter = OSAllocatedUnfairLock(initialState: 0.0)
    private var tapInstalled = false

    /// The latest RMS of the raw input, 0...1 by amplitude.
    var currentLevel: Double { meter.withLock { $0 } }

    /// Build the pipeline, or answer `nil` when this route has no usable input.
    ///
    /// The input format is read *after* the session has been activated by the
    /// caller, because it is the route's format and the route is only settled
    /// once the session is: reading it earlier and installing a tap for it is
    /// how a recording opens on the wrong sample rate and transcribes silence.
    init?(analyzerFormats: [AVAudioFormat]) {
        let engine = AVAudioEngine()
        let input = engine.inputNode.outputFormat(forBus: 0)
        guard input.channelCount > 0,
              let analyzerFormat = Self.preferredFormat(analyzerFormats, for: input),
              let converter = AVAudioConverter(from: input, to: analyzerFormat)
        else { return nil }

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.engine = engine
        self.inputFormat = input
        self.analyzerFormat = analyzerFormat
        self.converter = converter
        self.inputs = stream
        self.continuation = continuation
    }

    /// The format to convert into: the analyzer's own if this route already
    /// speaks it, so the ordinary case costs no resampling at all.
    static func preferredFormat(_ formats: [AVAudioFormat], for input: AVAudioFormat) -> AVAudioFormat? {
        let usable = formats.filter { $0.channelCount > 0 }
        let speech = usable.filter { $0.commonFormat == .pcmFormatFloat32 }
        if let exact = speech.first(where: { $0.sampleRate == input.sampleRate }) {
            return exact
        }
        return speech.first ?? usable.first
    }

    /// Install the tap and open the microphone.
    func start() throws {
        guard !tapInstalled else { return }

        let converter = converter
        let continuation = continuation
        let meter = meter
        let format = inputFormat
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            // The amplitude crosses the lock as a number: the buffer is the
            // audio thread's, and handing it to a second closure is handing a
            // non-sendable object across the one boundary that has no actor to
            // arbitrate it.
            let amplitude = Self.rms(of: buffer)
            meter.withLock { $0 = amplitude }
            guard let converted = Self.convert(buffer, using: converter) else { return }
            continuation.yield(AnalyzerInput(buffer: converted))
        }
        tapInstalled = true

        engine.prepare()
        do {
            try engine.start()
        } catch {
            stop()
            throw error
        }
    }

    /// Take the tap out and close the microphone. Safe to call twice, and from
    /// any path: every teardown in the view model goes through here.
    func stop() {
        if tapInstalled {
            tapInstalled = false
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        continuation.finish()
        meter.withLock { $0 = 0 }
    }

    /// One tap buffer, converted to what the analyzer accepts.
    ///
    /// The converter is handed exactly one buffer and then told there is no more
    /// data, which is what keeps it from waiting for a second input it will
    /// never get inside a real-time callback. Whatever it could not fit stays
    /// inside it and comes out with the next buffer; the output capacity is
    /// sized for the rate ratio so that, at most, one buffer is in flight.
    static func convert(_ buffer: AVAudioPCMBuffer, using converter: AVAudioConverter) -> AVAudioPCMBuffer? {
        let ratio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else {
            return nil
        }

        var supplied = false
        var failure: NSError?
        let status = converter.convert(to: output, error: &failure) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard failure == nil, status != .error, output.frameLength > 0 else { return nil }
        return output
    }

    /// Root mean square across every channel, which is the amplitude the meter
    /// is a picture of.
    static func rms(of buffer: AVAudioPCMBuffer) -> Double {
        guard let channels = buffer.floatChannelData else { return 0 }
        let frames = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frames > 0, channelCount > 0 else { return 0 }

        var sum = 0.0
        for channel in 0..<channelCount {
            let samples = channels[channel]
            for index in 0..<frames {
                let sample = Double(samples[index])
                sum += sample * sample
            }
        }
        return (sum / Double(frames * channelCount)).squareRoot()
    }
}

private extension Character {
    /// Whether this character is one a space would be wrong after or before.
    ///
    /// CJK is written without word spacing, so a separator between two of its
    /// characters is a typo the model never produces. Full-width punctuation
    /// counts: a Chinese full stop is followed by the next sentence directly.
    var isWhitespaceBoundaryFree: Bool {
        guard let scalar = unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x3000...0x303F, // CJK symbols and punctuation
             0x3040...0x30FF, // kana
             0x3400...0x4DBF, // CJK extension A
             0x4E00...0x9FFF, // CJK unified ideographs
             0xF900...0xFAFF, // compatibility ideographs
             0xFF00...0xFF60, // full-width forms
             0x20000...0x2FA1F: // supplementary ideographic planes
            return true
        default:
            return false
        }
    }
}
