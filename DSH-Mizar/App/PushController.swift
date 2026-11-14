//
//  PushController.swift
//  DSH-Mizar
//
//  This phone's end of a notification.
//
//  Three things, and each is somewhere SwiftUI has no hook:
//
//    1. **The device token.** iOS hands it to the `UIApplicationDelegate` and
//       nowhere else, so an adaptor is the only way to get one at all.
//    2. **What a notification looks like while the app is open.** Without a
//       `UNUserNotificationCenterDelegate`, iOS shows nothing at all for a
//       notification that arrives in the foreground -- so an approval asked for
//       while the operator is reading a different session would be silently
//       swallowed.
//    3. **What a tap does.** A notification that opens the app and leaves the
//       operator on the session list is a notification that wasted a tap.
//

import Foundation
import UIKit
import UserNotifications
import MizarKit

/// The application delegate, for the parts SwiftUI cannot reach.
final class PushAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    /// Posted when iOS issues a device token, with the token as the object.
    static let tokenReceived = Notification.Name("mizar.push.token")

    /// Posted when the operator taps a notification, with the session id.
    static let openSession = Notification.Name("mizar.push.open")

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil,
    ) -> Bool {
        // A tap on a notification can be what launched this process, and the
        // session it names is in the launch options before any view exists.
        // It is stashed rather than posted: a post made now would arrive with
        // no subscriber -- the root view is not mounted yet -- which is the
        // tap that opens the app on the session list. `didReceive` below
        // stashes the same fact, so whichever of the two iOS uses, one is
        // enough.
        //
        // `assumeIsolated` rather than a hop: UIKit calls every application
        // delegate method on the main thread, and a `Task` here would race the
        // first frame it exists to inform.
        if let userInfo = options?[.remoteNotification] as? [AnyHashable: Any],
           let sessionId = userInfo["sessionId"] as? String,
           !sessionId.isEmpty {
            MainActor.assumeIsolated {
                PendingPushSession.stash(sessionId)
            }
        }
        // Before anything can arrive. iOS does not queue a foreground
        // notification for a delegate that is set later.
        UNUserNotificationCenter.current().delegate = self
        // And before this method returns, which is the other deadline UIKit
        // sets: a background task handler registered later than launch is a
        // handler the system does not know about when it prepares the wake.
        BackgroundRefresh.shared.register()
        // Push-to-start wakes the app in the background to create the activity.
        // That wake is the only chance to learn the activity token before the
        // session finishes; without this, a card created while the phone was in
        // a pocket has no address the relay can end.
        // A push-to-start wake may still be `.inactive` while the delegate is
        // running. Check again once the launch has settled; a normal foreground
        // launch has become `.active` by then and is left to RootView's start.
        Task {
            try? await Task.sleep(for: .seconds(1))
            guard UIApplication.shared.applicationState != .active else { return }
            await AppModel.shared.registerPushInBackground()
        }
        return true
    }

    /// A silent end push is the one notification that must work with no screen.
    ///
    /// The relay sends this beside the activity-token end. It carries no alert
    /// and no content: its only job is the background wake, after which the app
    /// can enumerate its own ActivityKit cards and end the one that is done.
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void,
    ) {
        guard userInfo["mizarEndLiveActivity"] as? Bool == true else {
            completionHandler(.noData)
            return
        }
        Task { @MainActor in
            await AppModel.shared.endLiveActivitiesFromPush()
            completionHandler(.newData)
        }
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data,
    ) {
        // Lowercase hex, which is what APNs and the relay both expect. `%02x`
        // over the bytes, not `description` over the `Data`: the latter gives
        // "<0a1b2c…>", which is not a token.
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        PushRegistration.storedToken = token
        NotificationCenter.default.post(name: Self.tokenReceived, object: token)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error,
    ) {
        // Deliberately quiet. The two ways this fails are a simulator without a
        // push-capable runtime and a device whose provisioning profile has no
        // `aps-environment` entitlement, and neither is something the operator
        // can act on from a phone -- but both are worth a line in the device
        // log, which is where a "why is it silent" question gets answered.
        NSLog("[mizar] remote notifications unavailable: %@", String(describing: error))
    }

    /// Show a notification that arrives while the app is open -- or drop it,
    /// because the operator switched that kind off.
    ///
    /// Without this, iOS shows nothing for a foreground notification. The plugin
    /// declines to send while the app reports itself in the foreground, which
    /// covers most of it -- but the report is a round trip, and an approval
    /// asked for in the second between the app opening and the computer hearing about
    /// it would otherwise vanish.
    ///
    /// This is also where the four switches in the settings screen mean
    /// something. The relay copies the plugin's `kind` into the payload, so the
    /// decision is made here, on the phone, at the moment the notification
    /// arrives -- not by asking the computer to stop sending, which would need a round
    /// trip, a protocol change and a host that believed the phone. Reading
    /// `AppSettings.shared` at delivery time rather than caching it is what makes
    /// a switch take effect on the next notification instead of the next launch.
    ///
    /// A question or an approval the phone is **already drawing** is the other
    /// thing that keeps a banner off the screen, and it is here rather than on
    /// the computer because only the phone knows it. The host used to leave such
    /// a device out of the push entirely, on the strength of a `push.presence`
    /// report that iOS can leave behind when it suspends the app -- so a phone
    /// that went to the lock screen seconds after reporting itself on screen
    /// received nothing at all, and the agent sat blocked on a card no screen
    /// showed. See ``InteractionCoverage``.
    ///
    /// The two strings are read out of the notification here, before the hop to
    /// the main queue: `UNNotification` and its `userInfo` are not `Sendable`,
    /// and only a `String` and the classified kind need to cross.
    ///
    /// The completion handler is explicit rather than the `async` form, and it
    /// is called on the main queue. The async form's compiler-generated bridge
    /// calls the system's completion handler on a cooperative background queue
    /// after the body returns -- the body being on the main actor says nothing
    /// about where the completion lands -- and that is the callback UIKit's
    /// state-restoration archive runs behind (measured with the protocol probe
    /// recorded in `docs/ios-push-diagnosis-notes.md`: the body completes on the
    /// main thread, the async completion does not).
    ///
    /// One limit worth stating: a notification that arrives while the app is in
    /// the background is delivered by iOS without asking this delegate anything,
    /// so this suppresses what would appear over the app, and the switches
    /// describe what the operator wants to see rather than what the computer sends.
    /// Filtering the background case is the host's side of the wire.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void,
    ) {
        let content = notification.request.content
        let userInfo = content.userInfo
        let kind = NotificationKind.classify(
            kind: userInfo["kind"] as? String,
            title: content.title,
            reason: userInfo["reason"] as? String,
        )
        let described = kind?.rawValue ?? (userInfo["kind"] as? String ?? "unknown")
        // Read off the notification before the hop: `userInfo` is not `Sendable`,
        // and only a `String` needs to cross.
        let sessionID = userInfo["sessionId"] as? String
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let wanted = kind.map(AppSettings.shared.isEnabled) ?? true
                // The host no longer leaves out a phone that reported itself on
                // screen -- iOS suspends the process before that report can be
                // corrected, and the exclusion was swallowing the only wake-up
                // an approval or a question ever sends. The duplicate is dropped
                // here instead, where the truth is: if the matching card is
                // already in front of the operator, this banner would be the
                // second time they are told about one request.
                let covered = InteractionCoverage.covers(
                    kind,
                    sessionId: sessionID,
                    pending: AppModel.shared.pending,
                )
                ActivityLog.shared.add(
                    .push,
                    !wanted
                        ? "suppressed \(described): switched off in settings"
                        : covered
                            ? "suppressed \(described): already on screen"
                            : "presented \(described)",
                )
                // One exit, exactly once: the switch decision and the
                // completion are the same main-queue step, so there is no
                // branch that can answer twice -- or not at all.
                completionHandler(wanted && !covered ? [.banner, .list, .sound] : [])
            }
        }
    }

    /// Open the session the notification was about.
    ///
    /// The completion handler is explicit rather than the `async` form, and it
    /// is called on the main queue -- see
    /// ``userNotificationCenter(_:willPresent:withCompletionHandler:)`` for why:
    /// the async bridge completes on a background queue, and two crash reports
    /// (`docs/ios-push-diagnosis-notes.md` §2) put UIKit's state-restoration
    /// assertion directly behind this callback.
    ///
    /// Only the `sessionId` crosses into the main-queue block: the response and
    /// its `userInfo` are not `Sendable`, and nothing here waits for the
    /// network, the cache or the account -- the callback being answered and the
    /// session being loaded are two different conditions.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping @Sendable () -> Void,
    ) {
        let sessionID = response.notification.request.content
            .userInfo["sessionId"] as? String

        DispatchQueue.main.async {
            defer { completionHandler() }
            MainActor.assumeIsolated {
                guard let sessionID, !sessionID.isEmpty else { return }
                ActivityLog.shared.add(.push, "opened from a notification: session \(sessionID)")
                // Kept as well as posted. A cold launch can deliver this before
                // the root view is mounted, and a post with no subscriber is gone;
                // the root view takes what is waiting when it appears, and a tap
                // that arrived with the view already up clears it on its way
                // through the publisher. Either order opens the session once.
                PendingPushSession.stash(sessionID)
                NotificationCenter.default.post(name: Self.openSession, object: sessionID)
            }
        }
    }
}

