//
//  ActivityLog.swift
//  DSH-Mizar
//
//  What this app has been doing, kept so it can be handed over.
//
//  Two destinations, and both are needed. `os.Logger` is what a developer looks
//  at while the phone is plugged in -- free when nobody is streaming, structured,
//  and visible in Console.app next to everything else the system is saying. The
//  ring buffer is what the operator can *send*: a device log needs a computer, a cable
//  and a person who knows `log collect`, and the report that matters arrives as
//  "here is the zip" from somebody who has none of those.
//
//  The buffer is bounded because this is a phone. A fortnight of uptime with a
//  request log is a few thousand lines; keeping all of it would grow without
//  limit in a process that is suspended and resumed rather than restarted, so the
//  oldest records are dropped and the newest are what a report contains. The
//  export header says how many there are, so nobody has to guess whether they
//  are looking at everything.
//
//  Nothing here writes a credential. The scrubber in `MizarKit` is the second
//  line of defence for the archive; the first is that the token is never passed
//  to a log line in the first place -- the device token is recorded as "present,
//  64 characters" and never as itself.
//

import Foundation
import MizarKit
import os

/// The app's activity log.
@MainActor
final class ActivityLog {
    /// The log the app writes to.
    static let shared = ActivityLog()

    /// How many records are kept. See the note above about why it is bounded.
    static let defaultLimit = 4000

    /// The records, oldest first.
    private(set) var records: [LogRecord] = []

    private let limit: Int
    private let logger = Logger(subsystem: "me.shirazu.dshmizar", category: "app")

    /// - Parameter limit: how many records to keep.
    init(limit: Int = ActivityLog.defaultLimit) {
        self.limit = max(1, limit)
    }

    /// Write one record.
    ///
    /// - Parameters:
    ///   - category: what kind of thing happened.
    ///   - message: what happened, written for a person reading a file later.
    ///   - request: the call it is about, when it is about one.
    func add(_ category: LogRecord.Category, _ message: String, request: RequestDetail? = nil) {
        records.append(LogRecord(category: category, message: message, request: request))
        if records.count > limit {
            records.removeFirst(records.count - limit)
        }
        // The message goes to the device log as it is. It is the app's own text
        // and the app never puts a token in it; the alternative -- redacting
        // every interpolation -- makes the one log a developer reads while
        // debugging unreadable, which is how a logging system gets abandoned.
        //
        // `info` rather than `debug`, and that is the difference between a mirror
        // somebody can read and one they cannot: debug-level messages are not
        // kept, so `log show` on a simulator prints nothing at all for them --
        // measured, not assumed. `info` is in memory for the life of the log and
        // in Console.app with no flags.
        logger.info("[\(category.rawValue, privacy: .public)] \(message, privacy: .public)")
        #if DEBUG
        // The device console (`devicectl ... --console`) is the only channel a
        // cable-attached test has while no one is watching Console.app. os_log
        // alone is invisible there, and "the route was never attempted" is
        // exactly the kind of fact that has to be readable at the moment it
        // happens.
        print("[\(category.rawValue)] \(message)")
        #endif
    }

    /// How many records are held.
    var count: Int { records.count }

    /// Forget everything, for a fresh start after unpairing.
    func clear() {
        records.removeAll()
    }
}
