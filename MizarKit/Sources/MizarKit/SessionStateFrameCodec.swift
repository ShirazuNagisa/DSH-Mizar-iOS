//
//  SessionStateFrameCodec.swift
//  MizarKit
//
//  The phone half of the state channel. See protocol/state-channel-v1.md.
//
//  Mirrors `AGI Mizar/crates/agi-protocol/src/state_frame.rs` byte for byte.
//  Both sides decode the same fixture (`protocol/fixtures/state-frames.json`),
//  so a change to one without the other fails a test rather than a device.
//

import Foundation

/// Why a byte buffer is not a state frame.
public enum StateFrameError: Error, Equatable {
    case truncated
    case notAStateFrame
    case lengthMismatch
    case contradictoryFlags
    case unknownState(UInt8)
    case textNotAllowed(UInt8)
    case notUTF8
}

/// One frame of the state channel.
public struct StateFrame: Equatable, Sendable {
    /// First byte of every state frame. JSON frames start with `{`.
    public static let magic: UInt8 = 0x53  // 'S'
    /// Fixed header length.
    public static let headerLength = 13

    public struct Flags: OptionSet, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let heartbeat = Flags(rawValue: 1 << 0)
        public static let append = Flags(rawValue: 1 << 1)
        public static let snapshot = Flags(rawValue: 1 << 2)
        public static let final = Flags(rawValue: 1 << 3)
    }

    public let state: SessionState
    /// Monotonic per session; a new value starts a new interval.
    public let interval: UInt32
    public let textSeq: UInt32
    public let flags: Flags
    public let text: String

    public init(state: SessionState, interval: UInt32, textSeq: UInt32 = 0, flags: Flags, text: String = "") {
        self.state = state
        self.interval = interval
        self.textSeq = textSeq
        self.flags = flags
        self.text = text
    }

    /// Encode to bytes. The result is what goes inside a MizarKit Data message.
    public func encoded() -> Data {
        let payload = Data(text.utf8)
        var out = Data(capacity: StateFrame.headerLength + payload.count)
        out.append(StateFrame.magic)
        out.append(state.code)
        out.append(flags.rawValue)
        out.append(contentsOf: withUnsafeBytes(of: interval.bigEndian, Array.init))
        out.append(contentsOf: withUnsafeBytes(of: textSeq.bigEndian, Array.init))
        let length = UInt16(clamping: payload.count)
        out.append(contentsOf: withUnsafeBytes(of: length.bigEndian, Array.init))
        out.append(payload)
        return out
    }

    /// Decode, rejecting anything this build cannot honour.
    public init(decoding data: Data) throws {
        guard data.count >= StateFrame.headerLength else { throw StateFrameError.truncated }
        let bytes = [UInt8](data)
        guard bytes[0] == StateFrame.magic else { throw StateFrameError.notAStateFrame }

        let code = bytes[1]
        guard SessionState(code: code) != .unknown else { throw StateFrameError.unknownState(code) }
        let state = SessionState(code: code)
        let flags = Flags(rawValue: bytes[2])
        let interval = bytes[3...6].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        let textSeq = bytes[7...10].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        let length = Int(bytes[11]) << 8 | Int(bytes[12])
        guard bytes.count == StateFrame.headerLength + length else {
            throw StateFrameError.lengthMismatch
        }

        let hasText = flags.contains(.append)
        if flags.contains(.heartbeat) && (hasText || length != 0) {
            throw StateFrameError.contradictoryFlags
        }
        if !hasText && length != 0 { throw StateFrameError.contradictoryFlags }
        if hasText && !state.carriesText { throw StateFrameError.textNotAllowed(code) }

        guard let text = String(data: data[StateFrame.headerLength...], encoding: .utf8) else {
            throw StateFrameError.notUTF8
        }

        self.state = state
        self.interval = interval
        self.textSeq = textSeq
        self.flags = flags
        self.text = text
    }

    public var isHeartbeat: Bool { flags.contains(.heartbeat) }
}

/// What the display does after a frame.
public enum StateApplied: Equatable, Sendable {
    /// A new interval: replace everything.
    case began
    /// Same state, liveness only. Redraw nothing.
    case renewed
    /// Text changed.
    case updated
    /// The stream ended.
    case finished
    /// An older frame arrived after a newer one.
    case stale
}

/// The receiver's view of one session's state channel.
///
/// Kept in MizarKit rather than the app so both ends apply the same rules, and
/// so "is this frame newer?" has exactly one answer.
public struct StateChannel: Sendable {
    /// How often the host renews a held state.
    public static let heartbeatInterval: TimeInterval = 5
    /// When an interval is considered dead: slightly over two missed beats.
    public static let staleAfter: TimeInterval = 12

    public private(set) var interval: UInt32?
    public private(set) var state: SessionState?
    public private(set) var text: String = ""
    public private(set) var finished = false
    private var lastAt: Date = .distantPast

    public init() {}

    @discardableResult
    public mutating func apply(_ frame: StateFrame, at now: Date = Date()) -> StateApplied {
        if let current = interval {
            if frame.interval < current { return .stale }
            if frame.interval > current { return begin(frame, at: now) }
            lastAt = now
            if frame.isHeartbeat { return .renewed }
            if frame.flags.contains(.snapshot) {
                text = frame.text
            } else if frame.flags.contains(.append) {
                // An append names its byte offset in the interval. A gap means
                // a frame was lost, and splicing two unrelated stretches
                // together draws a sentence that was never said; wait for the
                // next snapshot instead (the protocol's rule).
                if frame.textSeq != UInt32(text.utf8.count) {
                    return .stale
                }
                text += frame.text
            }
            if frame.flags.contains(.final) {
                finished = true
                return .finished
            }
            return .updated
        }
        return begin(frame, at: now)
    }

    private mutating func begin(_ frame: StateFrame, at now: Date) -> StateApplied {
        interval = frame.interval
        state = frame.state
        text = (frame.flags.contains(.snapshot) || frame.flags.contains(.append)) ? frame.text : ""
        finished = frame.flags.contains(.final)
        lastAt = now
        return .began
    }

    /// Whether the host has gone quiet on an interval that promised heartbeats.
    ///
    /// A terminal state never goes stale: the failure already happened, and a
    /// disconnect does not undo it.
    public func isStale(at now: Date = Date()) -> Bool {
        guard let state, state.needsHeartbeat else { return false }
        return now.timeIntervalSince(lastAt) > StateChannel.staleAfter
    }
}
