//
//  LiveActivityController.swift
//  DSH-Mizar
//
//  The island, driven from this side of the wall.
//
//  Everything about *what* the activity shows was decided in `MizarKit` before
//  this file existed: `LiveActivityDecision.make` reads the running sessions and
//  answers with a phase and whether the activity should come down. This file
//  does three things and no fourth:
//
//    - **Derives the running sessions from what the app already knows.** A row in
//      `session.list` says a session is running; the app's own conversation cache
//      says what the operator asked it and when the turn began. No request is
//      made for any of it -- the island is a display of what the phone has, and a
//      display that only updates when the network answers is a display that stops
//      exactly when the computer is busy. The reading itself lives in
//      `RunningSession.running(in:conversations:titles:now:)`, shared with the
//      background refresh so the two cannot disagree about which row is up. The
//      title is not in `session.list`; it arrives with the usage frame, and this
//      file is where the app's title list is joined to the running sessions.
//
//    - **Asks the decision layer**, with the one flag it owns.
//
//    - **Makes the activity match, and keeps the address it can be ended at**:
//      `Activity.request` when there is none, `Activity.update` when there is,
//      `Activity.end` when the decision says so -- and nothing at all when the
//      operator has switched the feature off. The request carries
//      `pushType: .token`, so ActivityKit also issues the token that addresses
//      *this card*, and this file reads it (never observes it -- see
//      ``ActivityCalls``), leaves it in the app's push registration, and forgets
//      it the moment the card is gone. That address is how a card gets ended
//      while the app is suspended, which is the half of this problem no local
//      code can reach.
//
//  The ActivityKit calls themselves live in ``ActivityCalls`` at the bottom of
//  the file, and the split is not tidiness. `Activity` is not `Sendable` and its
//  `update`/`end` are nonisolated `async`, so a reference held by a main-actor
//  object cannot be handed to them: Swift 6's region checker refuses, correctly,
//  because the class could then be touched from two places at once. The
//  activities are therefore looked up *inside* those functions and never leave
//  them; what comes back is a line for the log.
//
//  ## Where an activity may be started from
//
//  Apple's rule is that *this app* starts a Live Activity from the **foreground**,
//  and that updating and ending one may happen in the background. (A card the
//  system starts on a push-to-start event is the other allowlisted way for one to
//  appear, and that is the paragraph below.) This file used to
//  ask from the background anyway, on the theory that what the documentation
//  forbids and what the system does are not the same question, and it logged the
//  app state with the answer. The answer never produced a card that appeared off
//  screen, and the attempt was a system call with no contract behind it on every
//  wake -- including the wake that has the least time to spare -- so the request
//  is now made only while the app is on screen. A background refresh still
//  updates and ends an activity that is already up; what it no longer does is try
//  to make one appear. The next foreground refresh is the retry, and that is why
//  there is no queue here and no "start owed" flag.
//
//  **The phone in a pocket can now get a card, and only through the host.** A
//  refresh that runs off screen (`BackgroundRefresh`) could always keep an
//  activity that is already up current; what it cannot do is make one appear.
//  That is push-to-start, and it is a different token from everything above:
//  `pushToStartTokenUpdates` issues one per *install* for starting activities,
//  `watchForRemoteStart()` keeps it, and `push.register` carries it as
//  `liveActivityStartToken`. With it the plugin can tell the relay to start a
//  card the moment a session begins -- while this app is suspended, with no code
//  of it running -- and that is the only path by which the island appears on a
//  phone nobody has opened. Everything this controller does stays the same
//  after that: a start event arrives as an activity that is already there, and
//  the next `refresh` adopts it, updates it, or ends it.
//
//  **Such a card is not end-addressable until this app runs.** An end push
//  addresses the activity's own token, and only this app ever learns that token
//  -- by reading `Activity.activities` while it is running. A card started
//  remotely therefore comes down here, on the first refresh that finds nothing
//  running, and not by an end push; the relay's end path still covers only the
//  cards this app started itself.
//
//  **The three tokens are not interchangeable.** The device token addresses the
//  phone's alerts. The activity token (`Activity.pushToken`, `pushType: .token`
//  on the request below) addresses one card and dies with it: it is how a card is
//  ended while this app is suspended. The push-to-start token addresses the
//  *next* card, which does not exist yet. Registering one does not conjure the
//  others.
//
//  ## The flag
//
//  `appOpenedSinceLastFinish` is the caller's half of the decision layer's
//  contract. It is set when the operator opens the app, and cleared when a
//  dismissal has been acted on. It is *also* cleared when a running phase is
//  applied, and that is worth stating plainly because it is the case the
//  contract's prose implies rather than spells out: the flag means "the operator
//  has opened the app **since the last running session ended**", and the moment a
//  session is running again, that sentence is no longer true of the opening that
//  set the flag. Left set, it would announce the next session's finish as one the
//  operator had already seen -- and the decision layer would answer "dismiss"
//  about an ending nobody witnessed.
//
//  The card comes down on a finish whether or not the operator has seen it (see
//  `apply`), so the flag no longer decides whether a check stays up. It is still
//  kept true, because it is the decision layer's answer to "was that finish
//  witnessed", and an answer it computes from a flag this file left lying would
//  be the wrong answer.
//

