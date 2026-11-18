//
//  ComposerDictationTests.swift
//  DSH-MizarTests
//
//  The microphone's decision table, without a microphone.
//
//  Everything a press decides before it needs audio is pinned here: which of
//  the three gates answers first, how a refusal is read, when a language's
//  assets are a download instead of a feature, and how the transcriber's
//  segments become one line of draft. None of it touches the microphone, and
//  none of it depends on speech assets being installed -- the simulator ships
//  no speech model at all, which is why the "no model" path is the one thing a
//  test runner can walk end to end.
//
//  What is deliberately *not* here: a recording. There is no way to start one
//  in a test runner without a finger, a real microphone and an operator to
//  answer the alert, and a test that pretended to would be proving that a fake
//  works.
//

import AVFoundation
import Foundation
import Speech
import Testing
@testable import DSH_Mizar

@MainActor
struct ComposerDictationTests {
    // MARK: - Phases

    @Test("a phase compares by what it carries")
    func phaseEquality() {
        #expect(ComposerDictator.Phase.idle == .idle)
        #expect(ComposerDictator.Phase.assets(progress: 0.5) == .assets(progress: 0.5))
        #expect(ComposerDictator.Phase.assets(progress: nil) != .assets(progress: 0))
        #expect(ComposerDictator.Phase.assets(progress: 1) != .assets(progress: 0))
        #expect(ComposerDictator.Phase.recording != .preparing)
    }

    @Test("a refused microphone is an explanation, and a grant is not")
    func permissionMapping() {
        #expect(ComposerDictator.answer(for: .granted) == .granted)
        #expect(ComposerDictator.answer(for: .undetermined) == .undetermined)
        #expect(ComposerDictator.answer(for: .denied) == .denied)
    }

    /// The one branch that decides whether a language is worth explaining.
    ///
    /// `supported` and `downloading` are both "not yet, and it can be": the
    /// difference between them is what the strip shows, not what a press does,
    /// because in both cases the press answers `false` and the next one records.
    @Test("asset status decides between ready, download and never")
    func assetCapability() {
        #expect(ComposerDictator.capability(for: .installed) == .ready)
        #expect(ComposerDictator.capability(for: .supported) == .install)
        #expect(ComposerDictator.capability(for: .downloading) == .install)
        #expect(ComposerDictator.capability(for: .unsupported) == .unavailable)
    }

    // MARK: - The press

    @Test("a press with no speech model answers instead of starting or crashing")
    func beginWithoutASpeechModel() async {
        // The injected ask is the alert the runner cannot answer. On a
        // simulator without a model it is never reached, which is the point of
        // asking the model before the microphone.
        let dictator = ComposerDictator(requestMicrophonePermission: { false })
        let started = await dictator.begin()

        #expect(started == false)
        #expect(dictator.isRecording == false)
        switch dictator.phase {
        case .unsupported, .permissionDenied, .failed, .idle:
            break
        case .assets:
            // A simulator that has the model but not its assets answers "not
            // yet" as well; the download itself is the system's business.
            dictator.cancel()
        case .recording, .preparing:
            Issue.record("a press in a test runner started a recording")
        }
        dictator.cancel()
        #expect(dictator.isRecording == false)
    }

    @Test("a press that already answered is answered again, not restarted")
    func repeatedPress() async {
        let dictator = ComposerDictator(requestMicrophonePermission: { false })
        let first = await dictator.begin()
        let phaseAfterFirst = dictator.phase
        let second = await dictator.begin()

        #expect(first == false)
        #expect(second == false)
        #expect(dictator.isRecording == false)
        // The refresh of the same answer must not lose the explanation the
        // first press produced: a press on a device without the model says so
        // every time rather than flashing idle.
        #expect(dictator.phase == phaseAfterFirst || dictator.phase == .idle)
        dictator.cancel()
    }

    @Test("finishing without a recording answers nothing and leaves the entry at rest")
    func finishWithoutRecording() async {
        let dictator = ComposerDictator(requestMicrophonePermission: { false })
        let transcript = await dictator.finish()
        #expect(transcript == nil)
        #expect(dictator.phase == .idle)
        #expect(dictator.liveText.isEmpty)
        #expect(dictator.level == 0)
        #expect(dictator.elapsed == 0)
    }

    @Test("cancelling clears the preview and the clock")
    func cancelClearsThePreview() async {
        let dictator = ComposerDictator(requestMicrophonePermission: { false })
        _ = await dictator.begin()
        dictator.cancel()

        #expect(dictator.phase == .idle)
        #expect(dictator.liveText.isEmpty)
        #expect(dictator.level == 0)
        #expect(dictator.elapsed == 0)
        #expect(dictator.isRecording == false)
    }

    @Test("reset puts an explanation away, and an idle entry stays idle")
    func resetExplanations() async {
        let dictator = ComposerDictator(requestMicrophonePermission: { false })
        dictator.reset()
        #expect(dictator.phase == .idle)

        _ = await dictator.begin()
        dictator.reset()
        #expect(dictator.phase == .idle || dictator.phase == .unsupported)
        dictator.cancel()
    }

    // MARK: - The meter

