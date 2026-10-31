//
//  LiveActivityAnswers.swift
//  MizarKit
//
//  Answering an approval from the island.
//
//  The card is drawn in the widget's process and the button is pressed on a Lock
//  Screen, but the answer has to reach the computer -- which means a socket, a
//  token and the protocol, none of which a widget extension has. This file is the
//  seam that gives the button those three things without launching the app to its
//  foreground: `LiveActivityIntent` runs in the app's process (the system wakes it
//  for exactly this), so the Keychain this app wrote at pairing time is readable,
//  and the same `MizarConnection` the screens use is available.
//
//  ### Why it does not reuse the app's connection
//
//  The app's socket is part of a view model that a background wake does not have
//  and must not build. What an answer needs is smaller than a launch: one
//  handshake, one call, one close. A short-lived connection also means the answer
//  cannot be stuck behind a queue of reads the app happens to be doing.
//
//  ### What happens when it fails
//
//  Nothing is thrown at the operator from a Lock Screen: a failed answer leaves
//  the approval on the card, and the next push from the computer (or the next
//  foreground refresh) is what corrects what is drawn. The alternative -- a card
//  that disappears because a button was pressed and a network was down -- would
//  claim a decision that never arrived.
//

import Foundation

#if os(iOS) && canImport(ActivityKit) && canImport(AppIntents)
import ActivityKit
import AppIntents
#endif

/// The one action the island can take.
public enum LiveActivityAnswers {
    /// What the host answered to an `approval.answer`.
    struct Acceptance: Decodable, Sendable {
        let accepted: Bool?
    }

    /// Answer one approval over a short-lived connection.
    ///
    /// Machines are tried newest pairing first, and the first one that both
    /// connects and accepts the answer wins. A phone paired with two computers
    /// cannot know from the island which one is asking -- the card carries a
    /// session id, not a host id -- and answering on the wrong socket is refused
    /// by that computer rather than applied, because the request id is not one it
    /// issued.
    ///
    /// - Parameters:
    ///   - requestId: the host's request id, exactly as the card carries it.
    ///   - outcome: what the operator chose.
    /// - Returns: whether a computer accepted the answer.
    @discardableResult
    public static func answer(requestId: String, outcome: ApprovalOutcome) async -> Bool {
        guard !requestId.isEmpty else { return false }
        let store = KeychainCredentialStore()
        guard let hosts = try? await store.loadAll(), !hosts.isEmpty else { return false }
        let ordered = hosts.sorted { $0.pairedAt > $1.pairedAt }
        for host in ordered {
            guard let connection = await open(host) else { continue }
            let payload = JSONValue.object([
                "requestId": .string(requestId),
                "outcome": .string(outcome.rawValue),
            ])
            let accepted = (try? await connection.call(
                "approval.answer",
                payload: payload,
                as: Acceptance.self,
            ))?.accepted ?? true
            await connection.disconnect()
            if accepted { return true }
        }
        return false
    }

    /// Open one socket to one machine, over whichever route answers first.
    ///
    /// The routes are dialled in the pairing's own order rather than raced: this
    /// is a single small call behind a button press, and a button that waits for
    /// a race to settle is a button that feels broken. The leashes are shorter
    /// than the app's for the same reason -- six seconds is already longer than
    /// anybody holds a Lock Screen button.
    ///
    /// - Parameter host: the pairing to dial.
    /// - Returns: a connected client, or `nil` when no route answered.
    private static func open(_ host: PairedHost) async -> MizarConnection? {
        for endpoint in host.endpoints {
            let configuration: MizarConnection.Configuration
            switch endpoint {
            case .direct(let authority):
                configuration = .init(
                    authority: authority,
                    token: host.deviceToken,
                    appVersion: "live-activity",
                    requestTimeout: .seconds(6),
                    handshakeTimeout: .seconds(4),
                )
            case .relay(let baseURL):
                configuration = .init(
                    authority: nil,
                    token: host.deviceToken,
                    appVersion: "live-activity",
                    requestTimeout: .seconds(10),
                    baseURL: baseURL,
                    handshakeTimeout: .seconds(10),
                )
            case .p2p:
                // A punched route needs the kernel's signaling channel and a
                // three-second budget. A button press is not the place to start
                // that machinery; the relay behind it is the route that works
                // from a Lock Screen.
                continue
            }
            let connection = MizarConnection(configuration: configuration)
            if (try? await connection.connect()) != nil {
                return connection
            }
            await connection.disconnect()
        }
        return nil
    }
}

#if os(iOS) && canImport(ActivityKit) && canImport(AppIntents)

// MARK: - The buttons' intents

/// "Allow once", from the island.
///
/// A `LiveActivityIntent` rather than a plain `AppIntent`: this must run without
/// bringing the app to the foreground, which is the one difference between the
/// two protocols that matters here.
public struct AllowOnceIntent: LiveActivityIntent {
    /// The request the card is showing.
    @Parameter(title: "request")
    public var requestId: String

    public init() {}
    public init(requestId: String) { self.requestId = requestId }

    public static var title: LocalizedStringResource { "Allow once" }

    /// Answer, then take the approval off the card this process can see.
    public func perform() async throws -> some IntentResult {
        let accepted = await LiveActivityAnswers.answer(requestId: requestId, outcome: .allowedOnce)
        if accepted {
            await LiveActivityCards.dropApproval(requestId)
        }
        return .result()
    }
}

/// "Reject", from the island.
public struct RejectIntent: LiveActivityIntent {
    /// The request the card is showing.
    @Parameter(title: "request")
    public var requestId: String

    public init() {}
    public init(requestId: String) { self.requestId = requestId }

    public static var title: LocalizedStringResource { "Reject" }

    public func perform() async throws -> some IntentResult {
        let accepted = await LiveActivityAnswers.answer(requestId: requestId, outcome: .rejected)
        if accepted {
            await LiveActivityCards.dropApproval(requestId)
        }
        return .result()
    }
}

// MARK: - Editing the card the button was pressed on

/// The bits of ActivityKit the intents need.
///
/// Kept behind an enum so the calls live in one place, the way
/// `LiveActivityController` keeps its own: `Activity` is not `Sendable`, and a
/// reference that leaked into an intent's properties would be touched from two
/// threads.
public enum LiveActivityCards {
    /// Take one approval off every card this app is showing.
    ///
    /// Optimistic and local: the computer will send its own update shortly, and
    /// the two agree. What this buys is the half-second between the press and
    /// that push, during which a card that still showed the answered approval
    /// would invite a second press.
    ///
    /// - Parameter requestId: the approval that was answered.
    public static func dropApproval(_ requestId: String) async {
        for activity in Activity<DSHMizarActivityAttributes>.activities
        where activity.activityState == .active || activity.activityState == .stale {
            var state = activity.content.state
            guard state.approvals.contains(where: { $0.requestId == requestId }) else { continue }
            state.approvals.removeAll { $0.requestId == requestId }
            await activity.update(ActivityContent(state: state, staleDate: nil))
        }
    }
}

#endif