import ActivityKit
import Foundation
import MizarKit
import UIKit

/// Starts, updates and ends this app's Live Activity.
///
/// `@MainActor` because the app's state is: it reads `sessions` and the settings
/// object, which are main-actor values, and it is called from the same places
/// the rest of the app's state is changed.
@MainActor
final class LiveActivityController {
    /// What the operator has switched on. Read at every decision, never copied:
    /// the switch has to be able to say no to an activity that is already up.
    private let settings: AppSettings
    /// Where every attempt is written down, including the ones that failed and
    /// the app state they failed in.
    private let log: ActivityLog

    /// Whether the operator has opened the app since the last running session
    /// ended, and the activity has not been taken down for it yet.
    private var appOpenedSinceLastFinish = false

    /// The token checks that follow a start, when there are any.
    ///
    /// One task, replaced on every start and cancelled when the card comes down.
    /// The token is looked for on a small fixed schedule rather than observed --
    /// see ``ActivityCalls/pushToken`` for why there is no `AsyncSequence` here
    /// -- and a task that outlived its start would be a read of an activity that
    /// may not be the one it was scheduled for.
    private var pushTokenChecks: Task<Void, Never>?

    /// The subscription to the token that starts an activity from the host.
    ///
    /// One for the process, replaced by nothing, cancelled by nothing: it stops
    /// when this object goes away, and until then it is the app's only source of
    /// the address that makes a pocketed phone show the island.
    private var startTokenWatch: Task<Void, Never>?

    /// How long after a start to look for the token again.
    ///
    /// ActivityKit does not hand the token over with `request`: it is sometimes
    /// there when the call returns and sometimes a moment later, and there is no
    /// callback that says which. Three reads, bounded, and no polling after
    /// them: a later arrival is picked up by the next `refresh`, which runs on
    /// the running poll, on every sync, and when the app comes back to the
    /// foreground. Waiting longer on a task started for one card is how a phone
    /// that starts and ends activities accumulates tasks.
    private static let pushTokenCheckDelays: [Duration] = [.milliseconds(500), .seconds(2), .seconds(5)]

    /// - Parameters:
    ///   - settings: the live copy of the operator's switches.
    ///   - log: the app's activity log.
    init(settings: AppSettings = .shared, log: ActivityLog = .shared) {
        self.settings = settings
        self.log = log
    }

    // MARK: - What the app tells this object

    /// The operator has opened the app.
    ///
    /// Only the flag, with no decision taken: at launch the session list has not
    /// been read yet, and "nothing is running" must not be confused with "nothing
    /// has been read". The refresh that can act on the flag arrives with the
    /// session list, milliseconds later.
    func appOpened() {
        appOpenedSinceLastFinish = true
        // An activity started from the host, rather than from here, needs a
        // token iOS only issues after a launch. Subscribing at the moment the
        // app is opened is the earliest point where the subscription has
        // something to hear.
        watchForRemoteStart()
    }

