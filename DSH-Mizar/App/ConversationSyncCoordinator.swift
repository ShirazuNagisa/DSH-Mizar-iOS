import Foundation
import Observation
import MizarKit

/// Plans and runs one bounded history synchronization pass.
@MainActor
@Observable
final class ConversationSyncCoordinator {
    struct Progress: Sendable, Equatable {
        var current: String
        var completed: Int
        var total: Int
        var startedAt: Date = Date()
        var fraction: Double { total == 0 ? 0 : Double(completed) / Double(total) }
        var remaining: TimeInterval? {
            guard completed > 0, total > completed else { return nil }
            let elapsed = Date().timeIntervalSince(startedAt)
            guard elapsed > 0 else { return nil }
            return elapsed / Double(completed) * Double(total - completed)
        }
    }

    struct RunIdentity: Sendable, Equatable {
        let hostId: String
        let invalidation: UInt64
    }

    struct Entry: Sendable {
        let session: SessionRow
        let cursor: SessionMessagesCursor
        let coveredAt: Double
    }

    enum Batch: Sendable {
        case answered(SessionSyncResult)
        case unsupported
        case failed(String)
    }

    enum Preflight: Sendable {
        case ready([SessionRow])
        case disconnected(String)
        case empty(String)
        case stale
    }

    typealias Validity = @MainActor () -> Bool

    struct Operations {
        var identity: @MainActor () -> RunIdentity?
        var initialTotal: @MainActor () -> Int
        var isConnected: @MainActor () -> Bool
        var preflight: @MainActor (RunIdentity) async -> Preflight
        var load: @MainActor (String) async -> CachedConversation?
        var nextCursor: @MainActor (CachedConversation?) -> SessionMessagesCursor
        var batch: @MainActor (RunIdentity, [Entry]) async -> Batch
        var fallback: @MainActor (RunIdentity, [Entry]) async -> [String: SessionMessagesResult]
        /// A nil page asks AppModel to use its ordinary reconnect-capable single-session path.
        var applyPage: @MainActor (Entry, SessionMessagesResult?, @escaping Validity) async -> Void
        var markUnchanged: @MainActor (Entry, @escaping Validity) async -> Void
        var finish: @MainActor (RunIdentity, @escaping Validity) async -> String?
        var log: @MainActor (String) -> Void
    }

    static let windowSize = 24
    static let maxBytes = 600_000
    static let pageSize = 200

    private(set) var progress: Progress?
    private(set) var problem: String?
    var isSyncing: Bool { progress != nil }

