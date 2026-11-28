//
//  StashPullPolicy.swift
//  MizarKit
//
//  When a stash pull is worth doing. Pure so AppModel and tests share one rule.
//

import Foundation

/// The guards around ``StashClient/pull()`` that live in the app model.
public enum StashPullPolicy {
    /// Minimum spacing between pulls on one process lifetime.
    public static let throttleInterval: TimeInterval = 60

    /// Whether a pull should run now.
    ///
    /// - Parameters:
    ///   - localAgentMode: the on-device agent has no relay mailbox.
    ///   - connected: a live socket is open; realtime frames replace letters.
    ///   - readyPhase: the app is fully connected and drawing live data.
    ///   - relayBaseURL: the pairing's relay room, when it has one.
    ///   - secondsSinceLastPull: time since the last pull started, or `nil` when
    ///     nothing has been pulled yet this launch.
    public static func shouldPull(
        localAgentMode: Bool,
        connected: Bool,
        readyPhase: Bool,
        relayBaseURL: String?,
        secondsSinceLastPull: TimeInterval?,
    ) -> Bool {
        guard !localAgentMode else { return false }
        guard !connected else { return false }
        guard !readyPhase else { return false }
        guard let relayBaseURL, !relayBaseURL.isEmpty else { return false }
        if let elapsed = secondsSinceLastPull, elapsed < throttleInterval { return false }
        return true
    }

    /// Seconds since `lastPull`, for the throttle guard.
    public static func secondsSinceLastPull(lastPull: Date?, now: Date = Date()) -> TimeInterval? {
        guard let lastPull else { return nil }
        return now.timeIntervalSince(lastPull)
    }
}