    /// Watch for the token that can start an activity while this app is not
    /// running, and keep it where `push.register` reads it.
    ///
    /// Per install rather than per card, so this is one task for the life of the
    /// process: the sequence reports the token when it appears and when it
    /// rotates, and an activity ending says nothing about it. Elements are `Data`
    /// and the sequence hangs off the *type*, so unlike
    /// ``ActivityCalls/pushToken`` this can be consumed from a task without
    /// handing an `Activity` across an isolation boundary.
    private func watchForRemoteStart() {
        guard startTokenWatch == nil else { return }
        startTokenWatch = Task { [weak self] in
            for await token in Activity<DSHMizarActivityAttributes>.pushToStartTokenUpdates {
                guard !Task.isCancelled, let self else { return }
                let hex = LiveActivityPushToken.hex(token)
                if LiveActivityStartTokenStore.store(hex) {
                    // Length, never the token: see ``ActivityLog``.
                    self.log.add(.live, "live-activity start token: \(hex.count) characters")
                }
            }
        }
    }

    /// The operator is looking at the app, and the app knows what is running.
    ///
    /// - Parameters:
    ///   - sessions: the session list as the host last gave it.
    ///   - conversations: where the prompts and the running turns are kept.
    ///   - sessionsAreKnown: whether that list is something the host said, rather
    ///     than the empty array a model has before its first read.
    func appOpened(
        sessions: [SessionRow],
        conversations: any ConversationCache,
        sessionsAreKnown: Bool,
        titles: [String: String],
    ) async {
        appOpened()
        await refresh(
            sessions: sessions,
            conversations: conversations,
            sessionsAreKnown: sessionsAreKnown,
            titles: titles,
        )
    }

    /// Read what the app knows, decide, and make the activity match.
    ///
    /// Called after the session list arrives, after a conversation is folded into
    /// the cache, after a full sync, when the app comes to the foreground, and
    /// when the switch moves. Cheap enough to be called all of those times: it
    /// reads the local cache, and it asks ActivityKit for the state of the world
    /// rather than keeping a copy of it.
    ///
    /// Every call is also a chance to learn the activity's push token: it may
    /// arrive after the start that asked for it (the bounded retry covers the
    /// first few seconds) and it may disappear when the card does. See
    /// ``refreshPushToken()``.
    ///
    /// - Parameters:
    ///   - sessions: the session list as the host last gave it.
    ///   - conversations: where the prompts and the running turns are kept.
    ///   - sessionsAreKnown: whether that list is something the host said, rather
    ///     than the empty array a model has before its first read.
    ///   - titles: the app's title list, keyed by session id.
    ///   - approvals: the approvals the host last listed as pending. Carried
    ///     through rather than derived here: an approval is the operator's to
    ///     answer, and the card has to keep showing it while the app is open just
    ///     as it does while the app is asleep.
    ///   - now: the instant to measure the clocks to.
    func refresh(
        sessions: [SessionRow],
        conversations: any ConversationCache,
        sessionsAreKnown: Bool,
        titles: [String: String],
        approvals: [LiveActivityApproval] = [],
        now: Date = Date(),
    ) async {
        guard sessionsAreKnown else {
            // Nothing has been read yet: the list is empty because the app has
            // just started, not because the computer is idle, and the decision layer
            // cannot tell those apart from a list. Acting on the second one is not
            // hypothetical -- measured at launch, the foreground hook fires
            // before the first `session.list` comes back, an empty list read as
            // "everything finished and the app has been opened", and a running
            // activity was taken down and started again a fifth of a second
            // later.
            return
        }
        let running = await RunningSession.running(
            in: sessions,
            conversations: conversations,
            titles: titles,
            now: now,
        )
        let decision = LiveActivityDecision.make(
            sessions: running,
            approvals: approvals,
            appOpenedSinceLastFinish: appOpenedSinceLastFinish,
            now: now,
        )
        await apply(decision, runningRowCount: running.count)
        refreshPushToken()
    }

    /// Take the island down because the host it describes cannot keep it true.
    ///
    /// A card is a window onto a *computer's* running turn: it is kept current by
    /// pushes from that computer and by a background refresh that can reach it.
    /// The on-device agent has neither -- the kernel answers `push.register` with
    /// `{ registered: false }`, and a suspended app's own agent is stopped, not
    /// running -- so a card for it would be a clock nobody could stop. Ending any
    /// card left from the computer before the switch is the honest state.
    func endForLocalAgent() async {
        guard ActivityCalls.hasPresentable else { return }
        log.add(
            .live,
            await ActivityCalls.endAll(
                with: LiveActivityState(),
                why: "the on-device agent has no off-screen channel",
            ),
        )
        forgetPushToken()
    }