/// A session a notification asked to open, held until a view can receive it.
///
/// A tap is delivered by UIKit, and its delivery is not ordered against the
/// app's first frame: a cold launch can be told to open a session before
/// SwiftUI has mounted the root view, and a `NotificationCenter` post made
/// then has no subscriber to hear it -- the app opens on the session list,
/// which is the one tap this whole path exists to spend well. So the delegate
/// writes the request here as well as posting it, and the root view takes it
/// when it appears. Whichever of the two arrives first, the session is opened
/// once: the post's receiver clears this on its way through.
///
/// Main-actor state, and deliberately not persisted: it is a request about the
/// frame that is about to be drawn, and a request that outlived the process
/// would open a session days later.
@MainActor
enum PendingPushSession {
    /// The session the last unread notification named, or `nil`.
    private static var sessionId: String?

    /// Remember a session a notification asked for.
    /// - Parameter id: the session.
    static func stash(_ id: String) {
        sessionId = id
    }

    /// Take the remembered session, forgetting it.
    /// - Returns: the session, or `nil` when nothing is waiting.
    static func take() -> String? {
        defer { sessionId = nil }
        return sessionId
    }
}

/// What this phone has told the host about itself.
enum PushRegistration {
    /// Where the token is kept.
    ///
    /// `UserDefaults`, not the Keychain: a device token is not a secret -- it is
    /// an address Apple issued to this install, useless without the provider key
    /// that signs for it -- and the Keychain survives a reinstall, which would
    /// leave a token that no longer exists being re-registered forever.
    private static let tokenKey = "mizar.pushToken"