    func sync(using operations: Operations) async {
        guard progress == nil else {
            operations.log("history sync: already running, second request ignored")
            return
        }
        operations.log("history sync: starting")
        let startedAt = Date()
        progress = Progress(current: "", completed: 0, total: operations.initialTotal(), startedAt: startedAt)
        problem = nil
        defer { progress = nil }

        guard !Task.isCancelled else { return }
        guard let identity = operations.identity() else {
            problem = "Not connected to the computer."
            return
        }
        guard valid(identity, operations) else { return }
        let preflight = await operations.preflight(identity)
        guard valid(identity, operations) else { return }
        let sessions: [SessionRow]
        switch preflight {
        case .ready(let rows): sessions = rows
        case .disconnected(let message):
            operations.log("history sync: skipped, not connected to the computer")
            problem = message
            return
        case .empty(let message):
            operations.log("history sync: the computer listed no sessions, or the list could not be read")
            problem = message
            return
        case .stale: return
        }
        guard valid(identity, operations) else { return }

        let runnable = sessions.filter { !$0.isSubagent }
        progress = Progress(current: "", completed: 0, total: runnable.count, startedAt: startedAt)
        operations.log("history sync: \(runnable.count) sessions to fetch")

        var queue: [Entry] = []
        var completed = 0
        for session in runnable {
            guard valid(identity, operations) else { return }
            let cached = await operations.load(session.sessionId)
            guard valid(identity, operations) else { return }
            if HistorySyncPolicy.isCurrent(cached, updatedAt: session.updatedAt) {
                completed += 1
                progress?.completed = completed
                operations.log("history sync: \(session.sessionId) unchanged")
                continue
            }
            let cursor = operations.nextCursor(cached)
            queue.append(Entry(session: session, cursor: cursor, coveredAt: cached?.syncedUpdatedAt ?? 0))
        }

        var unsupported = false
        while !queue.isEmpty {
            guard valid(identity, operations) else { return }
            guard operations.isConnected() else {
                operations.log("history sync: stopped with \(queue.count) session(s) unread, not connected")
                break
            }
            let window = Array(queue.prefix(Self.windowSize))
            let rest = Array(queue.dropFirst(window.count))
            var handled = Set<String>()

            if !unsupported {
                let outcome = await operations.batch(identity, window)
                guard valid(identity, operations) else { return }
                switch outcome {
                case .unsupported:
                    unsupported = true
                    operations.log("history sync: this computer does not answer batched reads; one request per session")
                case .failed(let message):
                    operations.log("history sync: batch read failed (\(message)); reading this window one by one")
                case .answered(let result):
                    for item in result.items {
                        guard let entry = window.first(where: { $0.session.sessionId == item.sessionId }),
                              handled.insert(item.sessionId).inserted else { continue }
                        guard valid(identity, operations) else { return }
                        progress?.current = Self.label(for: entry.session)
                        if item.unchanged == true {
                            await operations.markUnchanged(entry, { self.valid(identity, operations) })
                        } else if let page = item.messages {
                            await operations.applyPage(entry, page, { self.valid(identity, operations) })
                        } else {
                            operations.log("history sync: \(entry.session.sessionId) in batch failed: \(item.error?.message ?? "no answer")")
                            await operations.applyPage(entry, nil, { self.valid(identity, operations) })
                        }
                        guard valid(identity, operations) else { return }
                        completed += 1
                        setProgress(entry.session, completed, runnable.count, startedAt)
                    }
                    if handled.isEmpty {
                        operations.log("history sync: the batch answered no sessions; reading this window one by one")
                    } else {
                        queue = window.filter { !handled.contains($0.session.sessionId) } + rest
                        continue
                    }
                }
            }

            let pages = await operations.fallback(identity, window)
            guard valid(identity, operations) else { return }
            completed = await fallbackWindow(
                window,
                pages: pages,
                identity: identity,
                operations: operations,
                total: runnable.count,
                startedAt: startedAt,
                completed: completed,
            )
            guard valid(identity, operations) else { return }
            queue = rest
        }

        guard valid(identity, operations) else { return }
        let finishProblem = await operations.finish(identity, { self.valid(identity, operations) })
        guard valid(identity, operations) else { return }
        problem = finishProblem
        operations.log(String(format: "history sync: finished in %.1f s", Date().timeIntervalSince(startedAt)))
    }

    private func fallbackWindow(
        _ entries: [Entry],
        pages: [String: SessionMessagesResult],
        identity: RunIdentity,
        operations: Operations,
        total: Int,
        startedAt: Date,
        completed: Int,
    ) async -> Int {
        var completed = completed
        for entry in entries {
            guard !Task.isCancelled, valid(identity, operations) else { return completed }
            progress?.current = Self.label(for: entry.session)
            await operations.applyPage(entry, pages[entry.session.sessionId], { self.valid(identity, operations) })
            guard !Task.isCancelled, valid(identity, operations) else { return completed }
            completed += 1
            setProgress(entry.session, completed, total, startedAt)
        }
        return completed
    }

    private func setProgress(_ session: SessionRow, _ completed: Int, _ total: Int, _ startedAt: Date) {
        progress = Progress(
            current: Self.label(for: session),
            completed: completed,
            total: total,
            startedAt: startedAt,
        )
    }

    private static func label(for session: SessionRow) -> String {
        session.cwd.map { ($0 as NSString).lastPathComponent } ?? session.sessionId
    }

    private func valid(_ identity: RunIdentity, _ operations: Operations) -> Bool {
        !Task.isCancelled && operations.identity() == identity
    }
}
