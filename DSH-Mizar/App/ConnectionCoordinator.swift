import Foundation
import Observation
import MizarKit

/// Owns the active socket for one AppModel and identifies each adoption.
@MainActor
@Observable
final class ConnectionCoordinator {
    private(set) var activeConnection: MizarConnection?
    private(set) var generation = 0

    @discardableResult
    func install(_ connection: MizarConnection) -> Int {
        activeConnection = connection
        generation += 1
        return generation
    }

    /// Clears only the socket that is still active. Detaching never rewinds generation.
    @discardableResult
    func clear(ifMatching connection: AnyObject) -> Bool {
        guard activeConnection === connection else { return false }
        activeConnection = nil
        return true
    }

    func clear() {
        activeConnection = nil
    }

    struct Answered: Sendable {
        let endpoint: PairedHost.Endpoint
        let connection: MizarConnection
        let welcome: WelcomeFrame
    }

    struct Failure: Error, Sendable {
        let attempts: [(route: PairedHost.Endpoint, error: any Error)]
    }

    private enum DialResult: Sendable {
        case answered(Answered)
        case failed(route: PairedHost.Endpoint, error: any Error)
        case skipped
    }

    /// Runs the launch race; a cancelled handoff closes a winner that raced with cancellation.
    func firstAnswer(
        in dials: [(endpoint: PairedHost.Endpoint, connection: MizarConnection, delay: Duration)],
        onFailure: ((PairedHost.Endpoint, any Error) -> Void)? = nil,
    ) async throws -> Answered {
        var failures: [(route: PairedHost.Endpoint, error: any Error)] = []
        var winner: Answered?

        await withTaskGroup(of: DialResult.self) { group in
            for dial in dials {
                group.addTask {
                    if dial.delay > .zero {
                        do { try await Task.sleep(for: dial.delay) }
                        catch { return .skipped }
                    }
                    if Task.isCancelled { return .skipped }
                    do {
                        let welcome = try await dial.connection.connect()
                        return .answered(Answered(endpoint: dial.endpoint, connection: dial.connection, welcome: welcome))
                    } catch {
                        await dial.connection.disconnect()
                        return Task.isCancelled ? .skipped : .failed(route: dial.endpoint, error: error)
                    }
                }
            }
            for await result in group {
                switch result {
                case .answered(let answer):
                    guard winner == nil else {
                        await answer.connection.disconnect()
                        continue
                    }
                    winner = answer
                    group.cancelAll()
                case .failed(let route, let error):
                    guard winner == nil else { continue }
                    failures.append((route, error))
                    onFailure?(route, error)
                case .skipped:
                    break
                }
            }
        }

        if Task.isCancelled {
            if let winner { await winner.connection.disconnect() }
            throw CancellationError()
        }
        guard let winner else { throw Failure(attempts: failures) }
        return winner
    }
}