    static var storedToken: String? {
        get { UserDefaults.standard.string(forKey: tokenKey) }
        set {
            if let newValue { UserDefaults.standard.set(newValue, forKey: tokenKey) }
            else { UserDefaults.standard.removeObject(forKey: tokenKey) }
        }
    }

    /// Which APNs service issued this build's tokens.
    ///
    /// A Release build gets production tokens and a development-signed build
    /// gets sandbox ones -- but the question is answered by the signature, not
    /// by the compiler. `#if DEBUG` used to decide, and a Release build
    /// installed from Xcode is optimised (`DEBUG` off) while still signed for
    /// development: it said production for a sandbox token, Apple refused every
    /// push with `BadDeviceToken`, and the card on the Lock Screen could never
    /// be updated or ended. See `Distribution.apsEnvironment`, which reads the
    /// value out of the profile that signed the build.
    ///
    /// The two services do not accept each other's tokens, and the relay has to
    /// be told which one to talk to -- see `docs/relay-deployment.md` §10.2. A
    /// wrong answer is now survivable rather than silent: the relay asks the
    /// other Apple once and remembers the answer (`dsh-relay/src/push.ts`).
    static var environment: String {
        #if DEBUG
        // A debug build is development-signed by definition, and the simulator
        // has no profile to ask. The compiler is the one source that answers
        // there.
        return "sandbox"
        #else
        // No profile means no embedded signature: an App Store or TestFlight
        // install, both of which use production.
        return Distribution.apsEnvironment ?? "production"
        #endif
    }

    /// The language to write notifications in.
    ///
    /// The first preferred language, which is what the app's own interface is
    /// already following -- a notification in a different language from the
    /// screen it opens is worse than either.
    static var locale: String {
        Locale.preferredLanguages.first ?? "en"
    }
}