    // MARK: - Making the island match

    /// Carry out one decision.
    ///
    /// Two of the branches take the activity down, and both clear the stored push
    /// token as part of doing it: a token is an address for a card that is up, and
    /// one left behind is the host being told to push to a card that no longer
    /// exists. The token also changes while a card is up -- ActivityKit issues it
    /// after the request, and it may rotate -- so the `.running` branch reads it
    /// again on every refresh.
    ///
    /// - Parameters:
    ///   - decision: what to show, and whether to take the activity down.
    ///   - runningRowCount: how many sessions the decision was made from, for the
    ///     log only.
    private func apply(_ decision: LiveActivityDecision, runningRowCount: Int) async {
        // The switch first, before anything else looks at the decision. "Off"
        // has to mean off in the strong sense -- an activity already on screen is
        // the thing the operator was turning off -- and it is read here rather
        // than when the activity started, because a copy taken then is a switch
        // that only takes effect at the next launch.
        guard settings.values.liveActivitiesEnabled else {
            appOpenedSinceLastFinish = false
            guard ActivityCalls.hasPresentable else {
                forgetPushToken()
                return
            }
            log.add(.live, await ActivityCalls.endAll(with: decision.phase, why: "the operator switched it off"))
            forgetPushToken()
            return
        }

        if decision.shouldDismiss {
            // The operator has been back since the last finish, so anything still
            // up is a card whose moment has passed. With a finish now ending the
            // activity on the spot this is normally a dismissal of nothing, which
            // is why the emptiness check comes first: the log line is for the
            // times there *was* something left over.
            appOpenedSinceLastFinish = false
            guard ActivityCalls.hasPresentable else {
                forgetPushToken()
                return
            }
            log.add(.live, await ActivityCalls.endAll(with: decision.phase, why: "the app was opened after everything finished"))
            forgetPushToken()
            return
        }

        if decision.phase.isFinished {
            // Nothing is running, so nothing should be counting: the activity is
            // ended, not updated to the check. The check is what the island shows
            // *while* the activity comes down -- `.immediate` here means the card
            // is gone, which is the answer to "did my work finish" that this app
            // can actually give.
            //
            // Still never *started* from here: a check for work that stopped
            // before the activity existed is not worth a second look, which is
            // the decision layer's rule.
            guard ActivityCalls.hasPresentable else {
                forgetPushToken()
                return
            }
            log.add(.live, await ActivityCalls.endAll(with: decision.phase, why: "nothing is running any more"))
            forgetPushToken()
            return
        }

        // One card, not two. This app cannot start a second one -- the request
        // is guarded by `hasPresentable` -- but a start push can, because the
        // system creates that card while no code of this app is running. The
        // moment it runs is the first moment the duplicate is visible to
        // anybody, so it is the moment to take it down.
        if let line = await ActivityCalls.endSurplus(why: "a second card for the same computer") {
            log.add(.live, line)
        }
        // See the note at the top of the file: a session is running again, so
        // the opening the flag records is no longer "since the last finish".
        appOpenedSinceLastFinish = false
        let state = appStateWord
        guard ActivityCalls.hasPresentable else {
            // A card that is not up is started from the foreground, and only
            // from there. Asking from the background was the old behaviour:
            // the system does not start one for an app behind the screen, so
            // the attempt bought a log line and cost a system call on every
            // wake -- on the wake that has the least time to spare. The next
            // foreground refresh finds no activity and asks again.
            guard !isOffScreen else {
                log.add(.live, "not started: the app is off screen, and an activity starts in the foreground")
                return
            }
            log.add(.live, await ActivityCalls.start(decision.phase, appState: state, runningRowCount: runningRowCount))
            // The token is not part of the request's answer: it may be there
            // already and it may arrive a second from now, which is what the
            // bounded retry is for.
            capturePushToken()
            pollPushTokenAfterStart()
            return
        }
        if let line = await ActivityCalls.update(to: decision.phase, appState: state) { log.add(.live, line) }
        // Read on every refresh, not only after a start: the token may have
        // arrived since the last look, and a card the system ended underneath
        // this app leaves no other trace.
        capturePushToken()
    }

