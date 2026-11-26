import Foundation

/// Keeps the socket answering while the app is on screen.
///
/// A TCP socket can stay "connected" after the network carrying it disappears.
/// The coordinator asks the host a ping with its own deadline, then drops the
/// socket after the route-specific number of misses. Connection selection and
/// state writes stay with its caller.
@MainActor
final class LinkWatchdogCoordinator {
    /// The capabilities the watchdog needs from a live connection.
    protocol Connection: AnyObject, Sendable {
        func watchdogPing(within timeout: Duration) async -> Bool
        func watchdogDisconnect() async
        func watchdogCloseReason() async -> String?
    }

    struct Operations {
        var isAppActive: @MainActor () -> Bool
        var isReconnecting: @MainActor () -> Bool
        var currentConnection: @MainActor () -> (any Connection)?
        var isLocalRoute: @MainActor () -> Bool
        var ping: @MainActor (any Connection, Duration) async -> Bool
        var dropDisconnectedSocket: @MainActor (any Connection) async -> Void
        var log: @MainActor (String) -> Void
    }

    static let interval: Duration = .seconds(5)
    static let probeTimeout: Duration = .seconds(3)

    private let sleep: @MainActor (Duration) async throws -> Void
    private var watchdog: Task<Void, Never>?
    private var misses = 0

    var isRunning: Bool { watchdog != nil }
    var missCount: Int { misses }

    init(
        sleep: @escaping @MainActor (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        },
    ) {
        self.sleep = sleep
    }

    /// Replace the watchdog for the current socket.
    func start(using operations: Operations) {
        stop()
        guard operations.isAppActive(), operations.currentConnection() != nil else { return }

        watchdog = Task { [weak self, sleep] in
            while !Task.isCancelled {
                do {
                    try await sleep(Self.interval)
                } catch {
                    return
                }
                guard let self,
                      !Task.isCancelled,
                      operations.isAppActive(),
                      !operations.isReconnecting(),
                      let watched = operations.currentConnection()
                else {
                    return
                }

                let answered = await operations.ping(watched, Self.probeTimeout)
                guard !Task.isCancelled,
                      operations.currentConnection() === watched
                else {
                    return
                }
                if answered {
                    misses = 0
                    continue
                }

                misses += 1
                let missesNeeded = operations.isLocalRoute() ? 1 : 2
                guard misses >= missesNeeded else { continue }

                operations.log("link watchdog: the link stopped answering; dropping the socket")
                misses = 0
                await operations.dropDisconnectedSocket(watched)
                return
            }
        }
    }

    /// Stop the current watchdog and forget any partial miss sequence.
    func stop() {
        watchdog?.cancel()
        watchdog = nil
        misses = 0
    }
}