    /// Linear amplitude is the wrong scale for a meter: speech lives in the top
    /// third of it. The floor is where a meter that never moves stops being a
    /// meter, and the ceiling is a clip.
    @Test("the meter reads loudness, not amplitude")
    func meterScale() {
        #expect(ComposerDictator.level(fromRMS: 0) == 0)
        #expect(ComposerDictator.level(fromRMS: -1) == 0)
        #expect(ComposerDictator.level(fromRMS: .nan) == 0)
        #expect(ComposerDictator.level(fromRMS: 1) == 1)
        #expect(ComposerDictator.level(fromRMS: 4) == 1)

        // -50 dBFS is the floor; -30 and -10 are the middle and the top.
        let quiet = ComposerDictator.level(fromRMS: 0.003162)
        let middling = ComposerDictator.level(fromRMS: 0.031623)
        let loud = ComposerDictator.level(fromRMS: 0.316228)
        #expect(quiet <= 0.001)
        #expect(middling > quiet && middling < loud)
        #expect(abs(middling - 0.4) < 0.01)
        #expect(abs(loud - 0.8) < 0.01)
    }

    // MARK: - What the transcriber hands over

    /// The segments are the model's, not the sentence's: one can end without a
    /// space and the next can begin with a newline. Joining them blindly gives
    /// "helloworld"; joining them with a space puts one inside Chinese.
    @Test("segments join with a separator only where the language wants one")
    func segmentJoining() {
        #expect(ComposerDictator.joined("", "Hello") == "Hello")
        #expect(ComposerDictator.joined("Hello", "") == "Hello")
        #expect(ComposerDictator.joined("Hello", "world") == "Hello world")
        #expect(ComposerDictator.joined("Hello ", "world") == "Hello world")
        #expect(ComposerDictator.joined("你好。", "世界。") == "你好。世界。")
        #expect(ComposerDictator.joined("你好。", "Hello") == "你好。 Hello")
        #expect(ComposerDictator.joined("Hello", "你好") == "Hello 你好")
        #expect(ComposerDictator.needsSeparator(after: "点", before: "。") == false)
        #expect(ComposerDictator.needsSeparator(after: "a", before: "b") == true)
    }

    @Test("a transcript becomes one draft-shaped line")
    func transcriptNormalisation() {
        #expect(ComposerDictator.normalizedTranscript("") == "")
        #expect(ComposerDictator.normalizedTranscript("   ") == "")
        #expect(ComposerDictator.normalizedTranscript("  hello\n world ") == "hello world")
        #expect(ComposerDictator.normalizedTranscript("one\n\ttwo") == "one two")
        #expect(ComposerDictator.normalizedTranscript("你好 世界") == "你好 世界")
    }

    // MARK: - Reservations

    @Test("a reservation is only given up when the list is full and it is not the current one")
    func reservationEviction() {
        let current = Locale(identifier: "zh-Hans-CN")
        let other = Locale(identifier: "en-US")
        let another = Locale(identifier: "ja-JP")

        #expect(ComposerDictator.localesToRelease(reserved: [], maximum: 5, keeping: current).isEmpty)
        #expect(
            ComposerDictator.localesToRelease(reserved: [other], maximum: 5, keeping: current).isEmpty
        )
        #expect(
            ComposerDictator.localesToRelease(reserved: [current, other], maximum: 5, keeping: current)
                .isEmpty
        )
        // Full, and the current language is not among them: something else has
        // to go, or the download this language needs never starts.
        #expect(
            ComposerDictator.localesToRelease(reserved: [other, another], maximum: 2, keeping: current)
                == [other, another]
        )
        // Full, but the current language already holds a slot: nothing to do.
        #expect(
            ComposerDictator.localesToRelease(reserved: [current, other], maximum: 2, keeping: current)
                .isEmpty
        )
        // A system that reserves nothing cannot be reasoned about; leave it alone.
        #expect(ComposerDictator.localesToRelease(reserved: [other], maximum: 0, keeping: current).isEmpty)
    }

    // MARK: - The buffer pipeline

    /// Nothing below captures anything: these are the maths and the format
    /// choice that sit between a tap and the analyzer, run on buffers built for
    /// the test so that the conversion itself is checked without a microphone.
    @Test("the analyzer's own sample rate is used when the input already speaks it")
    func preferredFormat() throws {
        let input = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let sixteen = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let fortyEight = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))

        // No resampling when the route already matches.
        #expect(ComposerAudioCapture.preferredFormat([sixteen, fortyEight], for: input)?.sampleRate == 48_000)
        // The route does not match: the analyzer's format wins, and the
        // converter does the rate change.
        #expect(ComposerAudioCapture.preferredFormat([sixteen], for: input)?.sampleRate == 16_000)
        // Nothing to choose from is a failure the caller must handle, not a
        // crash.
        #expect(ComposerAudioCapture.preferredFormat([], for: input) == nil)
    }

    @Test("a tap buffer leaves the converter in the format the analyzer accepts")
    func bufferConversion() throws {
        let inputFormat = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let outputFormat = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let converter = try #require(AVAudioConverter(from: inputFormat, to: outputFormat))

        let source = try #require(AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 4096))
        source.frameLength = 4096
        let samples = try #require(source.floatChannelData)
        for index in 0..<4096 {
            samples[0][index] = 0.5
        }

        let converted = try #require(ComposerAudioCapture.convert(source, using: converter))
        #expect(converted.format.sampleRate == 16_000)
        #expect(converted.frameLength > 0)
        #expect(converted.frameLength <= 4096)
    }

    @Test("the level is the amplitude of every channel of the buffer")
    func bufferRMS() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        buffer.frameLength = 4
        let samples = try #require(buffer.floatChannelData)
        samples[0][0] = 0.5
        samples[0][1] = -0.5
        samples[0][2] = 0.5
        samples[0][3] = -0.5

        #expect(abs(ComposerAudioCapture.rms(of: buffer) - 0.5) < 0.0001)
    }
}