    // MARK: - The card's push token

    /// Look for the activity's push token once, and keep it if there is one.
    ///
    /// Synchronous on purpose. `Activity.pushToken` is a property, and the
    /// `AsyncSequence` that also reports it (`pushTokenUpdates`) would put an
    /// `Activity` -- which is not `Sendable` -- into a task, which is the one
    /// thing this file's design refuses to do. A property read is a lookup of the
    /// activity that is up and nothing held after: the activity object never
    /// leaves ``ActivityCalls``.
    ///
    /// - Returns: whether a token was found; `false` means "not issued yet",
    ///   which is an answer, not a failure.
    @discardableResult
    private func capturePushToken() -> Bool {
        guard let token = ActivityCalls.pushToken else { return false }
        if LiveActivityPushTokenStore.store(token) {
            // Length only: a push token is an address for this card, and this log
            // is exportable. The device token is recorded the same way.
            log.add(.live, "live activity push token: \(token.count) characters")
        }
        return true
    }

    /// Look again, a few times, for a token that was not there at the start.
    ///
    /// One task, on the main actor, sleeping between reads -- the bounded version
    /// of what the `AsyncSequence` would have done. It ends as soon as a token is
    /// found, as soon as the card is gone (a token read after the end would be an
    /// address for a card that is down), and after the last delay however things
    /// went, so a start that never produces a token cannot leave a task behind.
    private func pollPushTokenAfterStart() {
        // The previous start's task is about that start's token. Nothing else is
        // scheduled, ever: this is the only creator.
        pushTokenChecks?.cancel()
        pushTokenChecks = Task { [weak self] in
            for delay in Self.pushTokenCheckDelays {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, let self else { return }
                if self.capturePushToken() { return }
                guard ActivityCalls.hasPresentable else {
                    self.forgetPushToken()
                    return
                }
            }
        }
    }

    /// The stored token, as of the activity that is up right now.
    ///
    /// Called after every decision, and it covers the case no other branch does:
    /// an activity that was ended from somewhere else -- the operator's swipe on
    /// the Lock Screen, the system's own lifetime limit, the relay's end push --
    /// leaves the app holding a token for a card that is gone. Clearing it posts
    /// the notification that re-registers this phone without it, which is what
    /// stops the host pushing to a dead address.
    private func refreshPushToken() {
        guard ActivityCalls.hasPresentable else {
            forgetPushToken()
            return
        }
        capturePushToken()
    }

    /// Forget the token, and stop looking for another one.
    ///
    /// Idempotent: an unchanged value posts nothing, so every end path may call
    /// it without the app sending a registration per refresh.
    private func forgetPushToken() {
        pushTokenChecks?.cancel()
        pushTokenChecks = nil
        if LiveActivityPushTokenStore.store(nil) {
            log.add(.live, "live activity push token: forgotten, no activity is up")
        }
    }

    /// Where the app was when it asked ActivityKit for something.
    private var appStateWord: String {
        switch UIApplication.shared.applicationState {
        case .active: "foreground"
        case .inactive: "inactive"
        case .background: "background"
        @unknown default: "unknown"
        }
    }

    /// Whether the app is behind the screen right now.
    ///
    /// `.inactive` is not off screen: it is a transition -- the app switcher, a
    /// system sheet -- and the app has had the foreground, which is the condition
    /// ActivityKit's rule is about. `.background` is the only state in which a
    /// start is not attempted.
    private var isOffScreen: Bool {
        UIApplication.shared.applicationState == .background
    }
}

// MARK: - The ActivityKit side

/// Every call this app makes into ActivityKit.
///
/// Static methods on a caseless type rather than methods on the controller, for
/// one reason: nothing here touches the controller's state. Each function looks
/// up the activities itself, works with a `Sendable` phase, and answers with the
/// line to write in the log -- which is what keeps a non-`Sendable` `Activity`
/// from ever being handed across an isolation boundary.
///
/// The reads are synchronous -- `hasPresentable`, `pushToken`, and the lookup
/// under both -- because their answers are a `Bool` and a hex string, and the
/// activity that produced either is dropped inside the property. The async
/// functions are the ones whose ActivityKit methods are `async`.
private enum ActivityCalls {
    /// One activity of this app's one type.
    typealias Island = Activity<DSHMizarActivityAttributes>

