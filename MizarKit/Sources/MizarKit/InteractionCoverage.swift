//
//  InteractionCoverage.swift
//  MizarKit
//
//  Whether a notification is about a card this phone is already drawing.
//
//  The host used to answer this question itself, by leaving out every device
//  that had reported itself on screen. That report is asynchronous: iOS
//  suspends the process between the scene change and the `push.presence` call,
//  so a phone that went to the lock screen seconds after its last report stayed
//  in the host's "on screen" set for minutes. An approval or a question raised
//  in that window was pushed to nobody, the agent waited on a card no screen
//  could show, and the operator only found out when the turn looked stuck.
//
//  So the host now notifies every registered phone and this is the piece that
//  keeps the operator from being told twice: the phone knows what it is drawing,
//  the host cannot know what the phone is showing.
//

import Foundation

/// Whether the app already has the operator's eyes on this interaction.
public enum InteractionCoverage {
    /// Whether a notification of `kind` about `sessionId` is already on screen.
    ///
    /// Only a question or an approval can be "already on screen": a turn-ended
    /// notice is about a card that has gone, so it is never covered.
    ///
    /// The match is deliberately **strict**, and the reason is what makes the
    /// suppression safe: a card this test cannot place may not be drawn at all.
    /// The deck shows the open conversation's card and the home screen shows
    /// everything, so a sessionless request -- or one naming a conversation this
    /// phone does not have -- can sit in the pending set with nothing on screen
    /// to show for it. Suppressing its banner would leave the operator with
    /// neither a card nor a notification, which is the exact failure this whole
    /// path exists to prevent. So a request is only covered when both sides name
    /// the same session; anything less is presented.
    ///
    /// - Parameters:
    ///   - kind: what the notification is about, as the app classifies it.
    ///   - sessionId: the session the notification names, when it names one.
    ///   - pending: what the phone holds right now, or `nil` when it has not
    ///     read the pending set yet.
    /// - Returns: `true` when the matching card is held for that same session,
    ///   so a banner would be the second time the operator is told about one
    ///   request.
    public static func covers(
        _ kind: NotificationKind?,
        sessionId: String?,
        pending: PendingInteractions?,
    ) -> Bool {
        guard let pending, let wanted = sessionId, !wanted.isEmpty else { return false }
        /// A question and an approval of the same session are different cards.
        func holds(_ cardSession: String?) -> Bool {
            guard let cardSession else { return false }
            return cardSession == wanted
        }
        switch kind {
        case .question:
            return pending.questions.contains { holds($0.sessionId) }
        case .approval:
            return pending.approvals.contains { holds($0.sessionId) }
        default:
            return false
        }
    }
}