    /// Whether an activity is on screen.
    ///
    /// A `Bool` rather than the activities themselves: the caller is the main
    /// actor, and the array may not leave here.
    static var hasPresentable: Bool {
        !presentable.isEmpty
    }

    /// The push token of the activity that is up, hex-encoded, or `nil`.
    ///
    /// **Read, never observed.** ActivityKit also offers the token as an
    /// `AsyncSequence` (`Activity.pushTokenUpdates`), and that is the API this
    /// file cannot use: its elements are not `Sendable`, and consuming it from a
    /// main-actor controller puts a non-`Sendable` `Activity` in a task, where
    /// Swift 6's region checker has to either refuse it or be lied to. A
    /// synchronous property read has neither problem -- the activity is looked up
    /// and dropped inside this property, and what comes out is the `String` the
    /// wire carries. The price is that the token's arrival has to be noticed by
    /// looking, which is what the controller's bounded retry after a start and
    /// its read on every refresh are for.
    ///
    /// - Returns: lowercase hex, or `nil` when no activity is up or the one that
    ///   is has not been issued a token yet.
    static var pushToken: String? {
        for activity in presentable {
            guard let token = activity.pushToken else { continue }
            return LiveActivityPushToken.hex(token)
        }
        return nil
    }

    /// The activities that are up right now.
    ///
    /// Filtered by state rather than taken whole: `activities` also returns the
    /// ones that have ended and are waiting to be cleared, and updating one of
    /// those is a request the system answers by ignoring it.
    private static var presentable: [Island] {
        Island.activities.filter { $0.activityState == .active || $0.activityState == .stale }
    }

    /// Ask for a new activity.
    ///
    /// Started with `pushType: .token` so ActivityKit issues the token that
    /// addresses this card -- the one the relay needs to end it while the app is
    /// suspended. That is the *activity's* token and not a push-to-start token;
    /// it cannot make an activity appear, only update or end one that exists.
    /// The token itself arrives later, sometimes a moment later, which is why
    /// ``pushToken`` is read again after this returns.
    ///
    /// - Parameters:
    ///   - phase: what it should show.
    ///   - appState: where the app was, for the log line.
    ///   - runningRowCount: how many sessions it was built from, for the log line.
    /// - Returns: what to write in the log.
    static func start(_ phase: LiveActivityState, appState: String, runningRowCount: Int) async -> String {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            // A different switch from the app's own: this one is iOS Settings >
            // DSH-Mizar > Live Activities. Nothing can be done about it here, and
            // the next refresh will find it in the same state.
            return "not started: Live Activities are off for this app in iOS Settings"
        }
        do {
            let activity = try Island.request(
                attributes: DSHMizarActivityAttributes(),
                content: ActivityContent(state: phase, staleDate: nil),
                pushType: .token,
            )
            return "started \(activity.id.prefix(8)) with \(describe(phase))"
                + " while the app was \(appState)"
        } catch {
            // Apple's rule is that an activity is started in the foreground, and
            // the caller checks for it before asking (see `isOffScreen`), so a
            // refusal here is the system's own limit or a transient failure --
            // recorded with the app state it happened in, and retried by the next
            // foreground refresh.
            return "could not start \(runningRowCount) running session(s) while the app was \(appState): \(describe(error))"
        }
    }

    /// Send every activity what it should be showing.
    ///
    /// Skipped when an activity already says it: the elapsed times move with the
    /// clock rather than with the host, so an update per read would be an update
    /// per read of a number nobody draws. See ``saysTheSame(_:as:)``.
    ///
    /// - Parameters:
    ///   - phase: what to show.
    ///   - appState: where the app was when it sent it. Carried here for the same
    ///     reason ``start(_:appState:runningRowCount:)`` carries it: whether an
    ///     update from the background actually lands is the measurement this
    ///     whole path exists to make, and the word has to be in the line to be
    ///     the evidence.
    /// - Returns: what to write in the log, or `nil` when there was nothing to do.
    static func update(to phase: LiveActivityState, appState: String) async -> String? {
        let content = ActivityContent(state: phase, staleDate: nil)
        var changed = 0
        for activity in presentable where !saysTheSame(activity, as: phase) {
            await activity.update(content)
            changed += 1
        }
        guard changed > 0 else { return nil }
        return "updated \(changed) activity while the app was \(appState): \(describe(phase))"
    }

    /// Take every activity of this type down.
    ///
    /// `Activity.activities`, not the presentable ones: an activity that has
    /// already ended is still on the Lock Screen until it is dismissed or the
    /// system clears it four hours later, and `.immediate` is what "the operator
    /// turned this off", "the app was opened" and "nothing is running any more"
    /// all mean.
    ///
    /// The stored push token is the caller's to forget: once the card is down the
    /// address is dead, and a host still holding it would keep sending end
    /// pushes to nothing.
    ///
    /// - Parameters:
    ///   - phase: the state to end with.
    ///   - why: what to write in the log.
    /// - Returns: what to write in the log.
    static func endAll(with phase: LiveActivityState, why: String) async -> String {
        let content = ActivityContent(state: phase, staleDate: nil)
        let all = Island.activities
        for activity in all {
            await activity.end(content, dismissalPolicy: .immediate)
        }
        return "ended \(all.count) activity: \(why)"
    }

    /// End every activity but one, when something has posted a second.
    ///
    /// A start push creates a card without this app, so the app cannot refuse
    /// it; what it can do is notice on the next run, and this is that. The
    /// content is about to be written to the survivor anyway, so which one is
    /// kept does not change what the operator sees -- only that there is one.
    ///
    /// - Parameter why: what to write in the log.
    /// - Returns: the line to write, or `nil` when there was only one activity.
    static func endSurplus(why: String) async -> String? {
        let all = presentable
        guard all.count > 1 else { return nil }
        var ended = 0
        for activity in all.dropFirst() {
            await activity.end(
                ActivityContent(state: LiveActivityState(), staleDate: nil),
                dismissalPolicy: .immediate,
            )
            ended += 1
        }
        return "ended \(ended) duplicate activity: \(why)"
    }

    /// Whether an activity already says this.
    ///
    /// `elapsed` is left out of the comparison and nothing else is: it is the one
    /// field that moves on its own -- the decision layer measures it to `now`, so
    /// two reads a second apart never produce equal rows -- while `countingSince`,
    /// the instant the widget's own ticking text counts from, is what the island
    /// actually says. A second of tolerance on it, because the figure the app
    /// seeds from arrives with whole-second resolution and the seed moves by a
    /// second on an ordinary sync.
    ///
    /// - Parameters:
    ///   - activity: the activity on screen.
    ///   - phase: what the decision layer says it should show.
    /// - Returns: whether there is nothing to send.
    private static func saysTheSame(_ activity: Island, as phase: LiveActivityState) -> Bool {
        let mine = activity.content.state.rows
        let theirs = phase.rows
        guard mine.count == theirs.count else { return false }
        return zip(mine, theirs).allSatisfy { current, next in
            current.id == next.id
                && current.prompt == next.prompt
                && current.title == next.title
                && abs(current.countingSince.timeIntervalSince(next.countingSince)) < 1
        }
    }

    /// What a phase contains, without the prompts.
    ///
    /// The rows are described by session id, whole: the log is exportable and the
    /// operator's instructions are deliberately left out of it, while "which
    /// session was on the island and how many rows were there" is the part that
    /// explains a wrong card. Ids are already all over the request log, so this
    /// says nothing the export did not already contain.
    ///
    /// - Parameter phase: the phase.
    /// - Returns: one line.
    private static func describe(_ phase: LiveActivityState) -> String {
        guard !phase.rows.isEmpty else { return "nothing running" }
        let described = phase.rows.map(\.id).joined(separator: ", ")
        return "\(phase.rows.count) row(s): \(described)"
    }

    /// An ActivityKit failure, as one line.
    ///
    /// `ActivityAuthorizationError`'s own description is the interesting part --
    /// `denied`, `unsupported`, `targetMaximumExceeded` -- so it is kept rather
    /// than flattened into "could not start".
    ///
    /// - Parameter error: what was thrown.
    /// - Returns: the description.
    private static func describe(_ error: any Error) -> String {
        (error as? ActivityAuthorizationError).map(String.init(describing:)) ?? error.localizedDescription
    }
}
